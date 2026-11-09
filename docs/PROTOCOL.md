# Orbit Wire Protocol v1

The single source of truth for how the phone app (`mobile/`) talks to the desktop agent (`desktop/`).
Both sides MUST implement exactly this. If you change it, bump `v` and update both sides.

## Roles and ports

| Role | What | Where |
|------|------|-------|
| **Host** | Desktop agent on macOS / Windows | listens on **TCP 47821** (pairing) and **UDP 47821** (control) |
| **Device** | Phone app on iOS / Android (incl. Solana Seeker/Saga) | sends UDP from any local port, receives PONG on that same socket |

All multi-byte integers and floats are **big-endian**. Floats are IEEE-754 `f32`.
IDs (`deviceId`, `hostId`) are 16 random bytes, generated once and persisted. In JSON they are 32-char lowercase hex.

## 1. Discovery

**mDNS / Bonjour (primary).** Host advertises service type `_orbit._tcp` on port 47821 with instance name = computer name and TXT records:

| key | value |
|-----|-------|
| `id` | hostId (hex) |
| `name` | human computer name |
| `os` | `mac` or `windows` |
| `v` | `1` |

**UDP broadcast (fallback, for networks that block multicast).** Device sends the ASCII bytes `ORBIT?1` to `255.255.255.255:47821`. Host replies to the sender with UTF-8 JSON:
`{"t":"here","v":1,"id":"<hostId>","name":"Lev's MacBook","os":"mac","port":47821}`.
A host MUST ignore any other unencrypted UDP payload.

**Manual.** The device can also connect to a typed IP address.

## 2. Pairing (TCP 47821, newline-delimited JSON, one connection per pairing)

1. Device → Host: `{"t":"hello","v":1,"deviceId":"<hex>","name":"iPhone 17 Pro","platform":"ios|android","pub":"<base64 X25519 public key, 32 bytes>"}`
2. Host → Device: `{"t":"hello","v":1,"hostId":"<hex>","name":"Lev's MacBook","os":"mac|windows","pub":"<base64 X25519 public key>"}`
3. Both compute `shared = X25519(myPrivate, peerPublic)` and derive with **HKDF-SHA256**, `salt = UTF-8 "orbit/v1"`:
   - `key  = HKDF(shared, info = "key"  || deviceId(16 raw bytes) || hostId(16 raw bytes), L = 32)`
   - `code = HKDF(shared, info = "code" || deviceId || hostId, L = 4)` → read as `u32` big-endian, `% 1_000_000`, zero-padded to 6 digits.
4. Both show the 6-digit code. The host shows a native dialog: **"Allow ‹device name› to control this computer? Code 123 456"** with *Allow* / *Deny*.
5. Host → Device: `{"t":"paired","ok":true}` or `{"t":"paired","ok":false,"reason":"denied"}`. Timeout: 60 s → `ok:false, reason:"timeout"`.
6. On success both sides persist `(peerId, peerName, key)`. The host keeps one key per deviceId; the device keeps one key per hostId. Ephemeral X25519 key pairs are discarded.

Re-pairing an already-known deviceId replaces its key.

## 3. Control channel (UDP 47821, encrypted)

```
packet    = header(19) | nonce(12) | ciphertext | tag(16)
header    = 'O' 'B' | version u8 = 0x01 | deviceId (16 raw bytes)
AEAD      = ChaCha20-Poly1305 (IETF, 12-byte nonce), key = paired key, AAD = header
nonce     = 12 random bytes per packet
plaintext = session u32 | seq u32 | type u8 | payload
```

- `session` is random per app launch / per connection. `seq` starts at 1 and increments by 1 for every packet the device sends.
- Host accepts a packet iff it decrypts AND (`session` != last session for that device → reset, or `seq` > last seq). Otherwise drop silently.
- Unknown deviceId or failed decryption → drop silently, no reply.
- Max packet size 1200 bytes.

### Message types (device → host unless noted)

| type | name | payload | meaning |
|------|------|---------|---------|
| `0x01` | MOVE | `f32 dx, f32 dy` | relative pointer move in logical points, acceleration already applied on the phone |
| `0x02` | BUTTON | `u8 button, u8 down` | button 0 = left, 1 = right, 2 = middle; down 1 = press, 0 = release (used for drag) |
| `0x03` | CLICK | `u8 button, u8 count` | press+release, `count` 1–3 (double/triple click) |
| `0x04` | SCROLL | `f32 dx, f32 dy` | pixel scroll; `+dy` reveals content further down, `+dx` reveals content further right. Host accumulates fractions. The phone has already applied the user's "natural scrolling" choice. |
| `0x05` | GESTURE | `u8 id` | 1 overview (Mission Control / Task View), 2 app switcher, 3 show desktop, 4 previous Space/virtual desktop, 5 next Space/virtual desktop, 6 back, 7 forward, 8 zoom in, 9 zoom out. Host maps to OS shortcuts. |
| `0x06` | KEY | `u8 action, u8 mods, u16 usage` | action 0 tap, 1 down, 2 up. mods bitmask 1 shift, 2 ctrl, 4 alt/option, 8 meta (⌘ / Win). `usage` = USB HID keyboard usage ID (0x04 `a` … 0x1D `z`, 0x1E `1` … 0x27 `0`, 0x28 Enter, 0x29 Esc, 0x2A Backspace, 0x2B Tab, 0x2C Space, 0x3A–0x45 F1–F12, 0x4A Home, 0x4B PageUp, 0x4C Delete, 0x4D End, 0x4E PageDown, 0x4F Right, 0x50 Left, 0x51 Down, 0x52 Up). |
| `0x07` | TEXT | UTF-8 bytes (≤ 1000) | type this text as-is |
| `0x08` | MEDIA | `u8 id` | 1 play/pause, 2 next, 3 previous, 4 volume up, 5 volume down, 6 mute |
| `0x09` | AIM | `f32 yaw, f32 pitch` | air-pointer, radians relative to the phone's calibrated center (the phone zeroes on "Center"). Host maps yaw ±0.35 rad → full width of the virtual desktop, pitch ±0.20 rad → full height (+pitch = up), clamps, and smooths with a 1€ filter. |
| `0x0A` | PING | — | sent every 1 s while the control screen is open |
| `0x0B` | PONG | `u32 echoSeq, u8 os` | **host → device**, reply to PING, sent back to the packet's source address. Encrypted with the same key; header carries the *device's* deviceId. `os`: 0 mac, 1 windows. The host's own `session`/`seq` counters are independent. |
| `0x0C` | BYE | — | device is leaving; host releases any held buttons |

A host considers a device **connected** while it has received a valid packet in the last 3 s. When a device goes quiet, the host releases any held mouse buttons or keys.

## Security notes

- Pairing uses numeric comparison like Bluetooth: the user confirms the same 6 digits on both screens, which defeats a man-in-the-middle on the LAN.
- Every control packet is authenticated. Unpaired devices cannot move the cursor.
- Known v1 limitation: an attacker on the LAN who recorded an old session could replay it after the device starts a new session. v2 will add a host-issued session challenge.
