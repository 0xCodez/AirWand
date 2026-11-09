//! Orbit wire protocol v1 — see `docs/PROTOCOL.md`, which is the binding contract.
//!
//! ```text
//! packet    = header(19) | nonce(12) | ciphertext | tag(16)
//! header    = 'O' 'B' | version u8 = 0x01 | deviceId (16 raw bytes)
//! AEAD      = ChaCha20-Poly1305 (IETF), key = paired key, AAD = header
//! plaintext = session u32 | seq u32 | type u8 | payload       (all big-endian)
//! ```

use std::fmt;

use chacha20poly1305::aead::{Aead, KeyInit, Payload};
use chacha20poly1305::{ChaCha20Poly1305, Key, Nonce};

/// TCP (pairing) and UDP (control + broadcast discovery) port.
pub const PORT: u16 = 47821;
pub const PROTOCOL_VERSION: u8 = 1;
pub const MAGIC: [u8; 2] = *b"OB";
pub const ID_LEN: usize = 16;
pub const KEY_LEN: usize = 32;
pub const HEADER_LEN: usize = 2 + 1 + ID_LEN; // 19
pub const NONCE_LEN: usize = 12;
pub const TAG_LEN: usize = 16;
/// session u32 + seq u32 + type u8
pub const PLAIN_PREFIX_LEN: usize = 9;
pub const MIN_PACKET_LEN: usize = HEADER_LEN + NONCE_LEN + PLAIN_PREFIX_LEN + TAG_LEN;
pub const MAX_PACKET_LEN: usize = 1200;
pub const MAX_TEXT_LEN: usize = 1000;

/// Unencrypted UDP broadcast probe sent by devices (fallback discovery).
pub const DISCOVERY_PROBE: &[u8] = b"ORBIT?1";
/// mDNS service type (fully qualified, as mdns-sd expects it).
pub const SERVICE_TYPE: &str = "_orbit._tcp.local.";
/// HKDF salt for the pairing key derivation.
pub const HKDF_SALT: &[u8] = b"orbit/v1";

/// A device is "connected" while a valid packet arrived within this window.
pub const CONNECTED_WINDOW_MS: u64 = 3000;

/// AIM mapping: yaw ±0.35 rad spans the full desktop width, pitch ±0.20 rad the full height.
pub const AIM_YAW_HALF_RANGE: f32 = 0.35;
pub const AIM_PITCH_HALF_RANGE: f32 = 0.20;

pub type DeviceId = [u8; ID_LEN];
pub type HostId = [u8; ID_LEN];
pub type SessionKey = [u8; KEY_LEN];

/// Value for the `os` TXT record / JSON fields.
#[cfg(target_os = "macos")]
pub const HOST_OS: &str = "mac";
#[cfg(not(target_os = "macos"))]
pub const HOST_OS: &str = "windows";

/// Value for the `os` byte in PONG: 0 mac, 1 windows.
#[cfg(target_os = "macos")]
pub const HOST_OS_CODE: u8 = 0;
#[cfg(not(target_os = "macos"))]
pub const HOST_OS_CODE: u8 = 1;

pub mod msg_type {
    pub const MOVE: u8 = 0x01;
    pub const BUTTON: u8 = 0x02;
    pub const CLICK: u8 = 0x03;
    pub const SCROLL: u8 = 0x04;
    pub const GESTURE: u8 = 0x05;
    pub const KEY: u8 = 0x06;
    pub const TEXT: u8 = 0x07;
    pub const MEDIA: u8 = 0x08;
    pub const AIM: u8 = 0x09;
    pub const PING: u8 = 0x0A;
    pub const PONG: u8 = 0x0B;
    pub const BYE: u8 = 0x0C;
}

/// KEY modifier bitmask.
pub mod mods {
    pub const SHIFT: u8 = 1;
    pub const CTRL: u8 = 2;
    pub const ALT: u8 = 4;
    pub const META: u8 = 8;
}

/// KEY action byte.
pub mod key_action {
    pub const TAP: u8 = 0;
    pub const DOWN: u8 = 1;
    pub const UP: u8 = 2;
}

