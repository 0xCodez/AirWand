# AirWand for Mac & Windows (host agent)

A small menu-bar / tray app that lets a paired phone running AirWand act as a trackpad, air
pointer, keyboard and media remote for this computer. It implements the **Host** side of
[`docs/PROTOCOL.md`](../docs/PROTOCOL.md) (v1).

| | |
|---|---|
| Discovery | mDNS `_orbit._tcp` on port 47821 (TXT `id`, `name`, `os`, `v`) + reply to the `ORBIT?1` UDP broadcast |
| Pairing | TCP 47821, newline JSON, X25519 + HKDF-SHA256, 6-digit code confirmed in a native Allow / Deny dialog (60 s timeout) |
| Control | UDP 47821, ChaCha20-Poly1305 with the header as AAD, per-device session/seq replay protection, PING → PONG |
| Safety | held buttons and keys are released on BYE, on Pause, on Quit and when a device is silent for 3 s |

## Build

Requires a stable Rust toolchain (1.77+).

```sh
cd desktop
cargo build --release          # binary: target/release/airwand (airwand.exe on Windows)
cargo test                     # protocol, crypto, keymap, filter and config tests
RUST_LOG=debug cargo run       # run from source with verbose logs
```

Run the tests on macOS or Windows. On Linux, `tray-icon`, `tao` and `enigo` need GTK / X11
development packages, and Linux is not a supported host anyway.

### macOS

```sh
./scripts/bundle-macos.sh        # universal (arm64 + x86_64) dist/AirWand.app, ad-hoc signed
./scripts/bundle-macos.sh --zip  # also dist/AirWand-macos.zip
open dist/AirWand.app
```

The bundle uses `macos/Info.plist`: `LSUIElement` (no Dock icon), bundle id
`app.airwand.desktop`, `NSLocalNetworkUsageDescription` and `NSBonjourServices = [_orbit._tcp]`.

### Windows

```powershell
cargo build --release
.\target\release\airwand.exe
```

Release builds use the GUI subsystem, so no console window opens. Logs go to
`%APPDATA%\AirWand\airwand.log` instead.

## Permissions

### macOS: Accessibility (required)

macOS only lets apps post mouse and keyboard events after you grant Accessibility access. On
first start AirWand calls `AXIsProcessTrustedWithOptions(prompt: true)`, which opens the
system prompt. Go to **System Settings → Privacy & Security → Accessibility** and enable
**AirWand**, or the `airwand` binary / your terminal if you run it from source. Until you do,
the menu shows a ⚠ line and the log prints a warning. AirWand checks again every 5 s, but
some macOS versions only honour the grant after you restart AirWand.

The ad-hoc signature changes on every rebuild, so macOS treats each new build as a different
app. If input stops working after a rebuild, remove the old AirWand entry from the
Accessibility list and add it again.

### macOS: Local Network

macOS 15 and later ask "Allow AirWand to find devices on local networks?" the first time.
Choose **Allow**. Without it, Bonjour and the UDP control channel are blocked. To change it
later, use System Settings → Privacy & Security → Local Network.

### Windows: firewall

Phones must reach TCP and UDP 47821, plus UDP 5353 for mDNS. There are two options:

* Accept the Windows Defender Firewall prompt the first time `airwand.exe` starts. Tick
  **Private networks**.
* Or, once, from an **elevated** PowerShell:

  ```powershell
  powershell -ExecutionPolicy Bypass -File .\scripts\firewall-windows.ps1
  # options: -Profiles Private,Domain   -Program C:\path\to\airwand.exe   -Remove
  ```

Make sure your Wi-Fi network is set to **Private** (Settings → Network & internet → Wi-Fi →
your network).

### Windows: elevated apps

Windows blocks input injected by a normal process into windows of apps that run as
administrator (UIPI), including Task Manager and installers. If you need to control those,
run AirWand as administrator.

## Using it

1. Start AirWand. The ring icon appears in the menu bar or notification area, with the status
   "Waiting for devices".
2. In the phone app, tap this computer in the radar, or enter its IP address.
3. Check that both screens show the same 6-digit code, then click **Allow**. On Windows,
   click **Yes**.
4. The status changes to "Connected: ‹phone›".

Tray menu items:

* The status line.
* This computer's name.
* **Pause control / Resume control**: while paused, input is ignored but PINGs are still
  answered.
* **Paired devices**: the paired phones (● marks connected ones) and **Forget all**.
* **Quit AirWand**: releases held input and stops advertising.

## Configuration

The config is JSON at:

* macOS: `~/Library/Application Support/AirWand/config.json` (directory `0700`, file `0600`)
* Windows: `%APPDATA%\AirWand\config.json`

```json
{
  "hostId": "32 hex chars, generated once",
  "hostName": "Lev's MacBook Pro",
  "invertScroll": false,
  "paired": [
    { "deviceId": "…", "name": "iPhone 17 Pro", "platform": "ios", "key": "base64 32-byte key" }
  ]
}
```

* `hostName` defaults to the macOS Computer Name (`scutil --get ComputerName`) or the
  Windows host name. Edit it and restart AirWand to rename the computer.
