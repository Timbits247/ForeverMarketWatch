#!/usr/bin/env python3
"""
ForeverMarketWatch 24/7 Cloud Sync & Release Manifest Generator (GitHub Actions).

Uses Python 3 standard library only (zero pip dependencies):
  * Pulls hourly WoW: Forever commodity snapshots from Blizzard's Battle.net API
    using encrypted GitHub Secrets (BNET_CLIENT_ID / BNET_CLIENT_SECRET).
  * Computes min buyout, bottom-25% trimmed mean, max buyout, total quantity,
    and +10% Dip Wall order-book metrics (matching sync-blizzard-ah.ps1 exactly).
  * Maintains 7-day intraday + 90-day daily rollup history in cloud-sync/history.json.
  * Emits addon/ForeverMarketWatch/MarketFeedData.lua and release/manifest.json.
"""

import argparse
import base64
import datetime
import gzip
import hashlib
import json
import math
import os
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

ROOT_DIR = Path(__file__).resolve().parent.parent
ADDON_DIR = ROOT_DIR / "addon" / "ForeverMarketWatch"
CATALOG_LUA = ADDON_DIR / "ProfessionCatalog.lua"
FEED_LUA = ADDON_DIR / "MarketFeedData.lua"
TOC_FILE = ADDON_DIR / "ForeverMarketWatch.toc"
HISTORY_JSON = ROOT_DIR / "cloud-sync" / "history.json"
MANIFEST_JSON = ROOT_DIR / "release" / "manifest.json"

INTRADAY_RETENTION_SECONDS = 7 * 86400
INTRADAY_MERGE_WINDOW = 300
ALLOWED_REGIONS = {"us", "eu", "kr", "tw"}
ALLOWED_FACTIONS = {"Horde", "Alliance", "Neutral"}


def escape_lua_string(val: str) -> str:
    s = str(val or "")
    s = s.replace("\\", "\\\\").replace('"', '\\"').replace("\r", " ").replace("\n", " ").replace("\0", "")
    return s


def get_priority_item_ids() -> set:
    ids = set()
    if CATALOG_LUA.exists():
        raw = CATALOG_LUA.read_text(encoding="utf-8", errors="ignore")
        for m in re.finditer(r'\{\s*(\d+)\s*,\s*"[^"]+"\s*,', raw):
            ids.add(int(m.group(1)))
    return ids


def parse_toc_version() -> str:
    if TOC_FILE.exists():
        for line in TOC_FILE.read_text(encoding="utf-8", errors="ignore").splitlines():
            m = re.match(r"^##\s*Version:\s*(.+)$", line.strip())
            if m:
                return m.group(1).strip()
    return "2.1.0"


def parse_feed_synced_at() -> int:
    if FEED_LUA.exists():
        head = FEED_LUA.read_text(encoding="utf-8", errors="ignore")[:1024]
        m = re.search(r"syncedAt\s*=\s*(\d+)", head)
        if m:
            return int(m.group(1))
    return 0


def generate_manifest(feed_synced_at: int = None) -> dict:
    """Writes release/manifest.json with addon code hash, file list, and feed timestamp."""
    MANIFEST_JSON.parent.mkdir(parents=True, exist_ok=True)

    addon_files = sorted(
        f.name
        for f in ADDON_DIR.iterdir()
        if f.is_file() and f.suffix.lower() in (".lua", ".toc")
    )

    hasher = hashlib.sha256()
    for name in addon_files:
        if name == "MarketFeedData.lua":
            continue
        p = ADDON_DIR / name
        hasher.update(name.encode("utf-8"))
        hasher.update(b"\0")
        hasher.update(p.read_bytes().replace(b"\r\n", b"\n"))
        hasher.update(b"\0")

    feed_hash = ""
    if FEED_LUA.exists():
        feed_hash = hashlib.sha256(FEED_LUA.read_bytes().replace(b"\r\n", b"\n")).hexdigest()[:16]

    synced_at = feed_synced_at if feed_synced_at is not None else parse_feed_synced_at()

    manifest = {
        "addonName": "ForeverMarketWatch",
        "addonVersion": parse_toc_version(),
        "addonHash": hasher.hexdigest()[:16],
        "feedSyncedAt": synced_at,
        "feedHash": feed_hash,
        "generatedAt": int(time.time()),
        "files": addon_files,
    }
    MANIFEST_JSON.write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    print(
        f"[manifest] version={manifest['addonVersion']} addonHash={manifest['addonHash']} "
        f"feedSyncedAt={manifest['feedSyncedAt']} files={len(addon_files)}"
    )
    return manifest


