//! Pairing cryptography (PROTOCOL.md §2): X25519 + HKDF-SHA256 key and 6-digit code derivation.

use anyhow::{bail, Result};
use hkdf::Hkdf;
use rand_core::{OsRng, RngCore};
use sha2::Sha256;
use x25519_dalek::{EphemeralSecret, PublicKey};

use crate::protocol::{DeviceId, HostId, SessionKey, HKDF_SALT, ID_LEN};

/// Fills an array with bytes from the OS CSPRNG.
pub fn random_bytes<const N: usize>() -> [u8; N] {
    let mut b = [0u8; N];
    OsRng.fill_bytes(&mut b);
    b
}

pub fn random_u32() -> u32 {
    OsRng.next_u32()
}

fn info(label: &[u8], device_id: &DeviceId, host_id: &HostId) -> Vec<u8> {
    let mut v = Vec::with_capacity(label.len() + 2 * ID_LEN);
    v.extend_from_slice(label);
    v.extend_from_slice(device_id);
    v.extend_from_slice(host_id);
    v
}

/// `key  = HKDF(shared, salt="orbit/v1", info="key"  || deviceId || hostId, L=32)`
/// `code = HKDF(shared, salt="orbit/v1", info="code" || deviceId || hostId, L=4)` → u32 BE % 1_000_000
pub fn derive(shared: &[u8; 32], device_id: &DeviceId, host_id: &HostId) -> (SessionKey, u32) {
    let hk = Hkdf::<Sha256>::new(Some(HKDF_SALT), shared);
    let mut key = [0u8; 32];
    hk.expand(&info(b"key", device_id, host_id), &mut key)
        .expect("32 bytes is a valid HKDF-SHA256 output length");
    let mut code = [0u8; 4];
    hk.expand(&info(b"code", device_id, host_id), &mut code)
        .expect("4 bytes is a valid HKDF-SHA256 output length");
    (key, u32::from_be_bytes(code) % 1_000_000)
}

/// Six digits, zero padded, without separator: `"004217"`.
pub fn code_digits(code: u32) -> String {
    format!("{:06}", code % 1_000_000)
}

/// Six digits grouped for display: `"004 217"`.
pub fn code_display(code: u32) -> String {
    let d = code_digits(code);
    format!("{} {}", &d[..3], &d[3..])
}

/// Host side of one pairing attempt. The ephemeral secret is consumed by `finish`.
pub struct Handshake {
    secret: EphemeralSecret,
    public: PublicKey,
}

pub struct PairingSecrets {
    pub key: SessionKey,
    pub code: u32,
}

impl Handshake {
    pub fn new() -> Self {
        let secret = EphemeralSecret::random_from_rng(OsRng);
        let public = PublicKey::from(&secret);
        Handshake { secret, public }
    }

    pub fn public_bytes(&self) -> [u8; 32] {
        *self.public.as_bytes()
    }

    pub fn finish(self, peer_public: [u8; 32], device_id: &DeviceId, host_id: &HostId) -> Result<PairingSecrets> {
        let shared = self.secret.diffie_hellman(&PublicKey::from(peer_public));
        if !shared.was_contributory() {
            bail!("peer sent a low-order X25519 public key");
        }
        let (key, code) = derive(shared.as_bytes(), device_id, host_id);
        Ok(PairingSecrets { key, code })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use x25519_dalek::StaticSecret;

    // Independent vector computed with Node.js `crypto` (X25519 via PKCS#8 raw keys,
    // hkdfSync('sha256', shared, 'orbit/v1', info, L)).
    const DEVICE_PUB: &str = "7b4e909bbe7ffe44c465a220037d608ee35897d31ef972f07f74892cb0f73f13";
    const HOST_PUB: &str = "0faa684ed28867b97f4a6a2dee5df8ce974e76b7018e3f22a1c4cf2678570f20";
    const SHARED: &str = "9e004098efc091d4ec2663b4e9f5cfd4d7064571690b4bea97ab146ab9f35056";
    const KEY: &str = "4227789d919ffd1eb403822d9965619879a8611e88219ed445ba229b1e756301";
    const CODE: u32 = 880_004; // 0x40115e04 % 1_000_000

    fn ids() -> (DeviceId, HostId) {
        let mut d = [0u8; 16];
        let mut h = [0u8; 16];
        for i in 0..16 {
            d[i] = i as u8;
            h[i] = 0xf0 + i as u8;
        }
        (d, h)
    }

    #[test]
    fn known_vector() {
        let dev = StaticSecret::from([0x11u8; 32]);
        let host = StaticSecret::from([0x22u8; 32]);
        let dev_pub = PublicKey::from(&dev);
        let host_pub = PublicKey::from(&host);
        assert_eq!(hex::encode(dev_pub.as_bytes()), DEVICE_PUB);
        assert_eq!(hex::encode(host_pub.as_bytes()), HOST_PUB);

        let s1 = dev.diffie_hellman(&host_pub);
        let s2 = host.diffie_hellman(&dev_pub);
        assert_eq!(s1.as_bytes(), s2.as_bytes());
        assert_eq!(hex::encode(s1.as_bytes()), SHARED);

        let (d, h) = ids();
        let (key, code) = derive(s1.as_bytes(), &d, &h);
        assert_eq!(hex::encode(key), KEY);
        assert_eq!(code, CODE);
        assert_eq!(code_digits(code), "880004");
        assert_eq!(code_display(code), "880 004");
    }

    #[test]
    fn derivation_is_deterministic_and_bound_to_ids() {
        let shared = [7u8; 32];
        let (d, h) = ids();
        let a = derive(&shared, &d, &h);
        let b = derive(&shared, &d, &h);
        assert_eq!(a, b);
        assert!(a.1 < 1_000_000);
        // Swapping roles or ids changes both outputs.
        let c = derive(&shared, &h, &d);
        assert_ne!(a.0, c.0);
        let mut d2 = d;
        d2[0] ^= 1;
        assert_ne!(a.0, derive(&shared, &d2, &h).0);
    }

    #[test]
    fn ephemeral_handshake_agrees_with_peer() {
        let (d, h) = ids();
        let host = Handshake::new();
        let host_pub = host.public_bytes();
        let device = Handshake::new();
        let device_pub = device.public_bytes();
        let a = host.finish(device_pub, &d, &h).unwrap();
        let b = device.finish(host_pub, &d, &h).unwrap();
        assert_eq!(a.key, b.key);
        assert_eq!(a.code, b.code);
    }

    #[test]
    fn low_order_point_is_rejected() {
        let (d, h) = ids();
        assert!(Handshake::new().finish([0u8; 32], &d, &h).is_err());
    }

    #[test]
    fn code_formatting_pads() {
        assert_eq!(code_digits(42), "000042");
        assert_eq!(code_display(42), "000 042");
    }
}
