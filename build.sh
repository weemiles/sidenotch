#!/bin/bash
# Builds SideNotch.app. Signed locally — it never leaves this machine.
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
  <key>CFBundleShortVersionString</key><string>0.1.2</string>
  <key>CFBundleVersion</key><string>3</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSAppleEventsUsageDescription</key><string>이미 열려 있는 Safari 탭을 앞으로 가져오기 위해 필요합니다.</string>
</dict>
</plist>
PLIST

# An ad-hoc signature changes with every build, and macOS then forgets the
# Accessibility and Keychain grants. A local development certificate keeps
# the same identity across builds, so use one when the machine has it.
IDENTITY="${SIDENOTCH_SIGN_IDENTITY:-$(security find-identity -p codesigning -v 2>/dev/null \
  | awk -F'"' '/Apple Development/ { print $2; exit }')}"
codesign --force --sign "${IDENTITY:--}" "$APP" >/dev/null 2>&1 || true
echo "built: $(pwd)/$APP"
