# M3 (1/3): rednet compatibility shim — an UNCHANGED rednet program over rpv.
#
#   21 = router + directory (app=rednet-dir:4100)
#   22 = host A, 10.0.1.2, gw 10.0.1.1, shim=1, app=legacy-chat:client:23
#   23 = host B, 10.0.2.2, gw 10.0.2.1, shim=1, app=legacy-chat:server:22
#
# Acceptance: the client resolves the server's name through rednet.lookup, sends
# by *computer id* across a router (different subnets), gets the reply, and its
# broadcast is relayed by the directory.
param([int]$TimeoutSec = 120, [string]$Root = $env:RPV_ROOT)

$root = $Root
if (-not $root) { $root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path) }
$data = Join-Path $root "craftos-m3-shim"
$exe = "C:\Program Files\CraftOS-PC\CraftOS-PC_console.exe"
$bootstrap = Join-Path $root "poc\node2\startup.lua"
$rpvdir = Join-Path $root "poc\rpv"
$appsdir = Join-Path $root "poc\apps"
$compatdir = Join-Path $root "poc\compat"

if (Test-Path $data) { Remove-Item -Recurse -Force $data }
New-Item -ItemType Directory -Force -Path $data | Out-Null

$roles = @{}
$roles[21] = "role=router`niface=back|LAN-A|10.0.1.1/24|4001|256|wired`niface=left|LAN-B|10.0.2.1/24|4002|256|wired`napp=rednet-dir:4100`nspawn=22,23`nstats_at=20`n"
$roles[22] = "role=host`niface=back|LAN-A|10.0.1.2/24|4001|256|wired`ngw=10.0.1.1`nshim=1`napp=legacy-chat:client:23`nstats_at=20`n"
$roles[23] = "role=host`niface=back|LAN-B|10.0.2.2/24|4002|256|wired`ngw=10.0.2.1`nshim=1`napp=legacy-chat:server:22`n"

foreach ($id in @(21, 22, 23)) {
    $dir = Join-Path $data "computer\$id"
    foreach ($sub in @("rpv", "apps", "compat")) { New-Item -ItemType Directory -Force -Path (Join-Path $dir $sub) | Out-Null }
    Copy-Item (Join-Path $rpvdir "*.lua") (Join-Path $dir "rpv") -Force
    Copy-Item (Join-Path $appsdir "*.lua") (Join-Path $dir "apps") -Force
    Copy-Item (Join-Path $compatdir "*.lua") (Join-Path $dir "compat") -Force
    Copy-Item $bootstrap (Join-Path $dir "startup.lua") -Force
    Set-Content -Path (Join-Path $dir "role.txt") -Value $roles[$id] -Encoding ascii
}

New-Item -ItemType Directory -Force -Path (Join-Path $root "poc\out") | Out-Null
$stdout = Join-Path $root "poc\out\m3-shim.stdout.txt"
$stderr = Join-Path $root "poc\out\m3-shim.stderr.txt"
$proc = Start-Process -FilePath $exe -ArgumentList @("-d", "`"$data`"", "--headless", "--id", "21") `
    -RedirectStandardOutput $stdout -RedirectStandardError $stderr -PassThru -NoNewWindow

$clientLog = Join-Path $data "computer\22\legacy-log.txt"
$deadline = (Get-Date).AddSeconds($TimeoutSec)
$done = $false
while ((Get-Date) -lt $deadline) {
    Start-Sleep -Milliseconds 400
    if ($proc.HasExited) { break }
    if (Test-Path $clientLog) { if ((Get-Content $clientLog -Raw) -match "TEST_DONE") { $done = $true; break } }
}
Start-Sleep -Milliseconds 2000
if (-not $done -and (Test-Path $clientLog)) { if ((Get-Content $clientLog -Raw) -match "TEST_DONE") { $done = $true } }
if (-not $proc.HasExited) { $proc.Kill() }
Start-Sleep -Milliseconds 300

foreach ($id in @(21, 22, 23)) {
    $src = Join-Path $data "computer\$id\rpv-log.txt"
    if (Test-Path $src) { Copy-Item $src (Join-Path $root "poc\out\m3-shim-node$id.log") -Force }
    $legacy = Join-Path $data "computer\$id\legacy-log.txt"
    if (Test-Path $legacy) { Copy-Item $legacy (Join-Path $root "poc\out\m3-shim-legacy$id.log") -Force }
}

$client = if (Test-Path $clientLog) { Get-Content $clientLog -Raw } else { "" }
$serverLog = Join-Path $data "computer\23\legacy-log.txt"
$server = if (Test-Path $serverLog) { Get-Content $serverLog -Raw } else { "" }
$dirLog = if (Test-Path (Join-Path $data "computer\21\rpv-log.txt")) { Get-Content (Join-Path $data "computer\21\rpv-log.txt") -Raw } else { "" }

$verdict = "FAIL"
if ($client -match "LEGACY_LOOKUP name=host-23 -> 23" -and
    $client -match "LEGACY_REPLY sender=23" -and
    $client -match "LEGACY_RESULT lookup_ok=true reply_ok=true" -and
    $server -match "LEGACY_SERVER_GOT sender=22" -and
    $dirLog -match "DIR_LOOKUP id=23" -and
    $dirLog -match "DIR_BCAST") { $verdict = "PASS" }

"RESULT m3-shim done=$done verdict=$verdict"
"===== NODE 21 (router + directory) ====="
if ($dirLog) { Get-Content (Join-Path $data "computer\21\rpv-log.txt") | Where-Object { $_ -match "DIR_|REDNET_DIR|SPAWN|STATS" } }
"===== NODE 22 (host A: legacy rednet client) ====="
if (Test-Path $clientLog) { Get-Content $clientLog }
"===== NODE 23 (host B: legacy rednet server) ====="
if (Test-Path $serverLog) { Get-Content $serverLog }
"===== node logs (shim) ====="
Get-Content (Join-Path $data "computer\22\rpv-log.txt") -ErrorAction SilentlyContinue | Where-Object { $_ -match "SHIM_" } | Select-Object -First 12
"===== STDERR ====="
if (Test-Path $stderr) { Get-Content $stderr -Raw }
