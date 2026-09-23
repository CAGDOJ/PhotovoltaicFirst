param(
    [Parameter(Mandatory=$true)][string]$Mode,
    [Parameter(Mandatory=$true)][string]$Root
)

$ErrorActionPreference = 'Stop'
$Project = Join-Path $Root 'pvfirst'
$Internal = Join-Path $Root '_interno'
$Log = Join-Path $Internal 'current.log'
$Status = Join-Path $Internal 'status.txt'
$EnvStatus = Join-Path $Internal 'env_status.txt'
$SolarLock = Join-Path $Internal 'solar_background.lock'
try { Set-Location -LiteralPath $env:TEMP } catch {}

function Ensure-Folder([string]$Path) {
    if (-not (Test-Path $Path)) { New-Item -ItemType Directory -Force -Path $Path | Out-Null }
}
function Write-TextDefault([string]$Path, [string]$Text) {
    try { Ensure-Folder (Split-Path -Parent $Path) } catch {}
    $enc = [System.Text.Encoding]::Default
    $bytes = $enc.GetBytes($Text)
    for ($i = 0; $i -lt 25; $i++) {
        try {
            $fs = [System.IO.FileStream]::new($Path, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::ReadWrite)
            try { $fs.Write($bytes, 0, $bytes.Length) } finally { $fs.Close() }
            return
        } catch { Start-Sleep -Milliseconds 120 }
    }
    # Log/status nunca pode derrubar a simulacao.
}
function Add-TextDefault([string]$Path, [string]$Text) {
    try { Ensure-Folder (Split-Path -Parent $Path) } catch {}
    if (-not $Text.EndsWith([Environment]::NewLine)) { $Text = $Text + [Environment]::NewLine }
    $enc = [System.Text.Encoding]::Default
    $bytes = $enc.GetBytes($Text)
    for ($i = 0; $i -lt 25; $i++) {
        try {
            $fs = [System.IO.FileStream]::new($Path, [System.IO.FileMode]::Append, [System.IO.FileAccess]::Write, [System.IO.FileShare]::ReadWrite)
            try { $fs.Write($bytes, 0, $bytes.Length) } finally { $fs.Close() }
            return
        } catch { Start-Sleep -Milliseconds 120 }
    }
    # Se o HTA estiver lendo no mesmo instante, apenas ignora esta linha e segue.
}
function Write-Log([string]$Text) { try { Add-TextDefault $Log $Text } catch {} }
function Set-Status([string]$Text) { try { Write-TextDefault $Status $Text } catch {} }
function Set-EnvStatus([string]$Text) { try { Write-TextDefault $EnvStatus $Text } catch {} }
function Reset-Log([string[]]$Lines) {
    try {
        Ensure-Folder $Internal
        $joined = ($Lines -join [Environment]::NewLine) + [Environment]::NewLine
        Write-TextDefault $Log $joined
    } catch {}
}
function ConvertTo-WslPathManual([string]$WinPath) {
    $full = [System.IO.Path]::GetFullPath($WinPath)
    if ($full -notmatch '^([A-Za-z]):\\(.*)$') { throw "Caminho Windows invalido para WSL." }
    $drive = $matches[1].ToLower()
    $rest = $matches[2] -replace '\\','/'
    return "/mnt/$drive/$rest"
}
function Remove-Ansi([string]$Line) {
    return ($Line -replace "`e\[[0-9;?]*[ -/]*[@-~]", '')
}
function Get-RealWslDistro {
    $names = @()
    try {
        $raw = & wsl.exe -l -q 2>$null
        foreach ($line in $raw) {
            $s = ('' + $line) -replace "`0", ''
            $s = $s.Trim()
            if ($s -eq '') { continue }
            if ($s -match 'docker') { continue }
            $names += $s
        }
    } catch {}

    if ($names.Count -eq 0) {
        try {
            $raw2 = & wsl.exe -l -v 2>$null
            foreach ($line in $raw2) {
                $s = ('' + $line) -replace "`0", ''
                $s = $s.Trim()
                if ($s -eq '' -or $s -match '^NAME\s+') { continue }
                if ($s -match '^\*?\s*([^\s]+)\s+') {
                    $n = $Matches[1].Trim()
                    if ($n -and ($n -notmatch 'docker')) { $names += $n }
                }
            }
        } catch {}
    }

    $ordered = @()
    $ubuntu = $names | Where-Object { $_ -like 'Ubuntu*' } | Select-Object -First 1
    if ($ubuntu) { $ordered += $ubuntu }
    foreach ($n in $names) { if ($ordered -notcontains $n) { $ordered += $n } }

    foreach ($d in $ordered) {
        try {
            $out = & wsl.exe -d $d -- bash -lc 'printf PVFIRST_OK' 2>$null
            if ((($out -join '') -replace "`0", '').Trim() -eq 'PVFIRST_OK') { return $d }
        } catch {}
    }

    throw 'Nenhuma distribuicao Ubuntu/Linux valida foi encontrada no WSL.'
}

