// Host discovery (PROTOCOL.md §1): mDNS `_orbit._tcp` via bonsoir, plus the
// `ORBIT?1` UDP broadcast fallback. Results are merged by hostId.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:bonsoir/bonsoir.dart';
import 'package:flutter/foundation.dart';

import 'protocol.dart';

enum DiscoverySource { mdns, broadcast }

@immutable
class DiscoveredHost {
  const DiscoveredHost({
    required this.id,
    required this.name,
    required this.os,
    required this.address,
    required this.port,
    required this.lastSeen,
    required this.sources,
  });

  /// hostId hex (32 chars).
  final String id;
  final String name;
  final HostOs os;

  /// IP literal usable with Socket.connect / RawDatagramSocket.send.
  final String address;
  final int port;
  final DateTime lastSeen;
  final Set<DiscoverySource> sources;

  DiscoveredHost merge(DiscoveredHost other) => DiscoveredHost(
        id: id,
        name: other.name.isNotEmpty ? other.name : name,
        os: other.os,
        address: other.address.isNotEmpty ? other.address : address,
        port: other.port,
        lastSeen: other.lastSeen.isAfter(lastSeen) ? other.lastSeen : lastSeen,
        sources: <DiscoverySource>{...sources, ...other.sources},
      );
}

class HostDiscovery extends ChangeNotifier {
  HostDiscovery({this.enableBroadcast = true});

  final bool enableBroadcast;

  final Map<String, DiscoveredHost> _hosts = <String, DiscoveredHost>{};

  /// mDNS service name → hostId (the "lost" event only carries the name).
  final Map<String, String> _serviceNameToId = <String, String>{};

  BonsoirDiscovery? _bonsoir;
  StreamSubscription<BonsoirDiscoveryEvent>? _bonsoirSub;
  RawDatagramSocket? _udp;
  StreamSubscription<RawSocketEvent>? _udpSub;
  Timer? _probeTimer;
  Timer? _expiryTimer;
  bool _running = false;
  bool _disposed = false;

  bool get running => _running;

  List<DiscoveredHost> get hosts {
    final list = _hosts.values.toList()
      ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    return list;
  }

  DiscoveredHost? byId(String id) => _hosts[id];

  Future<void> start() async {
    if (_running || _disposed) return;
    _running = true;
    _expiryTimer = Timer.periodic(const Duration(seconds: 5), (_) => _expire());
    await Future.wait<void>(<Future<void>>[
      _startMdns(),
      if (enableBroadcast) _startBroadcast(),
    ]);
  }

  Future<void> stop() async {
    _running = false;
    _probeTimer?.cancel();
    _probeTimer = null;
    _expiryTimer?.cancel();
    _expiryTimer = null;
    await _udpSub?.cancel();
    _udpSub = null;
    _udp?.close();
    _udp = null;
    await _bonsoirSub?.cancel();
    _bonsoirSub = null;
    final b = _bonsoir;
    _bonsoir = null;
    if (b != null) {
      try {
        await b.stop();
      } catch (_) {
        // Already stopped.
      }
    }
  }

  /// Sends a broadcast probe right now (e.g. on pull-to-refresh).
  void probe() => _sendProbe();

  // ---------------------------------------------------------------- mDNS

  Future<void> _startMdns() async {
    try {
      final discovery = BonsoirDiscovery(type: Proto.serviceType);
      _bonsoir = discovery;
      await discovery.ready;
      if (!_running) return;
      _bonsoirSub = discovery.eventStream?.listen(
        _onMdnsEvent,
        onError: (Object e) => debugPrint('AirWand mDNS error: $e'),
      );
      await discovery.start();
    } catch (e) {
      debugPrint('AirWand: mDNS discovery unavailable: $e');
    }
  }

  void _onMdnsEvent(BonsoirDiscoveryEvent event) {
    final service = event.service;
    if (service == null) return;
    final type = event.type;
    if (type == BonsoirDiscoveryEventType.discoveryServiceFound) {
      final b = _bonsoir;
      if (b != null) service.resolve(b.serviceResolver);
    } else if (type == BonsoirDiscoveryEventType.discoveryServiceResolved) {
      if (service is ResolvedBonsoirService) _onResolved(service);
    } else if (type == BonsoirDiscoveryEventType.discoveryServiceLost) {
      final id = _serviceNameToId.remove(service.name);
      if (id == null) return;
      final h = _hosts[id];
      if (h == null) return;
      final sources = <DiscoverySource>{...h.sources}
        ..remove(DiscoverySource.mdns);
      if (sources.isEmpty) {
        _hosts.remove(id);
      } else {
        _hosts[id] = DiscoveredHost(
          id: h.id,
          name: h.name,
          os: h.os,
          address: h.address,
          port: h.port,
          lastSeen: h.lastSeen,
          sources: sources,
        );
      }
      _notify();
    }
  }

