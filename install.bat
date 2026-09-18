@echo off
REM ===================================================================
REM  Double-click this file to install the campus-network auto login.
REM  It self-deploys to %LOCALAPPDATA%\CampusNet, so it does not matter
REM  where you extracted this folder from (Downloads is fine).
REM  No administrator rights required.
REM
REM  Any extra arguments are passed through to install.ps1, e.g.
REM    install.bat -IntervalMinutes 3
REM ===================================================================
chcp 65001 >nul
title CampusNet - Install

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0install.ps1" %*
set CODE=%ERRORLEVEL%

echo.
if "%CODE%"=="0" (
    echo [OK] Install finished.
    echo      Auto login is set up. Log file: %LOCALAPPDATA%\CampusNet\login.log
) else (
    echo [!] Install exited with code %CODE%.
    echo     See %LOCALAPPDATA%\CampusNet\login.log for details.
)
echo.
pause
