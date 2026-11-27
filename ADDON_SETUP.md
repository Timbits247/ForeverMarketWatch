# ForeverMarketWatch — Setup & User Guide

**ForeverMarketWatch** is a pure in-game Auction House stock-charting and watchlist addon built for **World of Warcraft: Forever** (Client `1.60.1`, Interface `16001`).

---

## 1. Install Into WoW: Forever

### Option A: One-Click PowerShell Installer
1. Confirm [`wow-path.txt`](wow-path.txt) points to your WoW: Forever folder (default: `D:\World of Warcraft\_forever_`).
2. Run:
   ```powershell
   powershell -ExecutionPolicy Bypass -File "d:\AI Projects\wow-forever-ah-tracker\install-addon.ps1"
   ```

### Option B: Manual Copy
Copy the folder:
```text
d:\AI Projects\wow-forever-ah-tracker\addon\ForeverMarketWatch
```
into:
```text
D:\World of Warcraft\_forever_\Interface\AddOns\ForeverMarketWatch
```
Verify there is no double-nested folder — `ForeverMarketWatch.toc` must sit directly inside `Interface\AddOns\ForeverMarketWatch\`.

---

## 2. First Launch & Instant Day-1 Preview

1. Launch **World of Warcraft: Forever** and verify **ForeverMarketWatch** is checked on the Character Select **AddOns** list.
2. In-game, open the window via the **minimap gold-coin icon** or type:
   ```text
   /fmw
   ```
   *(You can also use `/market`.)*
3. **Preview all 4 chart modes immediately (without waiting weeks for data):**
   ```text
   /fmw demo
   ```
   This loads an isolated 90-day synthetic market preview (your real realm SavedVariables are untouched). Try switching:
   - **Chart Mode Dropdown (1–4)**:
     1. *Price & Min/Max Range*
     2. *Price + Supply Volume*
     3. *Price + Moving Average*
     4. *Full Stock View (+Targets)*
   - **Timeframes**: `1D`, `7D`, `30D`, `90D`, `All`
   - Hover the chart canvas for the interactive crosshair & in-chart HUD readout.
   - Run `/fmw demo` again to return to your live realm market.
4. **Run the built-in unit self-test suite:**
   ```text
   /fmw test
   ```

---

## 3. Automatic Hourly Blizzard API Sync (No Sitting at the AH!)

ForeverMarketWatch includes a native Windows PowerShell sync tool (`api-sync\`) that pulls **hourly Auction House snapshots directly from Blizzard's official WoW: Forever Battle.net API** (`dynamic-forever-{region}`) and feeds them straight into the in-game addon via `MarketFeedData.lua` — even while WoW is closed!

### One-Time 2-Minute Setup
1. Create a free Battle.net API client at **https://develop.battle.net/access/clients**:
   - Click **+ Create Client**
   - Client Name: `ForeverMarketWatch`
   - Redirect URI: `http://localhost`
   - Copy your **Client ID** and **Client Secret**.
2. Double-click **`api-sync\Setup Blizzard API.bat`** (or run `api-sync\setup-blizzard-api.ps1`).
3. Paste your Client ID, Client Secret, and Region (`us`, `eu`, or `tw`).
4. The wizard automatically discovers your **WoW: Forever Ruleset** (PvP / Normal / RP) and **Auction House(s)** (Horde / Alliance / Blackwater), performs your first sync, and offers to register a **silent hourly Windows background task** (`ForeverMarketWatchHourlySync` — zero popup windows!).
5. Whenever you log into WoW (or run `/reload`), ForeverMarketWatch automatically merges every hourly API snapshot into your charts and shows `API: Xm ago` in the bottom-left footer.

- Want an instant manual refresh anytime? Double-click **`api-sync\Sync Now.bat`**.
- Any custom item you add to your watchlist in-game is automatically picked up from `SavedVariables` on the next hourly sync!
- To stop the background hourly task later, run `api-sync\unregister-hourly-task.ps1`.

