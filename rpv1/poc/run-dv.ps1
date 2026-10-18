# Dynamic routing (distance-vector) acceptance -- CraftOS-PC.
#
# NO static routes anywhere: the routers must learn every remote subnet from the
# periodic DV announcements, suppress loops (split horizon + poisoned reverse) and
# expire routes that stop being refreshed.
#
#   -Topology ring  : R1-R2-R3 triangle, hostX on LAN-A, hostY on LAN-C
#                     (either 2-hop path is valid; a loop would break the ping)
#   -Topology chain : R1-R2-R3-R4 line, hosts at both ends (metric grows per hop)
#
#   pwsh -File poc\run-dv.ps1 [-Topology ring|chain]
param(
    [ValidateSet("ring", "chain")]
    [string]$Topology = "ring",
    [int]$TimeoutSec = 150,
    [string]$Root = $env:RPV_ROOT
)

$root = $Root
if (-not $root) { $root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path) }
$data = Join-Path $root "craftos-dv-$Topology"
$exe = "C:\Program Files\CraftOS-PC\CraftOS-PC_console.exe"
$bootstrap = Join-Path $root "poc\node2\startup.lua"
$rpvdir = Join-Path $root "poc\rpv"
$appsdir = Join-Path $root "poc\apps"
$compatdir = Join-Path $root "poc\compat"
$out = Join-Path $root "poc\out"
New-Item -ItemType Directory -Force -Path $out | Out-Null
if (Test-Path $data) { Remove-Item -Recurse -Force $data }

# channel plan: LAN-A 4101, LAN-B 4102, LAN-C 4103, LAN-D 4104
$dv = "dv=1`ndv_interval=2`ndv_timeout=8`n"
$roles = @{}
$computers = @()
$hostA = 25
$hostY = 26
$routerIds = @()

if ($Topology -eq "ring") {
    # R1: LAN-A + LAN-B   R2: LAN-B + LAN-C   R3: LAN-C + LAN-A
    $routerIds = @(21, 22, 23)
    $roles[21] = "role=router`niface=back|LAN-A|10.0.1.1/24|4101|256|wired`niface=left|LAN-B|10.0.2.1/24|4102|256|wired`n${dv}dv_debug=1`nspawn=22,23,$hostA,$hostY`nstats_at=25`n"
    $roles[22] = "role=router`niface=back|LAN-B|10.0.2.2/24|4102|256|wired`niface=left|LAN-C|10.0.3.1/24|4103|256|wired`n${dv}stats_at=25`n"
    $roles[23] = "role=router`niface=back|LAN-C|10.0.3.2/24|4103|256|wired`niface=left|LAN-A|10.0.1.3/24|4101|256|wired`n${dv}stats_at=25`n"
} else {
    # chain: R1 .. R4, one subnet per hop. Two-level spawning (R1 opens the other
    # routers, R2 opens the hosts) keeps CraftOS-PC from racing on its BIOS load.
    $routerIds = @(21, 22, 23, 24)
    $roles[21] = "role=router`niface=back|LAN-A|10.0.1.1/24|4101|256|wired`niface=left|LAN-B|10.0.2.1/24|4102|256|wired`n${dv}dv_debug=1`nspawn=22,23,24`nstats_at=25`n"
    $roles[22] = "role=router`niface=back|LAN-B|10.0.2.2/24|4102|256|wired`niface=left|LAN-C|10.0.3.1/24|4103|256|wired`n${dv}spawn=$hostA,$hostY`nstats_at=25`n"
    $roles[23] = "role=router`niface=back|LAN-C|10.0.3.2/24|4103|256|wired`niface=left|LAN-D|10.0.4.1/24|4104|256|wired`n${dv}stats_at=25`n"
    $roles[24] = "role=router`niface=back|LAN-D|10.0.4.2/24|4104|256|wired`n${dv}stats_at=25`n"
}

$hostALan = if ($Topology -eq "ring") { 4101 } else { 4101 }
$hostAGw = if ($Topology -eq "ring") { "10.0.1.1" } else { "10.0.1.1" }
$hostYIface = if ($Topology -eq "ring") { "iface=back|LAN-C|10.0.3.3/24|4103|256|wired`ngw=10.0.3.1`n" } else { "iface=back|LAN-D|10.0.4.3/24|4104|256|wired`ngw=10.0.4.2`n" }
$hostYAddr = if ($Topology -eq "ring") { "10.0.3.3" } else { "10.0.4.3" }
$roles[$hostA] = "role=host`niface=back|LAN-A|10.0.1.2/24|$hostALan|256|wired`ngw=$hostAGw`napp=rpv-selftest:$hostYAddr`nstart_delay=12`nlarge_bytes=2000`nprobe_ttl=8`nexpect_pings=4`nexpect_ttl2=0`nexpect_ttl_exceeded=0`n"
$roles[$hostY] = "role=host`n${hostYIface}app=udp-echo:7`n"

