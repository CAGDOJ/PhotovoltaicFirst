param(
    [string]$Root = '',
    [string]$Repo = 'CAGDOJ/PhotovoltaicFirst',
    [string]$Branch = 'main',
    [int]$IntervalSeconds = 15
)

$ErrorActionPreference = 'Continue'
if ([string]::IsNullOrWhiteSpace($Root)) {
    $ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
    $Root = Split-Path -Parent $ScriptDir
}
$Root = (Resolve-Path -LiteralPath $Root).Path.TrimEnd('\')
try { Set-Location -LiteralPath $env:TEMP } catch {}
$Internal = Join-Path $Root '_interno'
if (!(Test-Path $Internal)) { New-Item -ItemType Directory -Force -Path $Internal | Out-Null }
$Bridge = Join-Path $Root '_launcher\GITHUB_API_BRIDGE.ps1'
$LogFile = Join-Path $Internal 'github_pages_agent.log'
$LastCommandFile = Join-Path $Internal 'last_github_pages_command.txt'
$StatusJson = Join-Path $Root 'docs\status\pvfirst_status.json'
$TokenFile = Join-Path (Join-Path $env:LOCALAPPDATA 'PVFirst') 'github_api_token.dat'
$GlobalStateDir = Join-Path $env:LOCALAPPDATA 'PVFirst'
if (!(Test-Path $GlobalStateDir)) { New-Item -ItemType Directory -Force -Path $GlobalStateDir | Out-Null }
$GlobalPidFile = Join-Path $GlobalStateDir 'agent.pid'
try { [IO.File]::WriteAllText($GlobalPidFile, [string]$PID, [Text.Encoding]::ASCII) } catch {}

function Log([string]$Text) {
    $line = '[' + (Get-Date).ToString('yyyy-MM-dd HH:mm:ss') + '] ' + $Text
    try { Add-Content -LiteralPath $LogFile -Value $line -Encoding UTF8 } catch {}
}

function Read-SafeTail([string]$Path, [int]$Tail = 60) {
    if (!(Test-Path $Path)) { return '' }
    try { return (Get-Content -LiteralPath $Path -Tail $Tail -ErrorAction Stop) -join "`n" } catch { return 'arquivo ocupado' }
}

function Get-CompactSimulationLog {
    $path=Join-Path $Internal 'current.log'
    if(!(Test-Path $path)){return ''}
    $patterns=@('Cidade detectada','Hora local','Perfil selecionado','Irradiancia ajustada','Potencia PV disponivel','Energia total do data center','Energia vinda da PV','Energia vinda da GRID','CO2 emitido pela GRID','MODO DA FONTE','SIMULACAO FINALIZADA','TESTE ENVIADO COM SUCESSO','SEM INTERNET')
    try {
        $all=Get-Content -LiteralPath $path -Tail 220 -ErrorAction Stop
        $out=@()
        foreach($line in $all){foreach($pat in $patterns){if($line -like ('*'+$pat+'*')){$out+=$line;break}}}
        if($out.Count -gt 18){$out=$out|Select-Object -Last 18}
        return ($out -join "`n")
    } catch { return '' }
}

function Get-CompactAgentLog {
    if(!(Test-Path $LogFile)){return ''}
    try {
        $all=Get-Content -LiteralPath $LogFile -Tail 80 -ErrorAction Stop
        $use=$all|Where-Object{$_ -notmatch 'tempo limite|Nao consegui consultar comando|API de comando falhou'}
        return (($use|Select-Object -Last 10) -join "`n")
    } catch { return '' }
}

function Get-StoredToken {
    if (!(Test-Path -LiteralPath $TokenFile)) { return '' }
    try {
        $enc = (Get-Content -LiteralPath $TokenFile -Raw -ErrorAction Stop).Trim()
        if ([string]::IsNullOrWhiteSpace($enc)) { return '' }
        $sec = $enc | ConvertTo-SecureString
        $cred = New-Object System.Management.Automation.PSCredential('pvfirst',$sec)
        return $cred.GetNetworkCredential().Password
    } catch { return '' }
}

function Normalize-ProxyUrl([string]$Raw) {
    if ([string]::IsNullOrWhiteSpace($Raw)) { return '' }
    $v=$Raw.Trim().Trim('"')
    if ($v -match '^(?i)https?://') { return $v }
    if ($v -match '^[A-Za-z0-9._-]+:\d{2,5}$') { return 'http://' + $v }
    if ($v -match '(?i)(?:https?=)?([A-Za-z0-9._-]+):(\d{2,5})') { return 'http://' + $Matches[1] + ':' + $Matches[2] }
    return ''
}

function Get-WindowsProxyForWeb {
    try {
        $reg=Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' -ErrorAction Stop
        if ([int]$reg.ProxyEnable -eq 1 -and $reg.ProxyServer) {
            $raw=''+$reg.ProxyServer; $candidate=$raw
            if ($raw -match '(?i)(?:^|;)https=([^;]+)') { $candidate=$Matches[1] }
            elseif ($raw -match '(?i)(?:^|;)http=([^;]+)') { $candidate=$Matches[1] }
            return Normalize-ProxyUrl $candidate
        }
    } catch {}
    return ''
}

function Invoke-WebJson([string]$Uri, [string]$Token='') {
    $headers=@{'Accept'='application/vnd.github+json';'User-Agent'='PVFirst-PC-Agent';'Cache-Control'='no-cache'}
    if (-not [string]::IsNullOrWhiteSpace($Token)) {
        $headers['Authorization']='Bearer '+$Token
        $headers['X-GitHub-Api-Version']='2022-11-28'
    }
    $params=@{Uri=$Uri;UseBasicParsing=$true;TimeoutSec=20;Headers=$headers;ErrorAction='Stop'}
    $proxy=Get-WindowsProxyForWeb
    if ($proxy) { $params['Proxy']=$proxy; $params['ProxyUseDefaultCredentials']=$true }
    return Invoke-WebRequest @params
}

$script:LastConnectivityWarning = [datetime]::MinValue
function Log-ConnectivityWarning([string]$Text) {
    if(((Get-Date)-$script:LastConnectivityWarning).TotalMinutes -ge 5){Log $Text;$script:LastConnectivityWarning=Get-Date}
}

function Fetch-Command {
    try {
        $url="https://raw.githubusercontent.com/$Repo/$Branch/docs/commands/latest.json?t=$([DateTime]::UtcNow.Ticks)"
        $resp=Invoke-WebJson $url ''
        if (-not [string]::IsNullOrWhiteSpace($resp.Content)) { return $resp.Content | ConvertFrom-Json }
    } catch {}

    # Fallback autenticado. Usado somente se a CDN raw estiver indisponivel.
    $token=Get-StoredToken
    if (-not [string]::IsNullOrWhiteSpace($token)) {
        try {
            $uri="https://api.github.com/repos/$Repo/contents/docs/commands/latest.json?ref=$Branch&_=$([DateTime]::UtcNow.Ticks)"
            $resp=Invoke-WebJson $uri $token
            $obj=$resp.Content | ConvertFrom-Json
            $b64=(''+$obj.content) -replace '\s',''
            $bytes=[Convert]::FromBase64String($b64)
            return ([Text.Encoding]::UTF8.GetString($bytes) | ConvertFrom-Json)
        } catch {}
    }
    Log-ConnectivityWarning 'Controle remoto temporariamente sem conectividade. O simulador local continua normal.'
    return $null
}

function Write-Status([string]$AgentState,[string]$LastAction,[string]$LastResult) {
    $obj=[ordered]@{
        pc=$env:COMPUTERNAME
        agent=$AgentState
        repo=$Repo
        branch=$Branch
        last_action=$LastAction
        last_result=$LastResult
        status=Read-SafeTail (Join-Path $Internal 'status.txt') 5
        env=Read-SafeTail (Join-Path $Internal 'env_status.txt') 5
        log=Get-CompactSimulationLog
        agent_log=Get-CompactAgentLog
        updated_at=(Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    }
    $dir=Split-Path -Parent $StatusJson
    if (!(Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    $json=$obj | ConvertTo-Json -Depth 5
    [IO.File]::WriteAllText($StatusJson,$json,(New-Object Text.UTF8Encoding($false)))
}

function Push-Status-ToApi {
    if (!(Test-Path $Bridge)) { Log 'Bridge GitHub API nao encontrado.'; return $false }
    try {
        & $Bridge -Action put-status -Root $Root -Repo $Repo -Branch $Branch *> $null
        if ($LASTEXITCODE -eq 0) { Log 'Status enviado ao GitHub via API.'; return $true }
        Log ('Falha ao enviar status via API. Codigo '+$LASTEXITCODE)
    } catch { Log ('Falha ao enviar status via API: '+$_.Exception.Message) }
    return $false
}

function Sync-PagesViaApi {
    if (!(Test-Path $Bridge)) { return 'Bridge GitHub API nao encontrado.' }
    try {
        $out=& $Bridge -Action sync -Root $Root -Repo $Repo -Branch $Branch 2>&1
        if ($LASTEXITCODE -eq 0) { return 'Arquivos/resultados sincronizados pelo GitHub API.' }
        return 'Falha na sincronizacao API: '+(($out -join ' ') -replace "`r|`n",' ')
    } catch { return 'Falha na sincronizacao API: '+$_.Exception.Message }
}

function Run-CmdHidden([string]$CmdPath,[bool]$Wait,[int]$TimeoutSeconds=900) {
    if (!(Test-Path $CmdPath)) { return 'Arquivo nao encontrado: '+$CmdPath }
    try {
        $proc=Start-Process -FilePath 'cmd.exe' -ArgumentList @('/c',('"'+$CmdPath+'"')) -WorkingDirectory $env:TEMP -WindowStyle Hidden -PassThru
        if (-not $Wait) { return 'Comando iniciado: '+(Split-Path -Leaf $CmdPath) }
        $ok=$proc.WaitForExit($TimeoutSeconds*1000)
        if (-not $ok) { return 'Comando continua executando apos '+$TimeoutSeconds+' s.' }
        return 'Finalizado: '+(Split-Path -Leaf $CmdPath)+' (codigo '+$proc.ExitCode+')'
    } catch { return 'Erro ao executar '+(Split-Path -Leaf $CmdPath)+': '+$_.Exception.Message }
}

function Run-Action([string]$Action) {
    switch ($Action) {
        'none' { return 'Nenhuma acao.' }
        'verify' { return Run-CmdHidden (Join-Path $Internal 'check.cmd') $true 300 }
        'runonce' {
            return Run-CmdHidden (Join-Path $Internal 'run_once.cmd') $true 1200
        }
        'start' { return Run-CmdHidden (Join-Path $Internal 'solar_background.cmd') $false 0 }
        'pause' { return Run-CmdHidden (Join-Path $Internal 'stop.cmd') $true 120 }
        'stop' { return Run-CmdHidden (Join-Path $Internal 'stop.cmd') $true 120 }
        'dashboard' {
            return Sync-PagesViaApi
        }
        'gitstatus' {
            try {
                & $Bridge -Action test -Root $Root -Repo $Repo -Branch $Branch *> $null
                if ($LASTEXITCODE -eq 0) { return 'GitHub API do PC autenticada e pronta.' }
                return 'GitHub API do PC ainda nao autenticada.'
            } catch { return 'Erro ao verificar GitHub API: '+$_.Exception.Message }
        }
        'gitpush' { return Sync-PagesViaApi }
        'publish' {
            $s=Sync-PagesViaApi
            return 'Publicacao via API solicitada. '+$s
        }
        'lock' { Start-Process rundll32.exe -ArgumentList 'user32.dll,LockWorkStation' | Out-Null; return 'Sessao bloqueada.' }
        default { return 'Acao desconhecida: '+$Action }
    }
}

Log 'Agente V50 iniciado. Comunicacao PC <-> GitHub usa API; SSH nao e necessario para status/comandos.'
Write-Status 'rodando' '' 'Agente V50 iniciado'
Push-Status-ToApi | Out-Null

# Em uma pasta V43 nova, nao repete automaticamente um comando antigo que ja estava
# no GitHub antes do agente iniciar. O usuario pode enviar o proximo comando pelo celular.
if (!(Test-Path $LastCommandFile)) {
    $baseline = Fetch-Command
    if ($null -ne $baseline -and -not [string]::IsNullOrWhiteSpace((''+$baseline.id))) {
        Set-Content -LiteralPath $LastCommandFile -Value (''+$baseline.id) -Encoding ASCII
        Log ('Baseline do comando atual registrado sem reexecutar: '+(''+$baseline.id))
    }
}
$lastHeartbeat=Get-Date

while ($true) {
    if (!(Test-Path -LiteralPath $Root)) { break }
    $cmdObj=Fetch-Command
    if ($null -ne $cmdObj) {
        $cmdId=''+$cmdObj.id; $action=''+$cmdObj.action
        $lastId=''
        if (Test-Path $LastCommandFile) { $lastId=(Get-Content -LiteralPath $LastCommandFile -Raw -ErrorAction SilentlyContinue).Trim() }
        if (-not [string]::IsNullOrWhiteSpace($cmdId) -and $cmdId -ne $lastId) {
            Set-Content -LiteralPath $LastCommandFile -Value $cmdId -Encoding ASCII
            Log "Novo comando recebido: id=$cmdId action=$action"
            Write-Status 'executando' $action 'Comando recebido no PC'
            Push-Status-ToApi | Out-Null
            $result=Run-Action $action
            Log ('Resultado: '+$result)
            Write-Status 'rodando' $action $result
            Push-Status-ToApi | Out-Null
        }
    }
    # Heartbeat remoto a cada 10 min para nao gerar commits/builds a cada poucos segundos.
    if (((Get-Date)-$lastHeartbeat).TotalSeconds -ge 900) {
        Write-Status 'rodando' 'heartbeat' 'Agente ativo aguardando comandos'
        Push-Status-ToApi | Out-Null
        $lastHeartbeat=Get-Date
    }
    Start-Sleep -Seconds $IntervalSeconds
}

try { if (Test-Path $GlobalPidFile) { $v=(Get-Content $GlobalPidFile -Raw -ErrorAction SilentlyContinue).Trim(); if ($v -eq [string]$PID) { Remove-Item $GlobalPidFile -Force -ErrorAction SilentlyContinue } } } catch {}
