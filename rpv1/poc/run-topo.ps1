# P4-d acceptance: topology discovery + network map.
#
#   21 = router LAN-A 10.0.1.1 / LAN-B 10.0.2.1   (dv=1, topo reports)
#   22 = router LAN-B 10.0.2.2 / LAN-C 10.0.3.1   (dv=1, topo reports)
#   23 = collector on LAN-A 10.0.1.2              (topo_collect, dumps the map)
#   24 = host on LAN-C 10.0.3.2     25 = host on LAN-B 10.0.2.3
#
# Every node reports what it knows (its interfaces, its ARP cache, DV/fabric/WAN
# peers, the services it runs) to 10.0.1.2; the collector merges the reports into a
# node/link map. The routers learn the far subnets through DV, which is what turns
# the two LAN-B hosts into a discovered link.
#
#   pwsh -File poc\run-topo.ps1
param([int]$TimeoutSec = 180, [string]$Root = $env:RPV_ROOT)

$root = $Root
if (-not $root) { $root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path) }
$data = Join-Path $root "craftos-topo"
$exe = "C:\Program Files\CraftOS-PC\CraftOS-PC_console.exe"
$bootstrap = Join-Path $root "poc\node2\startup.lua"
$rpvdir = Join-Path $root "poc\rpv"
$appsdir = Join-Path $root "poc\apps"
$compatdir = Join-Path $root "poc\compat"
$out = Join-Path $root "poc\out"
New-Item -ItemType Directory -Force -Path $out | Out-Null
if (Test-Path $data) { Remove-Item -Recurse -Force $data }

$topo = "topo=1`ntopo_server=10.0.1.2`ntopo_interval=3`n"
$roles = @{}
$roles[21] = "role=router`niface=back|LAN-A|10.0.1.1/24|4901|512|wired`n" +
    "iface=left|LAN-B|10.0.2.1/24|4902|512|wired`ndv=1`ndv_interval=2`n${topo}spawn=22,23,24,25`nstats_at=60`n"
$roles[22] = "role=router`niface=back|LAN-B|10.0.2.2/24|4902|512|wired`n" +
    "iface=left|LAN-C|10.0.3.1/24|4903|512|wired`ndv=1`ndv_interval=2`n${topo}stats_at=60`n"
$roles[23] = "role=host`niface=back|LAN-A|10.0.1.2/24|4901|512|wired`ngw=10.0.1.1`n" +
    "${topo}topo_collect=1`ntopo_dump=1`ntopo_dump_every=8`nexpect_nodes=5`n" +
    "app=topo-selftest`nstart_delay=12`nstats_at=60`n"
$roles[24] = "role=host`niface=back|LAN-C|10.0.3.2/24|4903|512|wired`ngw=10.0.3.1`n${topo}stats_at=60`n"
$roles[25] = "role=host`niface=back|LAN-B|10.0.2.3/24|4902|512|wired`ngw=10.0.2.1`n${topo}stats_at=60`n"

foreach ($id in @(21, 22, 23, 24, 25)) {
    $dir = Join-Path $data "computer\$id"
    foreach ($sub in @("rpv", "apps", "compat")) { New-Item -ItemType Directory -Force -Path (Join-Path $dir $sub) | Out-Null }
    Copy-Item (Join-Path $rpvdir "*.lua") (Join-Path $dir "rpv") -Force
    Copy-Item (Join-Path $appsdir "*.lua") (Join-Path $dir "apps") -Force
    Copy-Item (Join-Path $compatdir "*.lua") (Join-Path $dir "compat") -Force
    Copy-Item $bootstrap (Join-Path $dir "startup.lua") -Force
    Set-Content -Path (Join-Path $dir "role.txt") -Value $roles[$id] -Encoding ascii
}

$stdout = Join-Path $out "topo.stdout.txt"
$stderr = Join-Path $out "topo.stderr.txt"
$proc = Start-Process -FilePath $exe -ArgumentList @("-d", "`"$data`"", "--headless", "--id", "21") `
    -RedirectStandardOutput $stdout -RedirectStandardError $stderr -PassThru -NoNewWindow

$watchLog = Join-Path $data "computer\23\rpv-log.txt"
$deadline = (Get-Date).AddSeconds($TimeoutSec)
$done = $false
while ((Get-Date) -lt $deadline) {
    Start-Sleep -Milliseconds 500
    if ($proc.HasExited) { break }
    if (Test-Path $watchLog) { if ((Get-Content $watchLog -Raw) -match "TEST_DONE") { $done = $true; break } }
}
Start-Sleep -Seconds 2
if (-not $proc.HasExited) { $proc.Kill() }
Start-Sleep -Milliseconds 400

$logs = @{}
foreach ($id in @(21, 22, 23, 24, 25)) {
    $p = Join-Path $data "computer\$id\rpv-log.txt"
    $logs[$id] = if (Test-Path $p) { Get-Content $p -Raw } else { "" }
    if ($logs[$id]) { Copy-Item $p (Join-Path $out "topo-node$id.log") -Force }
}
$mapPath = Join-Path $data "computer\23\netmap.txt"
$map = if (Test-Path $mapPath) { Get-Content $mapPath -Raw; Copy-Item $mapPath (Join-Path $out "topo-netmap.txt") -Force } else { "" }

$selftest = ($logs[23] -split "`n" | Where-Object { $_ -match "TOPO_SELFTEST nodes=" } | Select-Object -Last 1)
$nodes5 = $logs[23] -match "TOPO_SELFTEST nodes=5"
$allIds = $true
foreach ($id in @(21, 22, 23, 24, 25)) { if (-not ($map -match "NODE id=$id ")) { $allIds = $false } }
$linkCount = ([regex]::Matches($map, "LINK ")).Count
$beginEnd = ($map -match "NETMAP_BEGIN") -and ($map -match "NETMAP_END")
$reports = ($logs[21] -match "TOPO_SENT") -and ($logs[22] -match "TOPO_SENT") -and ($logs[24] -match "TOPO_SENT")

$verdict = "FAIL"
if ($done -and $nodes5 -and $allIds -and $linkCount -ge 4 -and $beginEnd -and $reports) { $verdict = "PASS" }

"RESULT topo done=$done verdict=$verdict"
"$($selftest -replace '^.*TOPO_SELFTEST', 'TOPO_SELFTEST')"
"CHECKS nodes5=$nodes5 all_ids=$allIds links=$linkCount netmap_framed=$beginEnd reports=$reports"
"===== NETMAP ====="
if ($map) { $map.Trim() } else { "(no netmap.txt)" }
"===== collector TOPO lines ====="
($logs[23] -split "`n" | Where-Object { $_ -match "TOPO_" }) | Select-Object -First 8 | ForEach-Object { "  " + $_.Trim() }
