param([Parameter(Mandatory=$true)][string]$Root)
$ErrorActionPreference = 'SilentlyContinue'
$Root = (Resolve-Path -LiteralPath $Root).Path.TrimEnd('\')
$Internal = Join-Path $Root '_interno'
try { Set-Location -LiteralPath $env:TEMP } catch {}

# Para o agente conhecido pelo PID.
$pidFile = Join-Path $Internal 'github_pages_agent.pid'
if (Test-Path $pidFile) {
    $txt = (Get-Content -LiteralPath $pidFile -Raw -ErrorAction SilentlyContinue).Trim()
    if ($txt -match '^\d+$') { Stop-Process -Id ([int]$txt) -Force -ErrorAction SilentlyContinue }
    Remove-Item -LiteralPath $pidFile -Force -ErrorAction SilentlyContinue
}

# Para a coleta Linux/WSL ligada a esta pasta.
try {
    $distro = (& wsl.exe -l -q 2>$null | ForEach-Object { ('' + $_) -replace "`0", '' } | Where-Object { $_.Trim() -ne '' -and $_ -notmatch 'docker' } | Select-Object -First 1).Trim()
    if ($distro) {
        $wslRoot = (& wsl.exe -d $distro -- wslpath -a "$Root" 2>$null | Out-String).Trim()
        if ($wslRoot) {
            $pattern = [Regex]::Escape($wslRoot)
            & wsl.exe -d $distro -- bash -lc "pkill -f '$pattern.*/run_solar_window.sh' 2>/dev/null || true; pkill -f '$pattern.*/_launcher/solar.sh' 2>/dev/null || true" | Out-Null
        }
    }
} catch {}

# Remove lock logico.
Remove-Item -LiteralPath (Join-Path $Internal 'solar_background.lock') -Force -ErrorAction SilentlyContinue


# Encerra especificamente a interface HTA temporaria da V42, que roda a partir de %TEMP%.
try {
    $sha=[System.Security.Cryptography.SHA1]::Create()
    $bytes=[Text.Encoding]::UTF8.GetBytes($Root.ToLowerInvariant())
    $hash=([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-','').Substring(0,10).ToLowerInvariant()
    Get-CimInstance Win32_Process -Filter "Name='mshta.exe'" -ErrorAction SilentlyContinue | ForEach-Object {
        try {
            $cmd=(''+$_.CommandLine).ToLowerInvariant()
            if($cmd -match ('pvfirstv42_'+[regex]::Escape($hash)+'\\.hta')) {
                Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
            }
        } catch {}
    }
} catch {}

# Encerra wrappers Windows desta instancia que tenham o caminho do projeto na linha de comando.
try {
    $needle = $Root.ToLowerInvariant()
    Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | ForEach-Object {
        try {
            if ($_.ProcessId -eq $PID) { return }
            $cmd = '' + $_.CommandLine
            if ($cmd -and $cmd.ToLowerInvariant().Contains($needle)) {
                if (@('powershell.exe','pwsh.exe','cmd.exe','wsl.exe','mshta.exe') -contains ('' + $_.Name).ToLowerInvariant()) {
                    Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
                }
            }
        } catch {}
    }
} catch {}

Start-Sleep -Milliseconds 300

try {
    $lp = Join-Path $Root '_interno\local_ui_server.pid'
    if (Test-Path $lp) {
        $id = (Get-Content -LiteralPath $lp -Raw -ErrorAction SilentlyContinue).Trim()
        if ($id -match '^\d+$') { Stop-Process -Id ([int]$id) -Force -ErrorAction SilentlyContinue }
        Remove-Item $lp -Force -ErrorAction SilentlyContinue
    }
    Remove-Item (Join-Path $Root '_interno\local_ui_port.txt') -Force -ErrorAction SilentlyContinue
} catch {}
