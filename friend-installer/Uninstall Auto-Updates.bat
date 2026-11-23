@echo off
title ForeverMarketWatch — Uninstall Auto-Updates
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Unregister-ScheduledTask -TaskName 'ForeverMarketWatchAutoSync' -Confirm:$false -ErrorAction SilentlyContinue; Remove-Item -Path (Join-Path $env:LOCALAPPDATA 'ForeverMarketWatchUpdater') -Recurse -Force -ErrorAction SilentlyContinue; Write-Host 'ForeverMarketWatch silent auto-updater has been removed. (Your WoW addon & saved data were left untouched.)' -ForegroundColor Green"
echo.
pause