def get_oauth_token(client_id: str, client_secret: str) -> str:
    creds = base64.b64encode(f"{client_id}:{client_secret}".encode("utf-8")).decode("ascii")
    req = urllib.request.Request(
        "https://oauth.battle.net/token",
        data=b"grant_type=client_credentials",
        method="POST",
        headers={
            "Authorization": f"Basic {creds}",
            "Content-Type": "application/x-www-form-urlencoded",
            "User-Agent": "ForeverMarketWatch-CloudSync/2.1",
        },
    )
    with urllib.request.urlopen(req, timeout=30) as resp:
        payload = json.loads(resp.read().decode("utf-8"))
    token = payload.get("access_token")
    if not token:
        raise RuntimeError("Failed to obtain Battle.net OAuth access token.")
    return token


def fetch_blizzard_json(url: str, token: str, if_modified_since: str = None, force: bool = False):
    headers = {
        "Authorization": f"Bearer {token}",
        "Accept-Encoding": "gzip",
        "User-Agent": "ForeverMarketWatch-CloudSync/2.1",
    }
    if if_modified_since and not force:
        headers["If-Modified-Since"] = if_modified_since

    req = urllib.request.Request(url, method="GET", headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=60) as resp:
            raw = resp.read()
            if resp.headers.get("Content-Encoding", "").lower() == "gzip":
                raw = gzip.decompress(raw)
            last_mod = resp.headers.get("Last-Modified")
            return False, json.loads(raw.decode("utf-8")), last_mod
    except urllib.error.HTTPError as exc:
        if exc.code == 304:
            return True, None, if_modified_since
        raise


def aggregate_auctions(payload: dict, is_commodity: bool) -> dict:
    """Aggregates raw Blizzard auctions into min/avg(bottom 25%)/max/qty + Dip Wall (+10%)."""
    auctions = payload.get("auctions") or []
    grouped = {}

    for a in auctions:
        item = a.get("item")
        if not isinstance(item, dict):
            continue
        item_id = item.get("id")
        if not item_id or item_id <= 0:
            continue

        qty = int(a.get("quantity") or 1)
        if qty <= 0:
            qty = 1

        if is_commodity:
            price = int(a.get("unit_price") or a.get("buyout") or 0)
        else:
            buyout = int(a.get("buyout") or 0)
            if buyout > 0:
                price = round(buyout / qty)
            else:
                price = int(a.get("unit_price") or 0)

        if price <= 0:
            continue

        grouped.setdefault(int(item_id), []).append((price, qty))

    results = {}
    for item_id, entries in grouped.items():
        entries.sort(key=lambda x: x[0])
        min_price = entries[0][0]
        max_price = entries[-1][0]
        total_qty = sum(q for _, q in entries)

        # Trimmed mean across cheapest 25% of supply (immune to 99,999g troll listings)
        target_qty = max(1, math.ceil(total_qty * 0.25))
        taken = 0
        weighted_sum = 0
        for price, qty in entries:
            take = min(qty, target_qty - taken)
            weighted_sum += price * take
            taken += take
            if taken >= target_qty:
                break
        avg_price = round(weighted_sum / taken) if taken > 0 else min_price

        # Dip Wall (+10% reset wall)
        wall_ceiling = math.ceil(min_price * 1.10)
        wall_qty = 0
        wall_cost = 0
        next_price = min_price
        for price, qty in entries:
            if price <= wall_ceiling:
                wall_qty += qty
                wall_cost += price * qty
            else:
                next_price = price
                break

        results[item_id] = {
            "min": int(min_price),
            "avg": int(avg_price),
            "max": int(max_price),
            "qty": int(total_qty),
            "wall": [int(wall_qty), int(wall_cost), int(next_price)],
        }
    return results


def day_key_utc(ts: int) -> str:
    dt = datetime.datetime.fromtimestamp(ts, tz=datetime.timezone.utc)
    return str(dt.year * 10000 + dt.month * 100 + dt.day)


def update_item_history(bucket: dict, now_ts: int, agg: dict):
    intraday = bucket.setdefault("intraday", [])
    daily = bucket.setdefault("daily", {})

    merged = False
    if intraday:
        last = intraday[-1]
        if abs(now_ts - int(last[0])) < INTRADAY_MERGE_WINDOW:
            last[0] = now_ts
            last[1] = agg["min"]
            last[2] = agg["avg"]
            last[3] = max(int(last[3]), agg["max"])
            last[4] = agg["qty"]
            merged = True

    if not merged:
        intraday.append([now_ts, agg["min"], agg["avg"], agg["max"], agg["qty"]])

    cutoff = now_ts - INTRADAY_RETENTION_SECONDS
    kept = []
    for pt in intraday:
        ts = int(pt[0])
        if ts < cutoff:
            dk = day_key_utc(ts)
            if dk not in daily:
                daily[dk] = [int(pt[1]), int(pt[2]), int(pt[3]), int(pt[1]), int(pt[4]), 1]
            else:
                d = daily[dk]
                cnt = int(d[5])
                nc = cnt + 1
                d[0] = min(int(d[0]), int(pt[1]))
                d[1] = round((int(d[1]) * cnt + int(pt[2])) / nc)
                d[2] = max(int(d[2]), int(pt[3]))
                d[3] = int(pt[1])
                d[4] = round((int(d[4]) * cnt + int(pt[4])) / nc)
                d[5] = nc
        else:
            kept.append(pt)

    bucket["intraday"] = kept
    bucket["lastScan"] = now_ts
    bucket["wall"] = agg["wall"]


