#!/bin/sh
# Build the buddy and its "eye" (screen-reading helper, kept as a separate app so
# rebuilding the buddy never re-asks for the Screen Recording permission).
set -e
cd "$(dirname "$0")"
swiftc -O buddy.swift -o buddy
if [ ! -d eye/ClaudeBuddyEye.app ]; then
  mkdir -p eye/ClaudeBuddyEye.app/Contents/MacOS
  swiftc -O eye/eye.swift -o eye/ClaudeBuddyEye.app/Contents/MacOS/ClaudeBuddyEye
  cat > eye/ClaudeBuddyEye.app/Contents/Info.plist <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>com.claude-buddy.eye</string>
  <key>CFBundleName</key><string>ClaudeBuddyEye</string>
  <key>CFBundleExecutable</key><string>ClaudeBuddyEye</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSUIElement</key><true/>
  <key>NSScreenCaptureUsageDescription</key><string>Reads the text behind the buddy to know which answer to read.</string>
</dict></plist>
PLIST
  codesign --force --sign - eye/ClaudeBuddyEye.app
fi
echo "Built ./buddy — run it with ./buddy (or add a LaunchAgent, see README)."