#[derive(Debug, Clone, PartialEq)]
pub enum Message {
    Move { dx: f32, dy: f32 },
    Button { button: u8, down: bool },
    Click { button: u8, count: u8 },
    Scroll { dx: f32, dy: f32 },
    Gesture(u8),
    Key { action: u8, mods: u8, usage: u16 },
    Text(String),
    Media(u8),
    Aim { yaw: f32, pitch: f32 },
    Ping,
    Pong { echo_seq: u32, os: u8 },
    Bye,
}

#[derive(Debug, Clone, PartialEq)]
pub struct Plaintext {
    pub session: u32,
    pub seq: u32,
    pub msg: Message,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum PacketError {
    TooShort,
    TooLong,
    BadMagic,
    BadVersion(u8),
    Decrypt,
    BadPayload(u8),
    UnknownType(u8),
}

impl fmt::Display for PacketError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            PacketError::TooShort => write!(f, "packet too short"),
            PacketError::TooLong => write!(f, "packet too long"),
            PacketError::BadMagic => write!(f, "bad magic"),
            PacketError::BadVersion(v) => write!(f, "unsupported version {v}"),
            PacketError::Decrypt => write!(f, "authentication failed"),
            PacketError::BadPayload(t) => write!(f, "malformed payload for type 0x{t:02x}"),
            PacketError::UnknownType(t) => write!(f, "unknown message type 0x{t:02x}"),
        }
    }
}

impl std::error::Error for PacketError {}

fn f32_at(b: &[u8], at: usize) -> f32 {
    f32::from_be_bytes([b[at], b[at + 1], b[at + 2], b[at + 3]])
}

fn u32_at(b: &[u8], at: usize) -> u32 {
    u32::from_be_bytes([b[at], b[at + 1], b[at + 2], b[at + 3]])
}

fn finite_pair(ty: u8, a: f32, b: f32) -> Result<(f32, f32), PacketError> {
    if a.is_finite() && b.is_finite() {
        Ok((a, b))
    } else {
        Err(PacketError::BadPayload(ty))
    }
}

impl Message {
    pub fn type_byte(&self) -> u8 {
        use msg_type::*;
        match self {
            Message::Move { .. } => MOVE,
            Message::Button { .. } => BUTTON,
            Message::Click { .. } => CLICK,
            Message::Scroll { .. } => SCROLL,
            Message::Gesture(_) => GESTURE,
            Message::Key { .. } => KEY,
            Message::Text(_) => TEXT,
            Message::Media(_) => MEDIA,
            Message::Aim { .. } => AIM,
            Message::Ping => PING,
            Message::Pong { .. } => PONG,
            Message::Bye => BYE,
        }
    }

    /// Appends the payload (without the type byte) to `out`.
    pub fn encode_payload(&self, out: &mut Vec<u8>) {
        match self {
            Message::Move { dx, dy } | Message::Scroll { dx, dy } => {
                out.extend_from_slice(&dx.to_be_bytes());
                out.extend_from_slice(&dy.to_be_bytes());
            }
            Message::Aim { yaw, pitch } => {
                out.extend_from_slice(&yaw.to_be_bytes());
                out.extend_from_slice(&pitch.to_be_bytes());
            }
            Message::Button { button, down } => {
                out.push(*button);
                out.push(u8::from(*down));
            }
            Message::Click { button, count } => {
                out.push(*button);
                out.push(*count);
            }
            Message::Gesture(id) | Message::Media(id) => out.push(*id),
            Message::Key { action, mods, usage } => {
                out.push(*action);
                out.push(*mods);
                out.extend_from_slice(&usage.to_be_bytes());
            }
            Message::Text(s) => out.extend_from_slice(s.as_bytes()),
            Message::Pong { echo_seq, os } => {
                out.extend_from_slice(&echo_seq.to_be_bytes());
                out.push(*os);
            }
            Message::Ping | Message::Bye => {}
        }
    }

