param(
    [Parameter(Mandatory=$true)][string]$Root
)

$Internal = Join-Path $Root '_interno'
$Lock = Join-Path $Internal 'solar_background.lock'

try {
    Add-Type @"
using System;
using System.Runtime.InteropServices;
public static class PvFirstPower {
    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern uint SetThreadExecutionState(uint esFlags);
}
"@
} catch {}

$ES_CONTINUOUS = 0x80000000
$ES_SYSTEM_REQUIRED = 0x00000001

while (Test-Path $Lock) {
    try { [PvFirstPower]::SetThreadExecutionState($ES_CONTINUOUS -bor $ES_SYSTEM_REQUIRED) | Out-Null } catch {}
    Start-Sleep -Seconds 25
}

try { [PvFirstPower]::SetThreadExecutionState($ES_CONTINUOUS) | Out-Null } catch {}
