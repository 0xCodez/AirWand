# Security Policy

Orbit lets a phone move the mouse and type on a computer. A flaw here can mean someone else controlling your machine, so we take reports seriously.

## Reporting a vulnerability

**Please do not open a public issue.**

- Preferred: GitHub private vulnerability reporting, *Security → Report a vulnerability* on this repository (`https://github.com/OWNER/orbit/security/advisories/new`).
- Include: affected component (`desktop/`, `mobile/`, protocol), version or commit, steps or a proof of concept, and the impact you expect.

What to expect:

| Step | Target |
|---|---|
| Acknowledgement | within 3 business days |
| Initial assessment | within 10 business days |
| Fix or mitigation for high-severity issues | as soon as practical, usually within 30 days |

We will credit you in the release notes unless you prefer otherwise. Please give us a reasonable window to ship a fix before public disclosure.

## Supported versions

Orbit is pre-1.0. Only the latest release receives security fixes.

| Version | Supported |
|---|---|
| latest `v0.x` | yes |
| older | no |

## Threat model (v0.1)

This summary follows the security notes in [docs/PROTOCOL.md](docs/PROTOCOL.md).

### Assets

- **Control of the computer:** pointer, keyboard and text injection, media keys.
- **Pairing keys:** the 32-byte symmetric key shared by each phone / computer pair.

### What Orbit defends against

| Threat | Defense |
|---|---|
| A stranger on the same Wi-Fi tries to move your cursor or type | Every control packet is ChaCha20-Poly1305 encrypted and authenticated with the paired key. Unknown device IDs and failed decryptions are dropped silently, with no reply. |
| Man-in-the-middle during pairing (ARP or mDNS spoofing on the LAN) | Ephemeral X25519 exchange plus **numeric comparison**: the 6-digit code is derived from the shared secret and both device IDs with HKDF-SHA256, and the user must see the same code on both screens and click *Allow* on the computer. An attacker in the middle ends up with different codes. |
| Pairing without the owner noticing | The computer shows a native *Allow / Deny* dialog with the device name and code. Pairing times out after 60 s. |
| Fake computer in discovery (spoofed mDNS or broadcast reply) | Discovery is unauthenticated by design, but a fake host cannot complete pairing with matching codes, and a phone only sends control input to hosts it already holds a key for. |
| Replay within a session, reordering | Packets carry a per-session sequence number; the host accepts only increasing `seq` values. |
| Stuck input after a disconnect | The host releases held buttons and keys when a device goes quiet for 3 s or sends BYE. |
| Data leaving the network | There is no cloud service, no account and no telemetry. All traffic stays on the LAN. |

### Known limitations

- **Cross-session replay (v1 protocol).** An attacker on the LAN who recorded the encrypted packets of an earlier session can replay that recording after the device has started a newer session, because the host resets its sequence window when the session ID changes. The attacker cannot create new input or read anything, only repeat old input. Fix planned: a host-issued session challenge (protocol v2, see [docs/ROADMAP.md](docs/ROADMAP.md)).
- **Key storage.** In v0.1 pairing keys are kept in app-private storage on the phone and in the user's configuration directory on the computer, not yet in the OS keychain (Keychain / Android Keystore / Windows DPAPI). Anyone who can read your user account's files can copy them. Moving keys to secure storage is on the roadmap.
- **Metadata is visible on the LAN.** mDNS and broadcast replies reveal the computer's name, OS and that Orbit is installed. Packet timing and size are visible to anyone on the network, even though the content is not.
- **Denial of service.** Anyone on the LAN can flood UDP port 47821 or the pairing port. Orbit drops invalid traffic cheaply, but it does not try to resist a determined local flood.
- **Release signing.** v0.1 macOS builds are ad-hoc signed (not notarized), Windows builds are unsigned, Android APKs use a debug key, and the iOS IPA is unsigned. Download builds only from this repository's Releases page and check the published checksums when available.

### Out of scope

- A phone or computer that is already compromised (malware, a jailbroken or rooted device, a stolen unlocked phone that is already paired).
- Physical access to an unlocked computer.
- Attacks that require the user to approve a pairing request they did not start. Read the code before you click *Allow*.

If your phone is lost, **remove it from the paired devices on every computer** to revoke its key. Pairing a new phone does not revoke the old one, because each phone has its own device ID and key.