---

## 4. Daily Auction House Workflow

- **Integrated AH Tab**: Open any Auction House and click the **Market Watch** tab (coexists cleanly alongside Blizzard's tabs, Auctionator, and TSM without taint).
- **Pre-Populated Profession Materials**: Automatically pre-loads 140+ crafting materials across **Herbalism**, **Mining**, **Skinning**, **Tailoring**, **Enchanting**, **Alchemy**, **Blacksmithing & Eng**, and **Cooking & Fishing** (filter by profession and click **Scan Group** for fast category refreshes, or run `/fmw seed` / **Settings -> Restore All Profession Materials** anytime).
- **Search Items to Add**:
  - Type 2+ letters in the **Search item name or ID...** box to instantly search the built-in Profession Catalog, your Bags, and past AH history.
  - At the Auction House, click **Search AH** (or press **Enter**) to run a live Auction House search for *any* item in the game and add it with 1 click.
  - Still supports **drag-and-drop** from bags, **Shift-clicking** item links, clicking **`+ AH`** to watch your last-viewed AH item, or `/fmw add <name|link|id>`.
- **Full Gold, Silver & Copper Prices**: All prices across the watchlist, header, KPI strip, hover HUD, and chart axes display Gold, Silver, and Copper.
- **Classic Stock Chart Bottom Volume**: Chart Modes 2 and 4 render green/red stock volume histogram bars strictly anchored along the bottom X-axis sub-pane beneath the price line.
- **Groups**: Click **Groups** to create/delete custom categories (defaults: *Consumables*, *Herbs*, *Raid Mats*, *Flipping*).
- **Scanning & Passive Capture**:
  - Click **Scan Watchlist** (or let **Auto-Scan on AH Open** refresh automatically after its cooldown, configurable in **Settings**).
  - Normal browsing/searching in Blizzard's AH or Auctionator is also passively recorded in the background.
- **Buy/Sell Target Alerts**: Click **Targets** on any watched item to enter **Buy Below** and **Sell Above** prices (e.g., `2g 50s`, `12.5g`, `45s`). Matching rows highlight with `[BUY]` / `[SELL]` badges and dashed target lines on the chart.
- **Quick Buy**: Click **Quick Buy** while at the Auction House to jump straight to that item's live listings.

---

## 4. Slash Commands Reference

| Command | Action |
| :--- | :--- |
| `/fmw` or `/market` | Toggle the standalone window |
| `/fmw scan` | Start a watchlist scan (when at the AH) |
| `/fmw stop` | Stop an in-progress scan |
| `/fmw add <link or id>` | Add an item directly to your watchlist |
| `/fmw demo` | Toggle isolated 90-day Demo Preview mode |
| `/fmw test` | Run the in-game unit self-test suite |

---

## 5. Blizzard Legal & Terms of Service Compliance Notice

- **Free & Unobfuscated Add-On**: ForeverMarketWatch is 100% free of charge, open-source, and contains zero paid tiers, advertisements, or obfuscated code, in accordance with the **Blizzard World of Warcraft UI Add-On Development Policy**.
- **Zero Gameplay Automation**: ForeverMarketWatch never executes automated purchases, bids, auction postings, batch cancellations, or unattended AFK timer scans. Every Auction House purchase, listing, or cancellation requires a direct physical player input inside World of Warcraft.
- **Official Battle.net Game Data API**: Out-of-game price snapshots use Blizzard's official **Battle.net Developer API** (`oauth.battle.net` / `{region}.api.blizzard.com`) with `If-Modified-Since` caching and write static Lua data files loaded only on login or `/reload` (never reading or modifying game process memory).
- **Trademark Attribution**: *World of Warcraft* and *Blizzard Entertainment* are trademarks or registered trademarks of Blizzard Entertainment, Inc. in the U.S. and/or other countries. ForeverMarketWatch is an independent community project and is not affiliated with or endorsed by Blizzard Entertainment, Inc.
