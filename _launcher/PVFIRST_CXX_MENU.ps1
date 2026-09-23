param([Parameter(Mandatory=$true)][string]$Root)
$ErrorActionPreference='Continue'
$Root=(Resolve-Path -LiteralPath $Root).Path.TrimEnd('\')
$Internal=Join-Path $Root '_interno'
$Project=Join-Path $Root 'pvfirst'
$Bridge=Join-Path $Root '_launcher\GITHUB_API_BRIDGE.ps1'
$AgentScript=Join-Path $Root '_launcher\GITHUB_PAGES_COMMAND_AGENT.ps1'
$TokenFile=Join-Path (Join-Path $env:LOCALAPPDATA 'PVFirst') 'github_api_token.dat'
$MobileUrl='https://cagdoj.github.io/PhotovoltaicFirst/controle-mobile-v48.html'
$DashboardUrl='https://cagdoj.github.io/PhotovoltaicFirst/dashboard.html'
try{Set-Location -LiteralPath $env:TEMP}catch{}

function Read-EnvFile {
  $map=@{}
  $f=Join-Path $Project 'config\pvfirst.env'
  if(Test-Path $f){
    foreach($line in Get-Content -LiteralPath $f -ErrorAction SilentlyContinue){
      $t=(''+$line).Trim()
      if($t -match '^export\s+([A-Za-z0-9_]+)="?(.*?)"?$'){$map[$Matches[1]]=$Matches[2].Trim('"')}
    }
  }
  return $map
}
function Set-EnvValue([string]$Key,[string]$Value){
  $f=Join-Path $Project 'config\pvfirst.env'
  $lines=@(); if(Test-Path $f){$lines=Get-Content -LiteralPath $f -ErrorAction SilentlyContinue}
  $ek=[regex]::Escape($Key); $lines=$lines|Where-Object{$_ -notmatch "^export\s+$ek="}
  $lines += ('export '+$Key+'="'+$Value+'"')
  Set-Content -LiteralPath $f -Value $lines -Encoding ASCII
}
function Profile-Name([string]$Id){
  switch($Id){
    'datacenter_moderate'{'Data Center - Moderado'}
    'datacenter_high'{'Data Center - Alta Carga'}
    'hpc_high'{'HPC - Alta Carga'}
    'hpc_extreme'{'HPC - Extremo'}
    default{$Id}
  }
}
function Apply-Profile([string]$Id){
  $p=@{}
  switch($Id){
    'datacenter_moderate'{$p=@{F='5e12';A='1200';E='0.22';G='1.12';S='500';AW='600';IW='250';OW='20';N='64';P='1.50';NW='8';ST='4'}}
    'datacenter_high'{$p=@{F='5e13';A='2500';E='0.23';G='1.15';S='1000';AW='750';IW='300';OW='20';N='128';P='1.40';NW='20';ST='10'}}
    'hpc_high'{$p=@{F='5e14';A='12000';E='0.24';G='1.18';S='3000';AW='1200';IW='450';OW='25';N='512';P='1.30';NW='80';ST='40'}}
    'hpc_extreme'{$p=@{F='1e15';A='30000';E='0.24';G='1.20';S='5000';AW='1800';IW='600';OW='30';N='1024';P='1.25';NW='150';ST='75'}}
    default{return}
  }
  Set-EnvValue 'PVFIRST_SIMULATION_PROFILE' $Id
  Set-EnvValue 'PVFIRST_DEFAULT_FLOPS' $p.F
  Set-EnvValue 'PVFIRST_PANEL_MATERIAL' 'monocrystalline'
  Set-EnvValue 'PVFIRST_PANEL_FACE_TYPE' 'bifacial'
  Set-EnvValue 'PVFIRST_PANEL_AREA_M2' $p.A
  Set-EnvValue 'PVFIRST_PANEL_BASE_EFFICIENCY' $p.E
  Set-EnvValue 'PVFIRST_BIFACIAL_GAIN' $p.G
  Set-EnvValue 'PVFIRST_GRID_CARBON_INTENSITY' '100'
  Set-EnvValue 'PVFIRST_HOST_SPEED_GFLOPS' $p.S
  Set-EnvValue 'PVFIRST_HOST_ACTIVE_W' $p.AW
  Set-EnvValue 'PVFIRST_HOST_IDLE_W' $p.IW
  Set-EnvValue 'PVFIRST_HOST_OFF_W' $p.OW
  Set-EnvValue 'PVFIRST_DC_ACTIVE_SERVERS' $p.N
  Set-EnvValue 'PVFIRST_DC_PUE' $p.P
  Set-EnvValue 'PVFIRST_DC_NETWORK_KW' $p.NW
  Set-EnvValue 'PVFIRST_DC_STORAGE_KW' $p.ST
  Set-EnvValue 'PVFIRST_SOLAR_START_HOUR' '6'
  Set-EnvValue 'PVFIRST_SOLAR_INTERVAL_SECONDS' '60'
  Set-EnvValue 'PVFIRST_SOLAR_ZERO_LIMIT' '5'
  Set-EnvValue 'PVFIRST_IRRADIANCE_MIN_WM2' '1'
  Write-Host "`nPerfil aplicado: $(Profile-Name $Id)" -ForegroundColor Green
}
function Show-Result {
  $log=Join-Path $Internal 'current.log'
  if(Test-Path $log){
    Write-Host "`n---------------- RESULTADO MAIS RECENTE ----------------" -ForegroundColor Cyan
    $all=Get-Content -LiteralPath $log -ErrorAction SilentlyContinue
    $keys=@('Cidade detectada','Hora local','Perfil selecionado','Irradiancia ajustada','Potencia PV disponivel','Energia total do data center','Energia vinda da PV','Energia vinda da GRID','CO2 emitido pela GRID','CO2 evitado pela PV','MODO DA FONTE','SIMULACAO FINALIZADA','SEM INTERNET','ERRO')
    $sel=@(); foreach($line in $all){foreach($k in $keys){if($line -like ('*'+$k+'*')){$sel+=$line;break}}}
    $sel|Select-Object -Last 20|ForEach-Object{Write-Host $_}
    Write-Host '--------------------------------------------------------'
  }
}
function Run-Cmd([string]$Name,[bool]$Wait=$true){
  $p=Join-Path $Internal $Name
  if(!(Test-Path $p)){Write-Host "Arquivo nao encontrado: $p" -ForegroundColor Red;return}
  if($Wait){
    & cmd.exe /c ('"'+$p+'"')
    Show-Result
  }else{
    Start-Process -FilePath 'cmd.exe' -ArgumentList @('/c',('"'+$p+'"')) -WorkingDirectory $env:TEMP -WindowStyle Hidden|Out-Null
  }
}
function Stop-OldAgents {
  $pidFile=Join-Path (Join-Path $env:LOCALAPPDATA 'PVFirst') 'agent.pid'
  if(Test-Path $pidFile){
    try{
      $oldText=(Get-Content $pidFile -Raw -ErrorAction Stop).Trim();$old=0
      if([int]::TryParse($oldText,[ref]$old) -and $old -gt 0 -and $old -ne $PID){
        $proc=Get-CimInstance Win32_Process -Filter ("ProcessId="+$old) -ErrorAction SilentlyContinue
        if($proc -and $proc.CommandLine -and ((''+$proc.CommandLine) -match 'GITHUB_PAGES_COMMAND_AGENT\.ps1')){
          Stop-Process -Id $old -Force -ErrorAction SilentlyContinue
        }
      }
    }catch{}
    Remove-Item $pidFile -Force -ErrorAction SilentlyContinue
  }
  try {
    Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
      $_.ProcessId -ne $PID -and $_.CommandLine -and $_.CommandLine -match 'GITHUB_PAGES_COMMAND_AGENT\.ps1'
    } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
  } catch {}
}
function Start-Agent {
  if(!(Test-Path $AgentScript)){return}
  Stop-OldAgents
  Start-Process -FilePath 'powershell.exe' -ArgumentList @('-NoLogo','-NoProfile','-ExecutionPolicy','Bypass','-File',$AgentScript,'-Root',$Root,'-Repo','CAGDOJ/PhotovoltaicFirst','-Branch','main','-IntervalSeconds','20') -WorkingDirectory $env:TEMP -WindowStyle Hidden|Out-Null
  Start-Sleep -Milliseconds 700
}
function Token-Ready { return (Test-Path $TokenFile) }
function Configure-MobileToken {
  if(Test-Path $Bridge){& powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $Bridge -Action ensure-token -Root $Root -Repo 'CAGDOJ/PhotovoltaicFirst' -Branch 'main'}
}
function Show-Header {
  Clear-Host
  $e=Read-EnvFile; $id='datacenter_high'; if($e.ContainsKey('PVFIRST_SIMULATION_PROFILE')){$id=$e['PVFIRST_SIMULATION_PROFILE']}
  $flops=''; if($e.ContainsKey('PVFIRST_DEFAULT_FLOPS')){$flops=$e['PVFIRST_DEFAULT_FLOPS']}
  Write-Host '============================================================' -ForegroundColor DarkCyan
  Write-Host ' PV-FIRST V48 - SIMULADOR C++ / SIMGRID' -ForegroundColor Cyan
  Write-Host '============================================================' -ForegroundColor DarkCyan
  Write-Host (' Perfil atual : '+(Profile-Name $id))
  Write-Host (' Job          : '+$flops+' FLOPs')
  Write-Host (' Controle movel: '+$(if(Token-Ready){'ATIVO'}else{'NAO CONFIGURADO'}))
  Write-Host ''
  Write-Host ' 1  RODAR TESTE AGORA' -ForegroundColor Green
  Write-Host ' 2  INICIAR COLETA CONTINUA' -ForegroundColor Green
  Write-Host ' 3  PARAR COLETA' -ForegroundColor Red
  Write-Host ' 4  ESCOLHER PERFIL DE SIMULACAO'
  Write-Host ' 5  ABRIR RESULTADOS LOCAIS'
  Write-Host ' 6  GERAR DASHBOARD'
  Write-Host ' 7  ABRIR CONTROLE NO CELULAR'
  Write-Host ' 8  CONFIGURAR TOKEN DO CONTROLE MOVEL'
  Write-Host ' 9  EDITAR CONFIGURACAO AVANCADA'
  Write-Host ' 0  SAIR (agente remoto continua ativo)'
  Write-Host ''
}
function Select-ProfileMenu {
  Clear-Host
  Write-Host 'PERFIL DE SIMULACAO' -ForegroundColor Cyan
  Write-Host '1  Data Center - Moderado'
  Write-Host '2  Data Center - Alta Carga'
  Write-Host '3  HPC - Alta Carga'
  Write-Host '4  HPC - Extremo'
  Write-Host '0  Voltar'
  $c=Read-Host 'Escolha'
  switch($c){'1'{Apply-Profile 'datacenter_moderate'}'2'{Apply-Profile 'datacenter_high'}'3'{Apply-Profile 'hpc_high'}'4'{Apply-Profile 'hpc_extreme'}default{return}}
  Start-Sleep -Seconds 1
}

