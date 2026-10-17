@echo off
setlocal enableextensions
cd /d %~dp0
echo.
echo ==========================================================
echo   Play and record - live performance logging
echo   Play one round while the tool records CPU / GPU / VRAM /
echo   memory / disk / network and the programs running behind.
echo   Nothing is changed on this PC.
echo   Stop with Ctrl+C in this window, or by closing the game.
echo ==========================================================
echo.
powershell -NoProfile -ExecutionPolicy Bypass -File GameOptimize.ps1 -Monitor
if errorlevel 1 (
  echo.
  echo [ERROR] The recording did not start.
  echo         Make sure GameOptimize.ps1 sits in the same folder as this file.
  echo.
  pause
  exit /b 1
)
exit /b 0
