param([Parameter(Mandatory=$true)][string]$Root)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase

$Root = (Resolve-Path -LiteralPath $Root).Path.TrimEnd('\')
$Internal = Join-Path $Root '_interno'
$Project = Join-Path $Root 'pvfirst'
$ConfigFile = Join-Path $Project 'config\pvfirst.env'
$Bridge = Join-Path $Root '_launcher\GITHUB_API_BRIDGE.ps1'
$AgentScript = Join-Path $Root '_launcher\GITHUB_PAGES_COMMAND_AGENT.ps1'
$TokenDir = Join-Path $env:LOCALAPPDATA 'PVFirst'
$TokenFile = Join-Path $TokenDir 'github_api_token.dat'
$CacheFile = Join-Path $TokenDir 'results_cache.csv'
if (!(Test-Path $TokenDir)) { New-Item -ItemType Directory -Force -Path $TokenDir | Out-Null }

$script:CurrentProcess = $null
$script:CentralRows = @()
$script:DisplayRows = @()
$script:LastRefreshSource = 'GitHub'

function Read-EnvFile {
    $map = @{}
    if (Test-Path $ConfigFile) {
        foreach ($line in Get-Content -LiteralPath $ConfigFile -ErrorAction SilentlyContinue) {
            $t = (''+$line).Trim()
            if ($t -match '^export\s+([A-Za-z0-9_]+)="?(.*?)"?$') { $map[$Matches[1]] = $Matches[2].Trim('"') }
        }
    }
    return $map
}
function EnvV([hashtable]$Map,[string]$Key,[string]$Default='') { if ($Map.ContainsKey($Key)) { return ''+$Map[$Key] }; return $Default }
function Set-EnvValue([string]$Key,[string]$Value) {
    $lines = @(); if (Test-Path $ConfigFile) { $lines = @(Get-Content -LiteralPath $ConfigFile -ErrorAction SilentlyContinue) }
    $ek=[regex]::Escape($Key); $lines = @($lines | Where-Object { $_ -notmatch "^export\s+$ek=" })
    $lines += ('export ' + $Key + '="' + $Value.Replace('"','') + '"')
    [IO.File]::WriteAllLines($ConfigFile,$lines,(New-Object Text.UTF8Encoding($false)))
}
function Get-Profile([string]$Id) {
    switch ($Id) {
        'datacenter_moderate' { return @{Name='Data Center - Moderado';F='5e12';A='1200';E='0.22';G='1.12';S='500';AW='600';IW='250';OW='20';N='64';P='1.50';NW='8';ST='4'} }
        'datacenter_high'     { return @{Name='Data Center - Alta Carga';F='5e13';A='2500';E='0.23';G='1.15';S='1000';AW='750';IW='300';OW='20';N='128';P='1.40';NW='20';ST='10'} }
        'hpc_high'            { return @{Name='HPC - Alta Carga';F='5e14';A='12000';E='0.24';G='1.18';S='3000';AW='1200';IW='450';OW='25';N='512';P='1.30';NW='80';ST='40'} }
        'hpc_extreme'         { return @{Name='HPC - Extremo';F='1e15';A='30000';E='0.24';G='1.20';S='5000';AW='1800';IW='600';OW='30';N='1024';P='1.25';NW='150';ST='75'} }
        default { return Get-Profile 'datacenter_high' }
    }
}
function Apply-Profile([string]$Id) {
    $p=Get-Profile $Id
    $pairs=@{
      PVFIRST_SIMULATION_PROFILE=$Id;PVFIRST_DEFAULT_FLOPS=$p.F;PVFIRST_PANEL_MATERIAL='monocrystalline';PVFIRST_PANEL_FACE_TYPE='bifacial';PVFIRST_PANEL_AREA_M2=$p.A;PVFIRST_PANEL_BASE_EFFICIENCY=$p.E;PVFIRST_BIFACIAL_GAIN=$p.G;PVFIRST_GRID_CARBON_INTENSITY='100';PVFIRST_HOST_SPEED_GFLOPS=$p.S;PVFIRST_HOST_ACTIVE_W=$p.AW;PVFIRST_HOST_IDLE_W=$p.IW;PVFIRST_HOST_OFF_W=$p.OW;PVFIRST_DC_ACTIVE_SERVERS=$p.N;PVFIRST_DC_PUE=$p.P;PVFIRST_DC_NETWORK_KW=$p.NW;PVFIRST_DC_STORAGE_KW=$p.ST;PVFIRST_SOLAR_START_HOUR='6';PVFIRST_SOLAR_INTERVAL_SECONDS='60';PVFIRST_SOLAR_ZERO_LIMIT='5';PVFIRST_IRRADIANCE_MIN_WM2='1'
    }
    foreach($k in $pairs.Keys){Set-EnvValue $k (''+$pairs[$k])}
    Load-ConfigFields
    $txtProfileNote.Text='Perfil aplicado. O arranjo foi dimensionado para atingir 100% de cobertura PV quando a irradiância disponível for suficiente. Se faltar energia fotovoltaica, a GRID complementa somente a parcela restante.'
}

function SecureToPlain([Security.SecureString]$Secure){ if($null -eq $Secure){return ''};$cred=New-Object Management.Automation.PSCredential('pvfirst',$Secure);return $cred.GetNetworkCredential().Password }
function Get-StoredToken { if(!(Test-Path $TokenFile)){return ''};try{$enc=(Get-Content $TokenFile -Raw).Trim();if(!$enc){return ''};$sec=$enc|ConvertTo-SecureString;return SecureToPlain $sec}catch{return ''} }
function Save-TokenPlain([string]$Plain){ if([string]::IsNullOrWhiteSpace($Plain)){return};$sec=ConvertTo-SecureString $Plain -AsPlainText -Force;$enc=$sec|ConvertFrom-SecureString;Set-Content -LiteralPath $TokenFile -Value $enc -Encoding ASCII }
function Normalize-ProxyUrl([string]$Raw){if([string]::IsNullOrWhiteSpace($Raw)){return ''};$v=$Raw.Trim().Trim('"');if($v -match '^(?i)https?://'){return $v};if($v -match '^[A-Za-z0-9._-]+:\d{2,5}$'){return 'http://'+$v};if($v -match '(?i)(?:https?=)?([A-Za-z0-9._-]+):(\d{2,5})'){return 'http://'+$Matches[1]+':'+$Matches[2]};return ''}
function Get-WindowsProxyForWeb { try{$reg=Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' -ErrorAction Stop;if([int]$reg.ProxyEnable -eq 1 -and $reg.ProxyServer){$raw=''+$reg.ProxyServer;$candidate=$raw;if($raw -match '(?i)(?:^|;)https=([^;]+)'){$candidate=$Matches[1]}elseif($raw -match '(?i)(?:^|;)http=([^;]+)'){$candidate=$Matches[1]};return Normalize-ProxyUrl $candidate}}catch{};return '' }
function Invoke-PvWeb([string]$Uri,[hashtable]$Headers=@{}){ $p=@{Uri=$Uri;UseBasicParsing=$true;TimeoutSec=25;Headers=$Headers;ErrorAction='Stop'};$proxy=Get-WindowsProxyForWeb;if($proxy){$p.Proxy=$proxy;$p.ProxyUseDefaultCredentials=$true};return Invoke-WebRequest @p }

function Get-ApiSettings {
    $e=Read-EnvFile
    return [pscustomobject]@{Repo=(EnvV $e 'PVFIRST_GITHUB_REPO' 'CAGDOJ/PhotovoltaicFirst');Branch=(EnvV $e 'PVFIRST_GITHUB_BRANCH' 'main');ResultsPath=(EnvV $e 'PVFIRST_RESULTS_PATH' 'docs/results');AutoSync=((EnvV $e 'PVFIRST_API_AUTO_SYNC' '1') -ne '0')}
}
function Get-RawResultsUrl { $s=Get-ApiSettings;return ('https://raw.githubusercontent.com/'+$s.Repo+'/'+$s.Branch+'/'+$s.ResultsPath+'/all.csv') }
function Load-CentralResults {
    $rows=@();$source='GitHub'
    try {
        $url=(Get-RawResultsUrl)+'?v='+[DateTime]::UtcNow.Ticks
        $resp=Invoke-PvWeb $url @{'Cache-Control'='no-cache';'User-Agent'='PVFirst-Desktop-V50.5'}
        $text=''+$resp.Content
        if($text.Trim()){[IO.File]::WriteAllText($CacheFile,$text,(New-Object Text.UTF8Encoding($false)));$rows=@($text|ConvertFrom-Csv -Delimiter ';')}
    } catch {
        if(Test-Path $CacheFile){try{$text=[IO.File]::ReadAllText($CacheFile,[Text.Encoding]::UTF8);$rows=@($text|ConvertFrom-Csv -Delimiter ';');$source='Cache local'}catch{}}
    }
    $rows=@($rows|Where-Object { -not [string]::IsNullOrWhiteSpace((''+$_.run_id)) } | Sort-Object run_datetime,run_id)
    $script:CentralRows=$rows;$script:LastRefreshSource=$source
    Fill-ResultProfileFilter
    Apply-ResultFilter
    Update-CardsFromRows $rows
    $txtCentralStatus.Text=('Fonte: '+$source+' • '+$rows.Count+' registro(s) • '+(Get-Date).ToString('HH:mm:ss'))
}
function D([object]$v){$n=0.0;[double]::TryParse((''+$v).Replace(',','.'),[Globalization.NumberStyles]::Any,[Globalization.CultureInfo]::InvariantCulture,[ref]$n)|Out-Null;return $n}
function F([object]$v,[int]$digits=3){return (D $v).ToString('N'+$digits,[Globalization.CultureInfo]::GetCultureInfo('pt-BR'))}
function Coverage($r){$t=D $r.energy_total_kwh;$p=D $r.energy_pv_kwh;if($t -le 0){return 0};return 100*$p/$t}
function Update-CardsFromRows($Rows){
    if(!$Rows -or $Rows.Count -eq 0){$txtPvPower.Text='-- kW';$txtPvEnergy.Text='-- kWh';$txtGridEnergy.Text='-- kWh';$txtCo2.Text='-- gCO₂';$txtCoverage.Text='-- %';$txtTotalEnergy.Text='-- kWh';$txtIrr.Text='-- W/m²';$txtMode.Text='SEM DADOS';$txtLastRun.Text='Nenhum registro na base central do GitHub.';$txtWeather.Text='';$txtPvState.Text='SEM DADOS';return}
    $r=$Rows[-1];$cov=Coverage $r
    $txtPvPower.Text=(F $r.pv_power_kw 2)+' kW';$txtPvEnergy.Text=(F $r.energy_pv_kwh 3)+' kWh';$txtGridEnergy.Text=(F $r.energy_grid_kwh 3)+' kWh';$txtCo2.Text=(F $r.co2_g 2)+' gCO₂';$txtCoverage.Text=(F $cov 1)+' %';$txtTotalEnergy.Text=(F $r.energy_total_kwh 3)+' kWh';$txtIrr.Text=(F $r.irradiance_adjusted_w_m2 1)+' W/m²';$txtMode.Text=''+$r.source_mode
    $txtLastRun.Text=('Última execução central: '+$r.run_datetime+' | '+$r.city+' | '+$r.simulation_profile)
    $txtWeather.Text=('Nuvens '+(F $r.cloud_cover_pct 0)+'% • Chuva '+(F $r.rain_mm 1)+' mm • Temperatura '+(F $r.temperature_c 1)+' °C • Vento '+(F $r.wind_speed_kmh 1)+' km/h')
    if($cov -ge 99.95){$txtPvState.Text='100% DA CARGA ATENDIDA POR PV';$txtPvState.Foreground=[System.Windows.Media.Brushes]::LimeGreen}elseif((D $r.energy_pv_kwh)-gt 0){$txtPvState.Text='PV ATIVA • GRID COMPLEMENTANDO';$txtPvState.Foreground=[System.Windows.Media.Brushes]::DarkOrange}else{$txtPvState.Text='PV SEM GERAÇÃO';$txtPvState.Foreground=[System.Windows.Media.Brushes]::IndianRed}
}
function Fill-ResultProfileFilter {
    $current=''+$cmbResultProfile.SelectedValue
    $cmbResultProfile.Items.Clear();[void]$cmbResultProfile.Items.Add('Todos')
    foreach($p in @($script:CentralRows|ForEach-Object{$_.simulation_profile}|Where-Object{$_}|Sort-Object -Unique)){[void]$cmbResultProfile.Items.Add($p)}
    if($current -and $cmbResultProfile.Items.Contains($current)){$cmbResultProfile.SelectedItem=$current}else{$cmbResultProfile.SelectedIndex=0}
}
function Apply-ResultFilter {
    $rows=@($script:CentralRows);$pf=''+$cmbResultProfile.SelectedItem;$src=$(if($cmbResultSource.SelectedItem -is [System.Windows.Controls.ComboBoxItem]){''+$cmbResultSource.SelectedItem.Content}else{''+$cmbResultSource.SelectedItem});$cov=$(if($cmbResultCoverage.SelectedItem -is [System.Windows.Controls.ComboBoxItem]){''+$cmbResultCoverage.SelectedItem.Content}else{''+$cmbResultCoverage.SelectedItem});$date=$null;if($dpResultDate.SelectedDate){$date=$dpResultDate.SelectedDate.Value.ToString('yyyy-MM-dd')}
    $rows=@($rows|Where-Object{if($pf -and $pf -ne 'Todos' -and $_.simulation_profile -ne $pf){return $false};if($src -and $src -ne 'Todas' -and $_.source_mode -ne $src){return $false};if($date -and $_.run_date -ne $date){return $false};$c=Coverage $_;if($cov -eq '100% PV' -and $c -lt 99.95){return $false};if($cov -eq 'PV + GRID' -and -not($c -gt 0 -and $c -lt 99.95)){return $false};if($cov -eq 'Somente GRID' -and $c -gt 0.01){return $false};return $true})
    $script:DisplayRows=$rows
    $view=@();foreach($r in ($rows|Sort-Object run_datetime -Descending)){ $view += [pscustomobject]@{DataHora=$r.run_datetime;Perfil=$r.simulation_profile;Cidade=$r.city;Irradiancia_Wm2=[math]::Round((D $r.irradiance_adjusted_w_m2),1);PV_kW=[math]::Round((D $r.pv_power_kw),2);Total_kWh=[math]::Round((D $r.energy_total_kwh),4);PV_kWh=[math]::Round((D $r.energy_pv_kwh),4);GRID_kWh=[math]::Round((D $r.energy_grid_kwh),4);Cobertura_PV_pct=[math]::Round((Coverage $r),1);CO2_g=[math]::Round((D $r.co2_g),2);Fonte=$r.source_mode;Area_m2=[math]::Round((D $r.panel_area_m2),0);Eficiencia=$r.panel_base_efficiency;Ganho_bifacial=$r.panel_bifacial_gain_configured;Servidores=$r.dc_active_servers;PUE=$r.dc_pue} }
    $gridResults.ItemsSource=$view
    $txtResultCount.Text=($rows.Count.ToString()+' registro(s) filtrado(s)')
}

function Test-IsPvFirstAgentProcess([int]$ProcessId) {
    if($ProcessId -le 0 -or $ProcessId -eq $PID){ return $false }
    try {
        $proc = Get-CimInstance Win32_Process -Filter ("ProcessId="+$ProcessId) -ErrorAction Stop
        if($null -eq $proc -or [string]::IsNullOrWhiteSpace((''+$proc.CommandLine))){ return $false }
        return ((''+$proc.CommandLine) -match 'GITHUB_PAGES_COMMAND_AGENT\.ps1')
    } catch { return $false }
}
function Get-PvFirstAgentProcesses {
    try {
        return @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
            $_.ProcessId -ne $PID -and
            $_.CommandLine -and
            $_.CommandLine -match 'GITHUB_PAGES_COMMAND_AGENT\.ps1'
        })
    } catch { return @() }
}
function Test-AgentForCurrentRoot($Proc) {
    if($null -eq $Proc -or [string]::IsNullOrWhiteSpace((''+$Proc.CommandLine))){ return $false }
    $cmd=''+$Proc.CommandLine
    # O agente e iniciado com -Root <pasta>. Compara o caminho atual sem depender do PID.
    return ($cmd.IndexOf($Root,[StringComparison]::OrdinalIgnoreCase) -ge 0)
}
function Ensure-Agent {
    if(!(Test-Path $AgentScript)){return $false}
    $agents=@(Get-PvFirstAgentProcesses)
    $current=@($agents | Where-Object { Test-AgentForCurrentRoot $_ })
    $oldRoots=@($agents | Where-Object { -not (Test-AgentForCurrentRoot $_) })

    # Encerra SOMENTE agentes verificados de outras versoes/pastas.
    foreach($proc in $oldRoots){
        try { Stop-Process -Id $proc.ProcessId -Force -ErrorAction SilentlyContinue } catch {}
    }

    # Se ja existe um agente desta mesma versao, preserva o primeiro e remove duplicados.
    if($current.Count -gt 0){
        $keep=$current[0]
        if($current.Count -gt 1){
            foreach($proc in $current | Select-Object -Skip 1){
                try { Stop-Process -Id $proc.ProcessId -Force -ErrorAction SilentlyContinue } catch {}
            }
        }
        try { [IO.File]::WriteAllText((Join-Path $TokenDir 'agent.pid'),[string]$keep.ProcessId,[Text.Encoding]::ASCII) } catch {}
        return $true
    }

    $s=Get-ApiSettings
    $p=Start-Process powershell.exe -ArgumentList @('-NoLogo','-NoProfile','-ExecutionPolicy','Bypass','-File',$AgentScript,'-Root',$Root,'-Repo',$s.Repo,'-Branch',$s.Branch,'-IntervalSeconds','20') -WorkingDirectory $env:TEMP -WindowStyle Hidden -PassThru
    if($p){
        try { [IO.File]::WriteAllText((Join-Path $TokenDir 'agent.pid'),[string]$p.Id,[Text.Encoding]::ASCII) } catch {}
        return $true
    }
    return $false
}
function Start-Agent { return Ensure-Agent }
function Start-InternalCommand([string]$Name,[bool]$Track=$true){$path=Join-Path $Internal $Name;if(!(Test-Path $path)){[System.Windows.MessageBox]::Show("Arquivo não encontrado:`n$path",'PV-First')|Out-Null;return $null};$psi=New-Object System.Diagnostics.ProcessStartInfo;$psi.FileName='cmd.exe';$psi.Arguments='/c "'+$path+'"';$psi.WorkingDirectory=$env:TEMP;$psi.UseShellExecute=$false;$psi.CreateNoWindow=$true;$p=New-Object System.Diagnostics.Process;$p.StartInfo=$psi;[void]$p.Start();if($Track){$script:CurrentProcess=$p};return $p}
function Sync-Now { if(!(Test-Path $Bridge)){return $false};$s=Get-ApiSettings;try{& $Bridge -Action sync -Root $Root -Repo $s.Repo -Branch $s.Branch *> $null;if($LASTEXITCODE -eq 0){$txtApiState.Text='API ONLINE • sincronização concluída';$txtApiState.Foreground=[System.Windows.Media.Brushes]::LimeGreen;return $true}}catch{$txtApiState.Text='Falha API: '+$_.Exception.Message};return $false }
function Test-Api {
    $s=Get-ApiSettings;$token=Get-StoredToken;if(!$token){$txtApiState.Text='Token do PC não configurado.';return}
    try{$h=@{Authorization='Bearer '+$token;Accept='application/vnd.github+json';'User-Agent'='PVFirst-Desktop-V50.5'};$resp=Invoke-PvWeb ('https://api.github.com/repos/'+$s.Repo) $h;$txtApiState.Text=('API ONLINE • '+$s.Repo+' • HTTP '+$resp.StatusCode);$txtApiState.Foreground=[System.Windows.Media.Brushes]::LimeGreen}catch{$txtApiState.Text='API OFFLINE/ERRO • '+$_.Exception.Message;$txtApiState.Foreground=[System.Windows.Media.Brushes]::IndianRed}
}
function Save-ApiConfig {
    $repo=(''+$txtApiRepo.Text).Trim();$branch=(''+$txtApiBranch.Text).Trim();if(!$repo){$repo='CAGDOJ/PhotovoltaicFirst'};if(!$branch){$branch='main'}
    Set-EnvValue 'PVFIRST_GITHUB_REPO' $repo;Set-EnvValue 'PVFIRST_GITHUB_BRANCH' $branch;Set-EnvValue 'PVFIRST_RESULTS_PATH' 'docs/results';Set-EnvValue 'PVFIRST_API_AUTO_SYNC' ($(if($chkAutoSync.IsChecked){'1'}else{'0'}))
    $plain=$pwdApiToken.Password.Trim();if($plain){Save-TokenPlain $plain;$pwdApiToken.Clear()}
    $txtApiState.Text='Configuração GitHub/API salva. Testando...';Test-Api
}
function Load-ApiFields {$s=Get-ApiSettings;$txtApiRepo.Text=$s.Repo;$txtApiBranch.Text=$s.Branch;$txtApiPath.Text=$s.ResultsPath;$chkAutoSync.IsChecked=$s.AutoSync;$txtTokenInfo.Text=$(if(Get-StoredToken){'Token criptografado no Windows: CONFIGURADO'}else{'Token do PC: NÃO CONFIGURADO'})}

function Load-ConfigFields {
    $e=Read-EnvFile;function V([string]$k,[string]$d=''){return EnvV $e $k $d}
    $txtFlops.Text=V 'PVFIRST_DEFAULT_FLOPS' '5e13';$txtStartHour.Text=V 'PVFIRST_SOLAR_START_HOUR' '6';$txtInterval.Text=V 'PVFIRST_SOLAR_INTERVAL_SECONDS' '60';$txtMinIrr.Text=V 'PVFIRST_IRRADIANCE_MIN_WM2' '1';$txtCity.Text=V 'PVFIRST_LOCATION_CITY' 'Belem';$txtLat.Text=V 'PVFIRST_LOCATION_LATITUDE' '-1.4537';$txtLon.Text=V 'PVFIRST_LOCATION_LONGITUDE' '-48.5078';$txtGridCI.Text=V 'PVFIRST_GRID_CARBON_INTENSITY' '100';$txtMaterial.Text=V 'PVFIRST_PANEL_MATERIAL' 'monocrystalline';$txtFace.Text=V 'PVFIRST_PANEL_FACE_TYPE' 'bifacial';$txtArea.Text=V 'PVFIRST_PANEL_AREA_M2' '2500';$txtEff.Text=V 'PVFIRST_PANEL_BASE_EFFICIENCY' '0.23';$txtGain.Text=V 'PVFIRST_BIFACIAL_GAIN' '1.15';$txtHostSpeed.Text=V 'PVFIRST_HOST_SPEED_GFLOPS' '1000';$txtHostActive.Text=V 'PVFIRST_HOST_ACTIVE_W' '750';$txtHostIdle.Text=V 'PVFIRST_HOST_IDLE_W' '300';$txtServers.Text=V 'PVFIRST_DC_ACTIVE_SERVERS' '128';$txtPue.Text=V 'PVFIRST_DC_PUE' '1.40';$txtNetwork.Text=V 'PVFIRST_DC_NETWORK_KW' '20';$txtStorage.Text=V 'PVFIRST_DC_STORAGE_KW' '10'
    $profileId=V 'PVFIRST_SIMULATION_PROFILE' 'datacenter_high';for($i=0;$i -lt $cmbProfile.Items.Count;$i++){if((''+$cmbProfile.Items[$i].Tag)-eq $profileId){$cmbProfile.SelectedIndex=$i;break}}
}
function Save-AdvancedConfig {
    $pairs=@{PVFIRST_DEFAULT_FLOPS=$txtFlops.Text;PVFIRST_SOLAR_START_HOUR=$txtStartHour.Text;PVFIRST_SOLAR_INTERVAL_SECONDS=$txtInterval.Text;PVFIRST_IRRADIANCE_MIN_WM2=$txtMinIrr.Text;PVFIRST_LOCATION_MODE='manual';PVFIRST_LOCATION_CITY=$txtCity.Text;PVFIRST_LOCATION_LATITUDE=$txtLat.Text;PVFIRST_LOCATION_LONGITUDE=$txtLon.Text;PVFIRST_GRID_CARBON_INTENSITY=$txtGridCI.Text;PVFIRST_PANEL_MATERIAL=$txtMaterial.Text;PVFIRST_PANEL_FACE_TYPE=$txtFace.Text;PVFIRST_PANEL_AREA_M2=$txtArea.Text;PVFIRST_PANEL_BASE_EFFICIENCY=$txtEff.Text;PVFIRST_BIFACIAL_GAIN=$txtGain.Text;PVFIRST_HOST_SPEED_GFLOPS=$txtHostSpeed.Text;PVFIRST_HOST_ACTIVE_W=$txtHostActive.Text;PVFIRST_HOST_IDLE_W=$txtHostIdle.Text;PVFIRST_DC_ACTIVE_SERVERS=$txtServers.Text;PVFIRST_DC_PUE=$txtPue.Text;PVFIRST_DC_NETWORK_KW=$txtNetwork.Text;PVFIRST_DC_STORAGE_KW=$txtStorage.Text}
    foreach($k in $pairs.Keys){Set-EnvValue $k (''+$pairs[$k]).Trim()};$txtProfileNote.Text='Configuração avançada salva.'
}

[xml]$xaml=@'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml" Title="PV-First | Simulador Fotovoltaico HPC" Width="1260" Height="820" MinWidth="1100" MinHeight="700" WindowStartupLocation="CenterScreen" Background="#F2F6FA" FontFamily="Segoe UI">
<Window.Resources>
<Style TargetType="Button"><Setter Property="Padding" Value="14,9"/><Setter Property="Margin" Value="4"/><Setter Property="FontWeight" Value="SemiBold"/><Setter Property="Cursor" Value="Hand"/></Style>
<Style x:Key="Card" TargetType="Border"><Setter Property="Background" Value="White"/><Setter Property="CornerRadius" Value="14"/><Setter Property="BorderBrush" Value="#D8E3EE"/><Setter Property="BorderThickness" Value="1"/><Setter Property="Padding" Value="16"/><Setter Property="Margin" Value="6"/></Style>
<Style TargetType="TextBox"><Setter Property="Padding" Value="8"/><Setter Property="Margin" Value="4"/><Setter Property="BorderBrush" Value="#C8D5E1"/></Style>
</Window.Resources>
<Grid><Grid.RowDefinitions><RowDefinition Height="88"/><RowDefinition Height="*"/><RowDefinition Height="34"/></Grid.RowDefinitions>
<Border Grid.Row="0" Background="#083866"><Grid Margin="22,12"><Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions><StackPanel><TextBlock Text="PV-FIRST" Foreground="White" FontSize="26" FontWeight="Bold"/><TextBlock Text="Integração de energia fotovoltaica em HPC / Data Center • C++ + SimGrid" Foreground="#D7E8F7" FontSize="13"/></StackPanel><StackPanel Grid.Column="1" Orientation="Horizontal" VerticalAlignment="Center"><TextBlock Text="Perfil:" Foreground="White" VerticalAlignment="Center" Margin="0,0,8,0"/><ComboBox x:Name="cmbProfile" Width="235" Height="34" SelectedIndex="1"><ComboBoxItem Tag="datacenter_moderate">Data Center - Moderado</ComboBoxItem><ComboBoxItem Tag="datacenter_high">Data Center - Alta Carga</ComboBoxItem><ComboBoxItem Tag="hpc_high">HPC - Alta Carga</ComboBoxItem><ComboBoxItem Tag="hpc_extreme">HPC - Extremo</ComboBoxItem></ComboBox><Button x:Name="btnApplyProfile" Content="APLICAR PERFIL" Background="#EAF4FF" Foreground="#083866" Margin="10,0,0,0"/></StackPanel></Grid></Border>
<TabControl Grid.Row="1" Margin="12" Background="Transparent" BorderThickness="0">
<TabItem Header="Operação e resultados"><ScrollViewer VerticalScrollBarVisibility="Auto"><StackPanel>
<Border Style="{StaticResource Card}"><Grid><Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions><StackPanel><TextBlock Text="CONTROLE LOCAL" Foreground="#597084" FontWeight="Bold" FontSize="12"/><WrapPanel Margin="-4,6,0,0"><Button x:Name="btnRun" Content="▶  RODAR TESTE AGORA" Background="#0E67AD" Foreground="White"/><Button x:Name="btnStart" Content="●  INICIAR COLETA" Background="#16834F" Foreground="White"/><Button x:Name="btnStop" Content="■  PARAR COLETA" Background="#BB2C2C" Foreground="White"/><Button x:Name="btnRefresh" Content="↻  ATUALIZAR GITHUB" Background="#E9F0F6" Foreground="#17324D"/></WrapPanel></StackPanel><StackPanel Grid.Column="1" HorizontalAlignment="Right" VerticalAlignment="Center"><TextBlock x:Name="txtRunState" Text="PRONTO" FontSize="18" FontWeight="Bold" Foreground="LimeGreen" HorizontalAlignment="Right"/><TextBlock x:Name="txtStatus" Text="Aguardando execução" Foreground="#65788B" Width="310" TextAlignment="Right" TextWrapping="Wrap"/><TextBlock x:Name="txtCentralStatus" Text="Fonte central: aguardando GitHub" Foreground="#65788B" FontSize="11" HorizontalAlignment="Right"/></StackPanel></Grid></Border>
<Grid><Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="*"/><ColumnDefinition Width="*"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
<Border Grid.Column="0" Style="{StaticResource Card}"><StackPanel><TextBlock Text="PHOTOVOLTAIC" Foreground="#17834F" FontWeight="Bold"/><TextBlock x:Name="txtPvPower" Text="-- kW" FontSize="27" FontWeight="Bold" Margin="0,8,0,0"/><TextBlock Text="Potência disponível" Foreground="#75889A"/><TextBlock x:Name="txtPvEnergy" Text="-- kWh" FontSize="19" FontWeight="SemiBold" Margin="0,10,0,0"/><TextBlock Text="Energia PV usada" Foreground="#75889A"/><TextBlock x:Name="txtPvState" Text="SEM DADOS" FontSize="12" FontWeight="Bold" Margin="0,12,0,0"/></StackPanel></Border>
<Border Grid.Column="1" Style="{StaticResource Card}"><StackPanel><TextBlock Text="GRID" Foreground="#9B2E2E" FontWeight="Bold"/><TextBlock x:Name="txtGridEnergy" Text="-- kWh" FontSize="27" FontWeight="Bold" Margin="0,8,0,0"/><TextBlock Text="Energia da rede" Foreground="#75889A"/><TextBlock x:Name="txtCo2" Text="-- gCO₂" FontSize="19" FontWeight="SemiBold" Margin="0,10,0,0"/><TextBlock Text="Emissão da GRID" Foreground="#75889A"/></StackPanel></Border>
<Border Grid.Column="2" Style="{StaticResource Card}"><StackPanel><TextBlock Text="DATA CENTER / HPC" Foreground="#0E67AD" FontWeight="Bold"/><TextBlock x:Name="txtTotalEnergy" Text="-- kWh" FontSize="27" FontWeight="Bold" Margin="0,8,0,0"/><TextBlock Text="Energia total" Foreground="#75889A"/><TextBlock x:Name="txtCoverage" Text="-- %" FontSize="19" FontWeight="SemiBold" Margin="0,10,0,0"/><TextBlock Text="Cobertura fotovoltaica" Foreground="#75889A"/></StackPanel></Border>
<Border Grid.Column="3" Style="{StaticResource Card}"><StackPanel><TextBlock Text="CLIMA / MODELO" Foreground="#6C4CA5" FontWeight="Bold"/><TextBlock x:Name="txtIrr" Text="-- W/m²" FontSize="27" FontWeight="Bold" Margin="0,8,0,0"/><TextBlock Text="Irradiância ajustada" Foreground="#75889A"/><TextBlock x:Name="txtMode" Text="SEM DADOS" FontSize="15" FontWeight="SemiBold" Margin="0,10,0,0" TextWrapping="Wrap"/><TextBlock Text="Fonte atendendo a carga" Foreground="#75889A"/></StackPanel></Border></Grid>
<Border Style="{StaticResource Card}"><StackPanel><TextBlock Text="ÚLTIMA EXECUÇÃO DA BASE CENTRAL" Foreground="#597084" FontWeight="Bold" FontSize="12"/><TextBlock x:Name="txtLastRun" Text="Nenhum registro central ainda." Margin="0,8,0,0" FontSize="14" TextWrapping="Wrap"/><TextBlock x:Name="txtWeather" Text="" Foreground="#65788B" Margin="0,5,0,0"/><TextBlock x:Name="txtProfileNote" Text="Somente registros dos perfis V50 dimensionados para cobertura PV total quando houver irradiância suficiente entram na base central. A GRID complementa quando necessário." Foreground="#65788B" Margin="0,8,0,0" TextWrapping="Wrap"/></StackPanel></Border>
<Border Style="{StaticResource Card}"><WrapPanel><Button x:Name="btnDashboard" Content="ABRIR DASHBOARD WEB" Background="#E9F0F6" Foreground="#17324D"/><Button x:Name="btnMobile" Content="CONTROLE NO CELULAR" Background="#E9F0F6" Foreground="#17324D"/><Button x:Name="btnResults" Content="RESULTS NO GITHUB" Background="#E9F0F6" Foreground="#17324D"/><Button x:Name="btnSync" Content="SINCRONIZAR AGORA" Background="#0E67AD" Foreground="White"/></WrapPanel></Border>
</StackPanel></ScrollViewer></TabItem>

<TabItem Header="Resultados"><Grid Margin="8"><Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="*"/></Grid.RowDefinitions><Border Style="{StaticResource Card}"><WrapPanel><StackPanel Margin="4"><TextBlock Text="Perfil"/><ComboBox x:Name="cmbResultProfile" Width="220"/></StackPanel><StackPanel Margin="4"><TextBlock Text="Fonte"/><ComboBox x:Name="cmbResultSource" Width="170"><ComboBoxItem IsSelected="True">Todas</ComboBoxItem><ComboBoxItem>PHOTOVOLTAIC</ComboBoxItem><ComboBoxItem>PHOTOVOLTAIC+GRID</ComboBoxItem><ComboBoxItem>GRID</ComboBoxItem></ComboBox></StackPanel><StackPanel Margin="4"><TextBlock Text="Cobertura PV"/><ComboBox x:Name="cmbResultCoverage" Width="160"><ComboBoxItem IsSelected="True">Todas</ComboBoxItem><ComboBoxItem>100% PV</ComboBoxItem><ComboBoxItem>PV + GRID</ComboBoxItem><ComboBoxItem>Somente GRID</ComboBoxItem></ComboBox></StackPanel><StackPanel Margin="4"><TextBlock Text="Data"/><DatePicker x:Name="dpResultDate" Width="150"/></StackPanel><Button x:Name="btnApplyResultFilter" Content="FILTRAR" Background="#0E67AD" Foreground="White" VerticalAlignment="Bottom"/><Button x:Name="btnClearResultFilter" Content="LIMPAR" VerticalAlignment="Bottom"/><Button x:Name="btnDownloadCsv" Content="ABRIR CSV CENTRAL" VerticalAlignment="Bottom"/></WrapPanel></Border><TextBlock x:Name="txtResultCount" Grid.Row="1" Margin="12,0,0,6" Foreground="#65788B"/><DataGrid x:Name="gridResults" Grid.Row="2" Margin="6" IsReadOnly="True" AutoGenerateColumns="True" CanUserAddRows="False" HeadersVisibility="Column" AlternatingRowBackground="#F6FAFD"/></Grid></TabItem>

<TabItem Header="Parâmetros"><ScrollViewer VerticalScrollBarVisibility="Auto"><StackPanel Margin="8"><Border Style="{StaticResource Card}"><StackPanel><TextBlock Text="CONFIGURAÇÃO DO EXPERIMENTO" FontWeight="Bold" Foreground="#083866" FontSize="16" Margin="0,0,0,12"/><Grid><Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="*"/><ColumnDefinition Width="*"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions><Grid.RowDefinitions><RowDefinition/><RowDefinition/><RowDefinition/><RowDefinition/><RowDefinition/></Grid.RowDefinitions>
<StackPanel Grid.Row="0" Grid.Column="0"><TextBlock Text="Job FLOPs"/><TextBox x:Name="txtFlops"/></StackPanel><StackPanel Grid.Row="0" Grid.Column="1"><TextBlock Text="Início coleta (hora)"/><TextBox x:Name="txtStartHour"/></StackPanel><StackPanel Grid.Row="0" Grid.Column="2"><TextBlock Text="Intervalo (s)"/><TextBox x:Name="txtInterval"/></StackPanel><StackPanel Grid.Row="0" Grid.Column="3"><TextBlock Text="Irradiância mínima"/><TextBox x:Name="txtMinIrr"/></StackPanel>
<StackPanel Grid.Row="1" Grid.Column="0"><TextBlock Text="Cidade"/><TextBox x:Name="txtCity"/></StackPanel><StackPanel Grid.Row="1" Grid.Column="1"><TextBlock Text="Latitude"/><TextBox x:Name="txtLat"/></StackPanel><StackPanel Grid.Row="1" Grid.Column="2"><TextBlock Text="Longitude"/><TextBox x:Name="txtLon"/></StackPanel><StackPanel Grid.Row="1" Grid.Column="3"><TextBlock Text="Intensidade GRID (gCO₂/kWh)"/><TextBox x:Name="txtGridCI"/></StackPanel>
<StackPanel Grid.Row="2" Grid.Column="0"><TextBlock Text="Material"/><TextBox x:Name="txtMaterial"/></StackPanel><StackPanel Grid.Row="2" Grid.Column="1"><TextBlock Text="Tipo painel"/><TextBox x:Name="txtFace"/></StackPanel><StackPanel Grid.Row="2" Grid.Column="2"><TextBlock Text="Área PV (m²)"/><TextBox x:Name="txtArea"/></StackPanel><StackPanel Grid.Row="2" Grid.Column="3"><TextBlock Text="Eficiência base"/><TextBox x:Name="txtEff"/></StackPanel>
<StackPanel Grid.Row="3" Grid.Column="0"><TextBlock Text="Ganho bifacial"/><TextBox x:Name="txtGain"/></StackPanel><StackPanel Grid.Row="3" Grid.Column="1"><TextBlock Text="Host GFLOP/s"/><TextBox x:Name="txtHostSpeed"/></StackPanel><StackPanel Grid.Row="3" Grid.Column="2"><TextBlock Text="Host ativo (W)"/><TextBox x:Name="txtHostActive"/></StackPanel><StackPanel Grid.Row="3" Grid.Column="3"><TextBlock Text="Host idle (W)"/><TextBox x:Name="txtHostIdle"/></StackPanel>
<StackPanel Grid.Row="4" Grid.Column="0"><TextBlock Text="Servidores ativos"/><TextBox x:Name="txtServers"/></StackPanel><StackPanel Grid.Row="4" Grid.Column="1"><TextBlock Text="PUE"/><TextBox x:Name="txtPue"/></StackPanel><StackPanel Grid.Row="4" Grid.Column="2"><TextBlock Text="Rede (kW)"/><TextBox x:Name="txtNetwork"/></StackPanel><StackPanel Grid.Row="4" Grid.Column="3"><TextBlock Text="Armazenamento (kW)"/><TextBox x:Name="txtStorage"/></StackPanel></Grid><Button x:Name="btnSaveConfig" Content="APLICAR E SALVAR CONFIGURAÇÃO" HorizontalAlignment="Left" Background="#0E67AD" Foreground="White" Margin="4,14,0,0"/></StackPanel></Border></StackPanel></ScrollViewer></TabItem>

<TabItem Header="GitHub / API"><ScrollViewer VerticalScrollBarVisibility="Auto"><StackPanel Margin="8"><Border Style="{StaticResource Card}"><StackPanel><TextBlock Text="GITHUB / API" FontWeight="Bold" Foreground="#083866" FontSize="16"/><TextBlock Text="Esta configuração controla a base central de resultados usada pelo PC, celular e dashboard web." Foreground="#65788B" Margin="0,4,0,12"/><Grid><Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions><StackPanel Grid.Column="0"><TextBlock Text="Repositório"/><TextBox x:Name="txtApiRepo"/><TextBlock Text="Branch"/><TextBox x:Name="txtApiBranch"/><TextBlock Text="Pasta de resultados"/><TextBox x:Name="txtApiPath" IsReadOnly="True" Background="#F1F4F7"/><CheckBox x:Name="chkAutoSync" Content="Sincronização automática após cada execução" Margin="6,12,0,0"/></StackPanel><StackPanel Grid.Column="1" Margin="20,0,0,0"><TextBlock Text="Token GitHub do PC"/><PasswordBox x:Name="pwdApiToken" Padding="8" Margin="4"/><TextBlock x:Name="txtTokenInfo" Text="" Foreground="#65788B" Margin="4"/><WrapPanel><Button x:Name="btnSaveApi" Content="SALVAR / TESTAR API" Background="#0E67AD" Foreground="White"/><Button x:Name="btnTestApi" Content="TESTAR CONEXÃO"/><Button x:Name="btnSyncApi" Content="SINCRONIZAR AGORA"/></WrapPanel><TextBlock x:Name="txtApiState" Text="Aguardando teste." Foreground="#65788B" Margin="4,12,4,0" TextWrapping="Wrap"/></StackPanel></Grid></StackPanel></Border></StackPanel></ScrollViewer></TabItem>

<TabItem Header="Log técnico"><Grid Margin="10"><TextBox x:Name="txtLog" FontFamily="Consolas" FontSize="12" IsReadOnly="True" AcceptsReturn="True" TextWrapping="NoWrap" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Auto" Background="#09131E" Foreground="#D6E6F5" BorderThickness="0" Padding="12"/></Grid></TabItem>
</TabControl>
<Border Grid.Row="2" Background="#E7EEF5" BorderBrush="#D2DDE8" BorderThickness="0,1,0,0"><TextBlock Text="PV-First V50.5 • C++/SimGrid • Resultados centralizados no GitHub" Foreground="#607386" VerticalAlignment="Center" Margin="16,0" FontSize="11"/></Border>
</Grid></Window>
'@
$reader=New-Object System.Xml.XmlNodeReader $xaml;$window=[System.Windows.Markup.XamlReader]::Load($reader)
$names=@('cmbProfile','btnApplyProfile','btnRun','btnStart','btnStop','btnRefresh','txtRunState','txtStatus','txtCentralStatus','txtPvPower','txtPvEnergy','txtPvState','txtGridEnergy','txtCo2','txtTotalEnergy','txtCoverage','txtIrr','txtMode','txtLastRun','txtWeather','txtProfileNote','btnDashboard','btnMobile','btnResults','btnSync','cmbResultProfile','cmbResultSource','cmbResultCoverage','dpResultDate','btnApplyResultFilter','btnClearResultFilter','btnDownloadCsv','txtResultCount','gridResults','txtFlops','txtStartHour','txtInterval','txtMinIrr','txtCity','txtLat','txtLon','txtGridCI','txtMaterial','txtFace','txtArea','txtEff','txtGain','txtHostSpeed','txtHostActive','txtHostIdle','txtServers','txtPue','txtNetwork','txtStorage','btnSaveConfig','txtApiRepo','txtApiBranch','txtApiPath','chkAutoSync','pwdApiToken','txtTokenInfo','btnSaveApi','btnTestApi','btnSyncApi','txtApiState','txtLog')
foreach($n in $names){Set-Variable -Name $n -Value $window.FindName($n) -Scope Script}

$btnApplyProfile.Add_Click({
    try {
        $item=$cmbProfile.SelectedItem
        if($item -and $item.Tag){
            $selectedProfileId=(''+$item.Tag)
            Apply-Profile $selectedProfileId
            $txtStatus.Text=('Perfil aplicado: '+$item.Content)
            $txtRunState.Text='PRONTO'
            $txtRunState.Foreground=[System.Windows.Media.Brushes]::LimeGreen
        }
    } catch {
        $msg=$_.Exception.Message
        $txtStatus.Text=('Erro ao aplicar perfil: '+$msg)
        $txtRunState.Text='ERRO DE PERFIL'
        $txtRunState.Foreground=[System.Windows.Media.Brushes]::IndianRed
        try { Write-StartupTrace ('ERRO aplicar perfil: '+$msg+' | '+$_.ScriptStackTrace) } catch {}
        [System.Windows.MessageBox]::Show(
            "Não foi possível aplicar o perfil, mas a interface continuará aberta.`n`n"+$msg,
            'PV-First - Perfil',
            [System.Windows.MessageBoxButton]::OK,
            [System.Windows.MessageBoxImage]::Warning
        ) | Out-Null
    }
})
$btnSaveConfig.Add_Click({Save-AdvancedConfig})
$btnRun.Add_Click({if($script:CurrentProcess -and -not $script:CurrentProcess.HasExited){return};Save-AdvancedConfig;$txtRunState.Text='EXECUTANDO';$txtRunState.Foreground=[System.Windows.Media.Brushes]::Orange;$txtStatus.Text='Rodando núcleo C++/SimGrid...';Start-InternalCommand 'run_once.cmd' $true|Out-Null})
$btnStart.Add_Click({Save-AdvancedConfig;Start-InternalCommand 'solar_background.cmd' $false|Out-Null;$txtRunState.Text='COLETA ATIVA';$txtRunState.Foreground=[System.Windows.Media.Brushes]::LimeGreen;$txtStatus.Text='Coleta contínua iniciada em segundo plano.'})
$btnStop.Add_Click({Start-InternalCommand 'stop.cmd' $false|Out-Null;$txtRunState.Text='PARANDO';$txtRunState.Foreground=[System.Windows.Media.Brushes]::Orange})
$btnRefresh.Add_Click({Load-CentralResults})
$btnSync.Add_Click({if(Sync-Now){Start-Sleep -Milliseconds 700;Load-CentralResults}})
$btnDashboard.Add_Click({Start-Process 'https://cagdoj.github.io/PhotovoltaicFirst/docs/dashboard.html'})
$btnMobile.Add_Click({Start-Process 'https://cagdoj.github.io/PhotovoltaicFirst/controle-mobile-v48.html'})
$btnResults.Add_Click({$s=Get-ApiSettings;Start-Process ('https://github.com/'+$s.Repo+'/tree/'+$s.Branch+'/'+$s.ResultsPath)})
$btnApplyResultFilter.Add_Click({Apply-ResultFilter})
$btnClearResultFilter.Add_Click({$cmbResultProfile.SelectedIndex=0;$cmbResultSource.SelectedIndex=0;$cmbResultCoverage.SelectedIndex=0;$dpResultDate.SelectedDate=$null;Apply-ResultFilter})
$btnDownloadCsv.Add_Click({$s=Get-ApiSettings;Start-Process ('https://raw.githubusercontent.com/'+$s.Repo+'/'+$s.Branch+'/'+$s.ResultsPath+'/all.csv')})
$btnSaveApi.Add_Click({Save-ApiConfig;Load-ApiFields})
$btnTestApi.Add_Click({Test-Api})
$btnSyncApi.Add_Click({if(Sync-Now){Start-Sleep -Milliseconds 700;Load-CentralResults}})

$timer=New-Object Windows.Threading.DispatcherTimer;$timer.Interval=[TimeSpan]::FromSeconds(2);$timer.Add_Tick({
    $statusPath=Join-Path $Internal 'status.txt';if(Test-Path $statusPath){try{$txtStatus.Text=(Get-Content $statusPath -Raw).Trim()}catch{}}
    $logPath=Join-Path $Internal 'current.log';if(Test-Path $logPath){try{$txtLog.Text=(Get-Content $logPath -Tail 180) -join "`r`n"}catch{}}
    if($script:CurrentProcess){try{if($script:CurrentProcess.HasExited){$script:CurrentProcess=$null;$txtRunState.Text='PRONTO';$txtRunState.Foreground=[System.Windows.Media.Brushes]::LimeGreen;Start-Sleep -Milliseconds 400;Load-CentralResults}else{$txtRunState.Text='EXECUTANDO';$txtRunState.Foreground=[System.Windows.Media.Brushes]::Orange}}catch{$script:CurrentProcess=$null}}
})
# Inicializacao em duas fases: a janela aparece primeiro; rede/API/agente so depois.
$startupLog = Join-Path $Internal 'startup_trace.log'
function Write-StartupTrace([string]$Message) {
    try {
        $line = ('[' + (Get-Date).ToString('yyyy-MM-dd HH:mm:ss') + '] ' + $Message)
        [IO.File]::AppendAllText($startupLog, $line + [Environment]::NewLine, (New-Object Text.UTF8Encoding($true)))
    } catch {}
}
function Safe-UiInit([string]$Name,[scriptblock]$Action) {
    try {
        Write-StartupTrace ('INICIO: ' + $Name)
        & $Action
        Write-StartupTrace ('OK: ' + $Name)
        return $true
    } catch {
        $msg = $_.Exception.Message
        Write-StartupTrace ('ERRO em ' + $Name + ': ' + $msg)
        try {
            $txtStatus.Text = ('Aviso em ' + $Name + ': ' + $msg)
            $txtRunState.Text = 'INTERFACE ATIVA'
            $txtRunState.Foreground = [System.Windows.Media.Brushes]::DarkOrange
        } catch {}
        return $false
    }
}

$initTimer = New-Object Windows.Threading.DispatcherTimer
$initTimer.Interval = [TimeSpan]::FromMilliseconds(700)
$initTimer.Add_Tick({
    $initTimer.Stop()
    Safe-UiInit 'carregar configuracao' { Load-ConfigFields } | Out-Null
    Safe-UiInit 'carregar GitHub/API' { Load-ApiFields } | Out-Null
    Safe-UiInit 'iniciar agente remoto' { if(Ensure-Agent){ $txtStatus.Text='Interface pronta • agente remoto ativo. Fechar esta janela não interrompe o agente.' } } | Out-Null
    Safe-UiInit 'carregar resultados centrais' { Load-CentralResults } | Out-Null
    try {
        $txtRunState.Text='PRONTO'
        $txtRunState.Foreground=[System.Windows.Media.Brushes]::LimeGreen
        if([string]::IsNullOrWhiteSpace($txtStatus.Text) -or $txtStatus.Text -eq 'Aguardando execução'){$txtStatus.Text='Interface pronta.'}
    } catch {}
})

$window.Add_Loaded({
    try { Remove-Item $startupLog -Force -ErrorAction SilentlyContinue } catch {}
    Write-StartupTrace 'JANELA CARREGADA'
    try { $timer.Start() } catch { Write-StartupTrace ('ERRO timer de log: '+$_.Exception.Message) }
    try { $initTimer.Start() } catch { Write-StartupTrace ('ERRO timer inicial: '+$_.Exception.Message) }
})
$script:AllowClose=$false
$window.Add_Closing({
    param($sender,$e)
    if(-not $script:AllowClose){
        $answer=[System.Windows.MessageBox]::Show(
            "Fechar apenas a interface do PV-First?`n`nO agente remoto e uma coleta que esteja em segundo plano continuarão ativos.`nPara interromper a coleta, use PARAR COLETA antes de fechar.",
            'PV-First - Fechar interface',
            [System.Windows.MessageBoxButton]::YesNo,
            [System.Windows.MessageBoxImage]::Information
        )
        if($answer -ne [System.Windows.MessageBoxResult]::Yes){ $e.Cancel=$true; return }
        $script:AllowClose=$true
    }
    try{$timer.Stop()}catch{}
    try{$initTimer.Stop()}catch{}
    Write-StartupTrace 'INTERFACE FECHADA; AGENTE REMOTO PRESERVADO'
})
# Protecao global da interface: erros de eventos nao devem encerrar a janela.
try {
    $window.Dispatcher.Add_UnhandledException({
        param($sender,$eventArgs)
        try {
            $msg=''+$eventArgs.Exception.Message
            Write-StartupTrace ('ERRO nao tratado da interface: '+$msg)
            $txtStatus.Text=('Erro de interface: '+$msg)
            $txtRunState.Text='INTERFACE ATIVA'
            $txtRunState.Foreground=[System.Windows.Media.Brushes]::DarkOrange
            $eventArgs.Handled=$true
        } catch {}
    })
} catch {}

Write-StartupTrace 'ANTES DO ShowDialog'
try {
    [void]$window.ShowDialog()
} catch {
    Write-StartupTrace ('ERRO ShowDialog: '+$_.Exception.Message+' | '+$_.ScriptStackTrace)
    try {
        [System.Windows.MessageBox]::Show(
            "A interface encontrou um erro, mas o diagnóstico foi preservado.`n`n" + $_.Exception.Message + "`n`nArquivo:`n" + $startupLog,
            'PV-First - Diagnóstico',
            [System.Windows.MessageBoxButton]::OK,
            [System.Windows.MessageBoxImage]::Error
        ) | Out-Null
    } catch {}
    Start-Sleep -Seconds 2
}
