# P1b acceptance: AEAD for the rednet WAN tunnel.
#
#   21 = router A (LAN-A + rednet WAN, advert)      23 = near host 10.0.1.2
#   22 = router B (LAN-B + rednet WAN, advert)      24 = far host  10.0.2.2
#   25 = sniffer/replayer on the WAN (standalone program, no rpv)
#
#   pwsh -File poc\run-wansec.ps1 -Mode plain      baseline: the sniffer MUST see the marker
#   pwsh -File poc\run-wansec.ps1 -Mode secure     AEAD: tunnel works, sniffer sees nothing,
#                                                  and its verbatim replay is rejected
#   pwsh -File poc\run-wansec.ps1 -Mode wrongpsk   mismatched PSK: fail closed, no tunnel
param(
    [ValidateSet("plain", "secure", "wrongpsk")]
    [string]$Mode = "secure",
    [int]$TimeoutSec = 180,
    [string]$Root = $env:RPV_ROOT
)

$root = $Root
if (-not $root) { $root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path) }
$data = Join-Path $root "craftos-wansec-$Mode"
$exe = "C:\Program Files\CraftOS-PC\CraftOS-PC_console.exe"
$bootstrap = Join-Path $root "poc\node2\startup.lua"
$rpvdir = Join-Path $root "poc\rpv"
$appsdir = Join-Path $root "poc\apps"
$compatdir = Join-Path $root "poc\compat"
$out = Join-Path $root "poc\out"
$psk = "00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff"
$pskBad = "ffeeddccbbaa99887766554433221100ffeeddccbbaa99887766554433221100"
New-Item -ItemType Directory -Force -Path $out | Out-Null
if (Test-Path $data) { Remove-Item -Recurse -Force $data }

$secA = if ($Mode -eq "plain") { "" } else { "wan_secure=1`nwan_psk=$psk`nwan_hello_interval=3`n" }
$secB = if ($Mode -eq "plain") { "" } elseif ($Mode -eq "wrongpsk") { "wan_secure=1`nwan_psk=$pskBad`nwan_hello_interval=3`n" } else { "wan_secure=1`nwan_psk=$psk`nwan_hello_interval=3`n" }
$sniffMode = if ($Mode -eq "secure") { "replay" } else { "log" }

$roles = @{}
$roles[21] = "role=router`niface=back|LAN-A|10.0.1.1/24|4501|512|wired`n" +
    "iface=right|WAN|172.16.0.1/24|rednet|512`nadvert=1`n${secA}spawn=22,23,24,25`nstats_at=30`n"
$roles[22] = "role=router`niface=back|LAN-B|10.0.2.1/24|4502|512|wired`n" +
    "iface=right|WAN|172.16.0.2/24|rednet|512`nadvert=1`n${secB}stats_at=30`n"
$roles[23] = "role=host`niface=back|LAN-A|10.0.1.2/24|4501|512|wired`ngw=10.0.1.1`n" +
    "app=wansec-selftest:10.0.2.2`nstart_delay=12`nmarker=RPVSECRET`n"
$roles[24] = "role=host`niface=back|LAN-B|10.0.2.2/24|4502|512|wired`ngw=10.0.2.1`n" +
    "app=wansec-peer`nmarker=RPVSECRET`n"

foreach ($id in @(21, 22, 23, 24)) {
    $dir = Join-Path $data "computer\$id"
    foreach ($sub in @("rpv", "apps", "compat")) { New-Item -ItemType Directory -Force -Path (Join-Path $dir $sub) | Out-Null }
    Copy-Item (Join-Path $rpvdir "*.lua") (Join-Path $dir "rpv") -Force
    Copy-Item (Join-Path $appsdir "*.lua") (Join-Path $dir "apps") -Force
    Copy-Item (Join-Path $compatdir "*.lua") (Join-Path $dir "compat") -Force
    Copy-Item $bootstrap (Join-Path $dir "startup.lua") -Force
    Set-Content -Path (Join-Path $dir "role.txt") -Value $roles[$id] -Encoding ascii
}
# 25 = sniffer: its own standalone startup program (no rpv library on that computer)
$sdir = Join-Path $data "computer\25"
New-Item -ItemType Directory -Force -Path $sdir | Out-Null
Copy-Item (Join-Path $root "poc\wan-sniffer.lua") (Join-Path $sdir "startup.lua") -Force
Set-Content -Path (Join-Path $sdir "sniff.txt") -Encoding ascii -Value @"
sniff_ids=21,22
sniff_mode=$sniffMode
sniff_replay_at=14
sniff_secs=45
sniff_marker=RPVSECRET
"@

