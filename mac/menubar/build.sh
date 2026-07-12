#!/bin/bash
# Build "Claude Sync.app" from main.swift and install to /Applications.
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
APP="/Applications/Claude Sync.app"

echo "compiling…"
mkdir -p "$DIR/.build"
swiftc -O -o "$DIR/.build/claude-sync-menubar" "$DIR/main.swift" -framework AppKit

echo "assembling bundle…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$DIR/.build/claude-sync-menubar" "$APP/Contents/MacOS/"
VER="$(cat "$DIR/../../VERSION" 2>/dev/null || echo 0.0)"
cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>com.claude-sync.menubar</string>
  <key>CFBundleName</key><string>Claude Sync</string>
  <key>CFBundleExecutable</key><string>claude-sync-menubar</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VER</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
EOF
codesign --force --sign - "$APP" 2>/dev/null || true
echo "built: $APP"