  Future<void> _onResolved(ResolvedBonsoirService service) async {
    final attrs = service.attributes;
    final id = (attrs['id'] ?? '').toLowerCase();
    if (id.length != Proto.idLength * 2) return;
    final v = attrs['v'];
    if (v != null && v != '${Proto.version}') return;
    final address = await _toIp(service.host);
    if (address == null || !_running) return;
    _serviceNameToId[service.name] = id;
    _upsert(DiscoveredHost(
      id: id,
      name: (attrs['name']?.isNotEmpty ?? false) ? attrs['name']! : service.name,
      os: HostOs.parse(attrs['os']),
      address: address,
      port: service.port > 0 ? service.port : Proto.port,
      lastSeen: DateTime.now(),
      sources: const <DiscoverySource>{DiscoverySource.mdns},
    ));
  }

  /// bonsoir reports either an IP literal or a `.local` host name.
  static Future<String?> _toIp(String? host) async {
    if (host == null || host.isEmpty) return null;
    var h = host.trim();
    final pct = h.indexOf('%'); // strip IPv6 zone id
    if (pct > 0) h = h.substring(0, pct);
    if (h.endsWith('.')) h = h.substring(0, h.length - 1);
    final literal = InternetAddress.tryParse(h);
    if (literal != null) {
      // Link-local IPv6 without a zone is not routable; skip it.
      if (literal.type == InternetAddressType.IPv6 && literal.isLinkLocal) {
        return null;
      }
      return literal.address;
    }
    try {
      final found = await InternetAddress.lookup(h)
          .timeout(const Duration(seconds: 3));
      final v4 = found.where((a) => a.type == InternetAddressType.IPv4);
      if (v4.isNotEmpty) return v4.first.address;
      return found.isNotEmpty ? found.first.address : null;
    } catch (_) {
      return null;
    }
  }

  // ----------------------------------------------------- UDP broadcast

  Future<void> _startBroadcast() async {
    try {
      final socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      if (!_running) {
        socket.close();
        return;
      }
      socket.broadcastEnabled = true;
      _udp = socket;
      _udpSub = socket.listen((event) {
        if (event != RawSocketEvent.read) return;
        while (true) {
          final d = socket.receive();
          if (d == null) break;
          _onBroadcastReply(d);
        }
      }, onError: (Object e) => debugPrint('AirWand UDP discovery error: $e'));
      _sendProbe();
      _probeTimer = Timer.periodic(
        const Duration(seconds: 2),
        (_) => _sendProbe(),
      );
    } catch (e) {
      debugPrint('AirWand: UDP discovery unavailable: $e');
    }
  }

  void _sendProbe() {
    final s = _udp;
    if (s == null) return;
    try {
      s.send(
        ascii.encode(Proto.discoveryProbe),
        InternetAddress('255.255.255.255'),
        Proto.port,
      );
    } catch (e) {
      // iOS needs the multicast entitlement to broadcast; mDNS still works.
      debugPrint('AirWand: broadcast probe failed: $e');
    }
  }

  void _onBroadcastReply(Datagram d) {
    try {
      final json = jsonDecode(utf8.decode(d.data));
      if (json is! Map || json['t'] != 'here') return;
      if ((json['v'] as num?)?.toInt() != Proto.version) return;
      final id = (json['id'] as String? ?? '').toLowerCase();
      if (id.length != Proto.idLength * 2) return;
      _upsert(DiscoveredHost(
        id: id,
        name: (json['name'] as String?) ?? 'Computer',
        os: HostOs.parse(json['os']),
        address: d.address.address,
        port: (json['port'] as num?)?.toInt() ?? Proto.port,
        lastSeen: DateTime.now(),
        sources: const <DiscoverySource>{DiscoverySource.broadcast},
      ));
    } catch (_) {
      // Not an AirWand reply; ignore.
    }
  }

  // ------------------------------------------------------------- merge

  void _upsert(DiscoveredHost h) {
    final old = _hosts[h.id];
    _hosts[h.id] = old == null ? h : old.merge(h);
    _notify();
  }

  /// Broadcast-only entries expire if not refreshed; mDNS has explicit "lost".
  void _expire() {
    final cutoff = DateTime.now().subtract(const Duration(seconds: 9));
    final stale = _hosts.values
        .where((h) =>
            !h.sources.contains(DiscoverySource.mdns) &&
            h.lastSeen.isBefore(cutoff))
        .map((h) => h.id)
        .toList();
    if (stale.isEmpty) return;
    stale.forEach(_hosts.remove);
    _notify();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    stop();
    super.dispose();
  }
}
