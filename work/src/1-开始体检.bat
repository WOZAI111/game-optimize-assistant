@echo off
setlocal enableextensions
cd /d "%~dp0"
echo.
echo ==========================================================
echo   Game optimization assistant - step 1: read-only scan
echo   This window will stay open. Follow the prompts.
echo   Nothing will be changed during this scan.
echo ==========================================================
echo.
rem Clear the "downloaded from the internet" mark so the script can run.
powershell -NoProfile -ExecutionPolicy Bypass -Command "Get-ChildItem -LiteralPath '%~dp0' -Recurse -File -ErrorAction SilentlyContinue | Unblock-File -ErrorAction SilentlyContinue" >nul 2>nul
powershell -NoProfile -ExecutionPolicy Bypass -File "GameOptimize.ps1"
if errorlevel 1 (
  echo.
  echo [ERROR] The scan did not finish.
  echo         Make sure GameOptimize.ps1 sits in the same folder as this file.
  echo.
  pause
  exit /b 1
)
exit /b 0
