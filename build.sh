#!/bin/bash
# Builds SideNotch.app. Ad-hoc signed — it never leaves this machine.
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release

APP="build/SideNotch.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/SideNotch "$APP/Contents/MacOS/SideNotch"

cat > "$APP/Contents/Info.plist" << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>SideNotch</string>
  <key>CFBundleDisplayName</key><string>SideNotch</string>
  <key>CFBundleIdentifier</key><string>io.github.weemiles.sidenotch</string>
  <key>CFBundleExecutable</key><string>SideNotch</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP" >/dev/null 2>&1 || true
echo "built: $(pwd)/$APP"
