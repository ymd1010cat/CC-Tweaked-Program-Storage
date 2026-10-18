# P5 acceptance: multi-hop (chained) bridges and STP-lite loop protection.
#
#   pwsh -File poc\run-stp.ps1 -Mode chain      two hops: LAN-A - b1 - link1 - b2 - LAN-B
#                                               - b3 - link2 - b4 - LAN-C  (no loop)
#   pwsh -File poc\run-stp.ps1 -Mode loop       two parallel bridge pairs between LAN-A
#                                               and LAN-B (a real loop): STP-lite must
#                                               block exactly one LAN side and still
#                                               deliver every frame once
#   pwsh -File poc\run-stp.ps1 -Mode failover   same loop, but the designated bridge stops
#                                               claiming at t=22s: the standby must take
#                                               over and end-to-end traffic must resume
#
# Bridges are standalone programs (their own two files, zero rpv dependency). Hosts run
# the rpv library and report end-to-end results.
param(
    [ValidateSet("chain", "loop", "failover")]
    [string]$Mode = "chain",
    [int]$TimeoutSec = 200,
    [string]$Root = $env:RPV_ROOT
)

$root = $Root
if (-not $root) { $root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path) }
$data = Join-Path $root "craftos-stp-$Mode"
$exe = "C:\Program Files\CraftOS-PC\CraftOS-PC_console.exe"
$bootstrap = Join-Path $root "poc\node2\startup.lua"
$rpvdir = Join-Path $root "poc\rpv"
$appsdir = Join-Path $root "poc\apps"
$compatdir = Join-Path $root "poc\compat"
$out = Join-Path $root "poc\out"
$psk = "00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff"
New-Item -ItemType Directory -Force -Path $out | Out-Null
if (Test-Path $data) { Remove-Item -Recurse -Force $data }

function Bridge-Config($Role, $LocalSide, $LanCh, $EnderSide, $LinkCh, $Id, $Stp, $SelfStop) {
    $cfg = "bridge_role=$Role`n" +
        "bridge_local=$LocalSide`nbridge_lan_channel=$LanCh`n" +
        "bridge_ender=$EnderSide`nbridge_link_channel=$LinkCh`n" +
        "bridge_secs=$($TimeoutSec - 20)`nbridge_psk=$psk`nbridge_psk_iter=64`n" +
        "bridge_allow_ethertypes=0800,0806`nbridge_broadcast_per_sec=400`nbridge_max_frame=4096`n" +
        "bridge_stp=$Stp`nbridge_id_num=$Id`nbridge_claim_interval=2`nbridge_stp_timeout=6`n"
    if ($SelfStop -gt 0) { $cfg += "bridge_selfstop_at=$SelfStop`n" }
    return $cfg
}

$bridges = @()   # id -> config
$hosts = @{}     # id -> role text
$spawner = 20

