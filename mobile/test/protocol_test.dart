// Protocol tests. The expected vectors were produced independently with
// Node.js `crypto` (hkdfSync sha256, chacha20-poly1305, x25519) so they pin
// the Dart implementation to standard primitives, and therefore to the
// desktop agent.

import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orbit/net/protocol.dart';
import 'package:orbit/ui/screens/keys_view.dart' show diffTyping;
import 'package:orbit/ui/screens/discovery_screen.dart' show parseHostPort;

Uint8List seq(int length, int start) =>
    Uint8List.fromList(List<int>.generate(length, (i) => (start + i) & 0xff));

void main() {
  final deviceId = seq(16, 0x00);
  final hostId = seq(16, 0x10);

  group('header', () {
    test('is O B 0x01 deviceId (19 bytes)', () {
      final h = buildHeader(deviceId);
      expect(h.length, 19);
      expect(h[0], 0x4F);
      expect(h[1], 0x42);
      expect(h[2], 0x01);
      expect(h.sublist(3), deviceId);
      expect(ascii.decode(h.sublist(0, 2)), 'OB');
    });

    test('rejects wrong deviceId length', () {
      expect(() => buildHeader(seq(15, 0)), throwsArgumentError);
    });
  });

  group('plaintext', () {
    test('session u32 | seq u32 | type u8 | payload, big-endian', () {
      final p = buildPlaintext(
        session: 0x01020304,
        seq: 5,
        type: MsgType.move,
        payload: Payload.move(1.5, -2.25),
      );
      expect(hexEncode(p), '0102030400000005013fc00000c0100000');
    });

    test('KEY payload layout', () {
      final k = Payload.key(KeyAction.tap, KeyMods.meta | KeyMods.shift, 0x21);
      expect(k, <int>[0x00, 0x09, 0x00, 0x21]);
    });

    test('CLICK count is clamped to 1..3', () {
      expect(Payload.click(MouseButton.left, 7), <int>[0, 3]);
      expect(Payload.click(MouseButton.right, 0), <int>[1, 1]);
    });

    test('TEXT is split on code point boundaries under 1000 bytes', () {
      final long = 'ж' * 900; // 2 bytes each = 1800 bytes
      final chunks = Payload.splitText(long);
      expect(chunks.length, 2);
      for (final c in chunks) {
        expect(utf8.encode(c).length, lessThanOrEqualTo(Proto.maxTextBytes));
      }
      expect(chunks.join(), long);
    });
  });

  group('constants (PROTOCOL.md)', () {
    test('ports, service, probe, salt, sizes', () {
      expect(Proto.port, 47821);
      expect(Proto.serviceType, '_orbit._tcp');
      expect(ascii.encode(Proto.discoveryProbe),
          <int>[0x4F, 0x52, 0x42, 0x49, 0x54, 0x3F, 0x31]);
      expect(Proto.hkdfSalt, 'orbit/v1');
      expect(Proto.version, 1);
      expect(Proto.headerLength, 19);
      expect(Proto.nonceLength, 12);
      expect(Proto.tagLength, 16);
      expect(Proto.maxPacket, 1200);
      expect(Proto.maxTextBytes, 1000);
    });

    test('message type ids', () {
      expect(<int>[
        MsgType.move,
        MsgType.button,
        MsgType.click,
        MsgType.scroll,
        MsgType.gesture,
        MsgType.key,
        MsgType.text,
        MsgType.media,
        MsgType.aim,
        MsgType.ping,
        MsgType.pong,
        MsgType.bye,
      ], <int>[0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0A, 0x0B, 0x0C]);
    });

    test('gesture, media, button and modifier ids', () {
      expect(<int>[
        GestureId.overview,
        GestureId.appSwitcher,
        GestureId.showDesktop,
        GestureId.previousSpace,
        GestureId.nextSpace,
        GestureId.back,
        GestureId.forward,
        GestureId.zoomIn,
        GestureId.zoomOut,
      ], <int>[1, 2, 3, 4, 5, 6, 7, 8, 9]);
      expect(<int>[
        MediaId.playPause,
        MediaId.next,
        MediaId.previous,
        MediaId.volumeUp,
        MediaId.volumeDown,
        MediaId.mute,
      ], <int>[1, 2, 3, 4, 5, 6]);
      expect(<int>[MouseButton.left, MouseButton.right, MouseButton.middle],
          <int>[0, 1, 2]);
      expect(<int>[KeyAction.tap, KeyAction.down, KeyAction.up], <int>[0, 1, 2]);
      expect(<int>[KeyMods.shift, KeyMods.ctrl, KeyMods.alt, KeyMods.meta],
          <int>[1, 2, 4, 8]);
    });

    test('HID usages', () {
      expect(Hid.a, 0x04);
      expect(Hid.letter('z'), 0x1D);
      expect(Hid.letter('Y'), 0x1C);
      expect(Hid.digit1, 0x1E);
      expect(Hid.digit0, 0x27);
      expect(<int>[Hid.enter, Hid.escape, Hid.backspace, Hid.tab, Hid.space],
          <int>[0x28, 0x29, 0x2A, 0x2B, 0x2C]);
      expect(Hid.f1, 0x3A);
      expect(Hid.f12, 0x45);
      expect(<int>[
        Hid.home,
        Hid.pageUp,
        Hid.delete,
        Hid.end,
        Hid.pageDown,
        Hid.right,
        Hid.left,
        Hid.down,
        Hid.up,
      ], <int>[0x4A, 0x4B, 0x4C, 0x4D, 0x4E, 0x4F, 0x50, 0x51, 0x52]);
    });
  });

  group('payload byte layouts', () {
    test('MOVE / SCROLL / AIM are two big-endian f32', () {
      expect(hexEncode(Payload.move(1.5, -2.25)), '3fc00000c0100000');
      expect(hexEncode(Payload.scroll(-1, 0.5)), 'bf8000003f000000');
      expect(hexEncode(Payload.aim(0.25, -0.125)), '3e800000be000000');
    });

    test('BUTTON / CLICK / GESTURE / MEDIA', () {
      expect(Payload.button(MouseButton.left, true), <int>[0, 1]);
      expect(Payload.button(MouseButton.middle, false), <int>[2, 0]);
      expect(Payload.click(MouseButton.left, 2), <int>[0, 2]);
      expect(Payload.gesture(GestureId.zoomOut), <int>[9]);
      expect(Payload.media(MediaId.mute), <int>[6]);
    });

    test('KEY usage is u16 big-endian', () {
      expect(Payload.key(KeyAction.up, KeyMods.ctrl | KeyMods.alt, 0x0102),
          <int>[0x02, 0x06, 0x01, 0x02]);
    });

    test('TEXT is UTF-8 and truncated on a code point boundary', () {
      expect(Payload.text('hé'), <int>[0x68, 0xC3, 0xA9]);
      final t = Payload.text('a${'ж' * 600}'); // 1 + 1200 bytes
      expect(t.length, lessThanOrEqualTo(Proto.maxTextBytes));
      expect(utf8.decode(t), 'a${'ж' * 499}');
    });

    test('PING plaintext is just the 9-byte prefix', () {
      final p = buildPlaintext(
        session: 0xCAFEBABE,
        seq: 0xFFFFFFFE,
        type: MsgType.ping,
      );
      expect(hexEncode(p), 'cafebabefffffffe0a');
    });
  });

  group('AEAD packet', () {
    final key = SecretKey(seq(32, 0x80));
    final nonce = seq(12, 0xA0);

    test('PING packet matches the independent vector', () async {
      final packet = await sealPacket(
        deviceId: deviceId,
        key: key,
        session: 0xCAFEBABE,
        seq: 0xFFFFFFFE,
        type: MsgType.ping,
        nonce: nonce,
      );
      expect(
        hexEncode(packet),
        '4f4201000102030405060708090a0b0c0d0e0f'
        'a0a1a2a3a4a5a6a7a8a9aaab'
        '1f0a9318280c97d093f1ae8c52'
        '43708e521cb2e0ae61895344',
      );
      expect(packet.length, 19 + 12 + 9 + 16);
    });

    test('opens a host-sealed PONG (independent vector)', () async {
      // Host: session 0x11223344, seq 1, PONG echoSeq 7, os 1 (windows),
      // header carries the *device's* id.
      final packet = hexDecode(
        '4f4201000102030405060708090a0b0c0d0e0f'
        'a0a1a2a3a4a5a6a7a8a9aaab'
        'c4d61ae2d7f3682f92fea43e5b93'
        '296a811ffd67a22c3a41ee58d5b45b5a',
      );
      final opened =
          await openPacket(packet, key: key, expectDeviceId: deviceId);
      expect(opened, isNotNull);
      expect(opened!.session, 0x11223344);
      expect(opened.seq, 1);
      expect(opened.type, MsgType.pong);
      final pong = Pong.parse(opened.payload)!;
      expect(pong.echoSeq, 7);
      expect(pong.os, HostOs.windows);
    });

    test('a full 1000-byte TEXT packet stays under 1200 bytes', () async {
      final packet = await sealPacket(
        deviceId: deviceId,
        key: key,
        session: 1,
        seq: 1,
        type: MsgType.text,
        payload: Payload.text('x' * 1000),
      );
      expect(packet.length, 19 + 12 + 9 + 1000 + 16);
      expect(packet.length, lessThanOrEqualTo(Proto.maxPacket));
    });

    test('rejects malformed packets', () async {
      final good = await sealPacket(
        deviceId: deviceId,
        key: key,
        session: 1,
        seq: 1,
        type: MsgType.ping,
        nonce: nonce,
      );
      // Other device id expected.
      expect(
        await openPacket(good, key: key, expectDeviceId: hostId),
        isNull,
      );
      // Wrong magic / version.
      expect(await openPacket(Uint8List.fromList(good)..[0] = 0x58, key: key),
          isNull);
      expect(await openPacket(Uint8List.fromList(good)..[2] = 0x02, key: key),
          isNull);
      // Truncated (no room for the 9-byte prefix + tag).
      expect(await openPacket(good.sublist(0, 19 + 12 + 16), key: key), isNull);
      // Oversized.
      final big = Uint8List(Proto.maxPacket + 1)
        ..setRange(0, Proto.headerLength, buildHeader(deviceId));
      expect(await openPacket(big, key: key), isNull);
    });

    test('matches the independent ChaCha20-Poly1305 vector', () async {
      final packet = await sealPacket(
        deviceId: deviceId,
        key: key,
        session: 0x01020304,
        seq: 5,
        type: MsgType.move,
        payload: Payload.move(1.5, -2.25),
        nonce: nonce,
      );
      expect(
        hexEncode(packet),
        '4f4201000102030405060708090a0b0c0d0e0f'
        'a0a1a2a3a4a5a6a7a8a9aaab'
        'd4f62aa2d7f3682b98c1643e5c52a0643c'
        '90c366e9c6165cd2cd96eca5a5f3bd67',
      );
      // header(19) + nonce(12) + plaintext(17) + tag(16)
      expect(packet.length, 19 + 12 + 17 + 16);
    });

    test('round trips', () async {
      final packet = await sealPacket(
        deviceId: deviceId,
        key: key,
        session: 0xDEADBEEF,
        seq: 42,
        type: MsgType.scroll,
        payload: Payload.scroll(-3.5, 12.25),
        nonce: nonce,
      );
      final opened = await openPacket(packet, key: key, expectDeviceId: deviceId);
      expect(opened, isNotNull);
      expect(opened!.session, 0xDEADBEEF);
      expect(opened.seq, 42);
      expect(opened.type, MsgType.scroll);
      final d = ByteData.sublistView(opened.payload);
      expect(d.getFloat32(0), -3.5);
      expect(d.getFloat32(4), 12.25);
    });

    test('tampering with the header (AAD) fails authentication', () async {
      final packet = await sealPacket(
        deviceId: deviceId,
        key: key,
        session: 1,
        seq: 1,
        type: MsgType.ping,
        nonce: nonce,
      );
      final bad = Uint8List.fromList(packet)..[5] ^= 0x01;
      expect(await openPacket(bad, key: key), isNull);
    });

    test('wrong key fails', () async {
      final packet = await sealPacket(
        deviceId: deviceId,
        key: key,
        session: 1,
        seq: 1,
        type: MsgType.ping,
      );
      expect(await openPacket(packet, key: SecretKey(seq(32, 1))), isNull);
    });

    test('PONG parses echoSeq and os', () async {
      final packet = await sealPacket(
        deviceId: deviceId,
        key: key,
        session: 99,
        seq: 7,
        type: MsgType.pong,
        payload: <int>[0, 0, 0x01, 0x02, 1],
      );
      final opened = await openPacket(packet, key: key);
      final pong = Pong.parse(opened!.payload)!;
      expect(pong.echoSeq, 0x0102);
      expect(pong.os, HostOs.windows);
    });
  });

  group('pairing derivation', () {
    test('HKDF key and code match the independent vector', () async {
      final secrets = await derivePairingSecrets(
        sharedSecret: seq(32, 0x01),
        deviceId: deviceId,
        hostId: hostId,
      );
      expect(
        hexEncode(secrets.key),
        'e3cb501edbc96aa1a8276172ce93ed3ef9a10a019db612e3572d1e2335f2deed',
      );
      // code bytes 1d4f591d -> 491739421 % 1e6 = 739421
      expect(secrets.code, '739421');
    });

    test('code formatting pads to six digits and groups 3+3', () {
      expect(pairingCodeFromBytes(<int>[0, 0, 0, 1]), '000001');
      expect(pairingCodeFromBytes(<int>[0x1d, 0x4f, 0x59, 0x1d]), '739421');
      expect(pairingCodeFromBytes(<int>[0xff, 0xff, 0xff, 0xff]), '967295');
      expect(pairingCodeFromBytes(<int>[0x00, 0x0f, 0x42, 0x40]), '000000');
      expect(groupPairingCode('482913'), '482 913');
    });

    test('X25519 matches RFC 7748 §6.1', () async {
      final x = X25519();
      final alice = await x.newKeyPairFromSeed(hexDecode(
        '77076d0a7318a57d3c16c17251b26645df4c2f87ebc0992ab177fba51db92c2a',
      ));
      final alicePub = await alice.extractPublicKey();
      expect(
        hexEncode(alicePub.bytes),
        '8520f0098930a754748b7ddcb43ef75a0dbf3a0d26381af4eba4a98eaa9b4e6a',
      );
      final bobPub = SimplePublicKey(
        hexDecode(
          'de9edb7d7b7dc1b4d35b61c2ece435373f8343c85b78674dadfc7e146f882b4f',
        ),
        type: KeyPairType.x25519,
      );
      final shared = await x.sharedSecretKey(
        keyPair: alice,
        remotePublicKey: bobPub,
      );
      expect(
        hexEncode(await shared.extractBytes()),
        '4a5d9d5ba4ce2de1728e3bf480350f25e07e21c947d19e3376f09b3c1e161742',
      );
    });
  });

  group('helpers', () {
    test('hex round trip', () {
      expect(hexDecode(hexEncode(deviceId)), deviceId);
      expect(() => hexDecode('abc'), throwsFormatException);
    });

    test('typing diff', () {
      expect(diffTyping('', 'hi'), (backspaces: 0, insert: 'hi'));
      expect(diffTyping('hello', 'help'), (backspaces: 2, insert: 'p'));
      expect(diffTyping('ab', ''), (backspaces: 2, insert: ''));
      expect(diffTyping('a👍', 'a'), (backspaces: 1, insert: ''));
    });

    test('host:port parsing', () {
      expect(parseHostPort('192.168.1.5'), ('192.168.1.5', Proto.port));
      expect(parseHostPort(' 10.0.0.2:5000 '), ('10.0.0.2', 5000));
      expect(parseHostPort('[fe80::1]:47821'), ('fe80::1', 47821));
      expect(parseHostPort('fe80::1'), ('fe80::1', Proto.port));
    });
  });
}
