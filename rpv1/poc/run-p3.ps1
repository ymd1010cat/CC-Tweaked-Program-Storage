# P3 acceptance: selective ACKs, multi-flow fairness, keepalive (and the slow-start
# curve, visible in the CONN_ACK cwnd lines).
#
#   22 = sender  (app=p3-selftest:10.0.1.2)
#   23 = receiver(app=p3-peer), listeners on conn 4400/4401 + UDP 4402 control
#
#   pwsh -File poc\run-p3.ps1
param([int]$TimeoutSec = 300, [string]$Root = $env:RPV_ROOT)

$root = $Root
if (-not $root) { $root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path) }
$data = Join-Path $root "craftos-p3"
$exe = "C:\Program Files\CraftOS-PC\CraftOS-PC_console.exe"
$bootstrap = Join-Path $root "poc\node2\startup.lua"
$rpvdir = Join-Path $root "poc\rpv"
$appsdir = Join-Path $root "poc\apps"
$compatdir = Join-Path $root "poc\compat"
$out = Join-Path $root "poc\out"
New-Item -ItemType Directory -Force -Path $out | Out-Null
if (Test-Path $data) { Remove-Item -Recurse -Force $data }

$roles = @{}
$roles[22] = "role=host`niface=back|LAN-A|10.0.1.1/24|4701|512|wired`n" +
    "app=p3-selftest:10.0.1.2`nstart_delay=4`nconn_mss=200`nconn_rto_min=0.2`nspawn=23`nstats_at=200`n"
$roles[23] = "role=host`niface=back|LAN-A|10.0.1.2/24|4701|512|wired`napp=p3-peer`n"

foreach ($id in @(22, 23)) {
    $dir = Join-Path $data "computer\$id"
    foreach ($sub in @("rpv", "apps", "compat")) { New-Item -ItemType Directory -Force -Path (Join-Path $dir $sub) | Out-Null }
    Copy-Item (Join-Path $rpvdir "*.lua") (Join-Path $dir "rpv") -Force
    Copy-Item (Join-Path $appsdir "*.lua") (Join-Path $dir "apps") -Force
    Copy-Item (Join-Path $compatdir "*.lua") (Join-Path $dir "compat") -Force
    Copy-Item $bootstrap (Join-Path $dir "startup.lua") -Force
    Set-Content -Path (Join-Path $dir "role.txt") -Value $roles[$id] -Encoding ascii
}

$stdout = Join-Path $out "p3.stdout.txt"
$stderr = Join-Path $out "p3.stderr.txt"
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
    if ($logs[$id]) { Copy-Item $p (Join-Path $out "p3-node$id.log") -Force }
}

$result = ($logs[22] -split "`n" | Where-Object { $_ -match "P3_RESULT" } | Select-Object -Last 1)
$sackOff = ($logs[22] -split "`n" | Where-Object { $_ -match "P3_SACK_OFF" } | Select-Object -Last 1)
$sackOn = ($logs[22] -split "`n" | Where-Object { $_ -match "P3_SACK_ON" } | Select-Object -Last 1)
$fairNo = ($logs[22] -split "`n" | Where-Object { $_ -match "P3_FAIR_NO_CAP" } | Select-Object -Last 1)
$fairCap = ($logs[22] -split "`n" | Where-Object { $_ -match "P3_FAIR_CAP" } | Select-Object -Last 1)
$kaAlive = ($logs[22] -split "`n" | Where-Object { $_ -match "P3_KEEPALIVE_ALIVE" } | Select-Object -Last 1)
$kaDead = ($logs[22] -split "`n" | Where-Object { $_ -match "P3_KEEPALIVE_BLACKHOLE" } | Select-Object -Last 1)
$peer = ($logs[23] -split "`n" | Where-Object { $_ -match "P3_PEER_STATE" } | Select-Object -Last 1)

$verdict = "FAIL"
$passMarker = $result -match "pass=true"
$sackEvidence = ($logs[23] -match "CONN_SACK_SENT") -and (($logs[22] -match "CONN_SACK ranges=") -or ($logs[22] -match "CONN_SACK_RETX"))
$kaEvidence = ($logs[22] -match "CONN_KEEPALIVE probe=") -and ($logs[22] -match "CONN_KEEPALIVE_TIMEOUT")
$slowStart = $logs[22] -match "CONN_ACK .*cwnd="        # curve visible in the ACK logs
$peerOk = $logs[23] -match "c4400=([2-9]\d{3,})"
if ($done -and $passMarker -and $sackEvidence -and $kaEvidence -and $slowStart) { $verdict = "PASS" }

"RESULT p3 done=$done verdict=$verdict"
"P3_RESULT   $($result -replace '^.*P3_RESULT', 'P3_RESULT')"
"SACK_OFF    $($sackOff -replace '^.*P3_SACK_OFF', 'P3_SACK_OFF')"
"SACK_ON     $($sackOn -replace '^.*P3_SACK_ON', 'P3_SACK_ON')"
"FAIR_NO_CAP $($fairNo -replace '^.*P3_FAIR_NO_CAP', 'P3_FAIR_NO_CAP')"
"FAIR_CAP    $($fairCap -replace '^.*P3_FAIR_CAP', 'P3_FAIR_CAP')"
"KA_ALIVE    $($kaAlive -replace '^.*P3_KEEPALIVE_ALIVE', 'P3_KEEPALIVE_ALIVE')"
"KA_BLACK    $($kaDead -replace '^.*P3_KEEPALIVE_BLACKHOLE', 'P3_KEEPALIVE_BLACKHOLE')"
"PEER        $($peer -replace '^.*P3_PEER_STATE', 'P3_PEER_STATE')"
"CHECKS pass=$passMarker sack_evidence=$sackEvidence keepalive_evidence=$kaEvidence slow_start_logged=$slowStart"
($logs[22] -split "`n" | Where-Object { $_ -match "CONN_P3 " } | Select-Object -Last 2) | ForEach-Object { "P3STATS " + $_.Trim() }
($logs[22] -split "`n" | Where-Object { $_ -match "CONN_SACK_RETX|CONN_SACK_SENT" } | Select-Object -First 3) | ForEach-Object { "SACK " + $_.Trim() }
