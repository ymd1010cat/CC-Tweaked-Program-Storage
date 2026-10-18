# Cluster acceptance on the modular library (fabric migrated into poc/rpv/).
#
#   21 = cluster member / line card for LAN-A (10.0.1.1/24, ch 4001) + fabric
#   22 = cluster member / line card for LAN-B (10.0.2.1/24, ch 4002) + fabric
#   23 = host A (10.0.1.2, gw 10.0.1.1)  -- runs app=rpv-selftest
#   24 = host B (10.0.2.2, gw 10.0.2.1)  -- echoes
#
# Acceptance: A -> 21 -fabric-> 22 -> B works, the cluster counts as ONE hop
# (ttl=2 survives), and the two members really used FABRIC_FWD / FABRIC_RECV.
param([int]$TimeoutSec = 150, [string]$Root = $env:RPV_ROOT)

$root = $Root
if (-not $root) { $root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path) }
$data = Join-Path $root "craftos-cluster"
$exe = "C:\Program Files\CraftOS-PC\CraftOS-PC_console.exe"
$bootstrap = Join-Path $root "poc\node2\startup.lua"
$rpvdir = Join-Path $root "poc\rpv"
$appsdir = Join-Path $root "poc\apps"
$compatdir = Join-Path $root "poc\compat"

if (Test-Path $data) { Remove-Item -Recurse -Force $data }
New-Item -ItemType Directory -Force -Path $data | Out-Null

$roles = @{}
$roles[21] = "role=router`niface=back|LAN-A|10.0.1.1/24|4001|256|wired`nfabric=left|5000|1024`nspawn=22,23,24`nstats_at=6`n"
$roles[22] = "role=router`niface=back|LAN-B|10.0.2.1/24|4002|128|wired`nfabric=left|5000|1024`nstats_at=6`n"
$roles[23] = "role=host`niface=back|LAN-A|10.0.1.2/24|4001|256|wired`ngw=10.0.1.1`napp=rpv-selftest:10.0.2.2`nstart_delay=3`nlarge_bytes=900`nexpect_pings=4`nexpect_ttl2=1`nexpect_ttl_exceeded=1`n"
$roles[24] = "role=host`niface=back|LAN-B|10.0.2.2/24|4002|256|wired`ngw=10.0.2.1`napp=udp-echo:7`n"

foreach ($id in @(21, 22, 23, 24)) {
    $dir = Join-Path $data "computer\$id"
    foreach ($sub in @("rpv", "apps", "compat")) { New-Item -ItemType Directory -Force -Path (Join-Path $dir $sub) | Out-Null }
    Copy-Item (Join-Path $rpvdir "*.lua") (Join-Path $dir "rpv") -Force
    Copy-Item (Join-Path $appsdir "*.lua") (Join-Path $dir "apps") -Force
    Copy-Item (Join-Path $compatdir "*.lua") (Join-Path $dir "compat") -Force
    Copy-Item $bootstrap (Join-Path $dir "startup.lua") -Force
    Set-Content -Path (Join-Path $dir "role.txt") -Value $roles[$id] -Encoding ascii
}

New-Item -ItemType Directory -Force -Path (Join-Path $root "poc\out") | Out-Null
$stdout = Join-Path $root "poc\out\cluster.stdout.txt"
$stderr = Join-Path $root "poc\out\cluster.stderr.txt"
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
    if (Test-Path $src) { Copy-Item $src (Join-Path $root "poc\out\cluster-node$id.log") -Force }
}
$t21 = if (Test-Path (Join-Path $data "computer\21\rpv-log.txt")) { Get-Content (Join-Path $data "computer\21\rpv-log.txt") -Raw } else { "" }
$t22 = if (Test-Path (Join-Path $data "computer\22\rpv-log.txt")) { Get-Content (Join-Path $data "computer\22\rpv-log.txt") -Raw } else { "" }
$t23 = if (Test-Path $log23) { Get-Content $log23 -Raw } else { "" }

$complete = ($t23 -match "complete=true")
$verdict = "FAIL"
if ($complete -and $t21 -match "FABRIC_FWD" -and $t22 -match "FABRIC_RECV" -and $t23 -match "ttl2_ok=true" -and $t21 -match "FABRIC_STATS") {
    $verdict = "PASS"
}

"RESULT cluster done=$done complete=$complete verdict=$verdict"
foreach ($id in @(21, 22, 23, 24)) {
    "===== NODE $id ====="
    $p = Join-Path $data "computer\$id\rpv-log.txt"
    if (Test-Path $p) { Get-Content $p | Where-Object { $_ -match "FABRIC|FWD|RESULTS|TEST_DONE|STATS|SPAWN|SELFTEST|IFACE" } }
}
"===== STDERR ====="
if (Test-Path $stderr) { Get-Content $stderr -Raw }