* `invertScroll` flips both scroll axes. Use it only if scrolling runs backwards on your
  system.
* Delete the file to reset AirWand. This creates a new host identity, so phones must pair
  again.

## OS mappings

| Gesture | macOS | Windows |
|---|---|---|
| 1 Overview | ⌃↑ (Mission Control) | Win+Tab (Task View) |
| 2 App switcher | ⌘⇥ | Alt+Tab |
| 3 Show desktop | F11 (default hotkey) | Win+D |
| 4 / 5 Prev / next Space or desktop | ⌃← / ⌃→ | Ctrl+Win+← / → |
| 6 / 7 Back / forward | ⌘[ / ⌘] | Alt+← / → |
| 8 / 9 Zoom in / out | ⌘= / ⌘- | Ctrl+= / Ctrl+- |

Show desktop on macOS uses F11 because that is the system default hotkey. AirWand sends the
F11 key code with the same Fn flag a real keyboard sets, so no Fn key is involved. ⌘F3 only
works with the F3 key's Mission Control function, and ⌃↓ is App Exposé, not Show Desktop.
If you remapped Show Desktop, set it back to F11 in System Settings → Keyboard → Keyboard
Shortcuts → Mission Control.

How each kind of input is injected:

* **Pointer**
  * macOS: Quartz `CGEvent`s. Drags send `*MouseDragged` events, and the pointer is clamped
    to real displays.
  * Windows: absolute `SendInput` on the virtual desktop, scaled by the monitor's DPI. This
    keeps Windows' own pointer acceleration from being applied on top of the phone's.
* **Scroll**
  * Both systems accumulate fractions of a pixel.
  * macOS: pixel-unit `CGEvent` scroll-wheel events.
  * Windows: `MOUSEEVENTF_WHEEL` / `HWHEEL` with sub-notch `WHEEL_DELTA` values (1 px =
    1.2 units).
* **Keys**
  * macOS: keyboard `CGEvent`s from HID usages, using ANSI key codes and explicit
    modifier flags.
  * Windows: enigo (`Key::Unicode` for letters, digits and punctuation).
* **Text, media keys and mouse buttons**: enigo on both systems. Double and triple clicks
  are sent as quick repeated clicks. On macOS, enigo also sets the click-state field.
* **AIM**: yaw ±0.35 rad and pitch ±0.20 rad map to the bounding box of all displays, with
  +yaw to the right and +pitch up. A 1€ filter smooths the result (min cutoff 1 Hz,
  β 0.007, derivative cutoff 1 Hz).

## Troubleshooting

* **The phone doesn't see the computer.**
  * Both devices must be on the same network. Guest Wi-Fi and "AP isolation" block
    device-to-device traffic.
  * On Windows, run the firewall script.
  * On macOS, check the Local Network permission.
  * As a last resort, enter the IP address manually.
* **Pairing works but nothing moves.**
  * macOS: Accessibility permission (see above).
  * Windows: the target window may be elevated (UIPI).
  * Check that AirWand isn't paused.
* **"binding UDP port 47821 … is AirWand already running?"** Another instance, or another
  app, holds the port. Quit it first.
* **The pairing dialog is hidden.** On macOS it can open behind full-screen apps; switch to
  it with ⌘⇥. On Windows it opens top-most. If you don't answer within 60 s, the phone gets
  `timeout`.
* **Scrolling goes the wrong way.** The phone already applies your natural-scrolling choice.
  If your OS inverts it a second time, set `"invertScroll": true`.
* **Logs**:
  * From source: `RUST_LOG=debug cargo run`.
  * macOS app: `RUST_LOG=debug dist/AirWand.app/Contents/MacOS/airwand`.
  * Windows release: `%APPDATA%\AirWand\airwand.log`.

## Code layout

```
src/main.rs          startup, tao event loop, tray wiring, quit
src/app.rs           shared state (config, connections, pause) + UI events
src/tray.rs          tray icon (drawn in code) and menu
src/protocol.rs      constants, header, seal/open, Message enum, replay guard (+ known-vector tests)
src/crypto.rs        X25519, HKDF key + code derivation (+ Node.js-generated test vector)
src/pairing.rs       TCP pairing server and the Allow/Deny flow
src/dialog.rs        native confirmation dialog (rfd on macOS, MessageBoxW on Windows)
src/control.rs       UDP loop: probe replies, sessions, PONG, watchdog
src/discovery.rs     mDNS advertisement, "here" message
src/config.rs        JSON config in the platform config dir
src/one_euro.rs      1€ filter
src/input/mod.rs     Injector (held-state tracking, gestures, AIM, text)
src/input/keymap.rs  HID usage → enigo key / macOS key code tables (+ coverage tests)
src/input/mac.rs     macOS backend (CGEvent + enigo, Accessibility FFI)
src/input/win.rs     Windows backend (SendInput + enigo)
src/input/generic.rs enigo-only fallback for other platforms (development)
```

A suitable CI matrix runs `cargo test` and `cargo build --release` on `macos-latest` and
`windows-latest`. Run `scripts/bundle-macos.sh` on the macOS runner.
