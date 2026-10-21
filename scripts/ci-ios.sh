#!/bin/bash
# Generate the Xcode project, run unit tests on a simulator, and zip an unsigned device .ipa.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

echo "== Xcode =="
python3 - <<'PY'
import os, shutil, subprocess, sys
cands = []
apps = "/Applications"
for name in os.listdir(apps):
    if not name.startswith("Xcode") or not name.endswith(".app"):
        continue
    if "beta" in name.lower():
        continue
    path = os.path.join(apps, name)
    cands.append(path)
if not cands:
    sys.exit("no Xcode.app found")
# Default Xcode.app sorts first; prefer the highest version by asking xcodebuild when several exist.
def version(path):
    try:
        out = subprocess.check_output(["/usr/libexec/PlistBuddy", "-c", "Print :CFBundleShortVersionString", os.path.join(path, "Contents/Info.plist")], text=True).strip()
        return tuple(int(p) if p.isdigit() else 0 for p in out.split("."))
    except Exception:
        return (0,)
cands.sort(key=version)
chosen = cands[-1]
print(chosen)
open("/tmp/xcode-path", "w").write(chosen)
PY
sudo xcode-select -s "$(cat /tmp/xcode-path)"
sudo xcodebuild -license accept || true
xcodebuild -version

if ! command -v xcodegen >/dev/null 2>&1; then
  brew install xcodegen
fi
xcodegen generate

pick_sim() {
  python3 - <<'PY'
import json, re, subprocess, sys
raw = subprocess.check_output(["xcrun", "simctl", "list", "devices", "available", "-j"], text=True)
data = json.loads(raw)
best = None
for runtime, devs in data.get("devices", {}).items():
    if "iOS" not in runtime:
        continue
    m = re.search(r"iOS-(\d+)-(\d+)", runtime)
    ver = (int(m.group(1)), int(m.group(2))) if m else (0, 0)
    for d in devs:
        name = d.get("name", "")
        if not d.get("isAvailable") or "iPhone" not in name:
            continue
        nums = [int(x) for x in re.findall(r"\d+", name)]
        num = nums[0] if nums else 0
        key = (ver, 0 if "SE" in name else 1, num, name)
        if best is None or key > best[0]:
            best = (key, d["udid"], name)
if not best:
    sys.exit("no available iPhone simulator")
print(best[1])
print(best[2], file=sys.stderr)
PY
}

UDID="$(pick_sim)"
echo "Simulator $UDID"
xcrun simctl boot "$UDID" || true
xcrun simctl bootstatus "$UDID" -b || true

echo "== Test =="
# Simulator installs need an ad-hoc signature. The device IPA below stays unsigned.
xcodebuild test \
  -project Moonlight.xcodeproj \
  -scheme Moonlight \
  -destination "platform=iOS Simulator,id=${UDID}" \
  -derivedDataPath "${RUNNER_TEMP:-/tmp}/moon-test" \
  -parallel-testing-enabled NO \
  ENABLE_DEBUG_DYLIB=NO \
  CODE_SIGN_IDENTITY="-" \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGNING_ALLOWED=YES

echo "== Unsigned device build =="
DD="${RUNNER_TEMP:-/tmp}/moon-device"
rm -rf "$DD"
xcodebuild build \
  -project Moonlight.xcodeproj \
  -scheme Moonlight \
  -configuration Release \
  -sdk iphoneos \
  -destination "generic/platform=iOS" \
  -derivedDataPath "$DD" \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY="" \
  DEVELOPMENT_TEAM="" \
  PROVISIONING_PROFILE_SPECIFIER="" \
  CODE_SIGN_ENTITLEMENTS="" \
  ONLY_ACTIVE_ARCH=NO

APP="$(find "$DD/Build/Products" -type d -name 'Moonlight.app' | head -1)"
test -d "$APP"
echo "App: $APP"
# Drop any signature the toolchain may have left. Sideload tools re-sign this bundle.
rm -rf "$APP/_CodeSignature"
rm -f "$APP/embedded.mobileprovision"
if codesign -d "$APP" >/dev/null 2>&1; then
  echo "warning: bundle still reports a signature; stripping again"
  codesign --remove-signature "$APP" || true
fi

STAGE="${RUNNER_TEMP:-/tmp}/moon-ipa"
rm -rf "$STAGE"
mkdir -p "$STAGE/Payload"
cp -R "$APP" "$STAGE/Payload/"
rm -rf "$STAGE/Payload/Moonlight.app/_CodeSignature"
rm -f "$STAGE/Payload/Moonlight.app/embedded.mobileprovision"
(
  cd "$STAGE"
  zip -r -y "$ROOT/Moonlight-unsigned.ipa" Payload
)
# The zip must contain Payload/<App>.app and must not ship a provisioning profile.
unzip -l "$ROOT/Moonlight-unsigned.ipa" | head -40
test -n "$(unzip -l "$ROOT/Moonlight-unsigned.ipa" | grep 'Payload/Moonlight.app/Info.plist' || true)"
if unzip -l "$ROOT/Moonlight-unsigned.ipa" | grep -q embedded.mobileprovision; then
  echo "refusing to upload an ipa that contains a provisioning profile"
  exit 1
fi
ls -lh "$ROOT/Moonlight-unsigned.ipa"
echo "IPA ready"
