param([Parameter(Mandatory=$true)][string]$Root)
$ErrorActionPreference='Stop'
$logDir=Join-Path $Root '_interno'
$logFile=Join-Path $logDir 'startup_error.log'
try {
    if(!(Test-Path $logDir)){New-Item -ItemType Directory -Force -Path $logDir|Out-Null}
    Remove-Item $logFile -Force -ErrorAction SilentlyContinue
    $desktop = Join-Path $PSScriptRoot 'PVFIRST_DESKTOP.ps1'
    if(!(Test-Path $desktop)){ throw "Interface não encontrada: $desktop" }
    & $desktop -Root $Root
} catch {
    $msg="PV-First V50.5 - falha ao abrir a interface.`r`n`r`n"+$_.Exception.Message+"`r`n`r`n"+$_.ScriptStackTrace
    try {[IO.File]::WriteAllText($logFile,$msg,(New-Object Text.UTF8Encoding($true)))}catch{}
    try {
        Add-Type -AssemblyName PresentationFramework
        [System.Windows.MessageBox]::Show(
            "Não foi possível abrir a interface local do PV-First.`n`n" + $_.Exception.Message + "`n`nDiagnóstico salvo em:`n"+$logFile,
            'PV-First - Erro de inicialização',
            [System.Windows.MessageBoxButton]::OK,
            [System.Windows.MessageBoxImage]::Error
        ) | Out-Null
    } catch {}
    Start-Sleep -Seconds 2
    exit 1
}
exit 0
