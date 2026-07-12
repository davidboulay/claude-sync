#!/bin/bash
# Build dist/ClaudeSync-<version>.dmg — run ON a Mac (needs Xcode CLT).
# The DMG carries the menu-bar app plus a CLI installer for the sync tools.
set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
VER="$(cat "$REPO/VERSION")"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

"$REPO/mac/menubar/build.sh" >/dev/null
cp -R "/Applications/Claude Sync.app" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

mkdir -p "$STAGE/.cli" "$STAGE/.cli-support"
cp "$REPO/linux/claude-session-translate" "$REPO/linux/claude-mv-project" \
   "$REPO/linux/claude-sync-check-update" "$REPO/mac/claude-rename-project" "$STAGE/.cli/"
cp "$REPO/mac/claude-sync-translate.plist" "$REPO/VERSION" "$STAGE/.cli-support/"

cat > "$STAGE/Install claude-sync.command" <<'EOF'
#!/bin/bash
# Installs the claude-sync CLI tools + background agents for the current user
# and puts the app in /Applications. Safe to rerun.
set -euo pipefail
SRC="$(cd "$(dirname "$0")" && pwd)"
echo "Installing claude-sync…"
mkdir -p ~/.local/bin ~/.local/share/claude-sync ~/Library/LaunchAgents ~/.config/claude-sync ~/.claude/sync-staging
[ -d "/Applications/Claude Sync.app" ] || cp -R "$SRC/Claude Sync.app" /Applications/
install -m 755 "$SRC/.cli/"* ~/.local/bin/
sed "s|__HOME__|$HOME|g" "$SRC/.cli-support/claude-sync-translate.plist" \
  > ~/Library/LaunchAgents/com.claude-sync.translate.plist
cat > ~/Library/LaunchAgents/com.claude-sync.menubar.plist <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>com.claude-sync.menubar</string>
  <key>ProgramArguments</key><array>
    <string>/Applications/Claude Sync.app/Contents/MacOS/claude-sync-menubar</string>
  </array>
  <key>RunAtLoad</key><true/>
</dict></plist>
PLIST
for agent in com.claude-sync.translate com.claude-sync.menubar; do
  launchctl bootout "gui/$(id -u)/$agent" 2>/dev/null || true
  launchctl bootstrap "gui/$(id -u)" ~/Library/LaunchAgents/"$agent".plist 2>/dev/null || true
done
curl -sL "https://raw.githubusercontent.com/lobehub/lobe-icons/refs/heads/master/packages/static-png/light/claudecode-color.png" \
  -o ~/.local/share/claude-sync/claude-logo.png 2>/dev/null || true
cp "$SRC/.cli-support/VERSION" ~/.local/share/claude-sync/installed-release 2>/dev/null || true
open "/Applications/Claude Sync.app"
echo
echo "Done. Next steps:"
echo "  - install Syncthing (https://github.com/syncthing/syncthing-macos) and share your"
echo "    projects folder + ~/.claude/sync-staging with your other devices"
echo "  - create ~/.config/claude-sync/config (see the README) or run the"
echo "    claude-sync-setup wizard from a Linux machine"
EOF
chmod +x "$STAGE/Install claude-sync.command"

mkdir -p "$REPO/dist"
rm -f "$REPO/dist/ClaudeSync-$VER.dmg"
hdiutil create -volname "Claude Sync $VER" -srcfolder "$STAGE" -ov -format UDZO \
  "$REPO/dist/ClaudeSync-$VER.dmg" >/dev/null
echo "built: $REPO/dist/ClaudeSync-$VER.dmg"