# Inicializacao local: o nucleo C++ funciona mesmo sem GitHub.
Start-Agent
if(-not (Token-Ready)){
  Write-Host '[PV-First] Controle movel ainda nao configurado. O simulador local funciona normalmente.' -ForegroundColor Yellow
  Write-Host '[PV-First] Use a opcao 8 quando quiser ativar o controle pelo celular.'
  Start-Sleep -Seconds 2
}
while($true){
  Show-Header
  $choice=Read-Host 'Escolha uma opcao'
  switch($choice){
    '1'{Write-Host "`nExecutando o nucleo C++/SimGrid..." -ForegroundColor Cyan;Run-Cmd 'run_once.cmd' $true;Read-Host 'ENTER para voltar'|Out-Null}
    '2'{Run-Cmd 'solar_background.cmd' $false;Write-Host 'Coleta continua iniciada em segundo plano.' -ForegroundColor Green;Start-Sleep 2}
    '3'{Run-Cmd 'stop.cmd' $true;Write-Host 'Coleta parada.' -ForegroundColor Yellow;Start-Sleep 2}
    '4'{Select-ProfileMenu}
    '5'{Start-Process explorer.exe -ArgumentList (Join-Path $Project 'results');Start-Sleep 1}
    '6'{Run-Cmd 'dashboard.cmd' $true;Start-Process $DashboardUrl;Start-Sleep 1}
    '7'{Start-Process $MobileUrl;Start-Sleep 1}
    '8'{Configure-MobileToken;Start-Agent;Read-Host 'ENTER para voltar'|Out-Null}
    '9'{Start-Process notepad.exe -ArgumentList (Join-Path $Project 'config\pvfirst.env');Start-Sleep 1}
    '0'{break}
    default{Start-Sleep -Milliseconds 500}
  }
  if($choice -eq '0'){break}
}
