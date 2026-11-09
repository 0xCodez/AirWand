// Encrypted UDP control channel (PROTOCOL.md §3).
//
// One RawDatagramSocket per app. PONGs arrive on the same socket.
// High-rate messages (MOVE, SCROLL, AIM) are coalesced to one packet per
// vsync (120 Hz on 120 Hz phones): calls made inside a frame (the trackpad
// engine already coalesces per frame) go out in a microtask of that same
// frame; calls from outside a frame (sensor events) wait for the next frame
// callback, with a timer fallback when no frames are being produced. The
// f32 rounding remainder of every MOVE / SCROLL is carried to the next one,
// so no motion is ever lost. Discrete messages flush pending motion first so
// ordering is preserved. Every packet
// goes through a single async chain so `seq` hits the wire strictly in order.

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart' show ChangeNotifier, debugPrint;
import 'package:flutter/scheduler.dart' show SchedulerBinding, SchedulerPhase;

import 'hosts.dart';
import 'protocol.dart';

enum LinkState { idle, connecting, connected, lost }

class ControlClient extends ChangeNotifier {
  ControlClient({required this.deviceId});

  final Uint8List deviceId;

  /// Fallback when no vsync arrives (app idle, no frames scheduled).
  static const Duration _flushFallback = Duration(milliseconds: 12);

  RawDatagramSocket? _socket;
  StreamSubscription<RawSocketEvent>? _socketSub;
  Future<RawDatagramSocket?>? _binding;

  PairedHost? _host;
  InternetAddress? _target;
  SecretKey? _key;
  int _session = 0;
  int _seq = 0;
  bool _suspended = false;
  bool _disposed = false;

  Timer? _pingTimer;
  int _pingTicks = 0;
  final Stopwatch _clock = Stopwatch()..start();
  final Map<int, int> _pingSentUs = <int, int>{};
  int? _lastPongUs;
  int? _latencyMs;
  LinkState _state = LinkState.idle;

  final StreamController<int> _latency = StreamController<int>.broadcast();

  Future<void> _chain = Future<void>.value();

  // Coalesced motion.
  double _moveX = 0, _moveY = 0;
  double _scrollX = 0, _scrollY = 0;
  double? _aimYaw, _aimPitch;
  Timer? _flushTimer;
  bool _flushScheduled = false;
  final Float32List _f32 = Float32List(1);

  /// Called when a PONG reports a different OS than stored.
  void Function(String hostId, HostOs os)? onHostOs;

  PairedHost? get host => _host;
  LinkState get state => _state;
  bool get isConnected => _state == LinkState.connected;

  /// Last measured round trip in ms (null until the first PONG).
  int? get latencyMs => _latencyMs;

  /// Round-trip latency in ms, one value per PONG.
  Stream<int> get latency => _latency.stream;

  // ------------------------------------------------------------ lifecycle

  /// Starts talking to [host] with a fresh session (seq restarts at 1).
  Future<void> connect(PairedHost host) async {
    final sameHost = _host?.id == host.id;
    if (sameHost && _sameEndpoint(host) && _state != LinkState.idle) {
      _host = host;
      return;
    }
    if (_host != null && !sameHost) {
      _sendBye(); // captured with the old host's key/address/session
    }
    _stopPinging();
    _host = host;
    _key = SecretKey(List<int>.of(host.key));
    _target = null;
    _session = randomU32();
    _seq = 0;
    _pingSentUs.clear();
    _lastPongUs = null;
    _latencyMs = null;
    _setState(LinkState.connecting);
    final target = await _resolve(host.address);
    if (_host?.id != host.id) return; // switched again meanwhile
    _target = target;
    await _ensureSocket();
    if (!_suspended && _host?.id == host.id) _startPinging();
  }

  /// The host's address/port changed (learned from discovery).
  Future<void> retarget(PairedHost host) async {
    if (_host?.id != host.id) return;
    final changed = !_sameEndpoint(host);
    _host = host;
    _key = SecretKey(List<int>.of(host.key));
    if (changed) {
      _target = await _resolve(host.address);
      _ping();
    }
  }

  bool _sameEndpoint(PairedHost h) =>
      _host != null && _host!.address == h.address && _host!.port == h.port;

  /// Stops sending and says BYE (app backgrounded / control screen closed).
  void suspend() {
    if (_suspended) return;
    _suspended = true;
    _stopPinging();
    _sendBye();
    _setState(LinkState.idle);
  }

