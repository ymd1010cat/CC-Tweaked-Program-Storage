# M2 hardening acceptance: PMTU/DF, advert sequence + loop protection,
# fabric frame fragmentation, channel namespace arbitration.
#
#   pmtu       21 router (LAN-A mtu 256, LAN-B mtu 128), 22 client (df_probe=1),
#              23 echo host -> 900 B with DF=1 gets ICMP frag-needed (mtu 128),
#              the client retries small and succeeds
#   advert     21 gateway A (advert_default=1), 22 gateway B (no gw -> learns a
#              WAN default route), 23 spoofing node (dup seq + 9 hops)
#   fabricfrag 21/22 cluster members with a deliberately small fabric MTU (128)
#              -> a 900 B payload must be fragmented across the fabric
#   channels   21 with a LAN iface, a fabric and a rednet WAN all on side "left"
#              -> CHANNEL_CONFLICT lines + CHANNEL_AUDIT
param(
    [string]$Scenario = "pmtu",
    [int]$TimeoutSec = 150,
    [string]$Root = $env:RPV_ROOT
)

$root = $Root
if (-not $root) { $root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path) }
$data = Join-Path $root "craftos-m2-$Scenario"
$exe = "C:\Program Files\CraftOS-PC\CraftOS-PC_console.exe"
$bootstrap = Join-Path $root "poc\node2\startup.lua"
$rpvdir = Join-Path $root "poc\rpv"
$appsdir = Join-Path $root "poc\apps"
$compatdir = Join-Path $root "poc\compat"

if (Test-Path $data) { Remove-Item -Recurse -Force $data }
New-Item -ItemType Directory -Force -Path $data | Out-Null

$roles = @{}
$watch = 21
if ($Scenario -eq "pmtu") {
    $roles[21] = "role=router`niface=back|LAN-A|10.0.1.1/24|4001|256|wired`niface=left|LAN-B|10.0.2.1/24|4002|128|wired`nspawn=22,23`nstats_at=14`n"
    $roles[22] = "role=host`niface=back|LAN-A|10.0.1.2/24|4001|256|wired`ngw=10.0.1.1`napp=rpv-selftest:10.0.2.2`nstart_delay=3`nlarge_bytes=900`ndf_probe=1`ndf_probe_bytes=200`npmtu_retry_bytes=88`nexpect_pings=4`nexpect_ttl2=1`nexpect_ttl_exceeded=1`n"
    $roles[23] = "role=host`niface=back|LAN-B|10.0.2.2/24|4002|256|wired`ngw=10.0.2.1`napp=udp-echo:7`n"
    $watch = 22
    $ids = @(21, 22, 23)
} elseif ($Scenario -eq "advert") {
    $roles[21] = "role=router`niface=back|LAN|10.0.1.1/24|4001|256|wired`niface=right|WAN|172.16.0.1/24|rednet|256`nadvert=1`nadvert_default=1`nrpv_host=gw-a`nspawn=22,23`nstats_at=12`n"
    $roles[22] = "role=router`niface=back|LAN|10.0.2.1/24|4002|256|wired`niface=right|WAN|172.16.0.2/24|rednet|256`nadvert=1`nstats_at=12`n"
    $roles[23] = "role=host`niface=back|LAN|10.0.1.3/24|4001|256|wired`ngw=10.0.1.1`nwan_side=back`napp=advert-spoof:172.16.0.99:99:5`n"
    $watch = 23
    $ids = @(21, 22, 23)
} elseif ($Scenario -eq "fabricfrag") {
    $roles[21] = "role=router`niface=back|LAN-A|10.0.1.1/24|4001|256|wired`nfabric=left|5000|128`nspawn=22,23,24`nstats_at=8`n"
    $roles[22] = "role=router`niface=back|LAN-B|10.0.2.1/24|4002|256|wired`nfabric=left|5000|128`nstats_at=8`n"
    $roles[23] = "role=host`niface=back|LAN-A|10.0.1.2/24|4001|256|wired`ngw=10.0.1.1`napp=rpv-selftest:10.0.2.2`nstart_delay=3`nlarge_bytes=900`nexpect_pings=4`nexpect_ttl2=1`nexpect_ttl_exceeded=1`n"
    $roles[24] = "role=host`niface=back|LAN-B|10.0.2.2/24|4002|256|wired`ngw=10.0.2.1`napp=udp-echo:7`n"
    $watch = 23
    $ids = @(21, 22, 23, 24)
} else {
    $roles[21] = "role=router`niface=back|LAN-A|10.0.1.1/24|4001|256|wired`niface=left|LAN-B|10.0.2.1/24|21|256|wired`niface=left|WAN|172.16.0.1/24|rednet|256`nfabric=left|21|1024`nstats_at=6`n"
    $ids = @(21)
}

