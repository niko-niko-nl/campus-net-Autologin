@echo off
REM ===================================================================
REM  Double-click to log in right now (instead of waiting for the
REM  scheduled task). Also prints the current online status.
REM ===================================================================
chcp 65001 >nul
title CampusNet - Login now

set "TARGET=%LOCALAPPDATA%\CampusNet\CampusNet.ps1"
if not exist "%TARGET%" (
    echo [!] Not installed yet. Run install.bat first.
    echo     Expected: %TARGET%
    pause
    exit /b 1
)

echo === Current status ===
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%TARGET%" -Mode status
echo.
echo === Trying to log in ===
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%TARGET%" -Mode ensure
set CODE=%ERRORLEVEL%
echo.
if "%CODE%"=="0" (echo [OK] Online.) else (echo [!] Not online. Exit code %CODE%.)
echo.
echo Log: %LOCALAPPDATA%\CampusNet\login.log
echo.
pause
