@echo off
title ForeverMarketWatch — Publish Update to GitHub
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\publish-update.ps1"
echo.
pause