foreach ($id in $ids) {
    $dir = Join-Path $data "computer\$id"
    foreach ($sub in @("rpv", "apps", "compat")) { New-Item -ItemType Directory -Force -Path (Join-Path $dir $sub) | Out-Null }
    Copy-Item (Join-Path $rpvdir "*.lua") (Join-Path $dir "rpv") -Force
    Copy-Item (Join-Path $appsdir "*.lua") (Join-Path $dir "apps") -Force
    Copy-Item (Join-Path $compatdir "*.lua") (Join-Path $dir "compat") -Force
    Copy-Item $bootstrap (Join-Path $dir "startup.lua") -Force
    Set-Content -Path (Join-Path $dir "role.txt") -Value $roles[$id] -Encoding ascii
}

New-Item -ItemType Directory -Force -Path (Join-Path $root "poc\out") | Out-Null
$stdout = Join-Path $root "poc\out\m2-$Scenario.stdout.txt"
$stderr = Join-Path $root "poc\out\m2-$Scenario.stderr.txt"
$proc = Start-Process -FilePath $exe -ArgumentList @("-d", "`"$data`"", "--headless", "--id", "21") `
    -RedirectStandardOutput $stdout -RedirectStandardError $stderr -PassThru -NoNewWindow

$watchLog = Join-Path $data "computer\$watch\rpv-log.txt"
$deadline = (Get-Date).AddSeconds($TimeoutSec)
$done = $false
while ((Get-Date) -lt $deadline) {
    Start-Sleep -Milliseconds 400
    if ($proc.HasExited) { break }
    if (Test-Path $watchLog) { if ((Get-Content $watchLog -Raw) -match "TEST_DONE") { $done = $true; break } }
}
Start-Sleep -Milliseconds 2500
if (-not $done -and (Test-Path $watchLog)) { if ((Get-Content $watchLog -Raw) -match "TEST_DONE") { $done = $true } }
if (-not $proc.HasExited) { $proc.Kill() }
Start-Sleep -Milliseconds 300

$texts = @{}
foreach ($id in $ids) {
    $src = Join-Path $data "computer\$id\rpv-log.txt"
    if (Test-Path $src) {
        Copy-Item $src (Join-Path $root "poc\out\m2-$Scenario-node$id.log") -Force
        $texts[$id] = Get-Content $src -Raw
    } else { $texts[$id] = "" }
}

$verdict = "FAIL"
if ($Scenario -eq "pmtu") {
    if ($texts[22] -match "pmtu_ok=true" -and $texts[22] -match "complete=true" -and
        $texts[22] -match "SELFTEST_FRAG_NEEDED" -and $texts[21] -match "PMTU_NEEDED" -and
        $texts[22] -match "PMTU_UPDATE dst=10.0.2.2 mtu=128") { $verdict = "PASS" }
} elseif ($Scenario -eq "advert") {
    if ($texts[21] -match "WAN_ADVERT_STALE gw=99" -and $texts[21] -match "WAN_ADVERT_LOOP gw=99 hops=9" -and
        $texts[22] -match "WAN_DEFAULT_ROUTE gw=21" -and $texts[21] -match "WAN_ADVERT_RECV gw=99") { $verdict = "PASS" }
} elseif ($Scenario -eq "fabricfrag") {
    if ($texts[23] -match "complete=true" -and $texts[21] -match "FABRIC_FRAG_TX" -and
        $texts[22] -match "FABRIC_FRAG_RX" -and $texts[22] -match "FRAGMENTED") { $verdict = "PASS" }
} else {
    if ($texts[21] -match "CHANNEL_CONFLICT fabric_bcast=21 collides with LAN iface on left" -and
        $texts[21] -match "CHANNEL_CONFLICT fabric_ucast=21 collides with LAN iface on left" -and
        $texts[21] -match "CHANNEL_CONFLICT fabric and rednet WAN share side=left" -and
        $texts[21] -match "CHANNEL_AUDIT conflicts=3") { $verdict = "PASS" }
}

"RESULT m2-$Scenario done=$done verdict=$verdict"
foreach ($id in $ids) {
    "===== NODE $id ====="
    $p = Join-Path $data "computer\$id\rpv-log.txt"
    if (Test-Path $p) {
        Get-Content $p | Where-Object { $_ -match "PMTU|FRAG|CHANNEL|WAN_ADVERT|WAN_DEFAULT|RESULTS|TEST_DONE|STATS|SPOOF|IFACE|SELFTEST_" }
    }
}
"===== STDERR ====="
if (Test-Path $stderr) { Get-Content $stderr -Raw }
