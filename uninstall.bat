@echo off
REM ===================================================================
REM  Double-click to uninstall: removes the scheduled task, the saved
REM  password, the logs and the desktop shortcut. Program files are kept.
REM
REM  Which installation gets uninstalled:
REM    - if this folder is an actual installation (has config.json), it
REM      uninstalls THIS folder;
REM    - otherwise it uninstalls the default install at
REM      %LOCALAPPDATA%\CampusNet.
REM  Either way the target directory is printed before doing anything.
REM
REM  Extra arguments are passed through, e.g.  uninstall.bat -Purge
REM ===================================================================
chcp 65001 >nul
title CampusNet - Uninstall

set "DEFAULT=%LOCALAPPDATA%\CampusNet"

if exist "%~dp0config.json" (
    set "TARGET=%~dp0uninstall.ps1"
    set "DIRRAW=%~dp0"
) else (
    set "TARGET=%DEFAULT%\uninstall.ps1"
    set "DIRRAW=%DEFAULT%\"
)

REM %~dp0 ends with a backslash; a trailing \" would be parsed as an escaped
REM quote when passed to powershell.exe, so strip it.
set "DIR=%DIRRAW:~0,-1%"

if not exist "%TARGET%" (
    echo [!] Not installed - could not find uninstall.ps1
    echo     Looked in: "%DIR%"
    echo.
    pause
    exit /b 1
)

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%TARGET%" -InstallDir "%DIR%" %*
set CODE=%ERRORLEVEL%

echo.
if "%CODE%"=="0" (echo [OK] Uninstall finished.) else (echo [!] Uninstall exited with code %CODE%.)
echo.
pause
