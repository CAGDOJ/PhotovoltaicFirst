param(
    [Parameter(Mandatory=$true)]
    [ValidateSet('ensure-token','test','put-status','sync','upload-file')]
    [string]$Action,
    [Parameter(Mandatory=$true)][string]$Root,
    [string]$Repo = 'CAGDOJ/PhotovoltaicFirst',
    [string]$Branch = 'main',
    [string]$LocalPath = '',
    [string]$RepoPath = '',
    [string]$Message = ''
)

$ErrorActionPreference = 'Stop'
$Root = (Resolve-Path -LiteralPath $Root).Path.TrimEnd('\')
$Internal = Join-Path $Root '_interno'
if (!(Test-Path $Internal)) { New-Item -ItemType Directory -Force -Path $Internal | Out-Null }

# O token fica FORA do projeto. Ele e protegido pelo DPAPI do Windows e so pode
# ser descriptografado pelo mesmo usuario do Windows que o salvou.
$TokenDir = Join-Path $env:LOCALAPPDATA 'PVFirst'
$TokenFile = Join-Path $TokenDir 'github_api_token.dat'
if (!(Test-Path $TokenDir)) { New-Item -ItemType Directory -Force -Path $TokenDir | Out-Null }

function SecureToPlain([Security.SecureString]$Secure) {
    if ($null -eq $Secure) { return '' }
    $cred = New-Object System.Management.Automation.PSCredential('pvfirst', $Secure)
    return $cred.GetNetworkCredential().Password
}

function Get-StoredToken {
    if (!(Test-Path -LiteralPath $TokenFile)) { return '' }
    try {
        $enc = (Get-Content -LiteralPath $TokenFile -Raw -ErrorAction Stop).Trim()
        if ([string]::IsNullOrWhiteSpace($enc)) { return '' }
        $sec = $enc | ConvertTo-SecureString
        return SecureToPlain $sec
    } catch {
        return ''
    }
}

function Save-Token([Security.SecureString]$Secure) {
    $enc = $Secure | ConvertFrom-SecureString
    Set-Content -LiteralPath $TokenFile -Value $enc -Encoding ASCII
}

function Normalize-ProxyUrl([string]$Raw) {
    if ([string]::IsNullOrWhiteSpace($Raw)) { return '' }
    $v = $Raw.Trim().Trim('"')
    if ($v -match '^(?i)https?://') { return $v }
    if ($v -match '^[A-Za-z0-9._-]+:\d{2,5}$') { return ('http://' + $v) }
    if ($v -match '(?i)(?:https?=)?([A-Za-z0-9._-]+):(\d{2,5})') {
        return ('http://' + $Matches[1] + ':' + $Matches[2])
    }
    return ''
}

function Get-WindowsProxyForWeb {
    foreach ($scope in @('Process','User','Machine')) {
        foreach ($name in @('HTTPS_PROXY','https_proxy','HTTP_PROXY','http_proxy')) {
            try {
                $raw = [Environment]::GetEnvironmentVariable($name, $scope)
                $url = Normalize-ProxyUrl $raw
                if ($url) { return $url }
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
            if ($url) { return $url }
        }
    } catch {}
    try {
        $txt = (& netsh winhttp show proxy 2>$null | Out-String)
        if ($txt -and $txt -notmatch '(?i)direct access|acesso direto|sem servidor proxy') {
            $m = [regex]::Match($txt, '(?i)(?:https?=)?([A-Za-z0-9._-]+):(\d{2,5})')
            if ($m.Success) { return ('http://' + $m.Groups[1].Value + ':' + $m.Groups[2].Value) }
        }
    } catch {}
    return ''
}

function Get-Headers([string]$Token) {
    return @{
        'Authorization' = 'Bearer ' + $Token
        'Accept' = 'application/vnd.github+json'
        'X-GitHub-Api-Version' = '2022-11-28'
        'User-Agent' = 'PVFirst-PC-Agent'
        'Cache-Control' = 'no-cache'
    }
}

function Invoke-GitHubApi([string]$Method, [string]$Uri, [string]$Token, [string]$Body = '') {
    $params = @{
        Method = $Method
        Uri = $Uri
        Headers = (Get-Headers $Token)
        TimeoutSec = 35
        ErrorAction = 'Stop'
    }
    if (-not [string]::IsNullOrWhiteSpace($Body)) {
        $params['Body'] = $Body
        $params['ContentType'] = 'application/json; charset=utf-8'
    }
    $proxy = Get-WindowsProxyForWeb
    if (-not [string]::IsNullOrWhiteSpace($proxy)) {
        $params['Proxy'] = $proxy
        $params['ProxyUseDefaultCredentials'] = $true
    }
    return Invoke-RestMethod @params
}

function Encode-RepoPath([string]$Path) {
    $parts = @()
    foreach ($p in ($Path -split '/')) {
        $parts += [Uri]::EscapeDataString($p)
    }
    return ($parts -join '/')
}

function Get-RemoteFile([string]$Path, [string]$Token) {
    $encoded = Encode-RepoPath $Path
    $uri = "https://api.github.com/repos/$Repo/contents/${encoded}?ref=$([Uri]::EscapeDataString($Branch))&_=$([DateTime]::UtcNow.Ticks)"
    try {
        return Invoke-GitHubApi 'GET' $uri $Token
    } catch {
        $status = $null
        try { $status = [int]$_.Exception.Response.StatusCode } catch {}
        if ($status -eq 404) { return $null }
        throw
    }
}

function Get-GitBlobSha([byte[]]$Bytes) {
    $prefix = [Text.Encoding]::UTF8.GetBytes(('blob ' + $Bytes.Length + [char]0))
    $all = New-Object byte[] ($prefix.Length + $Bytes.Length)
    [Array]::Copy($prefix, 0, $all, 0, $prefix.Length)
    [Array]::Copy($Bytes, 0, $all, $prefix.Length, $Bytes.Length)
    $sha1 = [Security.Cryptography.SHA1]::Create()
    try {
        $hash = $sha1.ComputeHash($all)
        return (($hash | ForEach-Object { $_.ToString('x2') }) -join '')
    } finally { $sha1.Dispose() }
}

function Put-Bytes([string]$TargetPath, [byte[]]$Bytes, [string]$CommitMessage, [string]$Token) {
    $localSha = Get-GitBlobSha $Bytes
    for ($attempt = 1; $attempt -le 5; $attempt++) {
        $remote = Get-RemoteFile $TargetPath $Token
        if ($null -ne $remote -and ('' + $remote.sha).ToLowerInvariant() -eq $localSha.ToLowerInvariant()) {
            return [pscustomobject]@{ Changed=$false; Path=$TargetPath; Message='sem alteracao' }
        }
        $payload = [ordered]@{
            message = $CommitMessage
            content = [Convert]::ToBase64String($Bytes)
            branch = $Branch
        }
        if ($null -ne $remote -and $remote.sha) { $payload['sha'] = '' + $remote.sha }
        $json = $payload | ConvertTo-Json -Depth 5 -Compress
        $encoded = Encode-RepoPath $TargetPath
        $uri = "https://api.github.com/repos/$Repo/contents/${encoded}"
        try {
            $resp = Invoke-GitHubApi 'PUT' $uri $Token $json
            return [pscustomobject]@{ Changed=$true; Path=$TargetPath; Message='enviado'; Response=$resp }
        } catch {
            $status = $null
            try { $status = [int]$_.Exception.Response.StatusCode } catch {}
            $msg = '' + $_.Exception.Message
            if ($attempt -lt 5 -and (($status -eq 409) -or ($status -eq 422) -or ($msg -match 'does not match|sha'))) {
                Write-Host ("[PV-First API] Conflito de versao em $TargetPath. Atualizando SHA e tentando novamente ($attempt/5)...")
                Start-Sleep -Milliseconds (700 * $attempt)
                continue
            }
            throw
        }
    }
}

function Put-LocalFile([string]$Source, [string]$Target, [string]$CommitMessage, [string]$Token) {
    if (!(Test-Path -LiteralPath $Source)) {
        return [pscustomobject]@{ Changed=$false; Path=$Target; Message='arquivo local nao existe' }
    }
    $bytes = [IO.File]::ReadAllBytes($Source)
    return Put-Bytes $Target $bytes $CommitMessage $Token
}

function Ensure-TokenInteractive {
    $existing = Get-StoredToken
    if (-not [string]::IsNullOrWhiteSpace($existing)) {
        Write-Host '[PV-First] Token GitHub API do PC: configurado e protegido pelo Windows.'
        return $true
    }

    Write-Host ''
    Write-Host '============================================================'
    Write-Host 'PV-First - TOKEN DO AGENTE DO PC (UMA UNICA VEZ)'
    Write-Host '============================================================'
    Write-Host 'Cole o MESMO fine-grained token que funcionou no controle do celular.'
    Write-Host 'Permissao necessaria: PhotovoltaicFirst -> Contents: Read and write.'
    Write-Host 'O token NAO aparecera na tela e sera salvo criptografado pelo Windows.'
    Write-Host 'Arquivo criptografado: %LOCALAPPDATA%\PVFirst\github_api_token.dat'
    Write-Host ''
    $sec = Read-Host -AsSecureString 'Cole o token e pressione ENTER'
    $plain = SecureToPlain $sec
    if ([string]::IsNullOrWhiteSpace($plain)) {
        Write-Host '[PV-First] Nenhum token informado. O agente abrira, mas nao conseguira devolver status ao GitHub.'
        return $false
    }
    if ($plain -notmatch '^(github_pat_|ghp_)') {
        Write-Host '[PV-First] Aviso: o valor nao parece um token GitHub. Nao foi salvo.'
        return $false
    }
    Save-Token $sec
    Write-Host '[PV-First] Token salvo criptografado para este usuario do Windows.'
    return $true
}

function Test-TokenAccess([string]$Token) {
    $uri = "https://api.github.com/repos/$Repo"
    $r = Invoke-GitHubApi 'GET' $uri $Token
    if ($null -ne $r) {
        Write-Host ('[PV-First] GitHub API autenticada: ' + $Repo)
        return $true
    }
    return $false
}

function CsvNumber([object]$Value) {
    $n = 0.0
    $txt = ('' + $Value).Trim().Replace(',','.')
    [double]::TryParse($txt,[Globalization.NumberStyles]::Any,[Globalization.CultureInfo]::InvariantCulture,[ref]$n) | Out-Null
    return $n
}

function Test-CompatibleResultRow($Row) {
    if ($null -eq $Row) { return $false }
    $id = ('' + $Row.simulation_profile_id).Trim()
    $area = CsvNumber $Row.panel_area_m2
    $eff  = CsvNumber $Row.panel_base_efficiency
    $gain = CsvNumber $Row.panel_bifacial_gain_configured
    switch ($id) {
        'datacenter_moderate' { return ([Math]::Abs($area-1200) -lt 0.01 -and [Math]::Abs($eff-0.22) -lt 0.0001 -and [Math]::Abs($gain-1.12) -lt 0.0001) }
        'datacenter_high'     { return ([Math]::Abs($area-2500) -lt 0.01 -and [Math]::Abs($eff-0.23) -lt 0.0001 -and [Math]::Abs($gain-1.15) -lt 0.0001) }
        'hpc_high'            { return ([Math]::Abs($area-12000) -lt 0.01 -and [Math]::Abs($eff-0.24) -lt 0.0001 -and [Math]::Abs($gain-1.18) -lt 0.0001) }
        'hpc_extreme'         { return ([Math]::Abs($area-30000) -lt 0.01 -and [Math]::Abs($eff-0.24) -lt 0.0001 -and [Math]::Abs($gain-1.20) -lt 0.0001) }
    }
    return $false
}

function Decode-RemoteText($Remote) {
    if ($null -eq $Remote -or [string]::IsNullOrWhiteSpace(('' + $Remote.content))) { return '' }
    try {
        $b64 = ('' + $Remote.content) -replace '\s',''
        return [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($b64))
    } catch { return '' }
}

function Read-CsvText([string]$Text) {
    if ([string]::IsNullOrWhiteSpace($Text)) { return @() }
    $lines = $Text -split "`r?`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    if ($lines.Count -lt 2) { return @() }
    try { return @($Text | ConvertFrom-Csv -Delimiter ';') } catch { return @() }
}

function Merge-CentralResults([string]$Token) {
    $resultsDir = Join-Path $Root 'pvfirst\results'
    $localRows = @()
    if (Test-Path -LiteralPath $resultsDir) {
        foreach ($f in (Get-ChildItem -LiteralPath $resultsDir -Filter 'RPVfirst*.csv' -File -ErrorAction SilentlyContinue | Sort-Object Name)) {
            try {
                $text = [IO.File]::ReadAllText($f.FullName,[Text.Encoding]::UTF8)
                foreach ($r in (Read-CsvText $text)) {
                    if (Test-CompatibleResultRow $r) { $localRows += $r }
                }
                # O arquivo diario da V50 tambem fica publico para auditoria.
                if ($localRows.Count -gt 0) {
                    $dailyRows = @((Read-CsvText $text) | Where-Object { Test-CompatibleResultRow $_ })
                    if ($dailyRows.Count -gt 0) {
                        $dailyCsv = ($dailyRows | ConvertTo-Csv -Delimiter ';' -NoTypeInformation) -join "`r`n"
                        $dailyBytes = (New-Object Text.UTF8Encoding($false)).GetBytes($dailyCsv + "`r`n")
                        [void](Put-Bytes ('docs/results/' + $f.Name) $dailyBytes ('PV-First V50: atualiza resultado diario ' + $f.Name) $Token)
                    }
                }
            } catch {}
        }
    }

    $remoteRows = @()
    try {
        $remote = Get-RemoteFile 'docs/results/all.csv' $Token
        $remoteRows = @(Read-CsvText (Decode-RemoteText $remote) | Where-Object { Test-CompatibleResultRow $_ })
    } catch {}

    $byId = @{}
    foreach ($r in @($remoteRows + $localRows)) {
        $id = ('' + $r.run_id).Trim()
        if ([string]::IsNullOrWhiteSpace($id)) { continue }
        if (Test-CompatibleResultRow $r) { $byId[$id] = $r }
    }
    $merged = @($byId.Values | Sort-Object run_datetime,run_id)

    if ($merged.Count -gt 0) {
        $csv = ($merged | ConvertTo-Csv -Delimiter ';' -NoTypeInformation) -join "`r`n"
    } else {
        $csv = 'run_id;run_date;run_time;run_datetime;day_of_year;simulation_profile_id;simulation_profile;collection_start_hour;collection_interval_s;standby_zero_limit_readings;irradiance_min_w_m2;location_mode;host_speed_gflops_configured;host_power_active_w;host_power_idle_w;host_power_off_w;git_auto_push;git_remote;git_branch;git_repo_url;city;latitude;longitude;panel_material;panel_face_type;panel_area_m2;panel_base_efficiency;panel_material_factor;panel_effective_base_efficiency;panel_bifacial_gain_configured;panel_face_gain_applied;cloud_cover_pct;rain_mm;temperature_c;wind_speed_kmh;irradiance_theoretical_w_m2;irradiance_adjusted_w_m2;pv_efficiency;pv_power_kw;grid_carbon_intensity_gco2_kwh;dc_active_servers;dc_pue;dc_network_kw;dc_storage_kw;dc_it_compute_kwh;dc_it_support_kwh;dc_it_total_kwh;dc_facility_overhead_kwh;dc_facility_total_kwh;job_flops;job_duration_s;job_energy_j;job_energy_kwh;job_average_power_kw;energy_total_kwh;energy_pv_kwh;energy_grid_kwh;co2_g;co2_without_pv_g;co2_avoided_by_pv_g;source_mode;photovoltaic_status;grid_status'
    }
    $enc = New-Object Text.UTF8Encoding($false)
    $bytes = $enc.GetBytes($csv + "`r`n")
    [void](Put-Bytes 'docs/results/all.csv' $bytes ('PV-First V50: atualiza base consolidada - ' + (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')) $Token)
    [void](Put-Bytes 'docs/results/latest.csv' $bytes ('PV-First V50: atualiza latest.csv - ' + (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')) $Token)

    $manifest = [ordered]@{
        schema='PVFIRST_RESULTS_V50'
        records=$merged.Count
        repo=$Repo
        branch=$Branch
        canonical='docs/results/all.csv'
        updated_at=(Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
        policy='Somente perfis V50 dimensionados para cobertura PV total quando a irradiancia e suficiente; GRID complementa quando necessario.'
    } | ConvertTo-Json -Depth 5
    [void](Put-Bytes 'docs/results/manifest.json' $enc.GetBytes($manifest) ('PV-First V50: atualiza manifest de resultados') $Token)
    return $merged.Count
}

function Sync-PublishedFiles([string]$Token) {
    $stamp = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    $pairs = @(
        [pscustomobject]@{ Source=(Join-Path $Root 'index.html'); Target='index.html' },
        [pscustomobject]@{ Source=(Join-Path $Root 'controle-mobile-v48.html'); Target='controle-mobile-v48.html' },
        [pscustomobject]@{ Source=(Join-Path $Root 'manifest.webmanifest'); Target='manifest.webmanifest' },
        [pscustomobject]@{ Source=(Join-Path $Root 'sw-v48.js'); Target='sw-v48.js' },
        [pscustomobject]@{ Source=(Join-Path $Root 'pvfirst-icon.svg'); Target='pvfirst-icon.svg' },
        [pscustomobject]@{ Source=(Join-Path $Root 'dashboard.html'); Target='dashboard.html' },
        [pscustomobject]@{ Source=(Join-Path $Root '.nojekyll'); Target='.nojekyll' },
        [pscustomobject]@{ Source=(Join-Path $Root 'docs\index.html'); Target='docs/index.html' },
        [pscustomobject]@{ Source=(Join-Path $Root 'docs\controle-mobile-v48.html'); Target='docs/controle-mobile-v48.html' },
        [pscustomobject]@{ Source=(Join-Path $Root 'docs\dashboard.html'); Target='docs/dashboard.html' }
    )
    foreach ($pair in $pairs) {
        $src = [string]$pair.Source; $dst = [string]$pair.Target
        if (Test-Path -LiteralPath $src) {
            $r = Put-LocalFile $src $dst ("PV-First V50: atualiza $dst - $stamp") $Token
            if ($r.Changed) { Write-Host ("[PV-First API] Enviado: " + $dst) }
        }
    }
    $count = Merge-CentralResults $Token
    Write-Host ("[PV-First API] Base central: docs/results/all.csv | registros validos: " + $count)
}

$token = Get-StoredToken
switch ($Action) {
    'ensure-token' {
        if (Ensure-TokenInteractive) {
            $token = Get-StoredToken
            try { if (Test-TokenAccess $token) { exit 0 } } catch {
                Write-Host ('[PV-First] Token salvo, mas o teste da API falhou: ' + $_.Exception.Message)
                exit 2
            }
        }
        exit 1
    }
    'test' {
        if ([string]::IsNullOrWhiteSpace($token)) { Write-Host '[PV-First] Token do PC ainda nao configurado.'; exit 1 }
        if (Test-TokenAccess $token) { exit 0 }
        exit 2
    }
    'put-status' {
        if ([string]::IsNullOrWhiteSpace($token)) { throw 'Token GitHub API do PC nao configurado.' }
        $statusPath = Join-Path $Root 'docs\status\pvfirst_status.json'
        $r = Put-LocalFile $statusPath 'docs/status/pvfirst_status.json' ('PV-First Agent: atualiza status - ' + (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')) $token
        if ($r.Changed) { Write-Host '[PV-First API] Status enviado ao GitHub.' }
        exit 0
    }
    'sync' {
        if ([string]::IsNullOrWhiteSpace($token)) { throw 'Token GitHub API do PC nao configurado.' }
        Sync-PublishedFiles $token
        exit 0
    }
    'upload-file' {
        if ([string]::IsNullOrWhiteSpace($token)) { throw 'Token GitHub API do PC nao configurado.' }
        if ([string]::IsNullOrWhiteSpace($LocalPath) -or [string]::IsNullOrWhiteSpace($RepoPath)) { throw 'LocalPath e RepoPath sao obrigatorios.' }
        if ([string]::IsNullOrWhiteSpace($Message)) { $Message = 'PV-First API: atualiza ' + $RepoPath }
        $r = Put-LocalFile $LocalPath $RepoPath $Message $token
        if ($r.Changed) { Write-Host ('[PV-First API] Enviado: ' + $RepoPath) }
        exit 0
    }
}
