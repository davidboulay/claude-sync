#!/bin/bash
# Install the Mac side of claude-sync: SwiftBar plugin, rename helper,
# LaunchAgent. Run ON the Mac from a clone of this repo. Idempotent.
set -euo pipefail
REPO="$(cd "$(dirname "$0")" && pwd)"

mkdir -p ~/.local/bin ~/.swiftbar ~/.local/share/claude-sync ~/Library/LaunchAgents

install -m 755 "$REPO/mac/claude-rename-project" ~/.local/bin/
install -m 755 "$REPO/linux/claude-mv-project" ~/.local/bin/          # shared script
install -m 755 "$REPO/linux/claude-sync-check-update" ~/.local/bin/   # shared script
install -m 755 "$REPO/linux/claude-session-translate" ~/.local/bin/   # shared script
sed "s|__HOME__|$HOME|g" "$REPO/mac/claude-sync-translate.plist" \
  > ~/Library/LaunchAgents/com.claude-sync.translate.plist
launchctl bootout "gui/$(id -u)/com.claude-sync.translate" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" ~/Library/LaunchAgents/com.claude-sync.translate.plist 2>/dev/null || true
if [ ! -f ~/.local/share/claude-sync/claude-logo.png ]; then
  mkdir -p ~/.local/share/claude-sync
  curl -sL "https://raw.githubusercontent.com/lobehub/lobe-icons/refs/heads/master/packages/static-png/light/claudecode-color.png" \
    -o ~/.local/share/claude-sync/claude-logo.png || true
fi
git -C "$REPO" rev-parse --short HEAD > ~/.local/share/claude-sync/installed-version 2>/dev/null || true
cp "$REPO/VERSION" ~/.local/share/claude-sync/installed-release 2>/dev/null || true

if command -v swiftc >/dev/null 2>&1; then
  # native menu-bar app (preferred)
  "$REPO/mac/menubar/build.sh"
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
  launchctl bootstrap "gui/$(id -u)" ~/Library/LaunchAgents/com.claude-sync.menubar.plist 2>/dev/null || true
  # restart onto the fresh binary (a running old instance would linger otherwise)
  pkill -f claude-sync-menubar 2>/dev/null || true
  sleep 1
  open "/Applications/Claude Sync.app" 2>/dev/null || true
else
  # SwiftBar plugin fallback (no Xcode command line tools)
  mkdir -p ~/.swiftbar
  install -m 755 "$REPO/mac/claude-sync.60s.sh" ~/.swiftbar/
  cp "$REPO/mac/swiftbar.plist" ~/Library/LaunchAgents/com.claude-sync.swiftbar.plist
  if command -v brew >/dev/null 2>&1; then
    brew list --cask swiftbar >/dev/null 2>&1 || brew install --cask swiftbar
  else
    echo "NOTE: Homebrew not found — install SwiftBar manually (https://swiftbar.app)"
  fi
  defaults write com.ameba.SwiftBar PluginDirectory "$HOME/.swiftbar"
  launchctl bootstrap "gui/$(id -u)" ~/Library/LaunchAgents/com.claude-sync.swiftbar.plist 2>/dev/null || true
  open -a SwiftBar 2>/dev/null || true
fi

echo "mac install done. Reminders:"
echo "  - System Settings > Sharing > Remote Login must be ON (session sync runs over SSH)"
echo "  - menu-bar badge icons are rendered and shipped by install-linux.sh on the Linux box"
echo "  - Syncthing: install the macOS app (https://github.com/syncthing/syncthing-macos), share ~/Claude"
