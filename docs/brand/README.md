# AirWand brand

The mark is a glass wand with a four-point spectral sparkle at its tip and the air trail
it just swept, drawn in the Prism palette (`mobile/lib/ui/prism/tokens.dart`): near-black
`#010102` stage, cobalt `#2E5CFF`, violet `#9646FF`, magenta `#FF3496`, cyan `#26C8FF`,
plus the anamorphic light streak from the trackpad.

| file | use |
|------|-----|
| `airwand-mark.svg` | the mark alone, transparent background |
| `airwand-icon.svg` / `airwand-icon-1024.png` | full-bleed square app icon (iOS, stores) |
| `airwand-icon-macos.svg` / `airwand-icon-macos-1024.png` | macOS squircle with margin and shadow; also Android legacy and Windows `.ico` |
| `airwand-adaptive-fg.svg`, `airwand-adaptive-bg.svg` | Android adaptive icon layers |
| `airwand-banner.png` | 1280×640 README header and GitHub social preview |

Wordmark: **Air** in `#F4F4F6`, **Wand** in the spectral gradient, Instrument Sans 600,
tight tracking (-0.035em). Tagline in Martian Mono caps.

Rendered copies used by the builds:

- `mobile/assets/branding/` → copied into the generated `android/` and `ios/` folders by
  `mobile/tool/bootstrap.sh`.
- `desktop/macos/AppIcon.iconset/` → `AppIcon.icns` by `desktop/scripts/bundle-macos.sh`.
- `desktop/windows/airwand.ico` → embedded into `airwand.exe` by `desktop/build.rs`.
- The tray / menu-bar glyph is drawn in code (`desktop/src/tray.rs`).

To re-render after editing an SVG, open it in Chromium (or any SVG renderer) at the sizes
listed in those folders.