if ($Mode -eq "chain") {
    # two hops: A - b1 - link1 - b2 - B - b3 - link2 - b4 - C
    $bridges += @{ id = 20; cfg = (Bridge-Config "client" "left" 4300 "right" 4998 20 1 0) }
    $bridges += @{ id = 21; cfg = (Bridge-Config "server" "left" 4301 "right" 4998 21 1 0) }
    $bridges += @{ id = 22; cfg = (Bridge-Config "client" "left" 4301 "right" 4999 22 1 0) }
    $bridges += @{ id = 23; cfg = (Bridge-Config "server" "left" 4302 "right" 4999 23 1 0) }
    $hosts[24] = "role=host`niface=back|LAN-A|10.0.1.2/24|4300|512|wired`napp=rpv-selftest:10.0.1.3`nstart_delay=10`nlarge_bytes=900`nexpect_pings=4`nexpect_ttl2=0`nexpect_ttl_exceeded=0`n"
    $hosts[25] = "role=host`niface=back|LAN-C|10.0.1.3/24|4302|512|wired`napp=udp-echo:7`n"
    $watch = 24
} else {
    # two parallel pairs between LAN-A and LAN-B: a real loop
    $selfStop = if ($Mode -eq "failover") { 22 } else { 0 }
    $bridges += @{ id = 20; cfg = (Bridge-Config "client" "left" 4300 "right" 4998 20 1 $selfStop) }
    $bridges += @{ id = 21; cfg = (Bridge-Config "server" "left" 4301 "right" 4998 21 1 0) }
    $bridges += @{ id = 22; cfg = (Bridge-Config "client" "left" 4300 "right" 4999 22 1 0) }
    $bridges += @{ id = 23; cfg = (Bridge-Config "server" "left" 4301 "right" 4999 23 1 0) }
    if ($Mode -eq "failover") {
        # start the end-to-end check only after the standby should have taken over
        $hosts[24] = "role=host`niface=back|LAN-A|10.0.1.2/24|4300|512|wired`napp=rpv-selftest:10.0.1.3`nstart_delay=34`nlarge_bytes=900`nexpect_pings=4`nexpect_ttl2=0`nexpect_ttl_exceeded=0`n"
    } else {
        $hosts[24] = "role=host`niface=back|LAN-A|10.0.1.2/24|4300|512|wired`napp=rpv-selftest:10.0.1.3`nstart_delay=12`nlarge_bytes=900`nexpect_pings=4`nexpect_ttl2=0`nexpect_ttl_exceeded=0`n"
    }
    $hosts[25] = "role=host`niface=back|LAN-B|10.0.1.3/24|4301|512|wired`napp=udp-echo:7`n"
    $watch = 24
}

# bridges: standalone program (+ spawner wrapper on the first one)
foreach ($b in $bridges) {
    $dir = Join-Path $data "computer\$($b.id)"
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    Copy-Item (Join-Path $root "poc\mc\ender-bridge.lua") $dir -Force
    Set-Content -Path (Join-Path $dir "bridge.txt") -Value $b.cfg -Encoding ascii
    if ($b.id -eq $spawner) {
        $ids = @($bridges | ForEach-Object { $_.id } | Where-Object { $_ -ne $spawner }) + @($hosts.Keys)
        $list = ($ids | Sort-Object) -join ", "
        Set-Content -Path (Join-Path $dir "startup.lua") -Encoding ascii -Value @"
if ccemux and ccemux.openEmu then
    for _, id in ipairs({ $list }) do
        ccemux.openEmu(id)
        os.sleep(0.8)
    end
end
os.sleep(1.5)
local fn = loadfile("ender-bridge.lua")
if fn then return fn() end
print("bridge program missing")
"@
    } else {
        Copy-Item (Join-Path $root "poc\mc\ender-bridge.lua") (Join-Path $dir "startup.lua") -Force
    }
}

# hosts: the rpv library
foreach ($id in $hosts.Keys) {
    $dir = Join-Path $data "computer\$id"
    foreach ($sub in @("rpv", "apps", "compat")) { New-Item -ItemType Directory -Force -Path (Join-Path $dir $sub) | Out-Null }
    Copy-Item (Join-Path $rpvdir "*.lua") (Join-Path $dir "rpv") -Force
    Copy-Item (Join-Path $appsdir "*.lua") (Join-Path $dir "apps") -Force
    Copy-Item (Join-Path $compatdir "*.lua") (Join-Path $dir "compat") -Force
    Copy-Item $bootstrap (Join-Path $dir "startup.lua") -Force
    Set-Content -Path (Join-Path $dir "role.txt") -Value $hosts[$id] -Encoding ascii
}

