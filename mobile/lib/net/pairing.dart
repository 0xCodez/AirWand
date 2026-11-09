// Pairing over TCP 47821, newline-delimited JSON (PROTOCOL.md §2).

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart' show ChangeNotifier, debugPrint;

import 'hosts.dart';
import 'protocol.dart';

enum PairingPhase { connecting, confirm, success, failed }

/// One pairing attempt with one host. Listen to it for phase changes.
class PairingSession extends ChangeNotifier {
  PairingSession({
    required this.address,
    required this.deviceId,
    required this.deviceName,
    required this.platform,
    this.port = Proto.port,
    this.expectedHostId,
  });

  final String address;
  final int port;
  final Uint8List deviceId;
  final String deviceName;

  /// `ios` | `android`
  final String platform;

  /// If known from discovery, the hello must match it.
  final String? expectedHostId;

  PairingPhase _phase = PairingPhase.connecting;
  String? _code;
  String? _hostName;
  HostOs? _hostOs;
  String? _error;
  PairedHost? _result;
  Socket? _socket;
  bool _disposed = false;
  bool _started = false;

  PairingPhase get phase => _phase;

  /// 6 digits once derived (phase >= confirm).
  String? get code => _code;
  String? get hostName => _hostName;
  HostOs? get hostOs => _hostOs;

  /// Human-readable failure reason (phase == failed).
  String? get error => _error;

  /// The paired host (phase == success).
  PairedHost? get result => _result;

  Future<void> start() async {
    if (_started) return;
    _started = true;
    StreamIterator<String>? lines;
    try {
      final socket = await Socket.connect(
        address,
        port,
        timeout: const Duration(seconds: 6),
      );
      if (_disposed) {
        socket.destroy();
        return;
      }
      _socket = socket;
      socket.setOption(SocketOption.tcpNoDelay, true);
      lines = StreamIterator<String>(
        const LineSplitter().bind(utf8.decoder.bind(socket)),
      );

      final x25519 = X25519();
      final keyPair = await x25519.newKeyPair();
      final myPublic = await keyPair.extractPublicKey();

      _sendLine(socket, <String, Object?>{
        't': 'hello',
        'v': Proto.version,
        'deviceId': hexEncode(deviceId),
        'name': deviceName,
        'platform': platform,
        'pub': base64Encode(myPublic.bytes),
      });
      await socket.flush();

      final hello = await _nextJson(lines, const Duration(seconds: 10));
      if (hello['t'] != 'hello') {
        throw const _PairingFailure('The computer answered unexpectedly.');
      }
      if ((hello['v'] as num?)?.toInt() != Proto.version) {
        throw const _PairingFailure(
          'This computer runs a different AirWand version. Update both apps.',
        );
      }
      final hostIdHex = (hello['hostId'] as String? ?? '').toLowerCase();
      final Uint8List hostId;
      final Uint8List hostPub;
      try {
        hostId = hexDecode(hostIdHex);
        hostPub = base64Decode(hello['pub'] as String? ?? '');
      } on FormatException {
        throw const _PairingFailure('The computer sent an invalid hello.');
      }
      if (hostId.length != Proto.idLength || hostPub.length != 32) {
        throw const _PairingFailure('The computer sent an invalid hello.');
      }
      if (expectedHostId != null &&
          expectedHostId!.isNotEmpty &&
          expectedHostId!.toLowerCase() != hostIdHex) {
        throw const _PairingFailure(
          'A different computer answered at this address.',
        );
      }
      _hostName = (hello['name'] as String?)?.trim().isNotEmpty == true
          ? (hello['name'] as String).trim()
          : 'Computer';
      _hostOs = HostOs.parse(hello['os']);

      final shared = await x25519.sharedSecretKey(
        keyPair: keyPair,
        remotePublicKey: SimplePublicKey(hostPub, type: KeyPairType.x25519),
      );
      final sharedBytes = await shared.extractBytes();
      final secrets = await derivePairingSecrets(
        sharedSecret: sharedBytes,
        deviceId: deviceId,
        hostId: hostId,
      );
      if (_disposed) return;
      _code = secrets.code;
      _setPhase(PairingPhase.confirm);

      // Host waits up to 60 s for the user; give the network some slack.
      final verdict = await _nextJson(
        lines,
        Proto.pairingTimeout + const Duration(seconds: 15),
      );
      if (verdict['t'] != 'paired') {
        throw const _PairingFailure('The computer answered unexpectedly.');
      }
      if (verdict['ok'] != true) {
        final reason = verdict['reason'];
        throw _PairingFailure(switch (reason) {
          'denied' => 'Pairing was declined on the computer.',
          'timeout' => 'Nobody confirmed the code in time.',
          _ => 'Pairing failed${reason is String ? ' ($reason)' : ''}.',
        });
      }
      _result = PairedHost(
        id: hostIdHex,
        name: _hostName!,
        os: _hostOs!,
        address: socket.remoteAddress.address,
        port: port,
        key: secrets.key,
        pairedAt: DateTime.now(),
      );
      _setPhase(PairingPhase.success);
    } on _PairingFailure catch (f) {
      _fail(f.message);
    } on TimeoutException {
      _fail(_code == null
          ? 'The computer did not answer.'
          : 'Nobody confirmed the code in time.');
    } on SocketException catch (e) {
      _fail(_describeSocketError(e));
    } catch (e) {
      debugPrint('AirWand pairing error: $e');
      _fail('Something went wrong while pairing.');
    } finally {
      try {
        await lines?.cancel();
      } catch (_) {
        // Already closed.
      }
      _socket?.destroy();
      _socket = null;
    }
  }

  void _sendLine(Socket socket, Map<String, Object?> json) {
    socket.add(utf8.encode('${jsonEncode(json)}\n'));
  }

  Future<Map<String, Object?>> _nextJson(
    StreamIterator<String> lines,
    Duration timeout,
  ) async {
    final deadline = DateTime.now().add(timeout);
    while (true) {
      final left = deadline.difference(DateTime.now());
      if (left <= Duration.zero) throw TimeoutException('pairing', timeout);
      final hasNext = await lines.moveNext().timeout(left);
      if (!hasNext) {
        throw _PairingFailure(_code == null
            ? 'The computer closed the connection.'
            : 'The computer cancelled pairing.');
      }
      final line = lines.current.trim();
      if (line.isEmpty) continue;
      final decoded = jsonDecode(line);
      if (decoded is Map) return decoded.cast<String, Object?>();
    }
  }

  String _describeSocketError(SocketException e) {
    final code = e.osError?.errorCode;
    // ECONNREFUSED: 61 (darwin), 111 (linux/android)
    if (code == 61 || code == 111) {
      return 'AirWand is not running on that computer.';
    }
    // EHOSTUNREACH / ENETUNREACH
    if (code == 65 || code == 113 || code == 51 || code == 101) {
      return 'That computer cannot be reached. Same Wi-Fi?';
    }
    return 'Could not connect to the computer.';
  }

  void _setPhase(PairingPhase p) {
    if (_disposed) return;
    _phase = p;
    notifyListeners();
  }

  void _fail(String message) {
    _error = message;
    _setPhase(PairingPhase.failed);
  }

  /// Aborts an in-flight attempt.
  void cancel() {
    _socket?.destroy();
    _socket = null;
  }

  @override
  void dispose() {
    _disposed = true;
    cancel();
    super.dispose();
  }
}

class _PairingFailure implements Exception {
  const _PairingFailure(this.message);
  final String message;
}
