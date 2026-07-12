#!/usr/bin/env bash
# Install the hub (Linux) side of claude-sync. Idempotent — rerun after
# pulling updates. Then run `claude-sync-setup` to connect peers.
set -euo pipefail
REPO="$(cd "$(dirname "$0")" && pwd)"
SHARE="$HOME/.local/share/claude-sync"

mkdir -p ~/.local/bin "$SHARE/peer-files" ~/.config/systemd/user \
         ~/.local/share/applications ~/.config/autostart

install -m 755 "$REPO/linux/claude-session-translate" \
               "$REPO/linux/claude-session-sync" \
               "$REPO/linux/claude-sync-status" \
               "$REPO/linux/claude-sync-tray" \
               "$REPO/linux/claude-sync-setup" \
               "$REPO/linux/claude-sync-check-update" \
               "$REPO/linux/claude-mv-project" ~/.local/bin/
cp "$REPO"/linux/systemd/claude-session-sync.{service,timer} \
   "$REPO"/linux/systemd/syncthing.service ~/.config/systemd/user/
sed "s|__HOME__|$HOME|g" "$REPO/linux/desktop/claude-sync-status.desktop" > ~/.local/share/applications/claude-sync-status.desktop
sed "s|__HOME__|$HOME|g" "$REPO/linux/desktop/claude-sync-tray.desktop" > ~/.config/autostart/claude-sync-tray.desktop
# peer-side files, staged for claude-sync-setup to deploy over ssh
cp "$REPO/mac/claude-sync.60s.sh" "$REPO/mac/claude-rename-project" "$SHARE/peer-files/"
cp "$REPO/stignore.template" "$SHARE/"
systemctl --user daemon-reload

# Claude Code mark (not committed to the repo) — fetched from LobeHub
if [ ! -f "$SHARE/claude-logo.png" ]; then
  curl -sL "https://raw.githubusercontent.com/lobehub/lobe-icons/refs/heads/master/packages/static-png/light/claudecode-color.png" \
    -o "$SHARE/claude-logo.png" || echo "NOTE: logo fetch failed — tray uses a drawn fallback"
fi
# app-library icons
if [ -f "$SHARE/claude-logo.png" ]; then
  for sz in 32 48 64 128 256; do
    mkdir -p ~/.local/share/icons/hicolor/${sz}x${sz}/apps
    ~/.local/bin/claude-sync-tray --render-icon "$sz" \
      ~/.local/share/icons/hicolor/${sz}x${sz}/apps/claude-sync.png >/dev/null
  done
  gtk-update-icon-cache ~/.local/share/icons/hicolor 2>/dev/null || true
fi

git -C "$REPO" rev-parse --short HEAD > "$SHARE/installed-version" 2>/dev/null || true
cp "$REPO/VERSION" "$SHARE/installed-release" 2>/dev/null || true

if [ -f ~/.config/claude-sync/config ]; then
  systemctl --user try-restart claude-session-sync.timer 2>/dev/null || true
  echo "install done — existing config kept. Health check: claude-sync-status"
else
  echo "install done — now connect your first peer with: claude-sync-setup"
fi