    /// Decodes a message from its type byte and payload. Trailing bytes beyond the
    /// documented payload are ignored (forward compatibility), short payloads are rejected.
    pub fn decode(ty: u8, p: &[u8]) -> Result<Message, PacketError> {
        use msg_type::*;
        let need = |n: usize| if p.len() >= n { Ok(()) } else { Err(PacketError::BadPayload(ty)) };
        Ok(match ty {
            MOVE => {
                need(8)?;
                let (dx, dy) = finite_pair(ty, f32_at(p, 0), f32_at(p, 4))?;
                Message::Move { dx, dy }
            }
            BUTTON => {
                need(2)?;
                Message::Button { button: p[0], down: p[1] != 0 }
            }
            CLICK => {
                need(2)?;
                Message::Click { button: p[0], count: p[1] }
            }
            SCROLL => {
                need(8)?;
                let (dx, dy) = finite_pair(ty, f32_at(p, 0), f32_at(p, 4))?;
                Message::Scroll { dx, dy }
            }
            GESTURE => {
                need(1)?;
                Message::Gesture(p[0])
            }
            KEY => {
                need(4)?;
                Message::Key { action: p[0], mods: p[1], usage: u16::from_be_bytes([p[2], p[3]]) }
            }
            TEXT => {
                if p.len() > MAX_TEXT_LEN {
                    return Err(PacketError::BadPayload(ty));
                }
                let s = std::str::from_utf8(p).map_err(|_| PacketError::BadPayload(ty))?;
                Message::Text(s.to_owned())
            }
            MEDIA => {
                need(1)?;
                Message::Media(p[0])
            }
            AIM => {
                need(8)?;
                let (yaw, pitch) = finite_pair(ty, f32_at(p, 0), f32_at(p, 4))?;
                Message::Aim { yaw, pitch }
            }
            PING => Message::Ping,
            PONG => {
                need(5)?;
                Message::Pong { echo_seq: u32_at(p, 0), os: p[4] }
            }
            BYE => Message::Bye,
            other => return Err(PacketError::UnknownType(other)),
        })
    }
}

/// Builds the 19-byte header (also the AEAD associated data).
pub fn header(device_id: &DeviceId) -> [u8; HEADER_LEN] {
    let mut h = [0u8; HEADER_LEN];
    h[0..2].copy_from_slice(&MAGIC);
    h[2] = PROTOCOL_VERSION;
    h[3..].copy_from_slice(device_id);
    h
}

/// Validates the cleartext header and returns the deviceId it names.
pub fn peek_device_id(packet: &[u8]) -> Result<DeviceId, PacketError> {
    if packet.len() < MIN_PACKET_LEN {
        return Err(PacketError::TooShort);
    }
    if packet.len() > MAX_PACKET_LEN {
        return Err(PacketError::TooLong);
    }
    if packet[0..2] != MAGIC {
        return Err(PacketError::BadMagic);
    }
    if packet[2] != PROTOCOL_VERSION {
        return Err(PacketError::BadVersion(packet[2]));
    }
    let mut id = [0u8; ID_LEN];
    id.copy_from_slice(&packet[3..HEADER_LEN]);
    Ok(id)
}

/// Encrypts a packet. `nonce` must be fresh random bytes for every packet.
pub fn seal(device_id: &DeviceId, key: &SessionKey, plain: &Plaintext, nonce: &[u8; NONCE_LEN]) -> Vec<u8> {
    let hdr = header(device_id);
    let mut pt = Vec::with_capacity(PLAIN_PREFIX_LEN + 16);
    pt.extend_from_slice(&plain.session.to_be_bytes());
    pt.extend_from_slice(&plain.seq.to_be_bytes());
    pt.push(plain.msg.type_byte());
    plain.msg.encode_payload(&mut pt);

    let cipher = ChaCha20Poly1305::new(Key::from_slice(key));
    let ct = cipher
        .encrypt(Nonce::from_slice(nonce), Payload { msg: &pt, aad: &hdr })
        .expect("ChaCha20-Poly1305 encryption cannot fail for in-memory buffers");

    let mut out = Vec::with_capacity(HEADER_LEN + NONCE_LEN + ct.len());
    out.extend_from_slice(&hdr);
    out.extend_from_slice(nonce);
    out.extend_from_slice(&ct);
    out
}

/// Authenticates, decrypts and decodes a packet.
pub fn open(packet: &[u8], key: &SessionKey) -> Result<Plaintext, PacketError> {
    peek_device_id(packet)?;
    let aad = &packet[..HEADER_LEN];
    let nonce = &packet[HEADER_LEN..HEADER_LEN + NONCE_LEN];
    let ct = &packet[HEADER_LEN + NONCE_LEN..];

    let cipher = ChaCha20Poly1305::new(Key::from_slice(key));
    let pt = cipher
        .decrypt(Nonce::from_slice(nonce), Payload { msg: ct, aad })
        .map_err(|_| PacketError::Decrypt)?;
    if pt.len() < PLAIN_PREFIX_LEN {
        return Err(PacketError::TooShort);
    }
    let session = u32_at(&pt, 0);
    let seq = u32_at(&pt, 4);
    let msg = Message::decode(pt[8], &pt[PLAIN_PREFIX_LEN..])?;
    Ok(Plaintext { session, seq, msg })
}

