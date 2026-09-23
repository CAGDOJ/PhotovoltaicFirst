@echo off
setlocal
set "ROOT=%~dp0.."
for %%I in ("%ROOT%") do set "ROOT=%%~fI"
del "%~dp0solar_background.lock" >nul 2>nul
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0run_wsl.ps1" -Mode stop -Root "%ROOT%"
exit /b %ERRORLEVEL%
