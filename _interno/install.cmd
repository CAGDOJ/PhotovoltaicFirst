@echo off
setlocal
set "ROOT=%~dp0.."
for %%I in ("%ROOT%") do set "ROOT=%%~fI"
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0run_wsl.ps1" -Mode install -Root "%ROOT%"
exit /b %ERRORLEVEL%
