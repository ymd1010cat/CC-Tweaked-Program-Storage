# P5-c acceptance (data plane): load across a multi-router mesh.
#
#   21 = router R1 (LAN-A + LAN-B)   22 = router R2 (LAN-B + LAN-C)
#   23 = router R3 (LAN-C + LAN-A)   <- the triangle gives every pair two paths
#   24 = near host 10.0.1.2 (app=mesh-load:10.0.3.2, 4 concurrent conn flows)
#   25 = far host  10.0.3.2 (app=mesh-peer)
#
# All three routers run DV, so the shortest path (2 hops through R3) is chosen while
# the redundant paths stay available. During the transfer the near host keeps pinging
# the far host: data plane and control plane are loaded at the same time.
#
#   pwsh -File poc\run-mesh.ps1
param([int]$TimeoutSec = 220, [string]$Root = $env:RPV_ROOT)

$root = $Root
if (-not $root) { $root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path) }
$data = Join-Path $root "craftos-mesh"
$exe = "C:\Program Files\CraftOS-PC\CraftOS-PC_console.exe"
$bootstrap = Join-Path $root "poc\node2\startup.lua"
$rpvdir = Join-Path $root "poc\rpv"
$appsdir = Join-Path $root "poc\apps"
$compatdir = Join-Path $root "poc\compat"
$out = Join-Path $root "poc\out"
New-Item -ItemType Directory -Force -Path $out | Out-Null
if (Test-Path $data) { Remove-Item -Recurse -Force $data }

$dv = "dv=1`ndv_interval=2`ndv_timeout=8`n"
$flows = 4
$perFlow = 1500
$roles = @{}
$roles[21] = "role=router`niface=back|LAN-A|10.0.1.1/24|5101|512|wired`n" +
    "iface=left|LAN-B|10.0.2.1/24|5102|512|wired`n${dv}spawn=22,23,24,25`nstats_at=90`n"
$roles[22] = "role=router`niface=back|LAN-B|10.0.2.2/24|5102|512|wired`n" +
    "iface=left|LAN-C|10.0.3.1/24|5103|512|wired`n${dv}stats_at=90`n"
$roles[23] = "role=router`niface=back|LAN-C|10.0.3.3/24|5103|512|wired`n" +
    "iface=left|LAN-A|10.0.1.3/24|5101|512|wired`n${dv}stats_at=90`n"
$roles[24] = "role=host`niface=back|LAN-A|10.0.1.2/24|5101|512|wired`ngw=10.0.1.1`n" +
    "app=mesh-load:10.0.3.2`nflows=$flows`nconn_bytes=$perFlow`nbase_port=4400`nstart_delay=14`nstats_at=90`n"
$roles[25] = "role=host`niface=back|LAN-C|10.0.3.2/24|5103|512|wired`ngw=10.0.3.3`n" +
    "app=mesh-peer`nflows=$flows`nbase_port=4400`nexpect_per_flow=$perFlow`nstats_at=90`n"

foreach ($id in @(21, 22, 23, 24, 25)) {
    $dir = Join-Path $data "computer\$id"
    foreach ($sub in @("rpv", "apps", "compat")) { New-Item -ItemType Directory -Force -Path (Join-Path $dir $sub) | Out-Null }
    Copy-Item (Join-Path $rpvdir "*.lua") (Join-Path $dir "rpv") -Force
    Copy-Item (Join-Path $appsdir "*.lua") (Join-Path $dir "apps") -Force
    Copy-Item (Join-Path $compatdir "*.lua") (Join-Path $dir "compat") -Force
    Copy-Item $bootstrap (Join-Path $dir "startup.lua") -Force
    Set-Content -Path (Join-Path $dir "role.txt") -Value $roles[$id] -Encoding ascii
}

$stdout = Join-Path $out "mesh.stdout.txt"
$stderr = Join-Path $out "mesh.stderr.txt"
$proc = Start-Process -FilePath $exe -ArgumentList @("-d", "`"$data`"", "--headless", "--id", "21") `
    -RedirectStandardOutput $stdout -RedirectStandardError $stderr -PassThru -NoNewWindow

$watchLog = Join-Path $data "computer\24\rpv-log.txt"
$peerLog = Join-Path $data "computer\25\rpv-log.txt"
$deadline = (Get-Date).AddSeconds($TimeoutSec)
$done = $false
while ((Get-Date) -lt $deadline) {
    Start-Sleep -Milliseconds 500
    if ($proc.HasExited) { break }
    if (Test-Path $watchLog) { if ((Get-Content $watchLog -Raw) -match "TEST_DONE") { $done = $true; break } }
}
Start-Sleep -Seconds 6
if (-not $proc.HasExited) { $proc.Kill() }
Start-Sleep -Milliseconds 500

$logs = @{}
foreach ($id in @(21, 22, 23, 24, 25)) {
    $p = Join-Path $data "computer\$id\rpv-log.txt"
    $logs[$id] = if (Test-Path $p) { Get-Content $p -Raw; Copy-Item $p (Join-Path $out "mesh-node$id.log") -Force } else { "" }
}

$result = ($logs[24] -split "`n" | Where-Object { $_ -match "MESH_RESULT" } | Select-Object -Last 1)
$verdictLine = ($logs[24] -split "`n" | Where-Object { $_ -match "MESH_VERDICT" } | Select-Object -Last 1)
$peer = ($logs[25] -split "`n" | Where-Object { $_ -match "MESH_PEER_RESULT" } | Select-Object -Last 1)

$flowsComplete = $verdictLine -match "flows_complete=true"
$bytesOk = $verdictLine -match "bytes_ok=true"
$peerComplete = $peer -match "complete=true"
# control plane under load: every router learned the remote subnets and no packet looped
$learned = 0
foreach ($id in @(21, 22, 23)) { if ($logs[$id] -match "DV_INSTALL|DV_UPDATE") { $learned++ } }
$loops = 0
foreach ($id in @(21, 22, 23)) { $loops += ([regex]::Matches($logs[$id], "ttl_drop=[1-9]")).Count }
$goodput = 0
if ($result -match "goodput_bps=([\d\.]+)") { $goodput = [double]$Matches[1] }

$verdict = "FAIL"
if ($done -and $flowsComplete -and $bytesOk -and $peerComplete -and $learned -eq 3 -and $loops -eq 0) { $verdict = "PASS" }

"RESULT mesh done=$done verdict=$verdict"
"$($result -replace '^.*MESH_RESULT', 'MESH_RESULT')"
"$($peer -replace '^.*MESH_PEER_RESULT', 'MESH_PEER_RESULT')"
"CHECKS flows_complete=$flowsComplete bytes_ok=$bytesOk peer_complete=$peerComplete routers_learned=$learned/3 ttl_loop_signs=$loops goodput_bps=$([int]$goodput)"
($logs[24] -split "`n" | Where-Object { $_ -match "MESH_VERDICT|CONN_STATS" }) | Select-Object -Last 2 | ForEach-Object { "HOST " + $_.Trim() }
foreach ($id in @(21, 22, 23)) {
    ($logs[$id] -split "`n" | Where-Object { $_ -match "DV_STATE" }) | Select-Object -Last 1 | ForEach-Object { "R$id " + $_.Trim() }
}
