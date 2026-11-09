# Roadmap

AirWand is pre-1.0. This is a direction, not a promise; priorities move with feedback. Ideas and votes are welcome in issues.

## v0.1 — First flight (this release)

The full loop, phone to computer, on a local network.

- **Hosts:** desktop agent for macOS (universal, Apple silicon + Intel) and Windows (x64), living in the menu bar / tray.
- **Phones:** one Flutter app for iPhone, Android and Solana Seeker / Saga.
- **Discovery:** AirDrop-like radar over mDNS (`_orbit._tcp`), UDP broadcast fallback, manual IP.
- **Pairing:** X25519 + HKDF-SHA256, 6-digit numeric comparison, native *Allow / Deny* on the computer.
- **Control:** ChaCha20-Poly1305 encrypted UDP, per-session sequence numbers, PING / PONG latency, auto-release of held input.
- **Modes:** Trackpad with gestures, Air pointer, Keys (live text + shortcut chips), Media + Presenter.
- **Multi-computer:** several paired hosts, three-finger swipe or host pill to switch.
- **Distribution:** GitHub Releases: ad-hoc signed macOS app, unsigned Windows exe, debug-signed APK, unsigned IPA for sideloading.

## v0.2 — Wider reach

### Protocol and security

- [ ] **Session challenge (anti-replay).** The host issues a fresh nonce that each new session must include, closing the cross-session replay gap described in [SECURITY.md](../SECURITY.md). Protocol `v2`, with a compatibility window for v1 peers.
- [ ] **Secure key storage.** Pairing keys move to iOS Keychain, Android Keystore, macOS Keychain and Windows DPAPI / Credential Manager.
- [ ] Signed and notarized macOS builds, signed Windows builds, published checksums.

### New ways to connect

- [ ] **Bluetooth HID mode on Android (no desktop agent).** The phone registers as a standard Bluetooth keyboard + mouse (Android `BluetoothHidDevice`), so it works with any computer, tablet or TV, with no install. Gesture-based features that need the agent (Air pointer mapping, OS-aware shortcuts) degrade gracefully. Not possible on iOS, which does not allow apps to act as HID devices.
- [ ] **Linux host.** Agent for Linux desktops: input via `uinput`, tray via StatusNotifierItem, mDNS via Avahi. X11 and Wayland.

### Apple ecosystem

- [ ] **Apple Watch.** Media and Presenter controls on the wrist, and a quick host switcher.
- [ ] **iOS widget and Live Activity.** Switch the active computer, or jump straight into Trackpad or Presenter, from the Home Screen, Lock Screen or Dynamic Island.

### Store releases

- [ ] **App Store** (iPhone) and **TestFlight** beta.
- [ ] **Google Play**, with a proper upload key instead of the debug key.
- [ ] **Solana dApp Store** for Seeker and Saga.

## Later

- Clipboard sync between phone and the active computer (opt-in).
- Per-computer settings (pointer speed, natural scrolling) and per-app shortcut chips.
- Custom gesture mapping.
- Presenter extras: laser-dot overlay drawn on the computer, slide timer, notes.
- Accessibility: switch control, larger targets, haptic-only feedback mode.
- Localisation of the app, starting with Russian.

## Not planned

- Cloud relay or remote control over the internet. AirWand stays on your local network.
- Accounts, telemetry or ads.
