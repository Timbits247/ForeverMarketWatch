# ForeverMarketWatch — 24/7 Cloud Sync & Hands-Off Friend Auto-Updater Setup

This sets up **Option 2A**: GitHub Actions fetches fresh hourly WoW: Forever AH prices 24/7 for free (using your encrypted Battle.net Secrets), and your friends run a **1-click installer once** so both **live AH prices** and **addon beta updates** sync silently in the background forever.

---

## Part 1: One-Time Setup for YOU (~5 minutes)

### 1. Create a Free GitHub Repository
1. Go to https://github.com/new
2. Repository name: `ForeverMarketWatch`
3. Visibility: **Public** *(required so friends can download `MarketFeedData.lua` & addon files with zero logins — your API keys are NOT in the repo! `.gitignore` blocks `api-config.json`, `api-history.json`, `sync.log`, and `wow-path.txt`.)*
4. Click **Create repository**.

### 2. Push This Project to GitHub
Open PowerShell in `d:\AI Projects\wow-forever-ah-tracker` and run:
```powershell
git init
git branch -M main
git add .
git status   # Double-check api-config.json is NOT listed!
git commit -m "Initial ForeverMarketWatch release"
git remote add origin https://github.com/<YOUR_GITHUB_USERNAME>/ForeverMarketWatch.git
git push -u origin main
```

### 3. Add Your Encrypted Battle.net API Secrets in GitHub
1. In your GitHub repo, go to **Settings -> Secrets and variables -> Actions**.
2. Under **Repository secrets**, click **New repository secret** twice:
   - Name: `BNET_CLIENT_ID` -> Value: *(your Battle.net Client ID)*
   - Name: `BNET_CLIENT_SECRET` -> Value: *(your Battle.net Client Secret)*
3. *(Optional)* Defaults are already set for **US Normal (Ruleset 2, Horde #113 + Alliance #110)**. To change them later, add Repository Variables `BNET_REGION`, `BNET_RULESET_ID`, `BNET_HOUSES`.

### 4. Test the 24/7 Cloud Sync
1. Go to the **Actions** tab in your GitHub repo -> click **Hourly AH Price Sync & Addon Release** -> click **Run workflow** (set `force = true` for the first run).
2. Wait ~15 seconds for the green checkmark! You'll see it commit a fresh `MarketFeedData.lua` and `release/manifest.json`.
3. From now on, GitHub runs this automatically every hour at `:30` — even while your PC is off!

### 5. Build the Tiny 1-Click Installer for Friends
Run this once in PowerShell (substituting your GitHub username):
```powershell
powershell -ExecutionPolicy Bypass -File "d:\AI Projects\wow-forever-ah-tracker\scripts\build-friend-installer.ps1" -GitHubRepo "<YOUR_GITHUB_USERNAME>/ForeverMarketWatch"
```
This drops a tiny ~10 KB **`ForeverMarketWatch-Installer.zip`** directly into your `Downloads` folder!

*(Whenever you push a bug fix or new feature to GitHub later, GitHub Actions automatically updates `release/manifest.json`, and every friend's PC silently downloads your update within 15 minutes!)*

---

## Part 2: Copy-Paste Discord Instructions for Your Friends

> **ForeverMarketWatch (WoW: Forever Beta) — 1-Click Install**
>
> 1. Unzip `ForeverMarketWatch-Installer.zip` anywhere.
> 2. Double-click **`Install ForeverMarketWatch.bat`** (or **`Install ForeverMarketWatch (Mac).command`** on macOS) and press **Enter** when it finds your WoW: Forever folder.
> 3. **Restart WoW: Forever** once — then click the gold coin minimap icon, type `/fmw`, or click the **MarketWatch** tab at the AH!
>
> **That's it!** You can delete the ZIP after installing — a silent background updater now keeps both your **hourly AH prices** and **addon beta updates** up to date every 15 minutes with zero popups and zero extra clicks. (Run `Uninstall Auto-Updates.bat` anytime to remove it.)

---

## Blizzard Attribution & Developer API Compliance

*World of Warcraft* and *Blizzard Entertainment* are trademarks or registered trademarks of Blizzard Entertainment, Inc. in the U.S. and/or other countries. ForeverMarketWatch is completely free, non-commercial, and not affiliated with or endorsed by Blizzard Entertainment, Inc. Cloud sync uses the official Battle.net Game Data API strictly within published rate limits (`If-Modified-Since` hourly caching) while keeping all API credentials private inside encrypted GitHub Secrets.
