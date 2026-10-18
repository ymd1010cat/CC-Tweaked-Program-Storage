# P2-c acceptance: NAT-lite (PAT + port forward) and multicast/broadcast domains.
#
#   pwsh -File poc\run-p2c.ps1 -Scenario nat
#     21 = NAT router (LAN-A internal 10.0.1.1/24, LAN-B external 10.0.2.1/24,
#          nat_forward=7000>10.0.1.2:7000)
#     22 = internal host 10.0.1.2 (app=nat-selftest): masquerade + ICMP through NAT
#     23 = external host 10.0.2.2 (app=nat-peer): sees the NAT address as the source,
#          and reaches the internal host through the forwarded port
#
#   pwsh -File poc\run-p2c.ps1 -Scenario mcast
#     21 = router with mcast=1, domains LAN-A>LAN-B, mcast_rate=10, bcast_relay+rate
#     22 = LAN-A host (joins 239.1.1.1, bursts 30 packets, sends a broadcast)
#     23 = LAN-B host (joins 239.1.1.1, must receive forwarded traffic + broadcast;
#          its own group send must be denied by the domain rules)
param(
    [ValidateSet("nat", "mcast")]
    [string]$Scenario = "nat",
    [int]$TimeoutSec = 150,
    [string]$Root = $env:RPV_ROOT
)

$root = $Root
if (-not $root) { $root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path) }
$data = Join-Path $root "craftos-p2c-$Scenario"
$exe = "C:\Program Files\CraftOS-PC\CraftOS-PC_console.exe"
$bootstrap = Join-Path $root "poc\node2\startup.lua"
$rpvdir = Join-Path $root "poc\rpv"
$appsdir = Join-Path $root "poc\apps"
$compatdir = Join-Path $root "poc\compat"
$out = Join-Path $root "poc\out"
New-Item -ItemType Directory -Force -Path $out | Out-Null
if (Test-Path $data) { Remove-Item -Recurse -Force $data }

$roles = @{}
if ($Scenario -eq "nat") {
    $roles[21] = "role=router`n" +
        "iface=back|LAN-A|10.0.1.1/24|4301|256|wired`n" +
        "iface=left|LAN-B|10.0.2.1/24|4302|256|wired`n" +
        "nat=1`nnat_out=LAN-B`nnat_forward=7000>10.0.1.2:7000`nnat_timeout=30`n" +
        "spawn=22,23`nstats_at=20`n"
    $roles[22] = "role=host`niface=back|LAN-A|10.0.1.2/24|4301|256|wired`ngw=10.0.1.1`n" +
        "app=nat-selftest:10.0.2.2`nstart_delay=3`n"
    $roles[23] = "role=host`niface=back|LAN-B|10.0.2.2/24|4302|256|wired`ngw=10.0.2.1`n" +
        "app=nat-peer`nstart_delay=6`nnat_addr=10.0.2.1`nnat_port=7000`n"
    $watchId = 22
    $watchFile = "rpv-log.txt"
    $watchMarker = "TEST_DONE"
} else {
    $roles[21] = "role=router`n" +
        "iface=back|LAN-A|10.0.1.1/24|4311|256|wired`n" +
        "iface=left|LAN-B|10.0.2.1/24|4312|256|wired`n" +
        "mcast=1`nmcast_domains=LAN-A>LAN-B`nmcast_rate=10`nbcast_relay=LAN-A>LAN-B`nbcast_rate=5`n" +
        "spawn=22,23`nstats_at=20`n"
    $roles[22] = "role=host`niface=back|LAN-A|10.0.1.2/24|4311|256|wired`ngw=10.0.1.1`n" +
        "mcast=1`nmcast_groups=239.1.1.1`napp=mcast-selftest`nstart_delay=2`nburst=30`n"
    $roles[23] = "role=host`niface=back|LAN-B|10.0.2.2/24|4312|256|wired`ngw=10.0.2.1`n" +
        "mcast=1`nmcast_groups=239.1.1.1`napp=mcast-peer`nstart_delay=8`n"
    $watchId = 23
    $watchFile = "rpv-log.txt"
    $watchMarker = "TEST_DONE"
}

foreach ($id in @(21, 22, 23)) {
    $dir = Join-Path $data "computer\$id"
    foreach ($sub in @("rpv", "apps", "compat")) { New-Item -ItemType Directory -Force -Path (Join-Path $dir $sub) | Out-Null }
    Copy-Item (Join-Path $rpvdir "*.lua") (Join-Path $dir "rpv") -Force
    Copy-Item (Join-Path $appsdir "*.lua") (Join-Path $dir "apps") -Force
    Copy-Item (Join-Path $compatdir "*.lua") (Join-Path $dir "compat") -Force
    Copy-Item $bootstrap (Join-Path $dir "startup.lua") -Force
    Set-Content -Path (Join-Path $dir "role.txt") -Value $roles[$id] -Encoding ascii
}

