#!/bin/bash
# Builds SummitRoad.app (needs Xcode or Xcode command-line tools, macOS 13+)
set -e
cd "$(dirname "$0")"
pkill -x SummitTrainer || true
swift build -c release --arch arm64 --arch x86_64
APP="build/SummitRoad.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/apple/Products/Release/SummitTrainer "$APP/Contents/MacOS/SummitTrainer"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
VERSION=$(tr -d '[:space:]' < VERSION)
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" -c "Set :CFBundleVersion $VERSION" "$APP/Contents/Info.plist"
codesign --force --deep --sign - "$APP"
echo "Built $APP"
(cd build && rm -f SummitRoad.zip && ditto -c -k --keepParent SummitRoad.app SummitRoad.zip)
echo "Zipped build/SummitRoad.zip"
open "$APP"
