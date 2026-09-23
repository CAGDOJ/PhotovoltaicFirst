param(
    [Parameter(Mandatory=$true)][string]$Root
)

$ErrorActionPreference = 'SilentlyContinue'
$Internal = Join-Path $Root '_interno'
$Log = Join-Path $Internal 'current.log'
$Status = Join-Path $Internal 'status.txt'
$Lock = Join-Path $Internal 'solar_background.lock'
try { Set-Location -LiteralPath $env:TEMP } catch {}

function Write-TextDefault([string]$Path, [string]$Text) {
    try {
        $dir = Split-Path -Parent $Path
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
        $enc = [System.Text.Encoding]::Default
        $bytes = $enc.GetBytes($Text)
        $fs = [System.IO.FileStream]::new($Path, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::ReadWrite)
        try { $fs.Write($bytes, 0, $bytes.Length) } finally { $fs.Close() }
    } catch {}
}

Write-TextDefault $Status "RUNNING: Coleta continua 24h em segundo plano"
Write-TextDefault $Log "[PV-First] Coleta continua 24h iniciada em segundo plano.`r`n[PV-First] Pode minimizar ou fechar esta janela; o processo continua enquanto o Windows nao suspender.`r`n[PV-First] Ativei bloqueio de suspensao enquanto a coleta estiver ligada. A tela pode apagar normalmente.`r`n[PV-First] Para encerrar, abra a interface e clique em Parar.`r`n"
Write-TextDefault $Lock (Get-Date).ToString('s')

function Q([string]$s) { return '"' + $s.Replace('"','\"') + '"' }

$keepArgs = '-NoLogo -NoProfile -ExecutionPolicy Bypass -File ' + (Q (Join-Path $Internal 'keep_awake.ps1')) + ' -Root ' + (Q $Root)
Start-Process -FilePath 'powershell.exe' -ArgumentList $keepArgs -WorkingDirectory $env:TEMP -WindowStyle Hidden | Out-Null

$runArgs = '-NoLogo -NoProfile -ExecutionPolicy Bypass -File ' + (Q (Join-Path $Internal 'run_wsl.ps1')) + ' -Mode solar -Root ' + (Q $Root)
Start-Process -FilePath 'powershell.exe' -ArgumentList $runArgs -WorkingDirectory $env:TEMP -WindowStyle Hidden | Out-Null

exit 0
