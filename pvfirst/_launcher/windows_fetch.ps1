param(
  [Parameter(Mandatory=$true)][string]$Url,
  [string]$Proxy = ''
)
$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
try {
  $p=@{Uri=$Url;UseBasicParsing=$true;TimeoutSec=18}
  if(-not [string]::IsNullOrWhiteSpace($Proxy)){
    $p['Proxy']=$Proxy
    $p['ProxyUseDefaultCredentials']=$true
  }
  $r=Invoke-WebRequest @p
  [Console]::Out.Write($r.Content)
  exit 0
}catch{
  [Console]::Error.WriteLine($_.Exception.Message)
  exit 1
}