  /// Resumes after [suspend] with a fresh session.
  void resume() {
    if (!_suspended) return;
    _suspended = false;
    if (_host == null) return;
    _session = randomU32();
    _seq = 0;
    _pingSentUs.clear();
    _setState(LinkState.connecting);
    _startPinging();
  }

  /// Leaves the current host entirely.
  void disconnect() {
    _stopPinging();
    _sendBye();
    _host = null;
    _key = null;
    _target = null;
    _setState(LinkState.idle);
  }

  // -------------------------------------------------------- send helpers

  void move(double dx, double dy) {
    if (!dx.isFinite || !dy.isFinite) return;
    _moveX += dx;
    _moveY += dy;
    _scheduleFlush();
  }

  void scroll(double dx, double dy) {
    if (!dx.isFinite || !dy.isFinite) return;
    _scrollX += dx;
    _scrollY += dy;
    _scheduleFlush();
  }

  void aim(double yaw, double pitch) {
    if (!yaw.isFinite || !pitch.isFinite) return;
    _aimYaw = yaw;
    _aimPitch = pitch;
    _scheduleFlush();
  }

  void button(int button, bool down) {
    _flushMotion();
    _send(MsgType.button, Payload.button(button, down));
  }

  void click(int button, [int count = 1]) {
    _flushMotion();
    _send(MsgType.click, Payload.click(button, count));
  }

  void gesture(int id) {
    _flushMotion();
    _send(MsgType.gesture, Payload.gesture(id));
  }

  void key(int usage, {int mods = KeyMods.none, int action = KeyAction.tap}) {
    _flushMotion();
    _send(MsgType.key, Payload.key(action, mods, usage));
  }

  void text(String text) {
    if (text.isEmpty) return;
    _flushMotion();
    for (final chunk in Payload.splitText(text)) {
      _send(MsgType.text, Payload.text(chunk));
    }
  }

  void media(int id) {
    _flushMotion();
    _send(MsgType.media, Payload.media(id));
  }

  // ------------------------------------------------------------ internals

  static SchedulerBinding? _scheduler() {
    try {
      return SchedulerBinding.instance;
    } catch (_) {
      return null; // no binding (plain unit tests)
    }
  }

  void _scheduleFlush() {
    if (_flushScheduled) return;
    _flushScheduled = true;
    final b = _scheduler();
    if (b == null || b.schedulerPhase != SchedulerPhase.idle) {
      // Inside a frame (or no scheduler): send in this frame, coalescing
      // everything queued in the same turn.
      scheduleMicrotask(_flushMotion);
      return;
    }
    b.scheduleFrameCallback((_) => _flushMotion());
    _flushTimer?.cancel();
    _flushTimer = Timer(_flushFallback, _flushMotion);
  }

  /// Rounds to f32 (the wire format) so the remainder can be carried.
  double _asF32(double v) {
    _f32[0] = v;
    return _f32[0];
  }

  void _flushMotion() {
    _flushTimer?.cancel();
    _flushTimer = null;
    _flushScheduled = false;
    if (_moveX != 0 || _moveY != 0) {
      final x = _asF32(_moveX), y = _asF32(_moveY);
      if (x != 0 || y != 0) {
        _send(MsgType.move, Payload.move(x, y));
        _moveX -= x;
        _moveY -= y;
      }
      // Sub-f32 residue below one millionth of a point is not worth a packet.
      if (_moveX.abs() < 1e-6) _moveX = 0;
      if (_moveY.abs() < 1e-6) _moveY = 0;
    }
    if (_scrollX != 0 || _scrollY != 0) {
      final x = _asF32(_scrollX), y = _asF32(_scrollY);
      if (x != 0 || y != 0) {
        _send(MsgType.scroll, Payload.scroll(x, y));
        _scrollX -= x;
        _scrollY -= y;
      }
      if (_scrollX.abs() < 1e-6) _scrollX = 0;
      if (_scrollY.abs() < 1e-6) _scrollY = 0;
    }
    final yaw = _aimYaw, pitch = _aimPitch;
    if (yaw != null && pitch != null) {
      _send(MsgType.aim, Payload.aim(yaw, pitch));
      _aimYaw = null;
      _aimPitch = null;
    }
  }

  void _startPinging() {
    _pingTimer?.cancel();
    _pingTicks = 0;
    _ping();
    _pingTimer = Timer.periodic(Proto.pingInterval, (_) {
      _pingTicks++;
      _ping();
      _checkLiveness();
    });
  }

  void _stopPinging() {
    _pingTimer?.cancel();
    _pingTimer = null;
  }