$stdout = Join-Path $out "wansec-$Mode.stdout.txt"
$stderr = Join-Path $out "wansec-$Mode.stderr.txt"
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
# give the sniffer time to finish its replay + final report
Start-Sleep -Seconds 8
if (-not $proc.HasExited) { $proc.Kill() }
Start-Sleep -Milliseconds 400

$logs = @{}
foreach ($id in @(21, 22, 23, 24)) {
    $p = Join-Path $data "computer\$id\rpv-log.txt"
    $logs[$id] = if (Test-Path $p) { Get-Content $p -Raw } else { "" }
    if ($logs[$id]) { Copy-Item $p (Join-Path $out "wansec-$Mode-node$id.log") -Force }
}
$sniffPath = Join-Path $data "computer\25\sniff-log.txt"
$sniff = if (Test-Path $sniffPath) { Get-Content $sniffPath -Raw; Copy-Item $sniffPath (Join-Path $out "wansec-$Mode-sniffer.log") -Force } else { "" }

$selftest = $logs[23] -match "WANSEC_SELFTEST_RESULT ping=true marker=true pass=true"
$peerOk = $logs[24] -match "WANSEC_PEER_RESULT markers=[1-9]"
$keysA = $logs[21] -match "WANSEC_KEYS"
$markerVisible = $sniff -match "SNIFF_MARKER_SEEN"
$authFail = ($logs[21] + $logs[22]) -match "WANSEC_AUTH_FAIL"
$replayCaught = ($logs[21] + $logs[22]) -match "WANSEC_REPLAY"
$replayed = $sniff -match "SNIFF_REPLAY_SENT"

$verdict = "FAIL"
if ($Mode -eq "plain") {
    # baseline: end-to-end works and the marker IS visible to an eavesdropper
    if ($selftest -and $peerOk -and $markerVisible) { $verdict = "PASS" }
} elseif ($Mode -eq "secure") {
    if ($selftest -and $peerOk -and $keysA -and (-not $markerVisible) -and $replayCaught) { $verdict = "PASS" }
} else {
    # wrong PSK: nothing gets through, the failure is authenticated, no marker leaks
    if ((-not $selftest) -and $authFail -and (-not $markerVisible)) { $verdict = "PASS" }
}

"RESULT wansec-$Mode done=$done verdict=$verdict"
"END_TO_END=$selftest PEER=$peerOk KEYS=$keysA MARKER_VISIBLE_TO_SNIFFER=$markerVisible AUTH_FAIL=$authFail REPLAY_CAUGHT=$replayCaught REPLAY_SENT=$replayed"
($logs[21] -split "`n" | Where-Object { $_ -match "WANSEC_STATE|WANSEC_KEYS" }) | Select-Object -Last 3 | ForEach-Object { "R21 " + $_.Trim() }
($logs[22] -split "`n" | Where-Object { $_ -match "WANSEC_STATE|WANSEC_AUTH_FAIL" }) | Select-Object -Last 2 | ForEach-Object { "R22 " + $_.Trim() }
($logs[23] -split "`n" | Where-Object { $_ -match "WANSEC_PING |WANSEC_MARKER |WANSEC_SELFTEST_RESULT" }) | Select-Object -First 4 | ForEach-Object { "HOST " + $_.Trim() }
($sniff -split "`n" | Where-Object { $_ -match "SNIFF_RESULT|SNIFF_REPLAY|SNIFF_MARKER|SNIFF_CAPTURED" }) | Select-Object -First 4 | ForEach-Object { "SNIFF " + $_.Trim() }