function Normalize-ProxyUrl([string]$Raw) {
    if ([string]::IsNullOrWhiteSpace($Raw)) { return $null }
    $v = $Raw.Trim().Trim('"')
    if ($v -match '^(?i)https?://') { return $v }
    if ($v -match '^[A-Za-z0-9._-]+:\d{2,5}$') { return ('http://' + $v) }
    if ($v -match '(?i)(?:https?=)?([A-Za-z0-9._-]+):(\d{2,5})') {
        return ('http://' + $Matches[1] + ':' + $Matches[2])
    }
    return $null
}
function Convert-ProxyOverrideToNoProxy([string]$Raw) {
    $items = @('localhost','127.0.0.1','::1')
    if (-not [string]::IsNullOrWhiteSpace($Raw)) {
        foreach ($part in ($Raw -split '[;,]')) {
            $x = $part.Trim()
            if ($x -eq '' -or $x -eq '<local>') { continue }
            if ($x.StartsWith('*.')) { $x = $x.Substring(1) }
            if ($items -notcontains $x) { $items += $x }
        }
    }
    return ($items -join ',')
}
function Get-AutoProxyInfo {
    $result = [ordered]@{ Enabled=$false; Url=''; NoProxy='localhost,127.0.0.1,::1,.intraer,10.0.0.0/8,192.168.0.0/16,172.16.0.0/12'; Source='direto' }

    # Primeiro usa o proxy que o launcher V42 ja detectou e gravou no pvfirst.env.
    # Isso evita divergencia entre a inicializacao e os processos de teste/coleta.
    try {
        $cfg = Join-Path $Project 'config\pvfirst.env'
        if (Test-Path -LiteralPath $cfg) {
            $auto=''; $url=''; $np=''
            foreach($line in Get-Content -LiteralPath $cfg -ErrorAction SilentlyContinue) {
                $t=(''+$line).Trim()
                if($t -match '^export\s+PVFIRST_PROXY_AUTO=\"?(.*?)\"?$'){ $auto=$Matches[1].Trim('\"') }
                elseif($t -match '^export\s+PVFIRST_PROXY_URL=\"?(.*?)\"?$'){ $url=$Matches[1].Trim('\"') }
                elseif($t -match '^export\s+PVFIRST_NO_PROXY=\"?(.*?)\"?$'){ $np=$Matches[1].Trim('\"') }
            }
            $norm=Normalize-ProxyUrl $url
            if($auto -eq '1' -and $norm) {
                $result.Enabled=$true; $result.Url=$norm
                if($np){$result.NoProxy=$np}
                $result.Source='configuracao detectada na inicializacao'
                return [pscustomobject]$result
            }
        }
    } catch {}

    foreach ($scope in @('Process','User','Machine')) {
        foreach ($name in @('HTTPS_PROXY','https_proxy','HTTP_PROXY','http_proxy')) {
            try {
                $raw = [Environment]::GetEnvironmentVariable($name, $scope)
                $url = Normalize-ProxyUrl $raw
                if ($url) {
                    $np = [Environment]::GetEnvironmentVariable('NO_PROXY', $scope)
                    if (-not $np) { $np = [Environment]::GetEnvironmentVariable('no_proxy', $scope) }
                    $result.Enabled = $true; $result.Url = $url
                    if ($np) { $result.NoProxy = Convert-ProxyOverrideToNoProxy $np }
                    $result.Source = "variavel $name/$scope"
                    return [pscustomobject]$result
                }
            } catch {}
        }
    }

    try {
        $reg = Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' -ErrorAction Stop
        if ([int]$reg.ProxyEnable -eq 1 -and $reg.ProxyServer) {
            $raw = '' + $reg.ProxyServer
            $candidate = $raw
            if ($raw -match '(?i)(?:^|;)https=([^;]+)') { $candidate = $Matches[1] }
            elseif ($raw -match '(?i)(?:^|;)http=([^;]+)') { $candidate = $Matches[1] }
            $url = Normalize-ProxyUrl $candidate
            if ($url) {
                $result.Enabled = $true; $result.Url = $url
                $result.NoProxy = Convert-ProxyOverrideToNoProxy ('' + $reg.ProxyOverride)
                $result.Source = 'Windows Internet Options'
                return [pscustomobject]$result
            }
        }
    } catch {}

    try {
        $txt = (& netsh winhttp show proxy 2>$null | Out-String)
        if ($txt -and $txt -notmatch '(?i)direct access|acesso direto|sem servidor proxy') {
            $m = [regex]::Match($txt, '(?i)(?:https?=)?([A-Za-z0-9._-]+):(\d{2,5})')
            if ($m.Success) {
                $result.Enabled = $true
                $result.Url = 'http://' + $m.Groups[1].Value + ':' + $m.Groups[2].Value
                $bypass = ''
                $bm = [regex]::Match($txt, '(?im)(?:Bypass List|Lista de Ignorados|Ignorar).*?:\s*(.+)$')
                if ($bm.Success) { $bypass = $bm.Groups[1].Value }
                $result.NoProxy = Convert-ProxyOverrideToNoProxy $bypass
                $result.Source = 'WinHTTP'
                return [pscustomobject]$result
            }
        }
    } catch {}

    # Fallback corporativo conhecido. Nao e forcado: so entra se 10.108.88.4:8080 responder.
    try {
        $hostFallback = '10.108.88.4'
        $portFallback = 8080
        $client = New-Object System.Net.Sockets.TcpClient
        $iar = $client.BeginConnect($hostFallback, $portFallback, $null, $null)
        $ok = $iar.AsyncWaitHandle.WaitOne(1200, $false)
        if ($ok -and $client.Connected) {
            try { $client.EndConnect($iar) } catch {}
            $result.Enabled = $true
            $result.Url = 'http://10.108.88.4:8080'
            $result.NoProxy = 'localhost,127.0.0.1,::1,.intraer,10.0.0.0/8,192.168.0.0/16,172.16.0.0/12'
            $result.Source = 'fallback corporativo detectado'
            $client.Close()
            return [pscustomobject]$result
        }
        $client.Close()
    } catch {}

    return [pscustomobject]$result
}
function Get-ProxyShellPrefix {
    $px = Get-AutoProxyInfo
    if (-not $px.Enabled) { return '' }
    $u = BashQuote $px.Url
    $n = BashQuote $px.NoProxy
    return "export PVFIRST_PROXY_AUTO='1'; export PVFIRST_PROXY_URL=$u; export PVFIRST_NO_PROXY=$n; export http_proxy=$u; export https_proxy=$u; export HTTP_PROXY=$u; export HTTPS_PROXY=$u; export no_proxy=$n; export NO_PROXY=$n; "
}
function Write-ProxyInfoToLog {
    $px = Get-AutoProxyInfo
    if ($px.Enabled) {
        Write-Log ("[PV-First] Proxy detectado automaticamente: " + $px.Url + " (" + $px.Source + ")")
        Write-Log ("[PV-First] Bypass/no_proxy: " + $px.NoProxy)
    } else {
        Write-Log '[PV-First] Proxy nao detectado. Usando conexao direta.'
    }
}

