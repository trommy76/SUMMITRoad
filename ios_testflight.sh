#!/bin/bash
# Archives the iOS app and uploads it to App Store Connect, where TestFlight picks it up.
# One-time setup is in README.md ("iPhone and iPad"). Usage:  TEAM_ID=ABCDE12345 ./ios_testflight.sh
set -e
cd "$(dirname "$0")"
: "${TEAM_ID:?Set TEAM_ID to your Apple Developer Team ID (developer.apple.com > Membership details)}"
command -v xcodegen >/dev/null || { echo "Install xcodegen first: brew install xcodegen"; exit 1; }
VERSION=$(tr -d '[:space:]' < VERSION)
BUILD=$(date +%y%m%d%H%M)          # TestFlight needs a build number that goes up every upload
xcodegen generate >/dev/null
ARCHIVE="build/SummitRoad-iOS.xcarchive"
rm -rf "$ARCHIVE"
xcodebuild archive -project SummitRoad.xcodeproj -scheme SummitRoad -configuration Release \
  -destination 'generic/platform=iOS' -archivePath "$ARCHIVE" -allowProvisioningUpdates \
  DEVELOPMENT_TEAM="$TEAM_ID" MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$BUILD"
cat > build/ExportOptions.plist <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>app-store-connect</string>
  <key>destination</key><string>upload</string>
  <key>teamID</key><string>$TEAM_ID</string>
  <key>signingStyle</key><string>automatic</string>
</dict></plist>
PLIST
xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportOptionsPlist build/ExportOptions.plist -allowProvisioningUpdates
echo "Uploaded SummitRoad $VERSION ($BUILD). It appears in TestFlight after Apple finishes processing (usually 5-15 minutes)."
