$ErrorActionPreference = 'SilentlyContinue'
$raw = & wsl.exe -l -v 2>$null
$items = @()
foreach ($line in $raw) {
    $s = ($line -replace "`0", "").Trim()
    if ($s -eq "" -or $s -match "^NAME\s+") { continue }
    if ($s -match "^\*?\s*([^\s]+)\s+") {
        $name = $Matches[1].Trim()
        if ($name -and ($name -notmatch "docker-desktop") -and ($name -notmatch "docker")) {
            $items += $name
        }
    }
}
$ubuntu = $items | Where-Object { $_ -like "Ubuntu*" } | Select-Object -First 1
if ($ubuntu) { [Console]::Write($ubuntu); exit 0 }
if ($items.Count -gt 0) { [Console]::Write($items[0]); exit 0 }
exit 1
