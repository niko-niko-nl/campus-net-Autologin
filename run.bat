@echo off
REM ===================================================================
REM  Double-click to log in right now (instead of waiting for the
REM  scheduled task). Also prints the current online status.
REM
REM  Which installation gets used:
REM    - if this folder IS an installation (has config.json), it uses
REM      THIS folder, so a custom -InstallDir works;
REM    - otherwise it falls back to the default %LOCALAPPDATA%\CampusNet.
REM ===================================================================
chcp 65001 >nul
title CampusNet - Login now

set "DEFAULT=%LOCALAPPDATA%\CampusNet"

if exist "%~dp0config.json" (
    set "DIRRAW=%~dp0"
) else (
    set "DIRRAW=%DEFAULT%\"
)

REM %~dp0 ends with a backslash; strip it so the path stays clean.
set "DIR=%DIRRAW:~0,-1%"
set "TARGET=%DIR%\CampusNet.ps1"

if not exist "%TARGET%" (
    echo [!] Not installed - could not find CampusNet.ps1
    echo     Looked in: "%DIR%"
    echo     Run install.bat first.
    echo.
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
echo Log: %DIR%\login.log
echo.
pause
