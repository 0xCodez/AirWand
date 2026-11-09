// AirWand wire protocol v1 — see docs/PROTOCOL.md (the binding contract).
//
// Everything here is pure Dart (no Flutter imports) so it can be unit tested
// and reused by any isolate.

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

/// Protocol-wide constants.
abstract final class Proto {
  static const int version = 1;
  static const int port = 47821;
  static const String serviceType = '_orbit._tcp';
  static const String discoveryProbe = 'ORBIT?1';
  static const String hkdfSalt = 'orbit/v1';

  static const int magic0 = 0x4F; // 'O'
  static const int magic1 = 0x42; // 'B'
  static const int headerLength = 19; // 'O' 'B' version deviceId(16)
  static const int idLength = 16;
  static const int nonceLength = 12;
  static const int tagLength = 16;
  static const int plaintextPrefix = 9; // session u32 | seq u32 | type u8
  static const int maxPacket = 1200;
  static const int maxTextBytes = 1000;

  /// A host is considered connected while it answered within this window.
  static const Duration connectedWindow = Duration(seconds: 3);
  static const Duration pingInterval = Duration(seconds: 1);
  static const Duration pairingTimeout = Duration(seconds: 60);
}

/// Control message types (device → host unless noted).
abstract final class MsgType {
  static const int move = 0x01;
  static const int button = 0x02;
  static const int click = 0x03;
  static const int scroll = 0x04;
  static const int gesture = 0x05;
  static const int key = 0x06;
  static const int text = 0x07;
  static const int media = 0x08;
  static const int aim = 0x09;
  static const int ping = 0x0A;
  static const int pong = 0x0B; // host → device
  static const int bye = 0x0C;
}

abstract final class MouseButton {
  static const int left = 0;
  static const int right = 1;
  static const int middle = 2;
}

abstract final class GestureId {
  static const int overview = 1;
  static const int appSwitcher = 2;
  static const int showDesktop = 3;
  static const int previousSpace = 4;
  static const int nextSpace = 5;
  static const int back = 6;
  static const int forward = 7;
  static const int zoomIn = 8;
  static const int zoomOut = 9;
}

abstract final class MediaId {
  static const int playPause = 1;
  static const int next = 2;
  static const int previous = 3;
  static const int volumeUp = 4;
  static const int volumeDown = 5;
  static const int mute = 6;
}

abstract final class KeyAction {
  static const int tap = 0;
  static const int down = 1;
  static const int up = 2;
}

/// Modifier bitmask for KEY.
abstract final class KeyMods {
  static const int none = 0;
  static const int shift = 1;
  static const int ctrl = 2;
  static const int alt = 4;
  static const int meta = 8;
}

/// USB HID keyboard usage IDs used by the app.
abstract final class Hid {
  static const int a = 0x04;
  static const int c = 0x06;
  static const int f = 0x09;
  static const int l = 0x0F;
  static const int n = 0x11;
  static const int r = 0x15;
  static const int s = 0x16;
  static const int t = 0x17;
  static const int v = 0x19;
  static const int w = 0x1A;
  static const int x = 0x1B;
  static const int z = 0x1D;
  static const int digit1 = 0x1E;
  static const int digit3 = 0x20;
  static const int digit4 = 0x21;
  static const int digit0 = 0x27;
  static const int enter = 0x28;
  static const int escape = 0x29;
  static const int backspace = 0x2A;
  static const int tab = 0x2B;
  static const int space = 0x2C;
  static const int f1 = 0x3A;
  static const int f5 = 0x3E;
  static const int f12 = 0x45;
  static const int home = 0x4A;
  static const int pageUp = 0x4B;
  static const int delete = 0x4C;
  static const int end = 0x4D;
  static const int pageDown = 0x4E;
  static const int right = 0x4F;
  static const int left = 0x50;
  static const int down = 0x51;
  static const int up = 0x52;

  /// HID usage for a lowercase ASCII letter `a`–`z`.
  static int letter(String ch) {
    final code = ch.toLowerCase().codeUnitAt(0);
    assert(code >= 0x61 && code <= 0x7A, 'not a letter: $ch');
    return a + (code - 0x61);
  }
}