/// Per-device replay protection (PROTOCOL.md §3):
/// accept iff `session` differs from the last accepted one (reset), or `seq` > last seq.
#[derive(Debug, Default, Clone)]
pub struct ReplayGuard {
    last: Option<(u32, u32)>,
}

impl ReplayGuard {
    pub fn accept(&mut self, session: u32, seq: u32) -> bool {
        match self.last {
            Some((s, last_seq)) if s == session => {
                if seq > last_seq {
                    self.last = Some((session, seq));
                    true
                } else {
                    false
                }
            }
            _ => {
                self.last = Some((session, seq));
                true
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    // Vector generated independently with Node.js `crypto` (x25519 + hkdf + chacha20-poly1305);
    // see crypto.rs tests for the derivation of this key.
    const KEY_HEX: &str = "4227789d919ffd1eb403822d9965619879a8611e88219ed445ba229b1e756301";
    const PACKET_HEX: &str = "4f4201000102030405060708090a0b0c0d0e0fa0a1a2a3a4a5a6a7a8a9aaab\
76b6735c96abcb6a96dcdfd84cf102f3233bc737999f7a436ea16eb60b6e59764e";

    fn key() -> SessionKey {
        let mut k = [0u8; 32];
        hex::decode_to_slice(KEY_HEX, &mut k).unwrap();
        k
    }

    fn device_id() -> DeviceId {
        let mut d = [0u8; 16];
        for (i, b) in d.iter_mut().enumerate() {
            *b = i as u8;
        }
        d
    }

    fn nonce() -> [u8; 12] {
        let mut n = [0u8; 12];
        for (i, b) in n.iter_mut().enumerate() {
            *b = 0xa0 + i as u8;
        }
        n
    }

    #[test]
    fn header_layout() {
        let h = header(&device_id());
        assert_eq!(h.len(), 19);
        assert_eq!(&h[..3], &[b'O', b'B', 1]);
        assert_eq!(&h[3..], &device_id());
    }

    #[test]
    fn known_vector_seal_and_open() {
        let plain = Plaintext { session: 0x0102_0304, seq: 5, msg: Message::Move { dx: 1.5, dy: -2.25 } };
        let packet = seal(&device_id(), &key(), &plain, &nonce());
        assert_eq!(hex::encode(&packet), PACKET_HEX);

        let expected = hex::decode(PACKET_HEX).unwrap();
        assert_eq!(peek_device_id(&expected).unwrap(), device_id());
        assert_eq!(open(&expected, &key()).unwrap(), plain);
    }

    // More vectors from Node.js `crypto` (same key / deviceId / nonce as above):
    // KEY tap, mods META|SHIFT (0x09), usage 0x0052 Up; session 0xdeadbeef, seq 7.
    const KEY_PACKET_HEX: &str = "4f4201000102030405060708090a0b0c0d0e0fa0a1a2a3a4a5a6a7a8a9aaab\
a919ceb796abcb6891e316d81ee0beaddb0120913975e519fb9c1ca001";
    // PONG echoSeq 0x01020304, os 1 (windows); session 0x0a0b0c0d, seq 1.
    const PONG_PACKET_HEX: &str = "4f4201000102030405060708090a0b0c0d0e0fa0a1a2a3a4a5a6a7a8a9aaab\
7dbf7c5596abcb6e9ce21ddb4830a675cbdb5ff76c5277349735c22ac0c8";

    /// Decrypts with the bare AEAD (no decoding) to inspect the plaintext bytes.
    fn raw_plaintext(pkt: &[u8]) -> Vec<u8> {
        let cipher = ChaCha20Poly1305::new(Key::from_slice(&key()));
        cipher
            .decrypt(
                Nonce::from_slice(&pkt[HEADER_LEN..HEADER_LEN + NONCE_LEN]),
                Payload { msg: &pkt[HEADER_LEN + NONCE_LEN..], aad: &pkt[..HEADER_LEN] },
            )
            .expect("packet authenticates")
    }

    #[test]
    fn known_vectors_key_and_pong() {
        let key_msg = Plaintext {
            session: 0xdead_beef,
            seq: 7,
            msg: Message::Key { action: key_action::TAP, mods: mods::META | mods::SHIFT, usage: 0x0052 },
        };
        assert_eq!(hex::encode(seal(&device_id(), &key(), &key_msg, &nonce())), KEY_PACKET_HEX);
        assert_eq!(open(&hex::decode(KEY_PACKET_HEX).unwrap(), &key()).unwrap(), key_msg);

        let pong = Plaintext { session: 0x0a0b_0c0d, seq: 1, msg: Message::Pong { echo_seq: 0x0102_0304, os: 1 } };
        assert_eq!(hex::encode(seal(&device_id(), &key(), &pong, &nonce())), PONG_PACKET_HEX);
        assert_eq!(open(&hex::decode(PONG_PACKET_HEX).unwrap(), &key()).unwrap(), pong);
    }

    #[test]
    fn packet_offsets() {
        assert_eq!(HEADER_LEN, 19);
        assert_eq!(MIN_PACKET_LEN, 19 + 12 + 9 + 16);
        let plain = Plaintext { session: 1, seq: 1, msg: Message::Ping };
        let pkt = seal(&device_id(), &key(), &plain, &nonce());
        // header(19) | nonce(12) | ciphertext(9 = session + seq + type) | tag(16)
        assert_eq!(pkt.len(), MIN_PACKET_LEN);
        assert_eq!(&pkt[..HEADER_LEN], &header(&device_id()));
        assert_eq!(&pkt[HEADER_LEN..HEADER_LEN + NONCE_LEN], &nonce());
        assert_eq!(raw_plaintext(&pkt).len(), PLAIN_PREFIX_LEN);
    }

    #[test]
    fn plaintext_byte_layout() {
        // Expected payload bytes after `session u32 BE | seq u32 BE`, type byte first.
        let cases: Vec<(Message, &str)> = vec![
            (Message::Move { dx: 1.5, dy: -2.25 }, "01 3fc00000 c0100000"),
            (Message::Button { button: 2, down: true }, "02 02 01"),
            (Message::Button { button: 0, down: false }, "02 00 00"),
            (Message::Click { button: 1, count: 3 }, "03 01 03"),
            (Message::Scroll { dx: -0.5, dy: 100.0 }, "04 bf000000 42c80000"),
            (Message::Gesture(9), "05 09"),
            (Message::Key { action: key_action::UP, mods: 0x0f, usage: 0x1234 }, "06 02 0f 1234"),
            (Message::Text("hé".to_string()), "07 68c3a9"),
            (Message::Media(6), "08 06"),
            (Message::Aim { yaw: 0.25, pitch: -1.0 }, "09 3e800000 bf800000"),
            (Message::Ping, "0a"),
            (Message::Pong { echo_seq: 0x0102_0304, os: 1 }, "0b 01020304 01"),
            (Message::Bye, "0c"),
        ];
        for (msg, body) in cases {
            let plain = Plaintext { session: 0x1122_3344, seq: 0x5566_7788, msg };
            let pkt = seal(&device_id(), &key(), &plain, &nonce());
            let expected = format!("1122334455667788{}", body.replace(' ', ""));
            assert_eq!(hex::encode(raw_plaintext(&pkt)), expected, "{:?}", plain.msg);
            assert_eq!(pkt.len(), HEADER_LEN + NONCE_LEN + expected.len() / 2 + TAG_LEN);
        }
    }

    #[test]
    fn decode_reads_big_endian_and_ignores_trailing_bytes() {
        assert_eq!(
            Message::decode(msg_type::KEY, &[1, 8, 0x00, 0x2c, 0xff]),
            Ok(Message::Key { action: key_action::DOWN, mods: mods::META, usage: 0x002c })
        );
        assert_eq!(
            Message::decode(msg_type::PONG, &[0, 0, 1, 0, 0]),
            Ok(Message::Pong { echo_seq: 256, os: 0 })
        );
        assert_eq!(Message::decode(msg_type::BUTTON, &[0, 7]), Ok(Message::Button { button: 0, down: true }));
        assert_eq!(Message::decode(msg_type::PING, &[1, 2, 3]), Ok(Message::Ping));
        assert!(Message::decode(msg_type::KEY, &[0, 0, 0]).is_err());
        assert!(Message::decode(msg_type::PONG, &[0, 0, 0, 0]).is_err());
        assert_eq!(Message::decode(msg_type::TEXT, &[]), Ok(Message::Text(String::new())));
    }

    #[test]
    fn round_trip_all_messages() {
        let msgs = vec![
            Message::Move { dx: -3.25, dy: 7.0 },
            Message::Button { button: 1, down: true },
            Message::Click { button: 0, count: 2 },
            Message::Scroll { dx: 0.5, dy: -12.75 },
            Message::Gesture(5),
            Message::Key { action: key_action::TAP, mods: mods::META | mods::SHIFT, usage: 0x52 },
            Message::Text("Привет, Orbit ✨".to_string()),
            Message::Media(4),
            Message::Aim { yaw: -0.1, pitch: 0.05 },
            Message::Ping,
            Message::Pong { echo_seq: 4_000_000_000, os: HOST_OS_CODE },
            Message::Bye,
        ];
        for (i, msg) in msgs.into_iter().enumerate() {
            let plain = Plaintext { session: 0xdead_beef, seq: i as u32 + 1, msg };
            let pkt = seal(&device_id(), &key(), &plain, &nonce());
            assert!(pkt.len() <= MAX_PACKET_LEN);
            assert_eq!(open(&pkt, &key()).unwrap(), plain);
        }
    }

    #[test]
    fn tampering_is_rejected() {
        let mut pkt = hex::decode(PACKET_HEX).unwrap();
        // Flip a bit in the header (AAD): must fail authentication.
        pkt[5] ^= 0x01;
        assert_eq!(open(&pkt, &key()), Err(PacketError::Decrypt));

        let mut pkt = hex::decode(PACKET_HEX).unwrap();
        let last = pkt.len() - 1;
        pkt[last] ^= 0x80;
        assert_eq!(open(&pkt, &key()), Err(PacketError::Decrypt));

        let pkt = hex::decode(PACKET_HEX).unwrap();
        let mut wrong = key();
        wrong[0] ^= 1;
        assert_eq!(open(&pkt, &wrong), Err(PacketError::Decrypt));
    }

    #[test]
    fn probe_and_garbage_are_not_packets() {
        assert_eq!(peek_device_id(DISCOVERY_PROBE), Err(PacketError::TooShort));
        let mut junk = vec![0u8; 80];
        junk[0] = b'X';
        assert_eq!(peek_device_id(&junk), Err(PacketError::BadMagic));
        let mut v2 = hex::decode(PACKET_HEX).unwrap();
        v2[2] = 2;
        assert_eq!(peek_device_id(&v2), Err(PacketError::BadVersion(2)));
        assert_eq!(peek_device_id(&vec![b'O'; MAX_PACKET_LEN + 1]), Err(PacketError::TooLong));
    }

    #[test]
    fn malformed_payloads() {
        assert!(Message::decode(msg_type::MOVE, &[0; 4]).is_err());
        assert!(Message::decode(msg_type::MOVE, &f32::NAN.to_be_bytes().repeat(2)).is_err());
        assert!(Message::decode(msg_type::TEXT, &[0xff, 0xfe]).is_err());
        assert!(Message::decode(msg_type::TEXT, &vec![b'a'; MAX_TEXT_LEN + 1]).is_err());
        assert_eq!(Message::decode(0x7f, &[]), Err(PacketError::UnknownType(0x7f)));
    }

    #[test]
    fn replay_rule() {
        let mut g = ReplayGuard::default();
        assert!(g.accept(10, 1));
        assert!(g.accept(10, 2));
        assert!(!g.accept(10, 2), "duplicate seq must be dropped");
        assert!(!g.accept(10, 1), "older seq must be dropped");
        assert!(g.accept(10, 5), "gaps are fine");
        assert!(!g.accept(10, 4));
        // New session resets the counter, even with a low seq.
        assert!(g.accept(11, 1));
        assert!(g.accept(11, 2));
        // Going back to the old session is a "different session" again → reset (documented v1 limitation).
        assert!(g.accept(10, 1));
        assert!(!g.accept(10, 1));
    }
}
