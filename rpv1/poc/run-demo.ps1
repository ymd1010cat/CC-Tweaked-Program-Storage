# LAN acceptance on the modular library (single-computer router, no rednet).
#
#   21 = router : LAN-A 10.0.1.1/24 (ch 4001, mtu 256), LAN-B 10.0.2.1/24 (ch 4002, mtu 128)
#   22 = host A : 10.0.1.2, gw 10.0.1.1, app=rpv-selftest:10.0.2.2
#   23 = host B : 10.0.2.2, gw 10.0.2.1, app=udp-echo:7
#
# Acceptance: complete=true and the router re-fragments on the smaller egress MTU.
param([int]$TimeoutSec = 120, [string]$Root = $env:RPV_ROOT)

$root = $Root
if (-not $root) { $root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path) }
$data = Join-Path $root "craftos-demo"
$exe = "C:\Program Files\CraftOS-PC\CraftOS-PC_console.exe"
$bootstrap = Join-Path $root "poc\node2\startup.lua"
$rpvdir = Join-Path $root "poc\rpv"
$appsdir = Join-Path $root "poc\apps"
$compatdir = Join-Path $root "poc\compat"

if (Test-Path $data) { Remove-Item -Recurse -Force $data }
New-Item -ItemType Directory -Force -Path $data | Out-Null

$roles = @{}
$roles[21] = "role=router`niface=back|LAN-A|10.0.1.1/24|4001|256|wired`niface=left|LAN-B|10.0.2.1/24|4002|128|wired`nspawn=22,23`nstats_at=6`n"
$roles[22] = "role=host`niface=back|LAN-A|10.0.1.2/24|4001|256|wired`ngw=10.0.1.1`napp=rpv-selftest:10.0.2.2`nstart_delay=3`nlarge_bytes=900`nexpect_pings=4`nexpect_ttl2=1`nexpect_ttl_exceeded=1`n"
$roles[23] = "role=host`niface=back|LAN-B|10.0.2.2/24|4002|256|wired`ngw=10.0.2.1`napp=udp-echo:7`nstats_at=6`n"

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
$stdout = Join-Path $root "poc\out\demo.stdout.txt"
$stderr = Join-Path $root "poc\out\demo.stderr.txt"
$proc = Start-Process -FilePath $exe -ArgumentList @("-d", "`"$data`"", "--headless", "--id", "21") `
    -RedirectStandardOutput $stdout -RedirectStandardError $stderr -PassThru -NoNewWindow

$log22 = Join-Path $data "computer\22\rpv-log.txt"
$deadline = (Get-Date).AddSeconds($TimeoutSec)
$done = $false
while ((Get-Date) -lt $deadline) {
    Start-Sleep -Milliseconds 400
    if ($proc.HasExited) { break }
    if (Test-Path $log22) { if ((Get-Content $log22 -Raw) -match "TEST_DONE") { $done = $true; break } }
}
Start-Sleep -Milliseconds 2000
if (-not $done -and (Test-Path $log22)) { if ((Get-Content $log22 -Raw) -match "TEST_DONE") { $done = $true } }
if (-not $proc.HasExited) { $proc.Kill() }
Start-Sleep -Milliseconds 300

foreach ($id in @(21, 22, 23)) {
    $src = Join-Path $data "computer\$id\rpv-log.txt"
    if (Test-Path $src) { Copy-Item $src (Join-Path $root "poc\out\demo-node$id.log") -Force }
}
$t21 = if (Test-Path (Join-Path $data "computer\21\rpv-log.txt")) { Get-Content (Join-Path $data "computer\21\rpv-log.txt") -Raw } else { "" }
$t22 = if (Test-Path $log22) { Get-Content $log22 -Raw } else { "" }

$complete = ($t22 -match "complete=true")
$verdict = "FAIL"
if ($complete -and $t21 -match "FRAGMENTED" -and $t21 -match "REASSEMBLED" -and $t22 -match "ttl2_ok=true" -and $t21 -match "FWD ") {
    $verdict = "PASS"
}

"RESULT lan done=$done complete=$complete verdict=$verdict"
foreach ($id in @(21, 22, 23)) {
    "===== NODE $id ====="
    $p = Join-Path $data "computer\$id\rpv-log.txt"
    if (Test-Path $p) { Get-Content $p | Where-Object { $_ -match "FRAGMENTED|REASSEMBLED|FWD |RESULTS|TEST_DONE|STATS|SPAWN|SELFTEST|UDPECHO|IFACE" } }
}
"===== STDERR ====="
if (Test-Path $stderr) { Get-Content $stderr -Raw }
