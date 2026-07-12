#!/usr/bin/env bash
# Build dist/claude-sync_<version>_all.deb — system-wide install of the Linux
# side (tools in /usr/bin, user units in /usr/lib/systemd/user).
# After installing: systemctl --user enable --now claude-session-sync.timer
# then run claude-sync-setup.
set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
VER="$(cat "$REPO/VERSION")"
PKG="$(mktemp -d)"
trap 'rm -rf "$PKG"' EXIT

mkdir -p "$PKG/DEBIAN" "$PKG/usr/bin" "$PKG/usr/lib/systemd/user" \
         "$PKG/usr/share/applications" "$PKG/etc/xdg/autostart" \
         "$PKG/usr/share/claude-sync/peer-files" "$PKG/usr/share/doc/claude-sync"

install -m 755 "$REPO/linux/claude-session-translate" \
               "$REPO/linux/claude-sync-tray" \
               "$REPO/linux/claude-sync-status" \
               "$REPO/linux/claude-sync-setup" \
               "$REPO/linux/claude-sync-check-update" \
               "$REPO/linux/claude-mv-project" "$PKG/usr/bin/"

sed 's|%h/.local/bin/claude-session-translate|/usr/bin/claude-session-translate|' \
  "$REPO/linux/systemd/claude-session-sync.service" > "$PKG/usr/lib/systemd/user/claude-session-sync.service"
cp "$REPO/linux/systemd/claude-session-sync.timer" "$PKG/usr/lib/systemd/user/"

sed 's|cosmic-term -e __HOME__/.local/bin/claude-sync-status|x-terminal-emulator -e /usr/bin/claude-sync-status|' \
  "$REPO/linux/desktop/claude-sync-status.desktop" > "$PKG/usr/share/applications/claude-sync-status.desktop"
sed 's|__HOME__/.local/bin/claude-sync-tray|/usr/bin/claude-sync-tray|' \
  "$REPO/linux/desktop/claude-sync-tray.desktop" > "$PKG/etc/xdg/autostart/claude-sync-tray.desktop"

cp "$REPO/stignore.template" "$REPO/VERSION" "$PKG/usr/share/claude-sync/"
cp "$REPO/mac/claude-sync.60s.sh" "$REPO/mac/claude-rename-project" "$PKG/usr/share/claude-sync/peer-files/"
cp "$REPO/README.md" "$PKG/usr/share/doc/claude-sync/"
cp "$REPO/LICENSE" "$PKG/usr/share/doc/claude-sync/copyright"

cat > "$PKG/DEBIAN/control" <<EOF
Package: claude-sync
Version: $VER
Section: utils
Priority: optional
Architecture: all
Maintainer: David Boulay <davidboulay@users.noreply.github.com>
Depends: python3, python3-pyqt6, rsync, curl, git
Recommends: syncthing
Description: Cross-device sync for Claude Code sessions, memory and projects
 Syncs Claude Code sessions, per-project memory, skills and project files
 across Linux and macOS machines over Syncthing, with an optional always-on
 relay. Includes a tray indicator, a device-pairing wizard, rename-safe
 session-store migrations and a built-in updater.
 .
 After installing: systemctl --user enable --now claude-session-sync.timer
 then run claude-sync-setup to pair devices.
EOF

mkdir -p "$REPO/dist"
dpkg-deb --root-owner-group --build "$PKG" "$REPO/dist/claude-sync_${VER}_all.deb"
echo "built: $REPO/dist/claude-sync_${VER}_all.deb"
