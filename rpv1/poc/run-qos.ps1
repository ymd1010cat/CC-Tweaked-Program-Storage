# P2-d acceptance: QoS egress queues (control traffic gets out in front of bulk).
#
#   22 = sender: runs the SAME experiment twice under the same 300-packet bulk flood
#        - phase A with qos off, phase B after enabling qos mid-run
#        and reports retransmits / elapsed for both, plus the QoS counters
#   23 = receiver: echoes UDP 7 (the flood target) and counts the conn transfer
#
#   pwsh -File poc\run-qos.ps1
param([int]$TimeoutSec = 260, [string]$Root = $env:RPV_ROOT)

$root = $Root
if (-not $root) { $root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path) }
$data = Join-Path $root "craftos-qos"
$exe = "C:\Program Files\CraftOS-PC\CraftOS-PC_console.exe"
$bootstrap = Join-Path $root "poc\node2\startup.lua"
$rpvdir = Join-Path $root "poc\rpv"
$appsdir = Join-Path $root "poc\apps"
$compatdir = Join-Path $root "poc\compat"
$out = Join-Path $root "poc\out"
New-Item -ItemType Directory -Force -Path $out | Out-Null
if (Test-Path $data) { Remove-Item -Recurse -Force $data }

$roles = @{}
$roles[22] = "role=host`niface=back|LAN-A|10.0.1.1/24|4401|512|wired`n" +
    "app=qos-selftest:10.0.1.2`nstart_delay=4`nconn_bytes=4000`nflood_packets=120`nconn_mss=400`nconn_rto_min=0.2`n" +
    "qos_budget=16`nqos_budget_bytes=4096`nspawn=23`nstats_at=90`n"
$roles[23] = "role=host`niface=back|LAN-A|10.0.1.2/24|4401|512|wired`n" +
    "app=qos-peer`nexpect_bytes=4000`n"

foreach ($id in @(22, 23)) {
    $dir = Join-Path $data "computer\$id"
    foreach ($sub in @("rpv", "apps", "compat")) { New-Item -ItemType Directory -Force -Path (Join-Path $dir $sub) | Out-Null }
    Copy-Item (Join-Path $rpvdir "*.lua") (Join-Path $dir "rpv") -Force
    Copy-Item (Join-Path $appsdir "*.lua") (Join-Path $dir "apps") -Force
    Copy-Item (Join-Path $compatdir "*.lua") (Join-Path $dir "compat") -Force
    Copy-Item $bootstrap (Join-Path $dir "startup.lua") -Force
    Set-Content -Path (Join-Path $dir "role.txt") -Value $roles[$id] -Encoding ascii
}

$stdout = Join-Path $out "qos.stdout.txt"
$stderr = Join-Path $out "qos.stderr.txt"
$proc = Start-Process -FilePath $exe -ArgumentList @("-d", "`"$data`"", "--headless", "--id", "22") `
    -RedirectStandardOutput $stdout -RedirectStandardError $stderr -PassThru -NoNewWindow

$watchLog = Join-Path $data "computer\22\rpv-log.txt"
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

$logs = @{}
foreach ($id in @(22, 23)) {
    $p = Join-Path $data "computer\$id\rpv-log.txt"
    $logs[$id] = if (Test-Path $p) { Get-Content $p -Raw } else { "" }
    if ($logs[$id]) { Copy-Item $p (Join-Path $out "qos-node$id.log") -Force }
}

$result = ($logs[22] -split "`n" | Where-Object { $_ -match "QOS_RESULT" } | Select-Object -Last 1)
$phaseA = ($logs[22] -split "`n" | Where-Object { $_ -match "QOS_PHASE_A" } | Select-Object -Last 1)
$phaseB = ($logs[22] -split "`n" | Where-Object { $_ -match "QOS_PHASE_B" } | Select-Object -Last 1)
$state = ($logs[22] -split "`n" | Where-Object { $_ -match "QOS_STATE" } | Select-Object -Last 1)
$peer = ($logs[23] -split "`n" | Where-Object { $_ -match "QOS_PEER_RESULT" } | Select-Object -Last 1)

$verdict = "FAIL"
$passMarker = $result -match "pass=true"
# the receiver reports its QoS counters every 5 s: the LAST line is the phase-B state
$peerStates = @($logs[23] -split "`n" | Where-Object { $_ -match "QOS_PEER_STATE" })
$lastState = if ($peerStates.Count) { $peerStates[-1] } else { "" }
$peerOk = $lastState -match "conn_bytes=(8000|[1-9]\d{4,})"
$classified = $lastState -match "high=[1-9]"
$enabled = $logs[23] -match "QOS_ENABLED"     # the receiver is the one that turns it on
if ($done -and $passMarker -and $peerOk -and $classified -and $enabled) { $verdict = "PASS" }

"RESULT qos done=$done verdict=$verdict"
"PHASE_A $($phaseA -replace '^.*QOS_PHASE_A', 'QOS_PHASE_A')"
"PHASE_B $($phaseB -replace '^.*QOS_PHASE_B', 'QOS_PHASE_B')"
"PEER    $($peer -replace '^.*QOS_PEER_RESULT', 'QOS_PEER_RESULT')"
"STATE   $($lastState -replace '^.*QOS_PEER_STATE', 'QOS_PEER_STATE')"
"CHECKS  pass_marker=$passMarker peer_bytes_ok=$peerOk control_classified=$classified"
($logs[22] -split "`n" | Where-Object { $_ -match "QOS_DROP|QOS_START" }) | Select-Object -First 3 | ForEach-Object { "NOTE " + $_.Trim() }
