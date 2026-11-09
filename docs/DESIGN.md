# Orbit Design Language

> **Visual direction: Prism (approved).** The colours, type and motion below were the first draft. The binding visual and motion spec is now the interactive prototype [`prototype/b-prism.html`](prototype/b-prism.html), implemented in `mobile/lib/ui/prism/`. Screens and gestures in this file still apply.

Working product name: **Orbit**. Your computers orbit your phone; you flick between them.
The bar is a first-party Apple app: calm, glassy, physical, every touch answered by light, motion and haptics.

## Signature ideas

1. **Orbit radar (discovery).** Like AirDrop: concentric rings breathe out from the phone at the center. Found computers appear as frosted-glass bubbles riding on the rings (laptop glyph for Mac, monitor glyph for Windows) and drift slowly. Tap a bubble → it grows into the pairing sheet.
2. **Anamorphic touch light.** Wherever a finger touches the trackpad, a soft light blob appears with a thin horizontal **anamorphic lens-flare streak** (cool blue → violet) running through it, plus a faint fading trail behind the finger. Two-finger scroll shows two blobs joined by a faint bar. Taps emit a tiny ripple ring. This is the hero effect; keep everything else quiet.
3. **Host pill (switching computers).** A Dynamic-Island-style capsule at the top shows the active computer: OS glyph, name, a live latency dot (mint < 15 ms, amber < 40 ms, red otherwise). Tap → it morphs (spring) into the Host Switcher sheet: a horizontal carousel of paired computers with status, plus "Add computer". **Three-finger swipe left/right on the trackpad switches computers directly**: the surface slides like a card, the pill text crossfades, a flare sweeps across, medium haptic.
4. **Mode dock.** A floating glass segmented control at the bottom: **Trackpad · Air · Keys · Media**. A sliding pill marks the active mode (spring, light haptic).

## Screens

1. **Discovery / Orbit** – radar, "Looking for computers on Wi-Fi…", list of found hosts under the radar, "Enter IP manually", tiny footnote "Install Orbit for Mac or Windows".
2. **Pairing sheet** – computer glyph + name, a huge 6-digit code in two groups (`482 913`), "Confirm this code on your Mac", progress shimmer, success state: check mark draws itself + flare + success haptic.
3. **Trackpad (home)** – host pill on top, full-bleed trackpad surface with a barely visible dot grid, a thin scroll strip on the right edge, optional L/R click bar at the bottom of the surface, mode dock.
   Gestures: 1-finger move · tap = click · double-tap = double-click · 2-finger tap = right click · 2-finger drag = scroll (with inertia) · tap-and-hold then move = drag (lock badge appears) · 3-finger swipe left/right = switch computer · 3-finger swipe up = Overview (Mission Control / Task View) · pinch = zoom.
4. **Air** – a big circular glass "lens" button; hold to aim (the phone becomes a laser pointer), release to stop. "Center" button to recalibrate. Left/Right click buttons. A small live aim map of the screen with a dot.
5. **Keys** – a text field that streams what you type, a special-keys row (esc, tab, ⌫, ⏎, arrows) and OS-aware shortcut chips (Copy, Paste, Undo, Search/Spotlight, Screenshot) that show ⌘ on Mac and Ctrl/Win on Windows.
6. **Media** – big play/pause, previous/next, a volume slider (sends volume up/down steps), mute, and a "Presenter" toggle that turns the screen into two giant Back/Next areas.
7. **Settings** – pointer speed, acceleration curve, scroll speed, natural scrolling, haptics, tap-to-click, theme (System/Dark/Light), paired computers (rename, forget).

## Tokens (dark is the hero theme; light mirrors it)

| token | dark | light |
|-------|------|-------|
| `bg` | `#05060A` | `#F2F3F7` |
| `bgElevated` | `#0D0F15` | `#FFFFFF` |
| `glass` | `rgba(30,33,44,0.55)` + blur 28 + saturate 180% | `rgba(255,255,255,0.62)` + blur 28 |
| `stroke` | `rgba(255,255,255,0.10)` hairline | `rgba(10,20,40,0.08)` |
| `text` | `#F4F6FB` | `#0B0D12` |
| `textSecondary` | `rgba(226,232,255,0.58)` | `rgba(20,24,36,0.56)` |
| `accentA` | `#5B8CFF` (orbit blue) | `#3D6BFF` |
| `accentB` | `#A06BFF` (violet) | `#7B4DFF` |
| `flare` | `#8FDBFF` | `#4FA9FF` |
| `success` | `#3DDC97` | `#16B377` |
| `warning` | `#FFB547` | `#E08A00` |
| `danger` | `#FF5A6E` | `#E5354A` |

- Accent gradient: `accentA → accentB` at 135°. Used sparingly: active dock pill, primary buttons, flare.
- Radii (continuous / squircle feel): 12 chips, 20 cards, 28 sheets, capsule for pills.
- Type: platform system face (SF Pro on iOS, Roboto/Google Sans on Android; `system-ui` on web). Large titles 34/700 tight tracking, title 22/600, body 17/400, caption 13/500 with +0.2 letter-spacing, the pairing code 56/300 tabular.
- Motion: springs everywhere (response ≈ 0.35 s, damping ≈ 0.82). Durations 180 / 280 / 420 ms. Respect reduce-motion: keep fades, drop parallax and flare sweeps.
- Haptics: selection tick on tap-to-click, light impact on mode change, medium impact on computer switch, success notification on pairing.
- Spacing scale: 4, 8, 12, 16, 20, 24, 32, 44.
