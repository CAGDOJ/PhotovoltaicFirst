@echo off
setlocal EnableExtensions DisableDelayedExpansion
set "PROJECT_IN=%~1"
set "LOG_IN=%~2"
set "PROJECT_WSL="
set "LOG_WSL="
set "WSL_DISTRO="

where wsl.exe >nul 2>nul
if errorlevel 1 (
  echo ERRO: WSL nao encontrado. Instale com: wsl --install -d Ubuntu
  exit /b 1
)

for %%I in ("%PROJECT_IN%") do set "PROJECT_ABS=%%~fI"
if not "%LOG_IN%"=="" for %%I in ("%LOG_IN%") do set "LOG_ABS=%%~fI"

rem Procura uma distro Linux real. Ignora docker-desktop.
for /f "usebackq delims=" %%D in (`powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0select_wsl.ps1" 2^>nul`) do (
  if not defined WSL_DISTRO set "WSL_DISTRO=%%D"
)

if not defined WSL_DISTRO (
  echo ERRO: nenhuma distro Linux valida encontrada no WSL.
  echo A distro docker-desktop nao serve para compilar o PV-First.
  echo Instale com: wsl --install -d Ubuntu
  exit /b 1
)

set "WSL_DISTRO=%WSL_DISTRO:"=%"
for /f "tokens=* delims= " %%A in ("%WSL_DISTRO%") do set "WSL_DISTRO=%%A"

wsl.exe -d "%WSL_DISTRO%" -- /usr/bin/env bash -lc "echo PVFIRST_WSL_OK" >nul 2>nul
if errorlevel 1 (
  echo ERRO: nao consegui iniciar a distro Linux: %WSL_DISTRO%
  echo Teste no PowerShell: wsl -d %WSL_DISTRO% -- /usr/bin/env bash -lc "echo ok"
  exit /b 1
)

call :toWsl "%PROJECT_ABS%" PROJECT_WSL
if defined LOG_ABS call :toWsl "%LOG_ABS%" LOG_WSL

endlocal & set "PROJECT_WSL=%PROJECT_WSL%" & set "LOG_WSL=%LOG_WSL%" & set "WSL_DISTRO=%WSL_DISTRO%"
exit /b 0

:toWsl
setlocal EnableExtensions DisableDelayedExpansion
set "WINPATH=%~1"
set "DRIVE=%WINPATH:~0,1%"
set "REST=%WINPATH:~2%"
set "REST=%REST:\=/%"
set "DRIVE_L=%DRIVE%"
if /I "%DRIVE%"=="A" set "DRIVE_L=a"
if /I "%DRIVE%"=="B" set "DRIVE_L=b"
if /I "%DRIVE%"=="C" set "DRIVE_L=c"
if /I "%DRIVE%"=="D" set "DRIVE_L=d"
if /I "%DRIVE%"=="E" set "DRIVE_L=e"
if /I "%DRIVE%"=="F" set "DRIVE_L=f"
if /I "%DRIVE%"=="G" set "DRIVE_L=g"
if /I "%DRIVE%"=="H" set "DRIVE_L=h"
if /I "%DRIVE%"=="I" set "DRIVE_L=i"
if /I "%DRIVE%"=="J" set "DRIVE_L=j"
if /I "%DRIVE%"=="K" set "DRIVE_L=k"
if /I "%DRIVE%"=="L" set "DRIVE_L=l"
if /I "%DRIVE%"=="M" set "DRIVE_L=m"
if /I "%DRIVE%"=="N" set "DRIVE_L=n"
if /I "%DRIVE%"=="O" set "DRIVE_L=o"
if /I "%DRIVE%"=="P" set "DRIVE_L=p"
if /I "%DRIVE%"=="Q" set "DRIVE_L=q"
if /I "%DRIVE%"=="R" set "DRIVE_L=r"
if /I "%DRIVE%"=="S" set "DRIVE_L=s"
if /I "%DRIVE%"=="T" set "DRIVE_L=t"
if /I "%DRIVE%"=="U" set "DRIVE_L=u"
if /I "%DRIVE%"=="V" set "DRIVE_L=v"
if /I "%DRIVE%"=="W" set "DRIVE_L=w"
if /I "%DRIVE%"=="X" set "DRIVE_L=x"
if /I "%DRIVE%"=="Y" set "DRIVE_L=y"
if /I "%DRIVE%"=="Z" set "DRIVE_L=z"
set "OUT=/mnt/%DRIVE_L%%REST%"
endlocal & set "%~2=%OUT%"
exit /b 0
