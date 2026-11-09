#!/usr/bin/env bash
# Builds a universal (Apple silicon + Intel) release of the Orbit host agent and wraps it
# into dist/Orbit.app, ad-hoc signed.
#
#   ./scripts/bundle-macos.sh            # build + bundle
#   ./scripts/bundle-macos.sh --zip      # also produce dist/Orbit-macos.zip
#
# Requirements: macOS, Xcode command line tools (lipo, codesign, ditto), rustup.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "error: bundle-macos.sh must run on macOS" >&2
  exit 1
fi

TARGETS=(aarch64-apple-darwin x86_64-apple-darwin)
BIN=orbit
APP="dist/Orbit.app"
VERSION="$(sed -n 's/^version *= *"\(.*\)"/\1/p' Cargo.toml | head -n 1)"
export MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-11.0}"

if command -v rustup >/dev/null 2>&1; then
  rustup target add "${TARGETS[@]}"
fi

LOCKED=()
if [[ -f Cargo.lock ]]; then
  LOCKED=(--locked)
fi

for t in "${TARGETS[@]}"; do
  echo "==> cargo build --release --target $t"
  cargo build --release "${LOCKED[@]+"${LOCKED[@]}"}" --target "$t"
done

echo "==> assembling $APP (version $VERSION)"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

lipo -create -output "$APP/Contents/MacOS/$BIN" \
  "target/aarch64-apple-darwin/release/$BIN" \
  "target/x86_64-apple-darwin/release/$BIN"
lipo -info "$APP/Contents/MacOS/$BIN"

sed "s/__VERSION__/$VERSION/g" macos/Info.plist > "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"
plutil -lint "$APP/Contents/Info.plist"

echo "==> ad-hoc signing"
codesign --force --deep --sign - --identifier app.orbit.desktop "$APP"
codesign --verify --verbose=2 "$APP"

if [[ "${1:-}" == "--zip" ]]; then
  echo "==> zipping"
  rm -f dist/Orbit-macos.zip
  ditto -c -k --keepParent "$APP" dist/Orbit-macos.zip
fi

cat <<EOF

Built $APP

First run:
  open "$APP"
  Grant Accessibility: System Settings → Privacy & Security → Accessibility → enable Orbit.
  Allow "Local Network" when macOS asks (needed for Bonjour discovery).

Note: an ad-hoc signature changes on every build, so macOS may ask for Accessibility
again after you rebuild (remove the old Orbit entry from the list, then add the new one).
EOF
