#!/bin/zsh
# Builds "System History.app" next to this script.
set -euo pipefail
cd "${0:A:h}"

APP="System History.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

swiftc -O -swift-version 5 -framework Cocoa -framework IOKit main.swift -o "$APP/Contents/MacOS/SystemHistory"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>System History</string>
  <key>CFBundleDisplayName</key><string>System History</string>
  <key>CFBundleIdentifier</key><string>local.systemhistory</string>
  <key>CFBundleExecutable</key><string>SystemHistory</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

# Non-APFS volumes (e.g. ExFAT) store metadata in hidden "._*" files inside the
# bundle, which break code signing. Strip them before and after signing.
strip_appledouble() { find "$APP" -name '._*' -delete; }
strip_appledouble
codesign --force --sign - "$APP" 2>/dev/null
strip_appledouble
codesign --verify "$APP"
echo "Built $PWD/$APP"
