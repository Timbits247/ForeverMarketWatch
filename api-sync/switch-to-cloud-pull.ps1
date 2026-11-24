<#
.SYNOPSIS
    Switches this PC from the local Blizzard API sync task (which pauses during Sleep)
    to pulling 24/7 overnight MarketFeedData.lua snapshots from your GitHub Actions cloud feed
    every 15 minutes + immediately on logon/wake (prices ONLY; never touches local code edits).
#>
$ErrorActionPreference = "Stop"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$VbsPath   = Join-Path $ScriptDir "run-cloud-pull-hidden.vbs"
$PullPs    = Join-Path $ScriptDir "pull-cloud-prices.ps1"

# 1. Remove old local-only sync task so it doesn't overwrite 24/7 cloud history
Unregister-ScheduledTask -TaskName "ForeverMarketWatchHourlySync" -Confirm:$false -ErrorAction SilentlyContinue
Write-Host "Removed old local-only task (ForeverMarketWatchHourlySync)." -ForegroundColor Yellow

# 2. Register silent 15-min + at-logon cloud price puller
$taskName = "ForeverMarketWatchCloudPricePull"
$action = New-ScheduledTaskAction -Execute "wscript.exe" -Argument "`"$VbsPath`""
$triggerRepeat = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) `
    -RepetitionInterval (New-TimeSpan -Minutes 15) `
    -RepetitionDuration (New-TimeSpan -Days 3650)
$triggerLogon = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
$settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -StartWhenAvailable `
    -MultipleInstances IgnoreNew `
    -ExecutionTimeLimit (New-TimeSpan -Minutes 3)

Register-ScheduledTask `
    -TaskName $taskName `
    -Action $action `
    -Trigger @($triggerRepeat, $triggerLogon) `
    -Settings $settings `
    -Description "Pulls 24/7 overnight MarketFeedData.lua prices from Timbits247/ForeverMarketWatch every 15 min." `
    -Force | Out-Null

Write-Host "Registered silent 24/7 cloud price pull task ($taskName — every 15 min + on wake/logon)." -ForegroundColor Green

# 3. Pull latest 24/7 overnight MarketFeedData.lua into live WoW right now!
& $PullPs -Force
