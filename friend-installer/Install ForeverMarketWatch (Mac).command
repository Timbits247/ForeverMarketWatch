#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RAW_BASE=$(python3 -c "import json,sys; print(json.load(open('$SCRIPT_DIR/repo-config.json'))['rawBaseUrl'].rstrip('/'))")

echo "============================================================"
echo "  ForeverMarketWatch — macOS 1-Click Installer"
echo "============================================================"

WOW_PATH="/Applications/World of Warcraft/_forever_"
if [ ! -d "$WOW_PATH" ]; then
  read -p "Enter path to your World of Warcraft/_forever_ folder: " WOW_PATH
fi
if [ ! -d "$WOW_PATH" ]; then
  echo "Folder not found: $WOW_PATH"
  exit 1
fi

UPDATER_DIR="$HOME/Library/Application Support/ForeverMarketWatchUpdater"
mkdir -p "$UPDATER_DIR"

cat > "$UPDATER_DIR/update.py" << 'PYEOF'
#!/usr/bin/env python3
import json, os, time, urllib.request
from pathlib import Path

BASE = Path(__file__).resolve().parent
cfg = json.loads((BASE / "config.json").read_text())
state_p = BASE / "state.json"
state = json.loads(state_p.read_text()) if state_p.exists() else {}
addon_dir = Path(cfg["wowPath"]) / "Interface" / "AddOns" / "ForeverMarketWatch"
addon_dir.mkdir(parents=True, exist_ok=True)
raw = cfg["rawBaseUrl"].rstrip("/")
bust = int(time.time())

try:
    req = urllib.request.Request(f"{raw}/release/manifest.json?t={bust}", headers={"User-Agent": "FMW-Mac/2.1"})
    manifest = json.loads(urllib.request.urlopen(req, timeout=20).read().decode("utf-8"))
except Exception:
    raise SystemExit(0)

def dl(name):
    url = f"{raw}/addon/ForeverMarketWatch/{name}?t={bust}"
    data = urllib.request.urlopen(urllib.request.Request(url, headers={"User-Agent": "FMW-Mac/2.1"}), timeout=45).read()
    tmp = addon_dir / (name + ".tmp")
    tmp.write_bytes(data)
    tmp.replace(addon_dir / name)

if state.get("addonHash") != manifest.get("addonHash") or not (addon_dir / "ForeverMarketWatch.toc").exists():
    for f in manifest.get("files", []):
        if f != "MarketFeedData.lua" and "/" not in f and ".." not in f:
            dl(f)
    state["addonHash"] = manifest.get("addonHash", "")

if state.get("feedSyncedAt", 0) != manifest.get("feedSyncedAt", 0) or state.get("feedHash") != manifest.get("feedHash") or not (addon_dir / "MarketFeedData.lua").exists():
    dl("MarketFeedData.lua")
    state["feedSyncedAt"] = manifest.get("feedSyncedAt", 0)
    state["feedHash"] = manifest.get("feedHash", "")

state_p.write_text(json.dumps(state))
PYEOF
chmod +x "$UPDATER_DIR/update.py"

python3 -c "import json; json.dump({'wowPath': '$WOW_PATH', 'rawBaseUrl': '$RAW_BASE'}, open('$UPDATER_DIR/config.json','w'))"
python3 "$UPDATER_DIR/update.py"

PLIST="$HOME/Library/LaunchAgents/com.forevermarketwatch.autosync.plist"
mkdir -p "$HOME/Library/LaunchAgents"
cat > "$PLIST" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>com.forevermarketwatch.autosync</string>
  <key>ProgramArguments</key><array><string>/usr/bin/python3</string><string>$UPDATER_DIR/update.py</string></array>
  <key>StartInterval</key><integer>900</integer>
  <key>RunAtLoad</key><true/>
</dict>
</plist>
EOF

launchctl unload "$PLIST" 2>/dev/null || true
launchctl load "$PLIST"

echo ""
echo "ALL DONE! Addon & live hourly AH prices installed, and silent auto-updates will run every 15 min."
echo "Restart WoW: Forever once, then type /fmw or click the gold coin minimap button!"
read -p "Press Enter to close..."
