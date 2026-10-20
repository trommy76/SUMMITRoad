#!/bin/bash
# Builds Summit Trainer.app (needs Xcode or Xcode command-line tools, macOS 13+)
set -e
cd "$(dirname "$0")"
pkill -x SummitTrainer || true
swift build -c release
APP="build/SummitTrainer.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/SummitTrainer "$APP/Contents/MacOS/SummitTrainer"
cp Resources/Info.plist "$APP/Contents/Info.plist"
VERSION=$(tr -d '[:space:]' < VERSION)
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" -c "Set :CFBundleVersion $VERSION" "$APP/Contents/Info.plist"
codesign --force --deep --sign - "$APP"
echo "Built $APP"
open "$APP"
