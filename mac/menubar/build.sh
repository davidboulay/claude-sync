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

# app icon from the logo the installer fetched (skip silently if absent)
LOGO="$HOME/.local/share/claude-sync/claude-logo.png"
ICON_KEY=""
if [ -f "$LOGO" ]; then
  ICONSET="$DIR/.build/AppIcon.iconset"
  rm -rf "$ICONSET"; mkdir -p "$ICONSET"
  for s in 16 32 128 256 512; do
    sips -z "$s" "$s" "$LOGO" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
    sips -z "$((s*2))" "$((s*2))" "$LOGO" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
  done
  if iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"; then
    ICON_KEY="  <key>CFBundleIconFile</key><string>AppIcon</string>"
  fi
fi
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
${ICON_KEY}
</dict></plist>
EOF
codesign --force --sign - "$APP" 2>/dev/null || true
echo "built: $APP"
