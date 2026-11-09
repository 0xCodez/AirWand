#!/usr/bin/env bash
# Generates the Flutter platform folders (android/, ios/) that are not
# committed in v1, then patches them for Orbit. Safe to run any number of
# times: every patch is idempotent. Works on macOS and Linux (GitHub runners).
#
#   bash tool/bootstrap.sh
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

say() { printf '\033[1;34m[orbit]\033[0m %s\n' "$*"; }
die() { printf '\033[1;31m[orbit]\033[0m %s\n' "$*" >&2; exit 1; }

command -v flutter >/dev/null 2>&1 || die "flutter is not on PATH (https://docs.flutter.dev/get-started/install)"
command -v python3 >/dev/null 2>&1 || die "python3 is required for patching"

if [ ! -d android ] || [ ! -d ios ]; then
  say "Generating platform folders with flutter create…"
  flutter create . --project-name orbit --org app.orbit --platforms android,ios
  # flutter create adds a counter-app widget test that does not apply here.
  if [ -f test/widget_test.dart ] && grep -q "MyApp" test/widget_test.dart; then
    rm -f test/widget_test.dart
    say "Removed template test/widget_test.dart"
  fi
else
  say "android/ and ios/ already exist, only patching."
fi

python3 - "$ROOT" <<'PY'
import os
import plistlib
import re
import sys

root = sys.argv[1]
changed = []

def read(path):
    with open(path, "r", encoding="utf-8") as f:
        return f.read()

def write(path, text):
    with open(path, "w", encoding="utf-8", newline="\n") as f:
        f.write(text)

# --------------------------------------------------------------- Android
manifest = os.path.join(root, "android", "app", "src", "main", "AndroidManifest.xml")
if os.path.isfile(manifest):
    xml = read(manifest)
    original = xml
    perms = [
        "android.permission.INTERNET",
        "android.permission.ACCESS_NETWORK_STATE",
        "android.permission.ACCESS_WIFI_STATE",
        "android.permission.CHANGE_WIFI_MULTICAST_STATE",
        "android.permission.VIBRATE",
    ]
    missing = [p for p in perms if ('android:name="%s"' % p) not in xml]
    if missing:
        lines = "".join('    <uses-permission android:name="%s"/>\n' % p for p in missing)
        xml, n = re.subn(r"(<manifest\b[^>]*>\s*\n)", lambda m: m.group(1) + lines, xml, count=1)
        if n == 0:
            raise SystemExit("AndroidManifest.xml: <manifest> tag not found")
    # App label "Orbit" on <application>.
    def fix_label(m):
        tag = m.group(0)
        if re.search(r'android:label="[^"]*"', tag):
            return re.sub(r'android:label="[^"]*"', 'android:label="Orbit"', tag, count=1)
        return tag.replace("<application", '<application\n        android:label="Orbit"', 1)
    xml = re.sub(r"<application\b[^>]*>", fix_label, xml, count=1, flags=re.S)
    if xml != original:
        write(manifest, xml)
        changed.append(manifest)

# minSdk >= 23 (Groovy build.gradle or Kotlin build.gradle.kts).
for name in ("build.gradle.kts", "build.gradle"):
    gradle = os.path.join(root, "android", "app", name)
    if not os.path.isfile(gradle):
        continue
    text = read(gradle)
    original = text
    kts = name.endswith(".kts")
    maxfn = "maxOf(23, flutter.minSdkVersion)" if kts else "Math.max(23, flutter.minSdkVersion)"
    # minSdk = flutter.minSdkVersion
    text = re.sub(r"(\bminSdk\s*=\s*)flutter\.minSdkVersion\b", lambda m: m.group(1) + maxfn, text)
    # minSdkVersion flutter.minSdkVersion   (older Groovy templates)
    text = re.sub(r"(\bminSdkVersion\s+)flutter\.minSdkVersion\b", lambda m: m.group(1) + "Math.max(23, flutter.minSdkVersion)", text)
    # Literal numbers lower than 23.
    def bump(m):
        return m.group(1) + ("23" if int(m.group(2)) < 23 else m.group(2))
    text = re.sub(r"(\bminSdk(?:Version)?\s*=?\s*)(\d+)\b", bump, text)
    if text != original:
        write(gradle, text)
        changed.append(gradle)

# ------------------------------------------------------------------- iOS
plist_path = os.path.join(root, "ios", "Runner", "Info.plist")
if os.path.isfile(plist_path):
    with open(plist_path, "rb") as f:
        plist = plistlib.load(f)
    before = dict(plist)
    plist["CFBundleDisplayName"] = "Orbit"
    plist["NSLocalNetworkUsageDescription"] = (
        "Orbit finds your computers on this Wi-Fi network and sends your "
        "trackpad, keyboard and media controls to them."
    )
    services = list(plist.get("NSBonjourServices") or [])
    if "_orbit._tcp" not in services:
        services.append("_orbit._tcp")
    plist["NSBonjourServices"] = services
    plist["NSMotionUsageDescription"] = (
        "Air mode uses motion sensors to turn your phone into a pointer."
    )
    plist["UIStatusBarStyle"] = "UIStatusBarStyleLightContent"
    plist["UISupportedInterfaceOrientations"] = ["UIInterfaceOrientationPortrait"]
    plist["UISupportedInterfaceOrientations~ipad"] = [
        "UIInterfaceOrientationPortrait",
        "UIInterfaceOrientationPortraitUpsideDown",
    ]
    # Portrait-only on iPad requires opting out of multitasking.
    plist["UIRequiresFullScreen"] = True
    if plist != before:
        with open(plist_path, "wb") as f:
            plistlib.dump(plist, f, sort_keys=False)
        changed.append(plist_path)

# bonsoir (NWBrowser) needs iOS 13+. Raise the deployment target if lower.
def ver_lt(v, minimum=(13, 0)):
    parts = tuple(int(x) for x in re.findall(r"\d+", v)[:2]) + (0,)
    return parts[:2] < minimum

pbx = os.path.join(root, "ios", "Runner.xcodeproj", "project.pbxproj")
if os.path.isfile(pbx):
    text = read(pbx)
    new = re.sub(
        r"(IPHONEOS_DEPLOYMENT_TARGET = )([\d.]+);",
        lambda m: m.group(1) + ("13.0" if ver_lt(m.group(2)) else m.group(2)) + ";",
        text,
    )
    if new != text:
        write(pbx, new)
        changed.append(pbx)

app_info = os.path.join(root, "ios", "Flutter", "AppFrameworkInfo.plist")
if os.path.isfile(app_info):
    with open(app_info, "rb") as f:
        info = plistlib.load(f)
    if "MinimumOSVersion" in info and ver_lt(str(info["MinimumOSVersion"])):
        info["MinimumOSVersion"] = "13.0"
        with open(app_info, "wb") as f:
            plistlib.dump(info, f, sort_keys=False)
        changed.append(app_info)

podfile = os.path.join(root, "ios", "Podfile")
if os.path.isfile(podfile):
    text = read(podfile)
    new = re.sub(r"^#?\s*platform :ios, '([\d.]+)'",
                 lambda m: "platform :ios, '%s'" % ("13.0" if ver_lt(m.group(1)) else m.group(1)),
                 text, count=1, flags=re.M)
    if new != text:
        write(podfile, new)
        changed.append(podfile)

if changed:
    print("[orbit] patched:")
    for c in changed:
        print("  - " + os.path.relpath(c, root))
else:
    print("[orbit] platform files already up to date")
PY

say "Fetching packages…"
flutter pub get

say "Done. Next: flutter run   (see README.md for iPhone / Android / Seeker notes)"
