#!/bin/sh
# Archives a Release build and uploads it to App Store Connect for TestFlight.
#   iOS/testflight.sh            # archive + upload
#   iOS/testflight.sh --local    # archive + export an .ipa only (no upload)
# Needs the app record (bundle id com.mhirst.conductor) to exist in App Store Connect.
set -e
cd "$(dirname "$0")"
BUILD=$(date +%Y%m%d%H%M)          # unique, increasing build number per upload
DEST=upload; [ "$1" = "--local" ] && DEST=export

xcodegen generate -q
echo "▸ archiving build $BUILD"
xcodebuild archive -project Conductor.xcodeproj -scheme Conductor -configuration Release \
  -destination 'generic/platform=iOS' -archivePath build/Conductor.xcarchive \
  -allowProvisioningUpdates CURRENT_PROJECT_VERSION="$BUILD" -quiet

cat > build/ExportOptions.plist <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>app-store-connect</string>
  <key>destination</key><string>$DEST</string>
  <key>teamID</key><string>N86L59CTP6</string>
  <key>signingStyle</key><string>automatic</string>
  <key>uploadSymbols</key><true/>
  <key>manageAppVersionAndBuildNumber</key><false/>
</dict></plist>
PLIST

echo "▸ $( [ "$DEST" = upload ] && echo uploading to App Store Connect || echo exporting .ipa )"
LOG=build/export.log
if xcodebuild -exportArchive -archivePath build/Conductor.xcarchive -exportOptionsPlist build/ExportOptions.plist \
     -exportPath build/export -allowProvisioningUpdates >"$LOG" 2>&1; then
  echo "✓ build $BUILD $( [ "$DEST" = upload ] && echo "uploaded — it appears in App Store Connect › TestFlight after processing" || echo "exported to build/export" )"
else
  grep -E "error|rror:" "$LOG" | head -5
  echo "✗ export failed (full log: iOS/$LOG)"
  exit 1
fi
