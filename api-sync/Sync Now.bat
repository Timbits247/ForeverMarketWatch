@echo off
title ForeverMarketWatch - Blizzard API Sync
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0sync-blizzard-ah.ps1" -Force
echo.
pause