$stdout = Join-Path $out "p2c-$Scenario.stdout.txt"
$stderr = Join-Path $out "p2c-$Scenario.stderr.txt"
$proc = Start-Process -FilePath $exe -ArgumentList @("-d", "`"$data`"", "--headless", "--id", "21") `
    -RedirectStandardOutput $stdout -RedirectStandardError $stderr -PassThru -NoNewWindow

$watchLog = Join-Path $data "computer\$watchId\$watchFile"
$deadline = (Get-Date).AddSeconds($TimeoutSec)
$done = $false
while ((Get-Date) -lt $deadline) {
    Start-Sleep -Milliseconds 500
    if ($proc.HasExited) { break }
    if (Test-Path $watchLog) { if ((Get-Content $watchLog -Raw) -match $watchMarker) { $done = $true; break } }
}
Start-Sleep -Seconds 2
if (-not $proc.HasExited) { $proc.Kill() }
Start-Sleep -Milliseconds 400

$logs = @{}
foreach ($id in @(21, 22, 23)) {
    $p = Join-Path $data "computer\$id\rpv-log.txt"
    $logs[$id] = if (Test-Path $p) { Get-Content $p -Raw } else { "" }
    if ($logs[$id]) { Copy-Item $p (Join-Path $out "p2c-$Scenario-node$id.log") -Force }
}

$verdict = "FAIL"
if ($Scenario -eq "nat") {
    $xlate = $logs[21] -match "NAT_XLATE proto=udp"
    $icmpX = $logs[21] -match "NAT_XLATE proto=icmp"
    $fwd = $logs[21] -match "NAT_FWD proto=udp ext_port=7000"
    $drop = $logs[21] -match "NAT_DROP proto=udp dst=10\.0\.2\.1 port=7002"
    $inside = $logs[22] -match "NAT_SELFTEST_RESULT .*pass=true"
    $outside = $logs[23] -match "PEER_RESULT .*source_is_nat=true .*inbound_reply=true .*pass=true"
    if ($xlate -and $icmpX -and $fwd -and $drop -and $inside -and $outside) { $verdict = "PASS" }
    "NAT_XLATE=$xlate NAT_ICMP_XLATE=$icmpX NAT_FWD=$fwd NAT_DROP=$drop INSIDE_PASS=$inside OUTSIDE_PASS=$outside"
    ($logs[21] -split "`n" | Where-Object { $_ -match "NAT_STATE|NAT_XLATE proto=icmp" }) | Select-Object -Last 3 | ForEach-Object { "ROUTER " + $_.Trim() }
    ($logs[23] -split "`n" | Where-Object { $_ -match "PEER_" }) | Select-Object -First 5 | ForEach-Object { "OUTSIDE " + $_.Trim() }
} else {
    $fwd = $logs[21] -match "MCAST_FORWARD group=239\.1\.1\.1"
    $deny = $logs[21] -match "MCAST_DENY group=239\.1\.1\.1"
    $rate = $logs[21] -match "MCAST_RATE_DROP group=239\.1\.1\.1"
    $bfwd = $logs[21] -match "BCAST_FORWARD"
    $recv = $logs[23] -match "MCAST_RECV_TOTAL n=(\d+)" -and [int]$Matches[1] -ge 5
    $brecv = $logs[23] -match "BCAST_RECV"
    $unjoined = $logs[22] -match "MCAST_NOJOIN|MCAST_OTHER_GROUP_SENT"
    if ($fwd -and $deny -and $rate -and $bfwd -and $recv -and $brecv -and $unjoined) { $verdict = "PASS" }
    "MCAST_FORWARD=$fwd MCAST_DENY=$deny MCAST_RATE_DROP=$rate BCAST_FORWARD=$bfwd PEER_RECV=$recv PEER_BCAST=$brecv UNJOINED_TEST=$unjoined"
    ($logs[21] -split "`n" | Where-Object { $_ -match "MCAST_STATE|MCAST_DENY|BCAST_FORWARD" }) | Select-Object -Last 4 | ForEach-Object { "ROUTER " + $_.Trim() }
    ($logs[23] -split "`n" | Where-Object { $_ -match "MCAST_|BCAST_" }) | Select-Object -First 6 | ForEach-Object { "LANB " + $_.Trim() }
}

"RESULT p2c-$Scenario done=$done verdict=$verdict"
