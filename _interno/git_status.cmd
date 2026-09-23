@echo off
setlocal
set "ROOT=%~dp0.."
for %%I in ("%ROOT%") do set "ROOT=%%~fI"
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%ROOT%\_launcher\GITHUB_API_BRIDGE.ps1" -Action test -Root "%ROOT%" -Repo "CAGDOJ/PhotovoltaicFirst" -Branch "main"
exit /b %ERRORLEVEL%