/// Host operating system as reported in TXT / hello / PONG.
enum HostOs {
  mac,
  windows;

  String get wire => this == HostOs.mac ? 'mac' : 'windows';

  static HostOs parse(Object? value) {
    if (value is int) return value == 1 ? HostOs.windows : HostOs.mac;
    final s = value?.toString().toLowerCase() ?? '';
    return s.startsWith('win') ? HostOs.windows : HostOs.mac;
  }
}

// ---------------------------------------------------------------------------
// Bytes helpers
// ---------------------------------------------------------------------------

final Random _secureRandom = Random.secure();

Uint8List randomBytes(int length) {
  final out = Uint8List(length);
  for (var i = 0; i < length; i++) {
    out[i] = _secureRandom.nextInt(256);
  }
  return out;
}

/// Random u32 (used for the per-connection `session`).
int randomU32() {
  // Random.nextInt accepts at most 2^32, so combine two 16-bit halves.
  final hi = _secureRandom.nextInt(1 << 16);
  final lo = _secureRandom.nextInt(1 << 16);
  return (hi << 16) | lo;
}

String hexEncode(List<int> bytes) {
  final sb = StringBuffer();
  for (final b in bytes) {
    sb.write((b & 0xff).toRadixString(16).padLeft(2, '0'));
  }
  return sb.toString();
}

Uint8List hexDecode(String hex) {
  final clean = hex.trim().toLowerCase();
  if (clean.length.isOdd) {
    throw const FormatException('hex string has odd length');
  }
  final out = Uint8List(clean.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    final v = int.tryParse(clean.substring(i * 2, i * 2 + 2), radix: 16);
    if (v == null) throw FormatException('invalid hex at $i');
    out[i] = v;
  }
  return out;
}

bool bytesEqual(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  var diff = 0;
  for (var i = 0; i < a.length; i++) {
    diff |= a[i] ^ b[i];
  }
  return diff == 0;
}

// ---------------------------------------------------------------------------
// Payload builders
// ---------------------------------------------------------------------------

abstract final class Payload {
  static Uint8List f32Pair(double a, double b) {
    final d = ByteData(8)
      ..setFloat32(0, a, Endian.big)
      ..setFloat32(4, b, Endian.big);
    return d.buffer.asUint8List();
  }

  static Uint8List move(double dx, double dy) => f32Pair(dx, dy);

  static Uint8List scroll(double dx, double dy) => f32Pair(dx, dy);

  static Uint8List aim(double yaw, double pitch) => f32Pair(yaw, pitch);

  static Uint8List button(int button, bool down) =>
      Uint8List.fromList([button & 0xff, down ? 1 : 0]);

  static Uint8List click(int button, int count) =>
      Uint8List.fromList([button & 0xff, count.clamp(1, 3)]);

  static Uint8List gesture(int id) => Uint8List.fromList([id & 0xff]);

  static Uint8List media(int id) => Uint8List.fromList([id & 0xff]);

  static Uint8List key(int action, int mods, int usage) {
    final d = ByteData(4)
      ..setUint8(0, action & 0xff)
      ..setUint8(1, mods & 0xff)
      ..setUint16(2, usage & 0xffff, Endian.big);
    return d.buffer.asUint8List();
  }

  /// UTF-8 text, truncated on a code point boundary to [Proto.maxTextBytes].
  static Uint8List text(String text) {
    final bytes = utf8.encode(text);
    if (bytes.length <= Proto.maxTextBytes) return bytes;
    var end = Proto.maxTextBytes;
    // Step back over UTF-8 continuation bytes (10xxxxxx).
    while (end > 0 && (bytes[end] & 0xC0) == 0x80) {
      end--;
    }
    return Uint8List.sublistView(bytes, 0, end);
  }

  /// Splits [text] into chunks that each fit in one TEXT packet.
  static List<String> splitText(String text) {
    final out = <String>[];
    final buf = StringBuffer();
    var bufBytes = 0;
    for (final rune in text.runes) {
      final ch = String.fromCharCode(rune);
      final n = utf8.encode(ch).length;
      if (bufBytes + n > Proto.maxTextBytes) {
        out.add(buf.toString());
        buf.clear();
        bufBytes = 0;
      }
      buf.write(ch);
      bufBytes += n;
    }
    if (bufBytes > 0) out.add(buf.toString());
    return out;
  }
}