foreach ($id in $routerIds + @($hostA, $hostY)) {
    $dir = Join-Path $data "computer\$id"
    foreach ($sub in @("rpv", "apps", "compat")) { New-Item -ItemType Directory -Force -Path (Join-Path $dir $sub) | Out-Null }
    Copy-Item (Join-Path $rpvdir "*.lua") (Join-Path $dir "rpv") -Force
    Copy-Item (Join-Path $appsdir "*.lua") (Join-Path $dir "apps") -Force
    Copy-Item (Join-Path $compatdir "*.lua") (Join-Path $dir "compat") -Force
    Copy-Item $bootstrap (Join-Path $dir "startup.lua") -Force
    Set-Content -Path (Join-Path $dir "role.txt") -Value $roles[$id] -Encoding ascii
}

$stdout = Join-Path $out "dv-$Topology.stdout.txt"
$stderr = Join-Path $out "dv-$Topology.stderr.txt"
$proc = Start-Process -FilePath $exe -ArgumentList @("-d", "`"$data`"", "--headless", "--id", "$($routerIds[0])") `
    -RedirectStandardOutput $stdout -RedirectStandardError $stderr -PassThru -NoNewWindow

$watchLog = Join-Path $data "computer\$hostA\rpv-log.txt"
$deadline = (Get-Date).AddSeconds($TimeoutSec)
$done = $false
while ((Get-Date) -lt $deadline) {
    Start-Sleep -Milliseconds 500
    if ($proc.HasExited) { break }
    if (Test-Path $watchLog) { if ((Get-Content $watchLog -Raw) -match "TEST_DONE") { $done = $true; break } }
}
Start-Sleep -Seconds 1
if (-not $proc.HasExited) { $proc.Kill() }
Start-Sleep -Milliseconds 400

foreach ($id in $routerIds + @($hostA, $hostY)) {
    $src = Join-Path $data "computer\$id\rpv-log.txt"
    if (Test-Path $src) { Copy-Item $src (Join-Path $out "dv-$Topology-node$id.log") -Force }
}

$logs = @{}
foreach ($id in $routerIds + @($hostA, $hostY)) {
    $p = Join-Path $data "computer\$id\rpv-log.txt"
    $logs[$id] = if (Test-Path $p) { Get-Content $p -Raw } else { "" }
}

# every router must have learned the far subnets (no static routes were configured)
$installs = 0
foreach ($id in $routerIds) { $installs += ([regex]::Matches($logs[$id], "DV_INSTALL")).Count }
$hostOk = ($logs[$hostA] -match "complete=true") -and ($logs[$hostA] -match "large_reply_ok=true")
$noStatic = $true
foreach ($id in $routerIds) { if ($logs[$id] -match "ROUTES_RELOADED") { $noStatic = $false } }
$loops = 0
foreach ($id in $routerIds) { $loops += ([regex]::Matches($logs[$id], "ttl_drop=[1-9]")).Count }

$expectMetric = if ($Topology -eq "ring") { 1 } else { 3 }
$metricSeen = $false
foreach ($id in $routerIds) { if ($logs[$id] -match "DV_ROUTE .* metric=$expectMetric ") { $metricSeen = $true } }

$verdict = "FAIL"
if ($installs -gt 0 -and $hostOk -and $noStatic -and $metricSeen -and $loops -eq 0) { $verdict = "PASS" }

"RESULT dv topology=$Topology done=$done verdict=$verdict"
"DV_INSTALLS $installs"
"HOST_END_TO_END $hostOk"
"NO_STATIC_ROUTES $noStatic"
"METRIC_$expectMetric $metricSeen"
"TTL_LOOP_SIGNS $loops"
"===== routers ====="
foreach ($id in $routerIds) {
    "--- node $id ---"
    if ($logs[$id]) { Get-Content (Join-Path $data "computer\$id\rpv-log.txt") | Where-Object { $_ -match "DV_|ROUTES_|NO_ROUTE" } | Select-Object -First 12 }
}
"===== host $hostA ====="
if ($logs[$hostA]) { Get-Content $watchLog | Where-Object { $_ -match "SELFTEST_PING_REPLY|SELFTEST_LARGE_REPLY|RESULTS|NO_ROUTE" } | Select-Object -First 6 }
