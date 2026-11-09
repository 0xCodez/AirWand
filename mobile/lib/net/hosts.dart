// Paired host store: which computers this phone may control, their keys,
// last-known address, and which one is active.

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart'
    show ChangeNotifier, debugPrint, immutable;
import 'package:shared_preferences/shared_preferences.dart';

import 'protocol.dart';

@immutable
class PairedHost {
  const PairedHost({
    required this.id,
    required this.name,
    required this.os,
    required this.address,
    required this.port,
    required this.key,
    required this.pairedAt,
  });

  /// hostId, 32-char lowercase hex.
  final String id;
  final String name;
  final HostOs os;

  /// Last known IPv4/IPv6 literal (or resolvable host name).
  final String address;
  final int port;

  /// 32-byte paired ChaCha20-Poly1305 key.
  final Uint8List key;
  final DateTime pairedAt;

  bool get isMac => os == HostOs.mac;

  String get osLabel => isMac ? 'Mac' : 'Windows PC';

  PairedHost copyWith({
    String? name,
    HostOs? os,
    String? address,
    int? port,
    Uint8List? key,
  }) {
    return PairedHost(
      id: id,
      name: name ?? this.name,
      os: os ?? this.os,
      address: address ?? this.address,
      port: port ?? this.port,
      key: key ?? this.key,
      pairedAt: pairedAt,
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
        'id': id,
        'name': name,
        'os': os.wire,
        'address': address,
        'port': port,
        // v1: stored base64 in shared_preferences. v2: flutter_secure_storage.
        'key': base64Encode(key),
        'pairedAt': pairedAt.toUtc().toIso8601String(),
      };

  static PairedHost? fromJson(Object? json) {
    if (json is! Map) return null;
    try {
      final id = json['id'] as String;
      final key = base64Decode(json['key'] as String);
      if (id.length != 32 || key.length != 32) return null;
      return PairedHost(
        id: id,
        name: (json['name'] as String?) ?? 'Computer',
        os: HostOs.parse(json['os']),
        address: (json['address'] as String?) ?? '',
        port: (json['port'] as num?)?.toInt() ?? Proto.port,
        key: key,
        pairedAt: DateTime.tryParse((json['pairedAt'] as String?) ?? '') ??
            DateTime.now(),
      );
    } catch (_) {
      return null;
    }
  }
}

class HostStore extends ChangeNotifier {
  HostStore(this._prefs) {
    _load();
  }

  static const String _hostsKey = 'orbit.hosts.v1';
  static const String _activeKey = 'orbit.activeHost.v1';

  final SharedPreferences _prefs;
  final List<PairedHost> _hosts = <PairedHost>[];
  String? _activeId;

  List<PairedHost> get hosts => List<PairedHost>.unmodifiable(_hosts);

  bool get isEmpty => _hosts.isEmpty;

  int get length => _hosts.length;

  PairedHost? get active {
    if (_hosts.isEmpty) return null;
    for (final h in _hosts) {
      if (h.id == _activeId) return h;
    }
    return _hosts.first;
  }

  int get activeIndex {
    final a = active;
    return a == null ? -1 : _hosts.indexWhere((h) => h.id == a.id);
  }

  PairedHost? byId(String id) {
    for (final h in _hosts) {
      if (h.id == id) return h;
    }
    return null;
  }

  bool contains(String id) => byId(id) != null;

  void _load() {
    final raw = _prefs.getString(_hostsKey);
    if (raw != null) {
      try {
        final list = jsonDecode(raw);
        if (list is List) {
          for (final item in list) {
            final h = PairedHost.fromJson(item);
            if (h != null && !contains(h.id)) _hosts.add(h);
          }
        }
      } catch (e) {
        debugPrint('Orbit: could not read paired hosts: $e');
      }
    }
    _activeId = _prefs.getString(_activeKey);
  }

  Future<void> _save() async {
    await _prefs.setString(
      _hostsKey,
      jsonEncode(_hosts.map((h) => h.toJson()).toList()),
    );
    final a = active;
    if (a == null) {
      await _prefs.remove(_activeKey);
    } else {
      await _prefs.setString(_activeKey, a.id);
    }
  }

  /// Adds or replaces a host (re-pairing replaces its key).
  Future<void> upsert(PairedHost host, {bool makeActive = true}) async {
    final i = _hosts.indexWhere((h) => h.id == host.id);
    if (i >= 0) {
      _hosts[i] = host;
    } else {
      _hosts.add(host);
    }
    if (makeActive || _activeId == null) _activeId = host.id;
    notifyListeners();
    await _save();
  }

  Future<void> forget(String id) async {
    _hosts.removeWhere((h) => h.id == id);
    if (_activeId == id) {
      _activeId = _hosts.isEmpty ? null : _hosts.first.id;
    }
    notifyListeners();
    await _save();
  }

  Future<void> rename(String id, String name) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return;
    final i = _hosts.indexWhere((h) => h.id == id);
    if (i < 0) return;
    _hosts[i] = _hosts[i].copyWith(name: trimmed);
    notifyListeners();
    await _save();
  }

  Future<void> setActive(String id) async {
    if (_activeId == id || !contains(id)) return;
    _activeId = id;
    notifyListeners();
    await _save();
  }

  /// The host [direction] steps away from the active one (wrapping),
  /// or `null` if there is nothing to switch to.
  PairedHost? neighbor(int direction) {
    if (_hosts.length < 2) return null;
    final i = activeIndex;
    final n = _hosts.length;
    return _hosts[((i + direction) % n + n) % n];
  }

  /// Switches to the next (+1) or previous (-1) host. Returns the new host.
  Future<PairedHost?> switchBy(int direction) async {
    final target = neighbor(direction);
    if (target == null) return null;
    await setActive(target.id);
    return target;
  }

  /// Updates the network endpoint / OS learned from discovery or PONG.
  /// Does not touch the user-chosen name.
  Future<void> updateEndpoint(
    String id, {
    String? address,
    int? port,
    HostOs? os,
  }) async {
    final i = _hosts.indexWhere((h) => h.id == id);
    if (i < 0) return;
    final old = _hosts[i];
    if ((address == null || address == old.address) &&
        (port == null || port == old.port) &&
        (os == null || os == old.os)) {
      return;
    }
    _hosts[i] = old.copyWith(address: address, port: port, os: os);
    notifyListeners();
    await _save();
  }
}