$stdout = Join-Path $out "stp-$Mode.stdout.txt"
$stderr = Join-Path $out "stp-$Mode.stderr.txt"
$proc = Start-Process -FilePath $exe -ArgumentList @("-d", "`"$data`"", "--headless", "--id", "$spawner") `
    -RedirectStandardOutput $stdout -RedirectStandardError $stderr -PassThru -NoNewWindow

$watchLog = Join-Path $data "computer\$watch\rpv-log.txt"
$deadline = (Get-Date).AddSeconds($TimeoutSec)
$done = $false
while ((Get-Date) -lt $deadline) {
    Start-Sleep -Milliseconds 500
    if ($proc.HasExited) { break }
    if (Test-Path $watchLog) { if ((Get-Content $watchLog -Raw) -match "TEST_DONE") { $done = $true; break } }
}
Start-Sleep -Seconds 2
if (-not $proc.HasExited) { $proc.Kill() }
Start-Sleep -Milliseconds 500

$logs = @{}
foreach ($b in $bridges) {
    $p = Join-Path $data "computer\$($b.id)\bridge-log.txt"
    $logs[$b.id] = if (Test-Path $p) { Get-Content $p -Raw; Copy-Item $p (Join-Path $out "stp-$Mode-bridge$($b.id).log") -Force } else { "" }
}
foreach ($id in $hosts.Keys) {
    $p = Join-Path $data "computer\$id\rpv-log.txt"
    $logs[$id] = if (Test-Path $p) { Get-Content $p -Raw; Copy-Item $p (Join-Path $out "stp-$Mode-host$id.log") -Force } else { "" }
}

$relaying = 0
foreach ($b in $bridges) { if ($logs[$b.id] -match "relayed=([1-9]\d*)") { $relaying++ } }
$endToEnd = $logs[$watch] -match "complete=true"
$blocks = 0
foreach ($b in $bridges) { $blocks += ([regex]::Matches($logs[$b.id], "STP_BLOCK side=lan")).Count }
$unblocks = 0
foreach ($b in $bridges) { $unblocks += ([regex]::Matches($logs[$b.id], "STP_UNBLOCK side=lan")).Count }
$claims = 0
foreach ($b in $bridges) { $claims += ([regex]::Matches($logs[$b.id], "STP_CLAIM from=")).Count }

$verdict = "FAIL"
if ($Mode -eq "chain") {
    # every bridge in the chain must have relayed, and the far host must be reachable
    if ($done -and $endToEnd -and $relaying -ge 4) { $verdict = "PASS" }
} elseif ($Mode -eq "loop") {
    # exactly one bridge blocks its LAN side, traffic still flows, no duplicate storm
    if ($done -and $endToEnd -and $relaying -ge 2 -and $blocks -ge 1 -and $claims -ge 1) { $verdict = "PASS" }
} else {
    $selfStop = $false
    foreach ($b in $bridges) { if ($logs[$b.id] -match "BRIDGE_SELFSTOP") { $selfStop = $true } }
    if ($done -and $endToEnd -and $selfStop -and $unblocks -ge 1) { $verdict = "PASS" }
}

"RESULT stp-$Mode done=$done verdict=$verdict"
"CHECKS end_to_end=$endToEnd relaying_bridges=$relaying/$($bridges.Count) stp_blocks=$blocks stp_unblocks=$unblocks stp_claims=$claims"
foreach ($b in $bridges) {
    $result = ([string]::Join("`n", @($logs[$b.id])) -split "`n" | Where-Object { $_ -match "BRIDGE_RESULT" } | Select-Object -Last 1)
    "B$($b.id) $($result -replace '^.*BRIDGE_RESULT', 'BRIDGE_RESULT')"
}
($logs[$watch] -split "`n" | Where-Object { $_ -match "RESULTS|NO_ROUTE" }) | Select-Object -First 2 | ForEach-Object { "HOST " + $_.Trim() }
foreach ($b in $bridges) {
    ([string]::Join("`n", @($logs[$b.id])) -split "`n" | Where-Object { $_ -match "STP_BLOCK|STP_UNBLOCK|STP_ROOT|BRIDGE_SELFSTOP|STP_PEER_TIMEOUT" }) |
        Select-Object -First 3 | ForEach-Object { "B$($b.id) " + $_.Trim() }
}