def export_market_feed_lua(history_root: dict, synced_at: int, source_label: str, priority_ids: set) -> str:
    synced_int = int(synced_at)
    ts_str = datetime.datetime.fromtimestamp(synced_int, tz=datetime.timezone.utc).strftime("%Y-%m-%d %H:%M:%S UTC")
    safe_source = escape_lua_string(source_label)
    lines = [
        "-- MarketFeedData.lua",
        "-- Auto-generated by ForeverMarketWatch 24/7 Cloud Sync (Blizzard Battle.net API).",
        f"-- Synced: {ts_str}",
        "",
        "local _, NS = ...",
        "",
        "NS.ExternalFeed = {",
        f"    syncedAt = {synced_int},",
        f'    source = "{safe_source}",',
        "    houses = {",
    ]

    houses = history_root.get("houses", {})
    for faction in sorted(houses.keys()):
        if faction not in ALLOWED_FACTIONS:
            continue
        lines.append(f'        ["{faction}"] = {{')
        house_map = houses[faction]
        for id_key in sorted(house_map.keys(), key=lambda x: int(x)):
            ih = house_map[id_key]
            id_int = int(id_key)
            if id_int <= 0:
                continue
            is_priority = (not priority_ids) or (id_int in priority_ids)
            last_scan = int(ih.get("lastScan") or 0)
            lines.append(f"            [{id_int}] = {{")
            lines.append(f"                lastScan = {last_scan},")
            wall = ih.get("wall")
            if isinstance(wall, list) and len(wall) >= 3:
                lines.append(f"                wall = {{{int(wall[0])},{int(wall[1])},{int(wall[2])}}},")

            pts = ih.get("intraday") or []
            if not is_priority and len(pts) > 36:
                pts = pts[-36:]
            pts_str = ",".join(
                f"{{{int(p[0])},{int(p[1])},{int(p[2])},{int(p[3])},{int(p[4])}}}" for p in pts
            )
            lines.append(f"                intraday = {{{pts_str}}},")

            daily = ih.get("daily") or {}
            d_keys = sorted(daily.keys(), key=lambda x: int(x))
            if not is_priority and len(d_keys) > 90:
                d_keys = d_keys[-90:]
            d_str = ",".join(
                f"[{int(dk)}]={{ {int(daily[dk][0])},{int(daily[dk][1])},{int(daily[dk][2])},"
                f"{int(daily[dk][3])},{int(daily[dk][4])},{int(daily[dk][5])} }}".replace(" ", "")
                for dk in d_keys
            )
            lines.append(f"                daily = {{{d_str}}},")
            lines.append("            },")
        lines.append("        },")

    lines.append("    },")
    lines.append("}")
    return "\n".join(lines) + "\n"


def parse_houses_env(raw: str) -> list:
    houses = []
    for part in (raw or "").split(","):
        part = part.strip()
        if not part:
            continue
        if ":" in part:
            hid, faction = part.split(":", 1)
            f_clean = faction.strip()
            if f_clean not in ALLOWED_FACTIONS:
                raise ValueError(f"Unsupported faction '{f_clean}' in BNET_HOUSES (expected Horde/Alliance/Neutral)")
            houses.append((int(hid.strip()), f_clean))
    return houses


