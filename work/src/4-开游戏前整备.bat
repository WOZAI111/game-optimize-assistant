@echo off
setlocal enableextensions
cd /d %~dp0
echo.
echo ==========================================================
echo   Pre-game cleanup - run this right before you play
echo   It pauses cloud sync and closes the background programs
echo   that steal memory and disk, then puts them back when you
echo   quit the game.
echo.
echo   Nothing is changed until you say yes in the next screen,
echo   and everything it stops can be restored later.
echo ==========================================================
echo.
powershell -NoProfile -ExecutionPolicy Bypass -File PreGame.ps1
if errorlevel 1 (
  echo.
  echo [ERROR] It did not run.
  echo         Make sure PreGame.ps1 sits in the same folder as this file.
  echo.
  pause
  exit /b 1
)
exit /b 0