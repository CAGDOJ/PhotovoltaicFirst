@echo off
setlocal
set "ROOT=%~dp0.."
for %%I in ("%ROOT%") do set "ROOT=%%~fI"
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0start_solar_background.ps1" -Root "%ROOT%"
exit /b %ERRORLEVEL%