function Invoke-WslCommand([string]$Distro, [string]$Command, [bool]$AsRoot) {
    $args = @('-d', $Distro)
    if ($AsRoot) { $args += @('-u', 'root') }
    $Command = (Get-ProxyShellPrefix) + 'export LC_ALL=C; export LANG=C; ' + $Command
    $args += @('--', 'bash', '-lc', $Command)
    & wsl.exe @args 2>&1 | ForEach-Object {
        $line = Remove-Ansi ('' + $_)
        if ($line -ne '') { Write-Log $line }
    }
    return $LASTEXITCODE
}
function BashQuote([string]$Text) {
    return "'" + ($Text -replace "'", "'\''") + "'"
}

try {
    if (-not (Test-Path $Project)) { throw 'Pasta pvfirst nao encontrada.' }

    switch ($Mode) {
        'check' {
            Reset-Log @('[PV-First] Verificacao do ambiente iniciada.', '[PV-First] Conferindo WSL, Ubuntu, CMake, g++, Git, pkg-config e SimGrid.')
            Set-EnvStatus 'CHECKING|Verificacao em andamento'
            Set-Status 'RUNNING: Verificando ambiente'
            try {
                $distro = Get-RealWslDistro
                $projectWsl = ConvertTo-WslPathManual $Project
                $cmd = "cd " + (BashQuote $projectWsl) + " && " +
                       "if command -v cmake >/dev/null 2>&1 && command -v g++ >/dev/null 2>&1 && command -v pkg-config >/dev/null 2>&1 && command -v git >/dev/null 2>&1 && pkg-config --exists simgrid 2>/dev/null; then echo READY; else echo NEEDS_INSTALL; fi"
                $outFile = Join-Path $Internal 'check_tmp.txt'
                $args = @('-d', $distro, '--', 'bash', '-lc', $cmd)
                $out = & wsl.exe @args 2>&1
                $joined = (($out -join "`n") -replace "`0", '')
                if ($joined -match 'READY') {
                    Set-EnvStatus "READY|$distro"
                    Set-Status 'OK: Ambiente instalado'
                    Reset-Log @('[PV-First] Ambiente instalado e pronto para uso.', '[PV-First] Use Rodar uma vez ou Coleta solar continua.')
                } else {
                    Set-EnvStatus "NEEDS_INSTALL|$distro"
                    Set-Status 'OK: Ambiente a instalar'
                    Reset-Log @('[PV-First] WSL/Ubuntu encontrado.', '[PV-First] Ambiente PV-First ainda precisa ser iniciado/verificado.', '[PV-First] A interface pedira permissao antes de instalar.')
                }
                exit 0
            } catch {
                Set-EnvStatus ('NO_WSL|' + $_.Exception.Message)
                Set-Status 'OK: Ambiente a instalar'
                Reset-Log @('[PV-First] Ubuntu/WSL nao esta pronto para o PV-First.', '[PV-First] Instale o Ubuntu no WSL ou clique em Verificar ambiente se ele ja existir.', '[PV-First] Dica: no PowerShell, use: wsl -l -v')
                exit 0
            }
        }
        'install' {
            Reset-Log @('[PV-First] Instalacao/verificacao iniciada.', '[PV-First] Esta etapa prepara Ubuntu, SimGrid, CMake e o projeto.')
            Set-Status 'RUNNING: Instalando/verificando ambiente'
            $distro = Get-RealWslDistro
            $projectWsl = ConvertTo-WslPathManual $Project
            $cmd = "cd " + (BashQuote $projectWsl) + " && bash ./_launcher/install.sh"
            $code = Invoke-WslCommand $distro $cmd $true
            if ($code -eq 0) {
                Set-EnvStatus "READY|$distro"
                Set-Status 'OK: Ambiente instalado'
                Write-Log '[PV-First] Ambiente pronto.'
            } else {
                Set-EnvStatus "NEEDS_INSTALL|$distro"
                Set-Status 'FAIL: Erro ao instalar/verificar'
                Write-Log "[PV-First] ERRO. Codigo: $code"
                exit $code
            }
        }
        'once' {
            Reset-Log @('[PV-First] Simulacao unica iniciada.', '[PV-First] O calculo real do C++/SimGrid aparecera abaixo.')
            Write-ProxyInfoToLog
            Set-Status 'RUNNING: Rodando simulacao unica'
            $distro = Get-RealWslDistro
            $projectWsl = ConvertTo-WslPathManual $Project
            $cmd = "cd " + (BashQuote $projectWsl) + " && bash ./_launcher/run_once.sh"
            $code = Invoke-WslCommand $distro $cmd $false
            if ($code -eq 0) {
                Set-EnvStatus "READY|$distro"
                Set-Status 'OK: Simulacao unica finalizada'
                Write-Log '[PV-First] Simulacao unica finalizada.'
            } else {
                Set-Status 'FAIL: Erro na simulacao'
                Write-Log "[PV-First] ERRO. Codigo: $code"
                exit $code
            }
        }
        'solar' {
            try { Write-TextDefault $SolarLock ((Get-Date).ToString('s')) } catch {}
            Reset-Log @('[PV-First] Coleta continua 24h em segundo plano iniciada.', '[PV-First] O calculo real sera atualizado a cada execucao.', '[PV-First] Pode fechar/minimizar a interface. A coleta continua enquanto o PC nao suspender.')
            Write-ProxyInfoToLog
            Set-Status 'RUNNING: Coleta solar continua'
            $distro = Get-RealWslDistro
            $projectWsl = ConvertTo-WslPathManual $Project
            $cmd = "cd /tmp && bash " + (BashQuote ($projectWsl + "/_launcher/solar.sh"))
            $code = Invoke-WslCommand $distro $cmd $false
            if ($code -eq 0) {
                Set-EnvStatus "READY|$distro"
                Set-Status 'OK: Coleta em standby/finalizada'
                Write-Log '[PV-First] Coleta solar encerrada ou em standby.'
            } else {
                Set-Status 'FAIL: Erro na coleta solar'
                Write-Log "[PV-First] ERRO. Codigo: $code"
                exit $code
            }
        }
        'dashboard' {
            Reset-Log @('[PV-First] Gerando painel visual local...')
            Set-Status 'RUNNING: Gerando painel visual'
            $distro = Get-RealWslDistro
            $projectWsl = ConvertTo-WslPathManual $Project
            $cmd = "cd " + (BashQuote $projectWsl) + " && python3 dashboard/build_dashboard.py"
            $code = Invoke-WslCommand $distro $cmd $false
            if ($code -eq 0) {
                Set-EnvStatus "READY|$distro"
                Set-Status 'OK: Painel visual gerado'
                Write-Log '[PV-First] Painel visual gerado.'
            } else {
                Set-Status 'FAIL: Erro ao gerar painel'
                Write-Log "[PV-First] ERRO. Codigo: $code"
                exit $code
            }
        }
        'gitstatus' {
            Reset-Log @('[PV-First] Verificando resultados salvos e status Git...')
            Set-Status 'RUNNING: Verificando Git/resultados'
            $distro = Get-RealWslDistro
            $projectWsl = ConvertTo-WslPathManual $Project
            $cmd = "cd " + (BashQuote $projectWsl) + " && bash ./_launcher/git_sync.sh status"
            $code = Invoke-WslCommand $distro $cmd $false
            Set-EnvStatus "READY|$distro"
            Set-Status 'OK: Verificacao Git finalizada'
            Write-Log '[PV-First] Verificacao Git/resultados finalizada.'
        }
        'gitpush' {
            Reset-Log @('[PV-First] Enviando resultados ao Git...')
            Write-ProxyInfoToLog
            Set-Status 'RUNNING: Enviando resultados ao Git'
            $distro = Get-RealWslDistro
            $projectWsl = ConvertTo-WslPathManual $Project
            $cmd = "cd " + (BashQuote $projectWsl) + " && bash ./_launcher/git_sync.sh push"
            $code = Invoke-WslCommand $distro $cmd $false
            Set-EnvStatus "READY|$distro"
            Set-Status 'OK: Rotina Git finalizada'
            Write-Log '[PV-First] Rotina Git finalizada. Se houver falha de login, a coleta continua normalmente.'
        }
        'clean' {
            Reset-Log @('[PV-First] Limpando build e logs...')
            Set-Status 'RUNNING: Limpando'
            $distro = Get-RealWslDistro
            $projectWsl = ConvertTo-WslPathManual $Project
            $cmd = "cd " + (BashQuote $projectWsl) + " && bash ./_launcher/clean.sh"
            $code = Invoke-WslCommand $distro $cmd $false
            if ($code -eq 0) {
                Set-EnvStatus "READY|$distro"
                Set-Status 'OK: Limpeza finalizada'
                Write-Log '[PV-First] Limpeza finalizada.'
            } else {
                Set-Status 'FAIL: Erro na limpeza'
                Write-Log "[PV-First] ERRO. Codigo: $code"
                exit $code
            }
        }
        'stop' {
            try { if (Test-Path $SolarLock) { Remove-Item $SolarLock -Force } } catch {}
            Reset-Log @('[PV-First] Solicitando parada...')
            Set-Status 'RUNNING: Parando'
            $distro = Get-RealWslDistro
            $cmd = "pkill -f run_solar_window.sh 2>/dev/null || true; pkill -f pvfirst 2>/dev/null || true; echo 'Parada enviada.'"
            $code = Invoke-WslCommand $distro $cmd $false
            Set-Status 'OK: Parada solicitada'
            Write-Log '[PV-First] Parada solicitada.'
        }
        default { throw "Modo desconhecido: $Mode" }
    }
} catch {
    Set-Status 'FAIL: Erro. Veja o log'
    Write-Log ('[PV-First] ERRO: ' + $_.Exception.Message)
    exit 1
}
