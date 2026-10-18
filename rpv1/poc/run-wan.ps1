# WAN acceptance on the modular library (rednet as the WAN interface only).
#
#   21 = gateway A : LAN 10.0.1.1/24 (ch 4001), WAN 172.16.0.1/24 (rednet)
#                    advert=1, rpv_host=gw-a, map 25 -> 172.16.0.9
#   22 = gateway B : LAN 10.0.2.1/24 (ch 4002, mtu 128), WAN 172.16.0.2/24 (rednet), advert=1
#   23 = host A    : 10.0.1.2, gw 10.0.1.1, app=rpv-selftest:10.0.2.2 (also probes 172.16.0.9)
#   24 = host B    : 10.0.2.2, gw 10.0.2.1, app=udp-echo:7
#   25 = plain rednet device on the WAN (poc/peer/legacy-rednet.lua)
#
# Acceptance: LAN->WAN->LAN works but is TWO router hops (ttl=2 must NOT survive),
# the WAN fragments the 900 B datagram, and the plain rednet device answers.
param([int]$TimeoutSec = 180, [string]$Root = $env:RPV_ROOT)

$root = $Root
if (-not $root) { $root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path) }
$data = Join-Path $root "craftos-wan"
$exe = "C:\Program Files\CraftOS-PC\CraftOS-PC_console.exe"
$bootstrap = Join-Path $root "poc\node2\startup.lua"
$rpvdir = Join-Path $root "poc\rpv"
$appsdir = Join-Path $root "poc\apps"
$compatdir = Join-Path $root "poc\compat"
$peer = Join-Path $root "poc\peer\legacy-rednet.lua"

if (Test-Path $data) { Remove-Item -Recurse -Force $data }
New-Item -ItemType Directory -Force -Path $data | Out-Null

$roles = @{}
$roles[21] = "role=router`niface=back|LAN|10.0.1.1/24|4001|256|wired`niface=right|WAN|172.16.0.1/24|rednet|256`nadvert=1`nrpv_host=gw-a`nmap=25:172.16.0.9`nspawn=22,23,24,25`nstats_at=10`n"
$roles[22] = "role=router`niface=back|LAN|10.0.2.1/24|4002|128|wired`niface=right|WAN|172.16.0.2/24|rednet|256`nadvert=1`nstats_at=10`n"
$roles[23] = "role=host`niface=back|LAN|10.0.1.2/24|4001|256|wired`ngw=10.0.1.1`napp=rpv-selftest:10.0.2.2`nstart_delay=6`nlarge_bytes=900`nlegacy_remote=172.16.0.9`nexpect_pings=3`nexpect_ttl2=0`nexpect_ttl_exceeded=1`n"
$roles[24] = "role=host`niface=back|LAN|10.0.2.2/24|4002|256|wired`ngw=10.0.2.1`napp=udp-echo:7`n"

foreach ($id in @(21, 22, 23, 24)) {
    $dir = Join-Path $data "computer\$id"
    foreach ($sub in @("rpv", "apps", "compat")) { New-Item -ItemType Directory -Force -Path (Join-Path $dir $sub) | Out-Null }
    Copy-Item (Join-Path $rpvdir "*.lua") (Join-Path $dir "rpv") -Force
    Copy-Item (Join-Path $appsdir "*.lua") (Join-Path $dir "apps") -Force
    Copy-Item (Join-Path $compatdir "*.lua") (Join-Path $dir "compat") -Force
    Copy-Item $bootstrap (Join-Path $dir "startup.lua") -Force
    Set-Content -Path (Join-Path $dir "role.txt") -Value $roles[$id] -Encoding ascii
}
$dir = Join-Path $data "computer\25"
New-Item -ItemType Directory -Force -Path $dir | Out-Null
Copy-Item $peer (Join-Path $dir "startup.lua") -Force
Set-Content -Path (Join-Path $dir "legacy.txt") -Encoding ascii -Value "ip=172.16.0.9`nlookup=gw-a`n"

New-Item -ItemType Directory -Force -Path (Join-Path $root "poc\out") | Out-Null
$stdout = Join-Path $root "poc\out\wan.stdout.txt"
$stderr = Join-Path $root "poc\out\wan.stderr.txt"
$proc = Start-Process -FilePath $exe -ArgumentList @("-d", "`"$data`"", "--headless", "--id", "21") `
    -RedirectStandardOutput $stdout -RedirectStandardError $stderr -PassThru -NoNewWindow

$log23 = Join-Path $data "computer\23\rpv-log.txt"
$deadline = (Get-Date).AddSeconds($TimeoutSec)
$done = $false
while ((Get-Date) -lt $deadline) {
    Start-Sleep -Milliseconds 400
    if ($proc.HasExited) { break }
    if (Test-Path $log23) { if ((Get-Content $log23 -Raw) -match "TEST_DONE") { $done = $true; break } }
}
Start-Sleep -Milliseconds 2500
if (-not $done -and (Test-Path $log23)) { if ((Get-Content $log23 -Raw) -match "TEST_DONE") { $done = $true } }
if (-not $proc.HasExited) { $proc.Kill() }
Start-Sleep -Milliseconds 300

foreach ($id in @(21, 22, 23, 24)) {
    $src = Join-Path $data "computer\$id\rpv-log.txt"
    if (Test-Path $src) { Copy-Item $src (Join-Path $root "poc\out\wan-node$id.log") -Force }
}
$legacy = Join-Path $data "computer\25\legacy-log.txt"
if (Test-Path $legacy) { Copy-Item $legacy (Join-Path $root "poc\out\wan-node25-legacy.log") -Force }

$t21 = if (Test-Path (Join-Path $data "computer\21\rpv-log.txt")) { Get-Content (Join-Path $data "computer\21\rpv-log.txt") -Raw } else { "" }
$t22 = if (Test-Path (Join-Path $data "computer\22\rpv-log.txt")) { Get-Content (Join-Path $data "computer\22\rpv-log.txt") -Raw } else { "" }
$t23 = if (Test-Path $log23) { Get-Content $log23 -Raw } else { "" }
$t25 = if (Test-Path $legacy) { Get-Content $legacy -Raw } else { "" }

$complete = ($t23 -match "complete=true")
$verdict = "FAIL"
if ($complete -and $t23 -match "legacy_reply_ok=true" -and $t23 -match "ttl2_ok=false" -and
    $t21 -match "WAN_SENT" -and $t21 -match "WAN_LEGACY_TX" -and $t22 -match "WAN_RECV" -and $t25 -match "LEGACY_REPLY") {
    $verdict = "PASS"
}

"RESULT wan done=$done complete=$complete verdict=$verdict"
foreach ($id in @(21, 22, 23, 24)) {
    "===== NODE $id ====="
    $p = Join-Path $data "computer\$id\rpv-log.txt"
    if (Test-Path $p) { Get-Content $p | Where-Object { $_ -match "WAN_|FWD |FRAGMENTED|REASSEMBLED|RESULTS|TEST_DONE|STATS|SPAWN|SELFTEST|UDPECHO|IFACE" } }
}
"===== NODE 25 (plain rednet on the WAN) ====="
if (Test-Path $legacy) { Get-Content $legacy }
"===== STDERR ====="
if (Test-Path $stderr) { Get-Content $stderr -Raw }