// ---------------------------------------------------------------------------
// Packets
// ---------------------------------------------------------------------------

/// `'O' 'B' | 0x01 | deviceId(16)`
Uint8List buildHeader(List<int> deviceId) {
  if (deviceId.length != Proto.idLength) {
    throw ArgumentError.value(deviceId.length, 'deviceId', 'must be 16 bytes');
  }
  final h = Uint8List(Proto.headerLength);
  h[0] = Proto.magic0;
  h[1] = Proto.magic1;
  h[2] = Proto.version;
  h.setRange(3, Proto.headerLength, deviceId);
  return h;
}

/// `session u32 | seq u32 | type u8 | payload`
Uint8List buildPlaintext({
  required int session,
  required int seq,
  required int type,
  List<int> payload = const <int>[],
}) {
  final out = Uint8List(Proto.plaintextPrefix + payload.length);
  final d = ByteData.sublistView(out);
  d.setUint32(0, session & 0xffffffff, Endian.big);
  d.setUint32(4, seq & 0xffffffff, Endian.big);
  d.setUint8(8, type & 0xff);
  out.setRange(Proto.plaintextPrefix, out.length, payload);
  return out;
}

/// A decoded, authenticated control packet.
class OpenedPacket {
  const OpenedPacket({
    required this.deviceId,
    required this.session,
    required this.seq,
    required this.type,
    required this.payload,
  });

  final Uint8List deviceId;
  final int session;
  final int seq;
  final int type;
  final Uint8List payload;
}

/// PONG payload: `u32 echoSeq | u8 os`.
class Pong {
  const Pong(this.echoSeq, this.os);
  final int echoSeq;
  final HostOs os;

  static Pong? parse(Uint8List payload) {
    if (payload.length < 5) return null;
    final d = ByteData.sublistView(payload);
    return Pong(d.getUint32(0, Endian.big), HostOs.parse(d.getUint8(4)));
  }
}

/// ChaCha20-Poly1305 (IETF, 12-byte nonce).
final Cipher _aead = Chacha20.poly1305Aead();

/// Seals one control packet:
/// `header(19) | nonce(12) | ciphertext | tag(16)` with AAD = header.
///
/// [nonce] is only meant to be injected by tests; production code lets it
/// default to 12 fresh random bytes.
Future<Uint8List> sealPacket({
  required List<int> deviceId,
  required SecretKey key,
  required int session,
  required int seq,
  required int type,
  List<int> payload = const <int>[],
  List<int>? nonce,
}) async {
  final header = buildHeader(deviceId);
  final n = nonce ?? randomBytes(Proto.nonceLength);
  if (n.length != Proto.nonceLength) {
    throw ArgumentError.value(n.length, 'nonce', 'must be 12 bytes');
  }
  final clear = buildPlaintext(
    session: session,
    seq: seq,
    type: type,
    payload: payload,
  );
  final box = await _aead.encrypt(
    clear,
    secretKey: key,
    nonce: n,
    aad: header,
  );
  final total = Proto.headerLength +
      Proto.nonceLength +
      box.cipherText.length +
      Proto.tagLength;
  if (total > Proto.maxPacket) {
    throw ArgumentError('packet too large: $total bytes');
  }
  final out = Uint8List(total);
  var o = 0;
  out.setRange(o, o += Proto.headerLength, header);
  out.setRange(o, o += Proto.nonceLength, n);
  out.setRange(o, o += box.cipherText.length, box.cipherText);
  out.setRange(o, o + Proto.tagLength, box.mac.bytes);
  return out;
}

