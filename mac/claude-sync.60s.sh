#!/bin/bash
# <swiftbar.title>Claude Sync</swiftbar.title>
# <swiftbar.hideAbout>true</swiftbar.hideAbout>
# <swiftbar.hideRunInTerminal>true</swiftbar.hideRunInTerminal>
# <swiftbar.hideLastUpdated>true</swiftbar.hideLastUpdated>
# <swiftbar.hideDisablePlugin>true</swiftbar.hideDisablePlugin>
#
# Menu-bar health for a claude-sync peer (macOS): Syncthing mirror state,
# freshness of session sync pushed from the hub, renamed-project detection.
# Configuration: ~/.config/claude-sync/config (deployed by claude-sync-setup).

CONF="$HOME/.config/claude-sync/config"
[ -f "$CONF" ] && . "$CONF"
ROOT="${LOCAL_ROOT:-$HOME/Claude}"
FOLDER="${ST_FOLDER_ID:-claude-projects}"
HUB="${HUB_DEVICE_ID:-}"
HUB_NAME="${HUB_NAME:-hub}"
DIR="$HOME/.local/share/claude-sync"
CFG="$HOME/Library/Application Support/Syncthing/config.xml"

state="green"
lines=()

KEY=$(sed -n 's/.*<apikey>\(.*\)<\/apikey>.*/\1/p' "$CFG" 2>/dev/null | head -1)
api() { curl -s -m 4 -H "X-API-Key: $KEY" "http://127.0.0.1:8384/rest/$1"; }

if [ -z "$KEY" ] || ! api system/ping | grep -q pong; then
  state="red"
  lines+=("✗ Syncthing not running — open the Syncthing app")
else
  conn=$(api system/connections | /usr/bin/python3 -c "
import json,sys
d=json.load(sys.stdin)
print(d['connections'].get('$HUB',{}).get('connected',False))" 2>/dev/null)
  if [ "$conn" = "True" ]; then
    lines+=("✓ $HUB_NAME connected")
  else
    state="amber"
    lines+=("● $HUB_NAME away — changes queue")
  fi
  read -r here_pct here_need <<< "$(api "db/completion?folder=$FOLDER" | /usr/bin/python3 -c "
import json,sys; d=json.load(sys.stdin); print(f\"{d['completion']:.0f} {d['needBytes']//1_000_000}\")" 2>/dev/null)"
  read -r there_pct there_need <<< "$(api "db/completion?folder=$FOLDER&device=$HUB" | /usr/bin/python3 -c "
import json,sys; d=json.load(sys.stdin); print(f\"{d['completion']:.0f} {d['needBytes']//1_000_000}\")" 2>/dev/null)"
  if [ "${here_need:-0}" -gt 0 ] 2>/dev/null; then
    lines+=("◐ this Mac: ${here_pct}% (${here_need} MB left)")
    [ "$state" = "green" ] && [ "$conn" = "True" ] && state="amber"
  fi
  if [ "${there_need:-0}" -gt 0 ] 2>/dev/null; then
    lines+=("◐ $HUB_NAME: ${there_pct}% (${there_need} MB left)")
    [ "$state" = "green" ] && [ "$conn" = "True" ] && state="amber"
  fi
  if [ "${here_need:-1}" = "0" ] && [ "${there_need:-1}" = "0" ]; then
    lines+=("✓ projects fully mirrored")
  fi
fi

hb="$HOME/.claude/.claude-sync-heartbeat"
[ -f "$hb" ] || hb="$HOME/.claude/.last-sync-from-linux"   # pre-rename compat
if [ -f "$hb" ]; then
  age=$(( $(date +%s) - $(cat "$hb") ))
  mins=$(( age / 60 ))
  if [ "$age" -lt 900 ]; then
    lines+=("✓ sessions: synced ${mins} min ago")
  else
    lines+=("● sessions: last sync ${mins} min ago ($HUB_NAME away?)")
    [ "$state" = "green" ] && state="amber"
  fi
else
  lines+=("? sessions: no sync heartbeat yet")
fi

# renamed-project detection: session stores whose folder no longer exists
renames=$(CS_ROOT="$ROOT" /usr/bin/python3 - <<'PY' 2>/dev/null
import difflib, os, re
from pathlib import Path
root = Path(os.environ.get("CS_ROOT", Path.home() / "Claude"))
store = Path.home() / ".claude/projects"
prefix = str(root) + "/"
seen, orphans = set(), []
if store.is_dir():
    for d in sorted(store.iterdir()):
        if not d.is_dir():
            continue
        f = next(iter(sorted(d.glob("*.jsonl"))), None)
        if f is None:
            continue
        try:
            head = f.open("rb").read(65536).decode("utf-8", "replace")
        except OSError:
            continue
        m = re.search(r'"cwd":"([^"]+)"', head)
        if not m or not m.group(1).startswith(prefix):
            continue
        top = m.group(1)[len(prefix):].split("/")[0]
        if top in seen:
            continue
        seen.add(top)
        if not (root / top).exists():
            orphans.append(top)
folders = [p.name for p in root.iterdir()
           if p.is_dir() and not p.name.startswith(".")] if root.is_dir() else []
for old in orphans:
    best = difflib.get_close_matches(old, folders, n=1, cutoff=0.6)
    print(f"{old}|{best[0] if best else ''}")
PY
)
[ -n "$renames" ] && [ "$state" = "green" ] && state="amber"

# menu bar icon
echo " | image=$(base64 -i "$DIR/badge-$state.png")"
echo "---"
echo "Claude Sync — $(hostname -s) | color=#D97757"
for l in "${lines[@]}"; do
  case "${l:0:1}" in
    "✓") c="#4caf50" ;;
    "●"|"◐") c="#e0a030" ;;
    "✗") c="#d84040" ;;
    *)   c="#909090" ;;
  esac
  echo "$l | color=$c"
done
if [ -n "$renames" ]; then
  echo "---"
  while IFS='|' read -r old guess; do
    [ -z "$old" ] && continue
    if [ -n "$guess" ]; then
      echo "● Repair rename: $old → $guess | bash=$HOME/.local/bin/claude-mv-project param1=--store-only param2=$old param3=$guess terminal=false refresh=true color=#e0a030"
      echo "-- the hub applies its half automatically on the next sync tick"
    else
      echo "● '$old' sessions orphaned — no matching folder found | color=#e0a030"
    fi
  done <<< "$renames"
fi
echo "---"
echo "Rename project… | bash=$HOME/.local/bin/claude-rename-project terminal=false refresh=true"
echo "Open Syncthing GUI | href=http://127.0.0.1:8384"
echo "Refresh now | refresh=true"
