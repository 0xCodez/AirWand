# Orbit — phone app (Flutter)

One codebase for **iPhone**, **Android** and **Solana Seeker / Saga** (Android).
It turns the phone into a trackpad, air pointer, keyboard and media remote for
computers running the Orbit desktop agent, and lets you flick between several
paired computers.

The wire protocol is in [`../docs/PROTOCOL.md`](../docs/PROTOCOL.md) and the
visual language in [`../docs/DESIGN.md`](../docs/DESIGN.md).

## Repository layout

```
mobile/
  pubspec.yaml            name: orbit, Dart >=3.4, Flutter >=3.22
  lib/
    main.dart             wiring: no paired hosts → Discovery, else Control
    net/                  protocol.dart · pairing.dart · discovery.dart · control.dart · hosts.dart
    input/                trackpad_engine.dart (raw multi-touch) · trackpad_math.dart · air_tracker.dart
    state/                settings, deviceId, service scope, haptics
    ui/                   theme tokens, glass widgets, touch light, screens
  test/                   protocol_test.dart · trackpad_math_test.dart
  tool/bootstrap.sh       creates + patches android/ and ios/ (macOS / Linux)
  tool/bootstrap.ps1      the same for Windows developers
```

### Generated platform folders are not committed (v1)

`android/` and `ios/` are produced by `flutter create` and patched by
`tool/bootstrap.sh`. They are listed in `.gitignore`. This keeps the repo free
of thousands of template lines and lets every developer and CI job regenerate
them with whatever Flutter version they have. The bootstrap is idempotent:
run it as often as you like.

The patches it applies:

| file | change |
|------|--------|
| `android/app/src/main/AndroidManifest.xml` | `INTERNET`, `ACCESS_NETWORK_STATE`, `ACCESS_WIFI_STATE`, `CHANGE_WIFI_MULTICAST_STATE`, `VIBRATE`; app label **Orbit** |
| `android/app/build.gradle(.kts)` | `minSdk` at least 23 |
| `ios/Runner/Info.plist` | `NSLocalNetworkUsageDescription`, `NSBonjourServices = [_orbit._tcp]`, `NSMotionUsageDescription`, `CFBundleDisplayName = Orbit`, light status bar, portrait only |
| `ios/Runner.xcodeproj`, `ios/Podfile`, `AppFrameworkInfo.plist` | iOS deployment target at least 13.0 (bonsoir uses `NWBrowser`) |

## Prerequisites

- Flutter **3.22 or newer** (stable channel), which brings Dart 3.4+.
  `flutter doctor` should be green for the platform you target.
- `python3` (macOS and Linux already have it) for `bootstrap.sh`.
- **iPhone:** a Mac with Xcode 15+ and CocoaPods (`sudo gem install cocoapods`
  or `brew install cocoapods`).
- **Android / Seeker / Saga:** Android Studio or the Android SDK command-line
  tools, plus a USB cable.
- The Orbit desktop agent running on the Mac / Windows PC, on the **same
  Wi-Fi network** as the phone.

## First run

```bash
cd mobile
bash tool/bootstrap.sh      # Windows: powershell -ExecutionPolicy Bypass -File tool\bootstrap.ps1
flutter test                # protocol + trackpad math
flutter run                 # pick a connected device
```

## Run on an iPhone (free Apple ID works)

1. Plug the iPhone into the Mac and trust the computer.
2. `open ios/Runner.xcworkspace`, select the **Runner** target →
   *Signing & Capabilities* → tick *Automatically manage signing* and pick
   your **Personal Team** (sign in with any Apple ID in Xcode → Settings →
   Accounts). If the bundle id `app.orbit.orbit` is taken, change it to
   something unique such as `app.orbit.yourname`.
3. On the iPhone enable **Developer Mode**: Settings → Privacy & Security →
   Developer Mode → On, then restart (iOS 16+).
4. `flutter run --release` (or Run from Xcode).
5. First launch: Settings → General → VPN & Device Management → trust your
   developer certificate.

With a free Apple ID the app is signed for **7 days**; after that it stops
launching and you simply run `flutter run` again. A paid developer account
removes the limit.

### Local Network permission on iOS

iOS asks *“Orbit would like to find and connect to devices on your local
network”* the first time the app browses for computers. Tap **Allow** — without
it neither discovery nor the control channel can reach the computer. If you
declined: Settings → Privacy & Security → Local Network → Orbit.

Notes:

- Discovery uses Bonjour (`_orbit._tcp`, declared in `NSBonjourServices`).
- The UDP broadcast fallback (`ORBIT?1`) needs Apple's multicast entitlement
  (`com.apple.developer.networking.multicast`), which free accounts cannot
  get. On iOS the fallback therefore fails silently and Bonjour or
  **Enter IP manually** are used instead. Android uses both.
- Air mode reads the gyroscope via Core Motion; the motion usage string is
  included for completeness.

## Run on Android / Solana Seeker / Saga

1. Enable **Developer options** (Settings → About phone → tap *Build number*
   seven times), then **USB debugging**. On Seeker/Saga the path is the same
   (Settings → About phone).
2. Connect the phone, accept the RSA prompt, check with `flutter devices`.
3. `flutter run --release`.

Or install a prebuilt APK: download `orbit-*.apk` from the project's
**GitHub Releases**, open it on the phone and allow *Install unknown apps* for
your browser or file manager when asked. (Build one yourself with
`flutter build apk --release`.)

## How it works (short)

- **Discovery** (`lib/net/discovery.dart`): bonsoir browses `_orbit._tcp`
  and reads TXT `id/name/os/v`; in parallel a UDP socket with
  `broadcastEnabled = true` sends `ORBIT?1` to `255.255.255.255:47821`
  every 2 s. Results are merged by `hostId`.
- **Pairing** (`lib/net/pairing.dart`): TCP 47821, newline JSON, ephemeral
  X25519; `key = HKDF-SHA256(shared, salt "orbit/v1", info "key"‖deviceId‖hostId, 32)`
  and the 6-digit code from `info "code"…`, 4 bytes, `u32 % 1 000 000`.
- **Control** (`lib/net/control.dart`): one UDP socket, ChaCha20-Poly1305
  with AAD = 19-byte header, random 12-byte nonce, random `session` per
  connection and `seq` +1 per packet. MOVE/SCROLL/AIM are coalesced at
  ~125 Hz; every packet goes through one serial queue so `seq` is strictly
  increasing on the wire. PING every second; PONG gives the latency dot.
- **Trackpad** (`lib/input/trackpad_engine.dart`): raw `Listener` pointer
  events (no gesture arena delay). Acceleration curve in
  `trackpad_math.dart` (tested).
- **Air** (`lib/input/air_tracker.dart`): gyro rate projected on gravity for
  yaw (works flat or upright), pitch fused with the accelerometer
  (complementary filter, 0.98), *Center* zeroes both.

## Known v1 limitations

- Pairing keys live in `shared_preferences` (base64). v2: move them to
  `flutter_secure_storage` (Keychain / Android Keystore).
- The TEXT diff works per grapheme; IME composition (CJK) sends intermediate
  text.
