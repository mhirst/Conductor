#!/bin/sh
# Builds Conductor, installs it on your iPhone/iPad (cable or Wi-Fi) and relaunches it.
#   iOS/run-on-phone.sh                 # first connected physical device
#   DEVICE=<udid> iOS/run-on-phone.sh   # a specific device
# The app reconnects to Live and reopens its last screen on launch, so a relaunch costs nothing.
set -e
cd "$(dirname "$0")"
BUNDLE=com.mhirst.conductor

if [ -z "$DEVICE" ]; then
  JSON="${TMPDIR:-/tmp}/conductor-devices.json"
  xcrun devicectl list devices --json-output "$JSON" >/dev/null 2>&1
  DEVICE=$(python3 - "$JSON" <<'PY'
import json, sys
devs = json.load(open(sys.argv[1]))["result"]["devices"]
for d in devs:
    hw, conn = d.get("hardwareProperties", {}), d.get("connectionProperties", {})
    if hw.get("reality") == "physical" and conn.get("pairingState") == "paired" \
       and conn.get("tunnelState") != "unavailable":
        print(hw["udid"]); break
PY
)
fi
[ -n "$DEVICE" ] || { echo "No iPhone/iPad found. Plug it in (or enable 'Connect via network' in Xcode)."; exit 1; }

start=$(date +%s)
xcodegen generate --use-cache -q          # picks up new/removed files; skipped when nothing changed
echo "▸ building for $DEVICE"
xcodebuild -project Conductor.xcodeproj -scheme Conductor -destination "id=$DEVICE" \
  -derivedDataPath build -allowProvisioningUpdates build -quiet 2>&1 | grep -E "error|warning: .*(sign|provision)" || true
APP=build/Build/Products/Debug-iphoneos/Conductor.app
[ -d "$APP" ] || { echo "build failed"; exit 1; }
echo "▸ installing"
xcrun devicectl device install app --device "$DEVICE" "$APP" >/dev/null
echo "▸ relaunching"
xcrun devicectl device process launch --device "$DEVICE" --terminate-existing "$BUNDLE" >/dev/null
echo "✓ done in $(( $(date +%s) - start ))s"
