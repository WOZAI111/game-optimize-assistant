@echo off
setlocal enableextensions
cd /d %~dp0
echo.
echo ==========================================================
echo   Roll back the last applied optimization
echo   (restores every value recorded in the journal)
echo ==========================================================
echo.
powershell -NoProfile -ExecutionPolicy Bypass -File GameOptimize.ps1 -RevertLatest -Elevate
if errorlevel 1 pause
exit /b 0