def run_sync(force: bool = False):
    client_id = os.environ.get("BNET_CLIENT_ID", "").strip()
    client_secret = os.environ.get("BNET_CLIENT_SECRET", "").strip()
    if not client_id or not client_secret:
        print("ERROR: BNET_CLIENT_ID and BNET_CLIENT_SECRET environment variables are required.", file=sys.stderr)
        sys.exit(1)

    region = os.environ.get("BNET_REGION", "us").strip().lower() or "us"
    if region not in ALLOWED_REGIONS:
        print(f"ERROR: Invalid BNET_REGION '{region}' (expected one of {sorted(ALLOWED_REGIONS)}).", file=sys.stderr)
        sys.exit(1)
    ruleset_id = int(os.environ.get("BNET_RULESET_ID", "2").strip() or "2")
    houses = parse_houses_env(os.environ.get("BNET_HOUSES", "113:Horde,110:Alliance"))
    if not houses:
        houses = [(113, "Horde"), (110, "Alliance")]

    namespace = f"dynamic-forever-{region}"
    base_url = f"https://{region}.api.blizzard.com"

    print(f"[sync] Authenticating with Battle.net OAuth ({region} / {namespace}, ruleset {ruleset_id})...")
    token = get_oauth_token(client_id, client_secret)

    history_root = {"houses": {}, "lastModified": {}}
    if HISTORY_JSON.exists():
        try:
            loaded = json.loads(HISTORY_JSON.read_text(encoding="utf-8"))
            if isinstance(loaded, dict) and isinstance(loaded.get("houses"), dict):
                history_root = loaded
                history_root.setdefault("lastModified", {})
        except Exception as exc:
            print(f"[sync] Warning: could not parse previous history.json, starting fresh: {exc}")

    now_ts = int(time.time())
    total_updated = 0

    for house_id, faction in houses:
        house_map = history_root["houses"].setdefault(faction, {})

        # A. Commodities endpoint
        comm_url = f"{base_url}/data/wow/ruleset/{ruleset_id}/auctions/{house_id}/commodities?namespace={namespace}&locale=en_US"
        comm_key = f"comm_{house_id}"
        print(f"[sync] Fetching commodities for {faction} (House #{house_id})...")
        try:
            not_mod, payload, last_mod = fetch_blizzard_json(
                comm_url, token, history_root["lastModified"].get(comm_key), force=force
            )
            if not_mod:
                print(f"[sync]   {faction} commodities unchanged (304 Not Modified).")
            elif payload:
                if last_mod:
                    history_root["lastModified"][comm_key] = last_mod
                agg_map = aggregate_auctions(payload, is_commodity=True)
                for item_id, agg in agg_map.items():
                    id_str = str(item_id)
                    bucket = house_map.setdefault(id_str, {"intraday": [], "daily": {}, "lastScan": 0})
                    update_item_history(bucket, now_ts, agg)
                    total_updated += 1
                print(f"[sync]   Aggregated {len(agg_map)} {faction} commodity items.")
        except Exception as exc:
            print(f"[sync]   Warning: commodities fetch failed for House #{house_id}: {exc}")

        # B. Optional non-commodity endpoint (skip quietly if Blizzard returns 403)
        item_url = f"{base_url}/data/wow/ruleset/{ruleset_id}/auctions/{house_id}?namespace={namespace}&locale=en_US"
        item_key = f"item_{house_id}"
        try:
            not_mod, payload, last_mod = fetch_blizzard_json(
                item_url, token, history_root["lastModified"].get(item_key), force=force
            )
            if not not_mod and payload:
                if last_mod:
                    history_root["lastModified"][item_key] = last_mod
                agg_map = aggregate_auctions(payload, is_commodity=False)
                for item_id, agg in agg_map.items():
                    id_str = str(item_id)
                    bucket = house_map.setdefault(id_str, {"intraday": [], "daily": {}, "lastScan": 0})
                    update_item_history(bucket, now_ts, agg)
                    total_updated += 1
                if agg_map:
                    print(f"[sync]   Aggregated {len(agg_map)} {faction} non-commodity items.")
        except Exception:
            pass

    if total_updated == 0 and not force:
        print("[sync] No new Blizzard snapshot yet (304 Not Modified). Refreshing manifest only.")
        generate_manifest()
        return

    HISTORY_JSON.parent.mkdir(parents=True, exist_ok=True)
    HISTORY_JSON.write_text(json.dumps(history_root, separators=(",", ":")), encoding="utf-8")

    priority_ids = get_priority_item_ids()
    source_label = f"Blizzard Cloud API ({namespace}, Ruleset #{ruleset_id})"
    lua_content = export_market_feed_lua(history_root, now_ts, source_label, priority_ids)
    FEED_LUA.write_text(lua_content, encoding="utf-8")
    print(f"[sync] Wrote {FEED_LUA.relative_to(ROOT_DIR)} ({len(lua_content):,} bytes, {total_updated} updates).")

    generate_manifest(feed_synced_at=now_ts)


def main():
    parser = argparse.ArgumentParser(description="ForeverMarketWatch Cloud Sync & Manifest Generator")
    parser.add_argument("--manifest-only", action="store_true", help="Only regenerate release/manifest.json")
    parser.add_argument("--force", action="store_true", help="Ignore If-Modified-Since cache")
    args = parser.parse_args()

    if args.manifest_only:
        generate_manifest()
    else:
        run_sync(force=args.force)


if __name__ == "__main__":
    main()