/// Authenticates and decrypts a packet. Returns `null` for anything that is
/// malformed or fails authentication (callers drop silently).
Future<OpenedPacket?> openPacket(
  Uint8List data, {
  required SecretKey key,
  List<int>? expectDeviceId,
}) async {
  const minLen = Proto.headerLength +
      Proto.nonceLength +
      Proto.plaintextPrefix +
      Proto.tagLength;
  if (data.length < minLen || data.length > Proto.maxPacket) return null;
  if (data[0] != Proto.magic0 ||
      data[1] != Proto.magic1 ||
      data[2] != Proto.version) {
    return null;
  }
  final header = Uint8List.sublistView(data, 0, Proto.headerLength);
  final deviceId = Uint8List.fromList(
    Uint8List.sublistView(data, 3, Proto.headerLength),
  );
  if (expectDeviceId != null && !bytesEqual(deviceId, expectDeviceId)) {
    return null;
  }
  const nonceEnd = Proto.headerLength + Proto.nonceLength;
  final nonce = Uint8List.sublistView(data, Proto.headerLength, nonceEnd);
  final tagStart = data.length - Proto.tagLength;
  final cipherText = Uint8List.sublistView(data, nonceEnd, tagStart);
  final tag = Uint8List.sublistView(data, tagStart);

  List<int> clear;
  try {
    clear = await _aead.decrypt(
      SecretBox(cipherText, nonce: nonce, mac: Mac(tag)),
      secretKey: key,
      aad: header,
    );
  } catch (_) {
    return null;
  }
  if (clear.length < Proto.plaintextPrefix) return null;
  final bytes = clear is Uint8List ? clear : Uint8List.fromList(clear);
  final d = ByteData.sublistView(bytes);
  return OpenedPacket(
    deviceId: deviceId,
    session: d.getUint32(0, Endian.big),
    seq: d.getUint32(4, Endian.big),
    type: d.getUint8(8),
    payload: Uint8List.fromList(
      Uint8List.sublistView(bytes, Proto.plaintextPrefix),
    ),
  );
}

// ---------------------------------------------------------------------------
// Pairing derivation (shared by pairing.dart and tests)
// ---------------------------------------------------------------------------

class PairingSecrets {
  const PairingSecrets({required this.key, required this.code});

  /// 32-byte ChaCha20-Poly1305 key.
  final Uint8List key;

  /// 6-digit, zero padded.
  final String code;
}

/// `HKDF-SHA256(shared, salt = "orbit/v1", info = label || deviceId || hostId)`
Future<Uint8List> hkdfAirWand({
  required List<int> sharedSecret,
  required String label,
  required List<int> deviceId,
  required List<int> hostId,
  required int length,
}) async {
  final hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: length);
  final info = <int>[...utf8.encode(label), ...deviceId, ...hostId];
  final derived = await hkdf.deriveKey(
    secretKey: SecretKey(List<int>.of(sharedSecret)),
    nonce: utf8.encode(Proto.hkdfSalt), // package:cryptography calls the salt "nonce"
    info: info,
  );
  return Uint8List.fromList(await derived.extractBytes());
}

Future<PairingSecrets> derivePairingSecrets({
  required List<int> sharedSecret,
  required List<int> deviceId,
  required List<int> hostId,
}) async {
  final key = await hkdfAirWand(
    sharedSecret: sharedSecret,
    label: 'key',
    deviceId: deviceId,
    hostId: hostId,
    length: 32,
  );
  final codeBytes = await hkdfAirWand(
    sharedSecret: sharedSecret,
    label: 'code',
    deviceId: deviceId,
    hostId: hostId,
    length: 4,
  );
  return PairingSecrets(key: key, code: pairingCodeFromBytes(codeBytes));
}

/// 4 bytes → u32 big-endian → `% 1 000 000` → zero padded to 6 digits.
String pairingCodeFromBytes(List<int> bytes) {
  if (bytes.length != 4) {
    throw ArgumentError.value(bytes.length, 'bytes', 'must be 4 bytes');
  }
  final v = ((bytes[0] & 0xff) << 24) |
      ((bytes[1] & 0xff) << 16) |
      ((bytes[2] & 0xff) << 8) |
      (bytes[3] & 0xff);
  return (v % 1000000).toString().padLeft(6, '0');
}

/// `482913` → `482 913` (display only).
String groupPairingCode(String code) {
  if (code.length != 6) return code;
  return '${code.substring(0, 3)} ${code.substring(3)}';
}
