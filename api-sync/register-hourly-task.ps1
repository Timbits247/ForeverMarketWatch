<#
.SYNOPSIS
    Registers a silent background Windows Scheduled Task (ForeverMarketWatchHourlySync)
    so Blizzard API prices check automatically every 5 minutes (using lightweight 304 checks)
    with zero popup windows.
#>
param(
    [int]$IntervalMinutes = 5
)

$ErrorActionPreference = "Stop"
$TaskName  = "ForeverMarketWatchHourlySync"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$VbsPath   = Join-Path $ScriptDir "run-hidden.vbs"

if (-not (Test-Path $VbsPath)) {
    Write-Error "Missing launcher: $VbsPath"
    exit 1
}

# Remove existing task if already registered
$existing = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
if ($existing) {
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
}

$action = New-ScheduledTaskAction -Execute "wscript.exe" -Argument "`"$VbsPath`""
$trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval (New-TimeSpan -Minutes $IntervalMinutes)
$settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -StartWhenAvailable `
    -ExecutionTimeLimit (New-TimeSpan -Minutes 4)

Register-ScheduledTask `
    -TaskName $TaskName `
    -Action $action `
    -Trigger $trigger `
    -Settings $settings `
    -Description "Blizzard Battle.net API Auction House sync every $IntervalMinutes minutes for ForeverMarketWatch (WoW: Forever)." | Out-Null

Write-Host "Registered silent background task: $TaskName (every $IntervalMinutes minutes)" -ForegroundColor Green
Write-Host "Uses lightweight 304 Not Modified checks and updates MarketFeedData.lua the moment Blizzard publishes a new snapshot." -ForegroundColor Cyan
Write-Host "To disable later, run: api-sync\unregister-hourly-task.ps1" -ForegroundColor Gray
