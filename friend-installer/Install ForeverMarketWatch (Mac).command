#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RAW_BASE="$(python3 -c 'import json, sys; print(json.load(open(sys.argv[1], encoding="utf-8"))["rawBaseUrl"].strip().rstrip("/"))' "$SCRIPT_DIR/repo-config.json")"

if ! printf '%s' "$RAW_BASE" | grep -Eq '^https://raw\.githubusercontent\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/[A-Za-z0-9_./-]+$'; then
  echo "ERROR: Untrusted or non-HTTPS rawBaseUrl in repo-config.json"
  exit 1
fi

echo "============================================================"
echo "  ForeverMarketWatch — macOS 1-Click Installer"
echo "============================================================"

WOW_PATH="/Applications/World of Warcraft/_forever_"
if [ ! -d "$WOW_PATH" ]; then
  read -r -p "Enter path to your World of Warcraft/_forever_ folder: " WOW_PATH
fi
if [ -d "$WOW_PATH/_forever_" ]; then
  WOW_PATH="$WOW_PATH/_forever_"
fi
if [ ! -d "$WOW_PATH" ]; then
  echo "Folder not found: $WOW_PATH"
  exit 1
fi

UPDATER_DIR="$HOME/Library/Application Support/ForeverMarketWatchUpdater"
mkdir -p "$UPDATER_DIR"
chmod 700 "$UPDATER_DIR"

cat > "$UPDATER_DIR/update.py" << 'PYEOF'
#!/usr/bin/env python3
import hashlib, json, re, shutil, time, urllib.request
from pathlib import Path

ALLOWED_RAW_RE = re.compile(r"^https://raw\.githubusercontent\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/[A-Za-z0-9_./-]+$")
SAFE_FILE_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_-]*\.(lua|toc)$")

BASE = Path(__file__).resolve().parent
cfg = json.loads((BASE / "config.json").read_text(encoding="utf-8"))
raw = str(cfg.get("rawBaseUrl", "")).strip().rstrip("/")
if not ALLOWED_RAW_RE.fullmatch(raw):
    raise SystemExit("Refusing untrusted rawBaseUrl")

state_p = BASE / "state.json"
state = json.loads(state_p.read_text(encoding="utf-8")) if state_p.exists() else {}
addon_dir = (Path(cfg["wowPath"]) / "Interface" / "AddOns" / "ForeverMarketWatch").resolve()
addon_dir.mkdir(parents=True, exist_ok=True)
bust = int(time.time())

try:
    req = urllib.request.Request(f"{raw}/release/manifest.json?t={bust}", headers={"User-Agent": "FMW-Mac/2.6"})
    manifest = json.loads(urllib.request.urlopen(req, timeout=20).read().decode("utf-8"))
except Exception:
    raise SystemExit(0)

if manifest.get("addonName") != "ForeverMarketWatch" or not manifest.get("addonHash"):
    raise SystemExit(0)

def fetch_bytes(name: str) -> bytes:
    url = f"{raw}/addon/ForeverMarketWatch/{name}?t={bust}"
    return urllib.request.urlopen(urllib.request.Request(url, headers={"User-Agent": "FMW-Mac/2.6"}), timeout=45).read()

if state.get("addonHash") != manifest.get("addonHash") or not (addon_dir / "ForeverMarketWatch.toc").exists():
    stage = BASE / "stage_code"
    if stage.exists():
        shutil.rmtree(stage)
    stage.mkdir(parents=True, exist_ok=True)
    try:
        names = []
        for f in manifest.get("files", []):
            if f == "MarketFeedData.lua":
                continue
            if not SAFE_FILE_RE.fullmatch(str(f)):
                raise RuntimeError(f"Unsafe filename: {f}")
            dest = (addon_dir / f).resolve()
            if dest.parent != addon_dir:
                raise RuntimeError(f"Path traversal blocked: {f}")
            (stage / f).write_bytes(fetch_bytes(f))
            names.append(f)

        h = hashlib.sha256()
        for f in sorted(names):
            h.update(f.encode("utf-8") + b"\0" + (stage / f).read_bytes().replace(b"\r\n", b"\n") + b"\0")
        if h.hexdigest()[:16] != str(manifest.get("addonHash", "")).lower()[:16]:
            raise RuntimeError("SHA-256 addonHash mismatch")

        for f in names:
            tmp = addon_dir / (f + ".tmp")
            tmp.write_bytes((stage / f).read_bytes())
            tmp.replace(addon_dir / f)
        state["addonHash"] = manifest.get("addonHash", "")
    finally:
        if stage.exists():
            shutil.rmtree(stage, ignore_errors=True)

if state.get("feedSyncedAt", 0) != manifest.get("feedSyncedAt", 0) or state.get("feedHash") != manifest.get("feedHash") or not (addon_dir / "MarketFeedData.lua").exists():
    feed_bytes = fetch_bytes("MarketFeedData.lua")
    exp_feed_hash = str(manifest.get("feedHash", "")).lower()[:16]
    if exp_feed_hash and hashlib.sha256(feed_bytes.replace(b"\r\n", b"\n")).hexdigest()[:16] != exp_feed_hash:
        raise SystemExit("SHA-256 feedHash mismatch")
    if not feed_bytes.startswith(b"-- MarketFeedData.lua"):
        raise SystemExit("Invalid MarketFeedData.lua header")
    tmp = addon_dir / "MarketFeedData.lua.tmp"
    tmp.write_bytes(feed_bytes)
    tmp.replace(addon_dir / "MarketFeedData.lua")
    state["feedSyncedAt"] = manifest.get("feedSyncedAt", 0)
    state["feedHash"] = manifest.get("feedHash", "")

state_p.write_text(json.dumps(state), encoding="utf-8")
PYEOF
chmod 700 "$UPDATER_DIR/update.py"

python3 -c 'import json, os, sys; p = sys.argv[1]; open(p, "w", encoding="utf-8").write(json.dumps({"wowPath": sys.argv[2], "rawBaseUrl": sys.argv[3]})); os.chmod(p, 0o600)' \
  "$UPDATER_DIR/config.json" "$WOW_PATH" "$RAW_BASE"

python3 "$UPDATER_DIR/update.py"

PLIST="$HOME/Library/LaunchAgents/com.forevermarketwatch.autosync.plist"
mkdir -p "$HOME/Library/LaunchAgents"
python3 -c 'import plistlib, sys
data = {
    "Label": "com.forevermarketwatch.autosync",
    "ProgramArguments": ["/usr/bin/python3", sys.argv[2]],
    "StartInterval": 900,
    "RunAtLoad": True,
}
with open(sys.argv[1], "wb") as fp:
    plistlib.dump(data, fp)
' "$PLIST" "$UPDATER_DIR/update.py"

launchctl unload "$PLIST" 2>/dev/null || true
launchctl load "$PLIST"

echo ""
echo "ALL DONE! Addon & live hourly AH prices installed, and silent auto-updates will run every 15 min."
echo "Restart WoW: Forever once, then type /fmw or click the gold coin minimap button!"
read -r -p "Press Enter to close..."
