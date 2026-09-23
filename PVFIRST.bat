@echo off
setlocal EnableExtensions
set "ROOT=%~dp0"
for %%I in ("%ROOT%.") do set "ROOT=%%~fI"
cd /d "%TEMP%"

start "PV-First V50.5" /wait powershell.exe -NoLogo -NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File "%ROOT%\_launcher\PVFIRST_DESKTOP_BOOT.ps1" -Root "%ROOT%"
set "RC=%ERRORLEVEL%"

if not "%RC%"=="0" (
  if exist "%ROOT%\_interno\startup_error.log" start "PV-First diagnostico" notepad.exe "%ROOT%\_interno\startup_error.log"
  if exist "%ROOT%\_interno\startup_trace.log" start "PV-First rastreio" notepad.exe "%ROOT%\_interno\startup_trace.log"
)
exit /b %RC%