  void _ping() {
    if (_host == null || _suspended) return;
    final seq = _enqueue(MsgType.ping, const <int>[]);
    if (seq == null) return;
    final now = _clock.elapsedMicroseconds;
    _pingSentUs[seq] = now;
    // Keep the map small: forget pings older than 10 s.
    _pingSentUs.removeWhere((_, t) => t < now - 10000000);
  }

  void _sendBye() {
    if (_host == null || _key == null) return;
    _flushMotion();
    _send(MsgType.bye);
  }

  void _checkLiveness() {
    final last = _lastPongUs;
    final now = _clock.elapsedMicroseconds;
    if (last != null &&
        now - last <= Proto.connectedWindow.inMicroseconds) {
      _setState(LinkState.connected);
    } else if (_state == LinkState.connected ||
        // Count timer ticks, not seq: seq does not advance while the address
        // is unresolved, which would leave the pill on "Connecting" forever.
        (_state == LinkState.connecting && _pingTicks > 4)) {
      _setState(LinkState.lost);
    }
  }

  void _send(int type, [List<int> payload = const <int>[]]) {
    _enqueue(type, payload);
  }

  /// Queues one packet and returns its seq (or null if nothing to send to).
  ///
  /// Key, address, session and seq are captured synchronously; the serial
  /// chain then seals and sends in exactly the enqueue order, so seq always
  /// increases on the wire even though encryption is async.
  int? _enqueue(int type, List<int> payload) {
    final key = _key;
    final target = _target;
    final host = _host;
    if (key == null || target == null || host == null || _disposed) {
      return null;
    }
    final session = _session;
    final seq = _seq = (_seq + 1) & 0xffffffff;
    final port = host.port;
    _chain = _chain.then((_) async {
      try {
        final socket = await _ensureSocket();
        if (socket == null) return;
        final packet = await sealPacket(
          deviceId: deviceId,
          key: key,
          session: session,
          seq: seq,
          type: type,
          payload: payload,
        );
        socket.send(packet, target, port);
      } catch (e) {
        debugPrint('Orbit send failed: $e');
      }
    });
    return seq;
  }

  Future<RawDatagramSocket?> _ensureSocket() {
    final existing = _socket;
    if (existing != null) return Future<RawDatagramSocket?>.value(existing);
    return _binding ??= () async {
      try {
        final s = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
        _socket = s;
        _socketSub = s.listen(_onSocketEvent, onError: (Object e) {
          debugPrint('Orbit control socket error: $e');
        });
        return s;
      } catch (e) {
        debugPrint('Orbit: could not open UDP socket: $e');
        return null;
      } finally {
        _binding = null;
      }
    }();
  }

  void _onSocketEvent(RawSocketEvent event) {
    if (event != RawSocketEvent.read) return;
    final s = _socket;
    if (s == null) return;
    while (true) {
      final d = s.receive();
      if (d == null) break;
      _onDatagram(d);
    }
  }

  Future<void> _onDatagram(Datagram d) async {
    final key = _key;
    final host = _host;
    if (key == null || host == null) return;
    final packet = await openPacket(
      d.data,
      key: key,
      expectDeviceId: deviceId,
    );
    if (packet == null || packet.type != MsgType.pong) return;
    if (_host?.id != host.id) return; // switched while decrypting
    final pong = Pong.parse(packet.payload);
    if (pong == null) return;
    final now = _clock.elapsedMicroseconds;
    _lastPongUs = now;
    final sent = _pingSentUs.remove(pong.echoSeq);
    if (sent != null) {
      final ms = ((now - sent) / 1000).round();
      _latencyMs = ms;
      if (!_latency.isClosed) _latency.add(ms);
    }
    if (pong.os != host.os) onHostOs?.call(host.id, pong.os);
    if (_state != LinkState.connected) {
      _setState(LinkState.connected);
    } else {
      _notify();
    }
  }

  static Future<InternetAddress?> _resolve(String address) async {
    final literal = InternetAddress.tryParse(address);
    if (literal != null) return literal;
    try {
      final found = await InternetAddress.lookup(address)
          .timeout(const Duration(seconds: 3));
      for (final a in found) {
        if (a.type == InternetAddressType.IPv4) return a;
      }
      return found.isEmpty ? null : found.first;
    } catch (_) {
      return null;
    }
  }

  void _setState(LinkState s) {
    if (_state == s) return;
    _state = s;
    _notify();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _stopPinging();
    _sendBye();
    _flushTimer?.cancel();
    _disposed = true;
    final s = _socket;
    // Let the BYE leave before closing.
    _chain.whenComplete(() {
      _socketSub?.cancel();
      s?.close();
    });
    _latency.close();
    super.dispose();
  }
}
