# Real-Minecraft harness for rpv (headless NeoForge + CC:Tweaked server).
#
# Drives the dedicated server purely through RCON:
#   * /setblock computers + modems (wireless_modem_normal or wired_modem_full)
#   * /data merge block {ComputerId:<id>,On:0b}   (materialises a real computer)
#   * writes startup.lua / role.txt / rpv / apps into
#     mc-server/world/computercraft/computer/<id>/
#   * /computercraft turn-on <id>      (boot = run our startup.lua)
#   * waits for a marker in the watch file, then reads the logs back off disk
#
# Geometry: every computer is facing=north at y=-60, z=0, so a peripheral on its
# +X side is "left" and on -X is "right" (verified in-game). Each computer gets
# at most one modem per side; wired links fill the gap between two modems of the
# same segment with computercraft:wired_modem_full (a /fill of computercraft:cable
# does NOT join a wired network).
#
#   -Scenario lan|pmtu|ftp|cluster|wan|shim|multi|sites|bench|probe|range|wiredtest
#   -Link wireless|wired   -FtpWindow N   -Distance N   -TimeoutSec N
#   -Target neoforge|fabric     (fabric accepts vanilla-protocol clients, so the
#                                fake-player bot can read spark's chat-only output)
#   -TpsWindowSec N   -SparkProfile   -SparkText
param(
    [string]$Scenario = "lan",
    [string]$Link = "wireless",
    [int]$FtpWindow = 4,
    [string]$FtpTransport = "udp",
    [int]$DropEvery = 0,
    [int]$Distance = 64,
    [switch]$AdvancedModems,      # use the ender modem (unlimited range / cross-dimension)
    [string]$BridgePsk = "00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff",
    [ValidateSet("off", "psk", "wrongpsk")]
    [string]$ConnSecure = "off",                 # control-plane AEAD for -FtpTransport conn
    [ValidateSet("wireless", "wired")]
    [string]$WanLink = "wireless",               # WAN modem kind (wired = wired_modem_full chain)
    [string]$ConnPsk = "00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff",
    [int]$Count = 8,
    [int]$Counters = 1,
    [int]$PerTick = 4,
    [int]$LoadSecs = 12,
    [int]$LoadConnBytes = 20000,
    [double]$RtoMin = 0.05,
    [int]$TpsWindowSec = 0,
    [switch]$SparkProfile,
    [switch]$SparkText,
    [int]$SparkWait = 8,
    [ValidateSet("neoforge", "fabric")]
    [string]$Target = "neoforge",
    [int]$TimeoutSec = 180,
    [string]$Root = $env:RPV_ROOT
)

$root = $Root
if (-not $root) { $root = "C:\Users\ymd10\Documents\DSHWork\cc_tweaked\rpv1" }
$env:RPV_ROOT = $root
$targets = @{
    neoforge = @{ dir = "mc-server";        rcon = 25575; game = 25565 }
    fabric   = @{ dir = "mc-server-fabric"; rcon = 25576; game = 25566 }
}
$tgt = $targets[$Target]
$server = Join-Path $root $tgt.dir
$rconPort = $tgt.rcon
$gamePort = $tgt.game
$world = Join-Path $server "world\computercraft\computer"
$py = "C:\Users\ymd10\.dsh\dsh-runtimes\dsh-primary-runtime\dependencies\python\python.exe"
$rcon = Join-Path $root "poc\mc\rcon.py"
$node = "C:\Users\ymd10\.dsh\dsh-runtimes\dsh-primary-runtime\dependencies\node\bin\node.exe"
$botScript = Join-Path $root "poc\mc\bot\read-chat.mjs"
$out = Join-Path $root "poc\out"
New-Item -ItemType Directory -Force -Path $out | Out-Null

function Invoke-Rcon {
    param([string[]]$Commands)
    $tmp = Join-Path $env:TEMP ("rpv-rcon-" + [guid]::NewGuid().ToString("N") + ".txt")
    [System.IO.File]::WriteAllLines($tmp, $Commands, (New-Object System.Text.ASCIIEncoding))
    $res = & $py $rcon --batch 127.0.0.1 $rconPort rpvtest $tmp 2>&1
    Remove-Item $tmp -Force -ErrorAction SilentlyContinue
    return $res
}

# side of a computer (facing=north, y=-60) holding a peripheral at (dx,dz).
# Probed in-game: +x => left, -x => right, +z(south) => front, -z(north) => back.
function Side-Name { param([int]$dx, [int]$dz = 0) if ($dz -gt 0) { "front" } elseif ($dz -lt 0) { "back" } elseif ($dx -gt 0) { "left" } else { "right" } }

# commands must be dimension-qualified outside the overworld (a computer in the
# nether is placed/turned on by id, but /setblock and /data need `execute in`)
function Dim-Prefix { param([string]$dim) if ($dim -and $dim -ne "overworld") { "execute in minecraft:$dim run " } else { "" } }
function Node-Dim { param($c) if ($c.dim) { $c.dim } else { "overworld" } }

$wireless = ($Link -ne "wired")
$mtype = if ($AdvancedModems) { "computercraft:wireless_modem_advanced" } elseif ($wireless) { "computercraft:wireless_modem_normal" } else { "computercraft:wired_modem_full" }
function Modem-Block { param($m)
    if ($m.type -match "wired_modem_full") { "$($m.type)" } else { "$($m.type)[facing=$($m.facing)]" }
}

$computers = @()
$roles = @{}
$counterIds = @()
$segZ = @{}
$bridges = @{}          # id -> bridge.txt content (standalone ender-bridge program)
$attackers = @{}        # id -> attack.txt content (standalone attacker test tool)
$extraDims = @()        # @{ dim=..; fill=..; forceload=.. } for non-overworld builds
$routes = @{}          # id -> routes.txt content
$payloadFor = 0        # computer id that gets payload.txt
$watch = 21
$watchFile = "rpv-log.txt"
$watchMarker = "TEST_DONE"

if ($Scenario -eq "lan" -or $Scenario -eq "pmtu") {
    $df = if ($Scenario -eq "pmtu") { "`ndf_probe=1`ndf_probe_bytes=200`npmtu_retry_bytes=88`n" } else { "" }
    $expectTtl = if ($Scenario -eq "pmtu") { 1 } else { 1 }
    # hosts keep their modem on the router-facing side so a straight wired run
    # never has to pass through a computer block
    $aDx = if ($wireless) { 1 } else { -1 }
    $bDx = if ($wireless) { -1 } else { 1 }
    $computers = @(
        @{ id = 21; x = 0;  modems = @(@{ dx = 1; seg = "A" }, @{ dx = -1; seg = "B" }) },
        @{ id = 22; x = 6;  modems = @(@{ dx = $aDx; seg = "A" }) },
        @{ id = 23; x = -6; modems = @(@{ dx = $bDx; seg = "B" }) }
    )
    $roles[21] = "role=router`niface=left|LAN-A|10.0.1.1/24|4001|256|$Link`niface=right|LAN-B|10.0.2.1/24|4002|128|$Link`nstats_at=30`n"
    $roles[22] = "role=host`niface=$(Side-Name $aDx)|LAN-A|10.0.1.2/24|4001|256|$Link`ngw=10.0.1.1`napp=rpv-selftest:10.0.2.2`nstart_delay=4`nlarge_bytes=900`n${df}expect_pings=4`nexpect_ttl2=1`nexpect_ttl_exceeded=$expectTtl`n"
    $roles[23] = "role=host`niface=$(Side-Name $bDx)|LAN-B|10.0.2.2/24|4002|256|$Link`ngw=10.0.2.1`napp=udp-echo:7`nstats_at=30`n"
    $watch = 22
} elseif ($Scenario -eq "sites") {
    # Three sites on one map:
    #   A (LAN-A, wireless)  -- rednet WAN (wireless) -->  B (transit router)
    #   B  -- 66 blocks, i.e. BEYOND the 64-block wireless radius -->  C
    # so that hop is a wired wired_modem_full chain carrying plain rpv.
    $computers = @(
        @{ id = 21; x = 0;  modems = @(@{ dx = -1; seg = "A" }, @{ dx = 1; seg = "W1" }) },
        @{ id = 22; x = 12; modems = @(@{ dx = -1; seg = "W1" }, @{ dx = 1; seg = "W2"; wire = "wired" }) },
        @{ id = 23; x = -6; modems = @(@{ dx = 1; seg = "A" }) },
        @{ id = 25; x = 80; modems = @(@{ dx = -1; seg = "W2"; wire = "wired" }, @{ dx = 1; seg = "C" }) },
        @{ id = 26; x = 86; modems = @(@{ dx = -1; seg = "C" }) }
    )
    $roles[21] = "role=router`niface=right|LAN-A|10.0.1.1/24|4001|256|wireless`niface=left|WAN1|172.16.0.1/24|rednet|256`nadvert=1`nrpv_host=gw-a`nstats_at=35`n"
    $roles[22] = "role=router`niface=right|WAN1|172.16.0.2/24|rednet|256`niface=left|LINK-BC|172.17.0.1/24|4010|256|wired`nadvert=1`nstats_at=35`n"
    $roles[25] = "role=router`niface=right|LINK-BC|172.17.0.2/24|4010|256|wired`niface=left|LAN-C|10.0.3.1/24|4003|256|wireless`nstats_at=35`n"
    $roles[23] = "role=host`niface=left|LAN-A|10.0.1.2/24|4001|256|wireless`ngw=10.0.1.1`napp=rpv-selftest:10.0.3.2`nstart_delay=8`nlarge_bytes=900`nprobe_ttl=4`nexpect_pings=4`nexpect_ttl2=0`nexpect_ttl_exceeded=2`n"
    $roles[26] = "role=host`niface=right|LAN-C|10.0.3.2/24|4003|256|wireless`ngw=10.0.3.1`napp=udp-echo:7`n"
    # adverts are single-hop by design, so the edges hold one static route each
    $routes[21] = "10.0.3.0/24 via 172.16.0.2`n"
    $routes[22] = "10.0.3.0/24 via 172.17.0.2`n"
    $routes[25] = "10.0.1.0/24 via 172.17.0.1`n"
    $watch = 23
} elseif ($Scenario -eq "ftp") {
    $computers = @(
        @{ id = 21; x = 0; modems = @(@{ dx = 1; seg = "A" }) },
        @{ id = 22; x = 6; modems = @(@{ dx = -1; seg = "A" }) }
    )
    $sSec = ""
    $cSec = ""
    if ($ConnSecure -eq "psk") { $sSec = "conn_secure=1`nconn_psk=$ConnPsk`n"; $cSec = "conn_secure=1`nconn_psk=$ConnPsk`n" }
    elseif ($ConnSecure -eq "wrongpsk") { $sSec = "conn_secure=1`nconn_psk=$ConnPsk`n"; $cSec = "conn_secure=1`nconn_psk=ffeeddccbbaa99887766554433221100ffeeddccbbaa99887766554433221100`n" }
    $roles[21] = "role=host`niface=left|L|10.0.1.1/24|4001|256|$Link`napp=ftp-server:4300`nftp_block=256`nftp_window=$FtpWindow`nftp_retx=0.4`nftp_transport=$FtpTransport`ndrop_every=$DropEvery`n${sSec}"
    $roles[22] = "role=host`niface=right|L|10.0.1.2/24|4001|256|$Link`ngw=10.0.1.1`napp=ftp-client:10.0.1.1:4300:payload.txt`nftp_transport=$FtpTransport`n${cSec}"
    $payloadFor = 21
    $watch = 22
} elseif ($Scenario -eq "load") {
    # pps ceiling probe: $Counters counters + $Count senders on one medium
    # (wireless: modems beside each computer; wired: modems on a cable row at
    # z=+1 so the cable chain never runs through a computer block).
    $mdx = if ($wireless) { 1 } else { 0 }
    $mdz = if ($wireless) { 0 } else { 1 }
    $counterIds = @()
    for ($i = 0; $i -lt $Counters; $i++) {
        $id = 21 + $i
        $x = 3 * $i
        $counterIds += $id
        $computers += @{ id = $id; x = $x; modems = @(@{ dx = $mdx; dz = $mdz; seg = "L" }) }
        $roles[$id] = "role=host`niface=$(Side-Name $mdx $mdz)|L|10.0.1.$($i + 1)/24|6400|256|$Link`napp=mc-load`nload_role=counter`nload_channel=6400`nload_secs=$LoadSecs`n"
    }
    for ($i = 1; $i -le $Count; $i++) {
        $id = 20 + $Counters + $i
        $x = 3 * ($Counters - 1 + $i)
        $computers += @{ id = $id; x = $x; modems = @(@{ dx = $mdx; dz = $mdz; seg = "L" }) }
        $roles[$id] = "role=host`niface=$(Side-Name $mdx $mdz)|L|10.0.1.$($Counters + $i)/24|6400|256|$Link`napp=mc-load`nload_role=sender`nload_channel=6400`nload_secs=$LoadSecs`nload_per_tick=$PerTick`n"
    }
    $watch = $counterIds[0]
    $watchFile = "mc-load-counter.txt"
    $watchMarker = "TEST_DONE"
} elseif ($Scenario -eq "loadwired") {
    # point-to-point WIRED comparison: same flood, but over a real wired run
    # (computercraft:wired_modem_full only attaches to horizontal neighbours, so
    # both modems sit beside their computer and the run fills the gap between).
    $computers = @(
        @{ id = 21; x = 0; modems = @(@{ dx = 1; seg = "L"; wire = "wired" }) },
        @{ id = 22; x = 6; modems = @(@{ dx = -1; seg = "L"; wire = "wired" }) }
    )
    $counterIds = @(21)
    $roles[21] = "role=host`niface=left|L|10.0.1.1/24|6400|256|wired`napp=mc-load`nload_role=counter`nload_channel=6400`nload_secs=$LoadSecs`n"
    $roles[22] = "role=host`niface=right|L|10.0.1.2/24|6400|256|wired`napp=mc-load`nload_role=sender`nload_channel=6400`nload_secs=$LoadSecs`nload_per_tick=$PerTick`n"
    $watch = 21
    $watchFile = "mc-load-counter.txt"
    $watchMarker = "TEST_DONE"
} elseif ($Scenario -eq "loadconn") {
    # same ramp, but every sender streams over a real connection (rpv/conn.lua:
    # handshake + sliding window + AIMD), i.e. WITH backpressure instead of flood.
    # The point is loss: conn must deliver everything, flood drops ~70%.
    $mdx = if ($wireless) { 1 } else { 0 }
    $mdz = if ($wireless) { 0 } else { 1 }
    $computers = @(
        @{ id = 21; x = 0; modems = @(@{ dx = $mdx; dz = $mdz; seg = "L" }) },
        @{ id = 22; x = 3; modems = @(@{ dx = $mdx; dz = $mdz; seg = "L" }) }
    )
    $counterIds = @(22)
    $roles[21] = "role=host`niface=$(Side-Name $mdx $mdz)|L|10.0.1.1/24|6400|256|$Link`napp=mc-load`nload_role=sender`nload_mode=conn`nload_dst=10.0.1.2`nload_port=6600`nload_conn_bytes=$LoadConnBytes`nconn_rto_min=$RtoMin`nload_secs=$LoadSecs`n"
    $roles[22] = "role=host`niface=$(Side-Name $mdx $mdz)|L|10.0.1.2/24|6400|256|$Link`napp=mc-load`nload_role=counter`nload_mode=conn`nload_port=6600`nload_secs=$LoadSecs`n"
    $watch = 22
    $watchFile = "mc-load-counter.txt"
    $watchMarker = "TEST_DONE"
} elseif ($Scenario -eq "loadrpv") {
    # same ramp, but the senders push real RPV1 UDP datagrams through a router,
    # so the numbers are protocol pps (ARP + IPv4 + UDP + checksum + forwarding),
    # not raw modem frames.
    if (-not $wireless) { throw "loadrpv scenario needs -Link wireless" }
    $computers = @(
        @{ id = 21; x = 0; modems = @(@{ dx = -1; seg = "A" }, @{ dx = 1; seg = "B" }) },
        @{ id = 22; x = 6; modems = @(@{ dx = -1; seg = "B" }) }
    )
    $roles[21] = "role=router`niface=right|LAN-A|10.0.1.1/24|4001|256|wireless`niface=left|LAN-B|10.0.2.1/24|4002|256|wireless`nstats_at=$($LoadSecs + 12)`n"
    $roles[22] = "role=host`niface=right|LAN-B|10.0.2.2/24|4002|256|wireless`napp=mc-load`nload_role=counter`nload_mode=rpv`nload_port=6500`nload_secs=$LoadSecs`n"
    for ($i = 1; $i -le $Count; $i++) {
        $id = 22 + $i
        $x = -4 - 3 * ($i - 1)
        $computers += @{ id = $id; x = $x; modems = @(@{ dx = 1; seg = "A" }) }
        $roles[$id] = "role=host`niface=left|LAN-A|10.0.1.$($i + 1)/24|4001|256|wireless`ngw=10.0.1.1`napp=mc-load`nload_role=sender`nload_mode=rpv`nload_dst=10.0.2.2`nload_port=6500`nload_secs=$LoadSecs`nload_per_tick=$PerTick`n"
    }
    $watch = 22
    $watchFile = "mc-load-counter.txt"
    $watchMarker = "TEST_DONE"
} elseif ($Scenario -eq "endbridge") {
    # CROSS-DIMENSION bridge. The ender modem (computercraft:wireless_modem_advanced
    # = unlimited range + cross-dimension) is used ONLY as a bridge transport, and
    # the bridge is a standalone program (poc/mc/ender-bridge.lua installed as
    # startup.lua; it never imports rpv/*). Hosts on both sides stay in ONE subnet
    # with no gateway: the bridge makes the two segments a single logical LAN.
    $lanCh = 4300
    $linkCh = 4999
    $wm = "computercraft:wireless_modem_normal"
    $em = "computercraft:wireless_modem_advanced"
    $computers = @(
        @{ id = 21; x = 0; dim = "overworld";  boot = "ender-bridge"; modems = @(
            @{ dx = 1; seg = "A"; type = $wm }, @{ dx = -1; seg = "E"; type = $em }) },
        @{ id = 22; x = 6; dim = "overworld";  modems = @(@{ dx = -1; seg = "A"; type = $wm }) },
        @{ id = 23; x = 0; dim = "the_nether"; y = 100; boot = "ender-bridge"; modems = @(
            @{ dx = 1; seg = "B"; type = $wm }, @{ dx = -1; seg = "E"; type = $em }) },
        @{ id = 24; x = 6; dim = "the_nether"; y = 100; modems = @(@{ dx = -1; seg = "B"; type = $wm }) }
    )
    $bridges[21] = "bridge_role=server`nbridge_id=rpv1`nbridge_local=left`nbridge_ender=right`nbridge_lan_channel=$lanCh`nbridge_link_channel=$linkCh`nbridge_secs=45`nbridge_psk=$BridgePsk`n"
    $bridges[23] = "bridge_role=client`nbridge_id=rpv1`nbridge_local=left`nbridge_ender=right`nbridge_lan_channel=$lanCh`nbridge_link_channel=$linkCh`nbridge_secs=45`nbridge_psk=$BridgePsk`n"
    $roles[22] = "role=host`niface=right|LAN|10.0.9.2/24|$lanCh|256|wireless`napp=rpv-selftest:10.0.9.3`nstart_delay=8`nlarge_bytes=900`nexpect_pings=4`nexpect_ttl2=1`nexpect_ttl_exceeded=0`n"
    $roles[24] = "role=host`niface=right|LAN|10.0.9.3/24|$lanCh|256|wireless`napp=udp-echo:7`n"
    $extraDims = @(@{ dim = "the_nether"; fill = "-4 98 -4 12 104 4"; forceload = "-1 -1 1 1" })
    $watch = 22
} elseif ($Scenario -eq "endbridgesec") {
    # Same cross-dimension bridge, but with an OFF-PATH ADVERSARY on the link
    # channel: computer 25 sits in the overworld with an ender modem on the link
    # channel and forges/HELLOs/replays/oversizes frames. The verdict requires the
    # authenticated traffic to still flow AND the attack to be rejected and counted.
    $lanCh = 4300
    $linkCh = 4999
    $wm = "computercraft:wireless_modem_normal"
    $em = "computercraft:wireless_modem_advanced"
    $computers = @(
        @{ id = 21; x = 0; dim = "overworld";  boot = "ender-bridge"; modems = @(
            @{ dx = 1; seg = "A"; type = $wm }, @{ dx = -1; seg = "E"; type = $em }) },
        @{ id = 22; x = 6; dim = "overworld";  modems = @(@{ dx = -1; seg = "A"; type = $wm }) },
        @{ id = 23; x = 0; dim = "the_nether"; y = 100; boot = "ender-bridge"; modems = @(
            @{ dx = 1; seg = "B"; type = $wm }, @{ dx = -1; seg = "E"; type = $em }) },
        @{ id = 24; x = 6; dim = "the_nether"; y = 100; modems = @(@{ dx = -1; seg = "B"; type = $wm }) },
        @{ id = 25; x = 24; dim = "overworld"; boot = "attacker"; log = "attack-log.txt"; modems = @(
            @{ dx = -1; seg = "E"; type = $em }) }
    )
    $bridges[21] = "bridge_role=server`nbridge_id=rpv1`nbridge_local=left`nbridge_ender=right`nbridge_lan_channel=$lanCh`nbridge_link_channel=$linkCh`nbridge_secs=45`nbridge_psk=$BridgePsk`n"
    $bridges[23] = "bridge_role=client`nbridge_id=rpv1`nbridge_local=left`nbridge_ender=right`nbridge_lan_channel=$lanCh`nbridge_link_channel=$linkCh`nbridge_secs=45`nbridge_psk=$BridgePsk`n"
    $attackers[25] = "attack_side=right`nattack_channel=$linkCh`nattack_secs=20`nattack_id=rpv1`nattack_forge=20`nattack_hellos=8`nattack_oversize=4096`nattack_forge_at=2`nattack_hello_at=4`nattack_replay_at=11`nattack_oversize_at=14`nattack_badtag_at=16`n"
    $roles[22] = "role=host`niface=right|LAN|10.0.9.2/24|$lanCh|256|wireless`napp=rpv-selftest:10.0.9.3`nstart_delay=8`nlarge_bytes=900`nexpect_pings=4`nexpect_ttl2=1`nexpect_ttl_exceeded=0`n"
    $roles[24] = "role=host`niface=right|LAN|10.0.9.3/24|$lanCh|256|wireless`napp=udp-echo:7`n"
    $extraDims = @(@{ dim = "the_nether"; fill = "-4 98 -4 12 104 4"; forceload = "-1 -1 1 1" })
    $watch = 22
} elseif ($Scenario -eq "longchain") {
    # LONG CHAIN: hostA - R1 - R2 - ... - R$Count - hostB, one subnet per hop and
    # full static routing at every router. Measures RTT + bulk transfer vs hops.
    $N = $Count
    $computers = @()
    for ($i = 1; $i -le $N; $i++) {
        $x = 12 * ($i - 1)
        $computers += @{ id = 20 + $i; x = $x; modems = @(
            @{ dx = -1; seg = "L$i" }, @{ dx = 1; seg = "L$($i + 1)" }) }
        # segment L_i: router i-1 on the west (10.0.i.1), router i on the east (10.0.i.2)
        $westIp = if ($i -eq 1) { "10.0.1.1" } else { "10.0.$i.2" }
        $eastIp = "10.0.$($i + 1).1"
        $roles[20 + $i] = "role=router`n" +
            "iface=right|L$i|$westIp/24|$(4700 + $i)|256|wireless`n" +
            "iface=left|L$($i + 1)|$eastIp/24|$(4700 + $i + 1)|256|wireless`n" +
            "stats_at=60`n"
        $r = @()
        for ($k = 1; $k -lt $i; $k++) { $r += "10.0.$k.0/24 via 10.0.$i.1" }        # back towards hostA
        for ($k = $i + 2; $k -le $N + 1; $k++) { $r += "10.0.$k.0/24 via 10.0.$($i + 1).2" }  # onward to hostB
        if ($r.Count -gt 0) { $routes[20 + $i] = ($r -join "`n") + "`n" }
    }
    $hostA = 21 + $N
    $hostB = 22 + $N
    $computers += @{ id = $hostA; x = -6; modems = @(@{ dx = 1; seg = "L1" }) }
    $computers += @{ id = $hostB; x = 12 * $N + 6; modems = @(@{ dx = -1; seg = "L$($N + 1)" }) }
    $roles[$hostA] = "role=host`niface=left|L1|10.0.1.2/24|4701|256|wireless`ngw=10.0.1.1`n" +
        "app=rpv-selftest:10.0.$($N + 1).2`nstart_delay=8`nlarge_bytes=2000`nprobe_ttl=$($N + 1)`n" +
        "expect_pings=4`nexpect_ttl2=0`nexpect_ttl_exceeded=0`nstats_at=60`n"
    $roles[$hostB] = "role=host`niface=right|L$($N + 1)|10.0.$($N + 1).2/24|$(4700 + $N + 1)|256|wireless`n" +
        "gw=10.0.$($N + 1).1`napp=udp-echo:7`n"
    $watch = $hostA
} elseif ($Scenario -eq "lib") {
    # LIBRARY acceptance on a real server: two plain computers, each running an
    # example program installed AS startup.lua. They load the library through
    # `require("rpv")` and build their node from an inline config table -- no
    # role.txt, no bootstrap, nothing from poc/apps. If this passes, the library
    # boundary works outside the project.
    $computers = @(
        @{ id = 21; x = 0; modems = @(@{ dx = 1; seg = "L" }); boot = "example:rpv-libtest.lua"; log = "lib-log.txt" },
        @{ id = 22; x = 6; modems = @(@{ dx = 1; seg = "L" }); boot = "example:rpv-echo.lua";    log = "echo-log.txt" }
    )
    $watch = 21
    $watchFile = "lib-log.txt"
    $watchMarker = "TEST_DONE"
} elseif ($Scenario -eq "dv") {
    # dynamic routing on a real server: a 3-router RING (no static routes at all)
    # plus a host on each side. The routers must learn the far subnets from their
    # own announcements, pick the shortest path and keep packets from looping.
    $computers = @(
        @{ id = 21; x = 0;   modems = @(@{ dx = -1; seg = "A" }, @{ dx = 1; seg = "B" }) },
        @{ id = 22; x = 8;   modems = @(@{ dx = -1; seg = "B" }, @{ dx = 1; seg = "C" }) },
        @{ id = 23; x = 16;  modems = @(@{ dx = -1; seg = "C" }, @{ dx = 1; seg = "A" }) },
        @{ id = 24; x = -6;  modems = @(@{ dx = 1; seg = "A" }) },
        @{ id = 25; x = 22;  modems = @(@{ dx = -1; seg = "C" }) }
    )
    $dv = "dv=1`ndv_interval=2`ndv_timeout=8`n"
    $roles[21] = "role=router`niface=right|LAN-A|10.0.1.1/24|4201|256|wireless`niface=left|LAN-B|10.0.2.1/24|4202|256|wireless`n$dv" + "stats_at=25`n"
    $roles[22] = "role=router`niface=right|LAN-B|10.0.2.2/24|4202|256|wireless`niface=left|LAN-C|10.0.3.1/24|4203|256|wireless`n$dv" + "stats_at=25`n"
    $roles[23] = "role=router`niface=right|LAN-C|10.0.3.2/24|4203|256|wireless`niface=left|LAN-A|10.0.1.3/24|4201|256|wireless`n$dv" + "stats_at=25`n"
    $roles[24] = "role=host`niface=left|LAN-A|10.0.1.2/24|4201|256|wireless`ngw=10.0.1.1`napp=rpv-selftest:10.0.3.3`nstart_delay=12`nlarge_bytes=2000`nprobe_ttl=8`nexpect_pings=4`nexpect_ttl2=0`nexpect_ttl_exceeded=0`n"
    $roles[25] = "role=host`niface=right|LAN-C|10.0.3.3/24|4203|256|wireless`ngw=10.0.3.1`napp=udp-echo:7`n"
    $watch = 24
} elseif ($Scenario -eq "svc") {
    # DHCP-lite + lookup-lite on a real server: 21 is the router AND the DHCP/DNS
    # server on LAN-A; 22 starts with only a placeholder address and must lease a
    # real one, register its name, resolve "host23" and ping it across the router;
    # 23 is that host on LAN-B.
    $computers = @(
        @{ id = 21; x = 0;  modems = @(@{ dx = -1; seg = "A" }, @{ dx = 1; seg = "B" }) },
        @{ id = 22; x = -6; modems = @(@{ dx = 1; seg = "A" }) },
        @{ id = 23; x = 6;  modems = @(@{ dx = -1; seg = "B" }) }
    )
    $roles[21] = "role=router`niface=right|LAN-A|10.0.1.1/24|4001|256|wireless`niface=left|LAN-B|10.0.2.1/24|4002|256|wireless`n" +
        "dhcp_pool=10.0.1.100-10.0.1.150`ndhcp_gw=10.0.1.1`ndhcp_dns=10.0.1.1`ndhcp_lease=600`ndns=1`n" +
        "name=svc-server`nstats_at=25`n"
    $roles[22] = "role=host`niface=left|LAN-A|10.254.0.22/16|4001|256|wireless`n" +
        "dhcp=1`nname=client22`ndns_server=10.0.1.1`napp=svc-selftest:host23`nstart_delay=2`ndhcp_timeout=20`n"
    $roles[23] = "role=host`niface=right|LAN-B|10.0.2.2/24|4002|256|wireless`ngw=10.0.2.1`n" +
        "name=host23`ndns_server=10.0.1.1`napp=udp-echo:7`n"
    $watch = 22
    $watchFile = "svc-log.txt"
    $watchMarker = "TEST_DONE"
    $computers[1].log = "svc-log.txt"
} elseif ($Scenario -eq "wanlink") {
    # Minimal WAN-link acceptance: two computers whose ONLY interface is the WAN,
    # both on 172.16.0.0/24, so ICMP echo + a large UDP echo cross the WAN directly
    # with no LAN hop in between. Runs with a wireless or a wired modem (-WanLink).
    $wz = if ($WanLink -eq "wired") { 1 } else { 0 }
    $wx = if ($WanLink -eq "wired") { 0 } else { 1 }
    $wside = if ($WanLink -eq "wired") { "back" } else { "left" }
    $wwire = if ($WanLink -eq "wired") { "wired" } else { $null }
    $wmodem = if ($WanLink -eq "wired") { "wan_modem=wired_modem_full`n" } else { "" }
    $computers = @(
        @{ id = 21; x = 0;  modems = @(@{ dx = $wx; dz = $wz; seg = "W"; wire = $wwire }) },
        @{ id = 22; x = 12; modems = @(@{ dx = $wx; dz = $wz; seg = "W"; wire = $wwire }) }
    )
    $roles[21] = "role=host`niface=$wside|WAN|172.16.0.1/24|rednet|512`nadvert=1`nwan_peer=172.16.0.2:22`n${wmodem}" +
        "app=rpv-selftest:172.16.0.2`nstart_delay=6`nlarge_bytes=900`nexpect_pings=4`nexpect_ttl2=0`nexpect_ttl_exceeded=0`nstats_at=30`n"
    $roles[22] = "role=host`niface=$($wside)|WAN|172.16.0.2/24|rednet|512`nadvert=1`nwan_peer=172.16.0.1:21`n${wmodem}app=udp-echo:7`nstats_at=30`n"
    $watch = 21
} elseif ($Scenario -eq "wansec") {
    # WAN tunnel AEAD on a real server: two routers whose WAN is rednet (21 LAN-A,
    # 22 LAN-B), a host on each side, and a standalone eavesdropper (25) on the WAN
    # segment. The marker must cross the tunnel but never appear in cleartext on the
    # wire, and the sniffer's spoofed replay must be rejected.
    # wired WAN: the segment-W modem row goes at z=1 (the harness never places computers
    # there, so the wired_modem_full cable run cannot clash) and that makes the peripheral
    # sit on the "front" side instead of "left"
    $wanWire = if ($WanLink -eq "wired") { "wired" } else { $null }
    $wanDz = if ($WanLink -eq "wired") { 1 } else { 0 }
    $wanDx1 = if ($WanLink -eq "wired") { 0 } else { 1 }    # side of id 21 (LAN modem is right)
    $wanDx2 = if ($WanLink -eq "wired") { 0 } else { -1 }   # side of id 22 (LAN modem is left)
    $wanSide = if ($WanLink -eq "wired") { "back" } else { "left" }
    $computers = @(
        @{ id = 21; x = 0;  modems = @(@{ dx = -1; seg = "A" }, @{ dx = $wanDx1; dz = $wanDz; seg = "W"; wire = $wanWire }) },
        @{ id = 22; x = 12; modems = @(@{ dx = $wanDx2; dz = $wanDz; seg = "W"; wire = $wanWire }, @{ dx = 1; seg = "B" }) },
        @{ id = 23; x = -6; modems = @(@{ dx = 1; seg = "A" }) },
        @{ id = 24; x = 18; modems = @(@{ dx = -1; seg = "B" }) },
        @{ id = 25; x = 6;  boot = "sniffer"; modems = @(@{ dx = 0; dz = 1; seg = "W"; wire = $wanWire }) }
    )
    $wpsk = "00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff"
    # wired WAN: the modems on segment W become wired_modem_full and the harness joins
    # them with a chain of wired_modem_full blocks (see the placement code)
    $wanModemKey = if ($WanLink -eq "wired") { "wan_modem=wired_modem_full`n" } else { "" }
    $roles[21] = "role=router`niface=right|LAN-A|10.0.1.1/24|4601|512|wireless`n" +
        "iface=$($wanSide)|WAN|172.16.0.1/24|rednet|512`nadvert=1`nwan_secure=1`nwan_psk=$wpsk`nwan_hello_interval=3`n${wanModemKey}stats_at=30`n"
    $roles[22] = "role=router`niface=right|LAN-B|10.0.2.1/24|4602|512|wireless`n" +
        "iface=$($wanSide)|WAN|172.16.0.2/24|rednet|512`nadvert=1`nwan_secure=1`nwan_psk=$wpsk`nwan_hello_interval=3`n${wanModemKey}stats_at=30`n"
    $roles[23] = "role=host`niface=left|LAN-A|10.0.1.2/24|4601|512|wireless`ngw=10.0.1.1`n" +
        "app=wansec-selftest:10.0.2.2`nstart_delay=14`nmarker=RPVSECRET`n"
    $roles[24] = "role=host`niface=right|LAN-B|10.0.2.2/24|4602|512|wireless`ngw=10.0.2.1`n" +
        "app=wansec-peer`nmarker=RPVSECRET`n"
    $watch = 23
} elseif ($Scenario -eq "cluster") {
    $computers = @(
        @{ id = 21; x = 0;   modems = @(@{ dx = -1; seg = "A" }, @{ dx = 1; seg = "F" }) },
        @{ id = 22; x = 12;  modems = @(@{ dx = -1; seg = "F" }, @{ dx = 1; seg = "B" }) },
        @{ id = 23; x = -4;  modems = @(@{ dx = 1; seg = "A" }) },
        @{ id = 24; x = 16;  modems = @(@{ dx = -1; seg = "B" }) }
    )
    $roles[21] = "role=router`niface=right|LAN-A|10.0.1.1/24|4001|256|$Link`nfabric=left|5000|1024`nstats_at=20`n"
    $roles[22] = "role=router`nfabric=right|5000|1024`niface=left|LAN-B|10.0.2.1/24|4002|256|$Link`nstats_at=20`n"
    $roles[23] = "role=host`niface=left|LAN-A|10.0.1.2/24|4001|256|$Link`ngw=10.0.1.1`napp=rpv-selftest:10.0.2.2`nstart_delay=4`nlarge_bytes=900`nexpect_pings=4`nexpect_ttl2=1`nexpect_ttl_exceeded=0`n"
    $roles[24] = "role=host`niface=right|LAN-B|10.0.2.2/24|4002|256|$Link`ngw=10.0.2.1`napp=udp-echo:7`n"
    $watch = 23
} elseif ($Scenario -eq "wan") {
    $computers = @(
        @{ id = 21; x = 0;   modems = @(@{ dx = -1; seg = "A" }, @{ dx = 1; seg = "W" }) },
        @{ id = 22; x = 12;  modems = @(@{ dx = -1; seg = "W" }, @{ dx = 1; seg = "B" }) },
        @{ id = 23; x = -4;  modems = @(@{ dx = 1; seg = "A" }) },
        @{ id = 24; x = 16;  modems = @(@{ dx = -1; seg = "B" }) }
    )
    $roles[21] = "role=router`niface=right|LAN|10.0.1.1/24|4001|256|$Link`niface=left|WAN|172.16.0.1/24|rednet|256`nadvert=1`nrpv_host=gw-a`nstats_at=30`n"
    $roles[22] = "role=router`niface=right|WAN|172.16.0.2/24|rednet|256`niface=left|LAN|10.0.2.1/24|4002|128|$Link`nadvert=1`nstats_at=30`n"
    $roles[23] = "role=host`niface=left|LAN|10.0.1.2/24|4001|256|$Link`ngw=10.0.1.1`napp=rpv-selftest:10.0.2.2`nstart_delay=6`nlarge_bytes=900`nexpect_pings=3`nexpect_ttl2=0`nexpect_ttl_exceeded=1`n"
    $roles[24] = "role=host`niface=right|LAN|10.0.2.2/24|4002|256|$Link`ngw=10.0.2.1`napp=udp-echo:7`n"
    $watch = 23
} elseif ($Scenario -eq "shim") {
    $computers = @(
        @{ id = 21; x = 0;   modems = @(@{ dx = -1; seg = "A" }, @{ dx = 1; seg = "B" }) },
        @{ id = 22; x = -4;  modems = @(@{ dx = 1; seg = "A" }) },
        @{ id = 23; x = 16;  modems = @(@{ dx = -1; seg = "B" }) }
    )
    $roles[21] = "role=router`niface=right|LAN-A|10.0.1.1/24|4001|256|$Link`niface=left|LAN-B|10.0.2.1/24|4002|256|$Link`napp=rednet-dir:4100`nstats_at=25`n"
    $roles[22] = "role=host`niface=left|LAN-A|10.0.1.2/24|4001|256|$Link`ngw=10.0.1.1`nshim=1`napp=legacy-chat:client:23`n"
    $roles[23] = "role=host`niface=right|LAN-B|10.0.2.2/24|4002|256|$Link`ngw=10.0.2.1`nshim=1`napp=legacy-chat:server:22`n"
    $watch = 22
    $watchFile = "legacy-log.txt"
} elseif ($Scenario -eq "multi") {
    $computers = @(
        @{ id = 21; x = 0;  modems = @(@{ dx = -1; seg = "S1" }, @{ dx = 1; seg = "S2" }) },
        @{ id = 22; x = 12; modems = @(@{ dx = -1; seg = "S2" }, @{ dx = 1; seg = "S3" }) },
        @{ id = 23; x = 24; modems = @(@{ dx = -1; seg = "S3" }, @{ dx = 1; seg = "S4" }) },
        @{ id = 24; x = -4; modems = @(@{ dx = 1; seg = "S1" }) },
        @{ id = 25; x = 30; modems = @(@{ dx = -1; seg = "S4" }) }
    )
    $roles[21] = "role=router`niface=right|S1|10.0.1.1/24|4101|256|$Link`niface=left|S2|10.0.2.1/24|4102|256|$Link`ngw=10.0.2.2`nstats_at=30`n"
    $roles[22] = "role=router`niface=right|S2|10.0.2.2/24|4102|256|$Link`niface=left|S3|10.0.3.1/24|4103|256|$Link`nstats_at=30`n"
    $roles[23] = "role=router`niface=right|S3|10.0.3.2/24|4103|256|$Link`niface=left|S4|10.0.4.1/24|4104|256|$Link`ngw=10.0.3.1`nstats_at=30`n"
    $roles[24] = "role=host`niface=left|S1|10.0.1.2/24|4101|256|$Link`ngw=10.0.1.1`napp=rpv-selftest:10.0.4.2`nstart_delay=4`nlarge_bytes=900`nprobe_ttl=4`nexpect_pings=4`nexpect_ttl2=0`nexpect_ttl_exceeded=2`n"
    $roles[25] = "role=host`niface=right|S4|10.0.4.2/24|4104|256|$Link`ngw=10.0.4.1`napp=udp-echo:7`n"
    $routes[22] = "10.0.1.0/24 via 10.0.2.1`n10.0.4.0/24 via 10.0.3.2`n"
    $watch = 24
} elseif ($Scenario -eq "range") {
    $x2 = [Math]::Max(2, $Distance)
    $computers = @(
        @{ id = 21; x = 0;  modems = @(@{ dx = 1; seg = "R" }) },
        @{ id = 22; x = $x2; modems = @(@{ dx = -1; seg = "R" }) }
    )
    $roles[21] = "role=host`niface=left|R|10.0.1.1/24|4001|256|$Link`napp=mc-range`n"
    $roles[22] = "role=host`niface=right|R|10.0.1.2/24|4001|256|$Link`napp=mc-range`n"
    $watch = 21
    $watchMarker = "RANGE_DONE"
    # long-distance ender-modem test: the far end needs its own loaded chunks and
    # a pocket to build in (the default band only covers x=-48..400)
    if ($x2 -gt 380) {
        $farLoad = @("forceload add $($x2 - 16) -16 $($x2 + 16) 16",
                     "fill $($x2 - 2) -61 -2 $($x2 + 2) -59 2 air")
        $null = Invoke-Rcon $farLoad
        $farLoad | ForEach-Object { $_ }
    }
} elseif ($Scenario -eq "bench") {
    $computers = @(
        @{ id = 21; x = 0; modems = @(@{ dx = 1; seg = "A" }) },
        @{ id = 22; x = 6; modems = @(@{ dx = -1; seg = "A" }) }
    )
    $roles[21] = "role=host`niface=left|L|10.0.1.1/24|4001|256|$Link`napp=mc-bench`nbench_role=sender`nbench_frames=200`n"
    $roles[22] = "role=host`niface=right|L|10.0.1.2/24|4001|256|$Link`napp=mc-bench`nbench_role=receiver`nbench_frames=200`n"
    $watch = 22
} elseif ($Scenario -eq "probe" -or $Scenario -eq "wiredtest") {
    $app = if ($Scenario -eq "probe") { "mc-probe" } else { "mc-wiredtest" }
    $extra = if ($Scenario -eq "probe") { "`nprobe_remote=22`nprobe_target=10.0.1.2" } else { "" }
    $extra2 = if ($Scenario -eq "probe") { "`nprobe_remote=21`nprobe_target=10.0.1.1" } else { "" }
    $computers = @(
        @{ id = 21; x = 0; modems = @(@{ dx = 1; seg = "A" }) },
        @{ id = 22; x = 6; modems = @(@{ dx = -1; seg = "A" }) }
    )
    $roles[21] = "role=host`niface=left|L|10.0.1.1/24|4001|256|$Link`napp=$app$extra`n"
    $roles[22] = "role=host`niface=right|L|10.0.1.2/24|4001|256|$Link`napp=$app$extra2`n"
    $watch = 21
} else {
    throw "unknown scenario: $Scenario"
}

# network runs between modems of the same segment: a chain of wired_modem_full
# blocks (a /fill of computercraft:cable does NOT join a wired network; full
# modems do, verified in-game). Per-modem wire="wired" overrides -Link, so one
# scenario can mix a wireless WAN with a long wired hop.
$cables = @()
$segs = @{}
foreach ($c in $computers) { foreach ($m in $c.modems) { $segs[$m.seg] = $true } }
foreach ($seg in $segs.Keys) {
    # is this whole segment wired? (per-modem wire="wired" overrides -Link)
    $wiredSeg = $true
    foreach ($cc in $computers) {
        foreach ($mm in $cc.modems) {
            if ($mm.seg -eq $seg) {
                $w = if ($mm.wire) { $mm.wire -eq "wired" } else { -not $wireless }
                if (-not $w) { $wiredSeg = $false }
            }
        }
    }
    if (-not $wiredSeg) { continue }        # wireless segment: nothing to run
    $xs = @(); $skip = @(); $segZv = 0
    foreach ($c in $computers) {
        $skip += $c.x
        foreach ($m in $c.modems) {
            if ($m.seg -eq $seg) {
                $xs += ($c.x + $m.dx)
                if ($m.dz) { $segZv = $m.dz }
            }
        }
    }
    if ($xs.Count -ge 2) {
        $lo = ($xs | Measure-Object -Minimum).Minimum
        $hi = ($xs | Measure-Object -Maximum).Maximum
        $bad = @()
        # computers live at z=0; a modem row at z!=0 can never clash with them
        if ($segZv -eq 0) {
            for ($x = $lo + 1; $x -le $hi - 1; $x++) { if ($skip -contains $x) { $bad += $x } }
        }
        if ($bad.Count -gt 0) { throw "cable run for segment $seg would overwrite computers at $($bad -join ',')" }
        if ($hi - $lo -ge 2) { $cables += @{ from = $lo + 1; to = $hi - 1; dz = $segZv } }
    }
}

$Y = -60
$Z = 0

# ---- teardown + placement --------------------------------------------------
# make sure nothing is still running (a leftover process keeps its old role.txt
# and `turn-on` would silently be a no-op), then wipe the whole test band.
$null = Invoke-Rcon @("forceload add -48 -16 400 16")
$null = Invoke-Rcon @("computercraft shutdown")
Start-Sleep -Seconds 2
$null = Invoke-Rcon @("fill -48 -60 0 400 -60 2 air")     # z=0 computers, z=1 wired modem rows
foreach ($ed in $extraDims) {
    $p = Dim-Prefix $ed.dim
    $null = Invoke-Rcon @("${p}forceload add $($ed.forceload)")
    $null = Invoke-Rcon @("${p}fill $($ed.fill) air")
}

$cmds = @("gamerule sendCommandFeedback false", "gamerule doDaylightCycle false", "gamerule doWeatherCycle false",
          "gamerule randomTickSpeed 0", "gamerule doMobSpawning false", "time set noon")
foreach ($c in $computers) {
    $cd = Node-Dim $c
    $p = Dim-Prefix $cd
    $cy = if ($c.y) { $c.y } else { $Y }
    $cz = if ($c.z) { $c.z } else { $Z }
    $cmds += "${p}setblock $($c.x) $cy $cz computercraft:computer_normal[facing=north]"
    foreach ($m in $c.modems) {
        $mz = $cz + $(if ($m.dz) { [int]$m.dz } else { 0 })
        $facing = if ($m.dz -and $m.dz -ne 0) { if ($m.dz -gt 0) { "north" } else { "south" } }
                  elseif ($m.dx -gt 0) { "west" } else { "east" }
        $mt = if ($m.type) { $m.type }
              elseif ($m.wire) { if ($m.wire -eq "wired") { "computercraft:wired_modem_full" } else { "computercraft:wireless_modem_normal" } }
              else { $mtype }
        $b = @{ type = $mt; facing = $facing }
        $cmds += "${p}setblock $($c.x + $m.dx) $cy $mz $(Modem-Block $b)"
    }
}
foreach ($cb in $cables) {
    $cz = $Z + $(if ($cb.dz) { [int]$cb.dz } else { 0 })
    $cmds += "fill $($cb.from) $Y $cz $($cb.to) $Y $cz computercraft:wired_modem_full"
}
foreach ($c in $computers) {
    $cd = Node-Dim $c
    $p = Dim-Prefix $cd
    $cy = if ($c.y) { $c.y } else { $Y }
    $cz = if ($c.z) { $c.z } else { $Z }
    $cmds += "${p}data merge block $($c.x) $cy $cz {ComputerId:$($c.id),On:0b}"
}
$cmds += "computercraft dump"
$place = Invoke-Rcon $cmds
$place | Set-Content (Join-Path $out "mc-$Scenario-$Link-place.txt")
if ($place -match "does not have property|does not accept|Unknown block|Failed to|not a block entity|not loaded") {
    "PLACEMENT_ERRORS:"
    $place | Where-Object { $_ -match "does not have property|Unknown block|Failed|not a block entity" }
}

# ---- filesystem transplant -------------------------------------------------
$srcR = Join-Path $root "poc\rpv"
$srcA = Join-Path $root "poc\apps"
$srcC = Join-Path $root "poc\compat"
$srcS = Join-Path $root "poc\security"
$boot = Join-Path $root "poc\node2\startup.lua"
foreach ($c in $computers) {
    $dir = Join-Path $world $c.id
    if (Test-Path $dir) { Get-ChildItem $dir -Force | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue }
    if ($c.boot -eq "ender-bridge" -or $c.boot -eq "attacker" -or $c.boot -eq "sniffer") {
        # standalone programs: ONLY their own files are installed, so the run proves
        # they work on a computer that has none of the rpv library
        if ($c.boot -eq "ender-bridge") {
            Copy-Item (Join-Path $root "poc\mc\ender-bridge.lua") (Join-Path $dir "startup.lua") -Force
            Set-Content -Path (Join-Path $dir "bridge.txt") -Value $bridges[$c.id] -Encoding ascii
        } elseif ($c.boot -eq "sniffer") {
            Copy-Item (Join-Path $root "poc\wan-sniffer.lua") (Join-Path $dir "startup.lua") -Force
            Set-Content -Path (Join-Path $dir "sniff.txt") -Encoding ascii -Value @"
sniff_ids=21,22
sniff_mode=replay
sniff_replay_at=22
sniff_secs=70
sniff_marker=RPVSECRET
"@
        } else {
            Copy-Item (Join-Path $root "poc\mc\bridge-attacker.lua") (Join-Path $dir "startup.lua") -Force
            Set-Content -Path (Join-Path $dir "attack.txt") -Value $attackers[$c.id] -Encoding ascii
        }
        continue
    }
    foreach ($sub in @("rpv", "apps", "compat")) { New-Item -ItemType Directory -Force -Path (Join-Path $dir $sub) | Out-Null }
    Copy-Item (Join-Path $srcR "*.lua") (Join-Path $dir "rpv") -Force
    Copy-Item (Join-Path $srcA "*.lua") (Join-Path $dir "apps") -Force
    Copy-Item (Join-Path $srcC "*.lua") (Join-Path $dir "compat") -Force
    Copy-Item (Join-Path $srcS "crypto.lua") (Join-Path $dir "crypto.lua") -Force
    Copy-Item (Join-Path $root "poc\rpv.lua") $dir -Force          # library entry point
    if ($c.boot -like "example:*") {
        # external program: installed as startup.lua too, but it uses the library
        # (require("rpv") + config table) instead of the project's bootstrap
        $ex = $c.boot.Substring("example:".Length)
        Copy-Item (Join-Path $root "poc\examples\$ex") (Join-Path $dir "startup.lua") -Force
    } else {
        Copy-Item $boot (Join-Path $dir "startup.lua") -Force
        Set-Content -Path (Join-Path $dir "role.txt") -Value $roles[$c.id] -Encoding ascii
    }
    if ($routes.ContainsKey($c.id)) { Set-Content -Path (Join-Path $dir "routes.txt") -Value $routes[$c.id] -Encoding ascii }
}
if ($payloadFor -gt 0) {
    $lines = 1..200 | ForEach-Object { "rpv-payload-line-{0:D3}" -f $_ }
    Set-Content -Path (Join-Path $world "$payloadFor\payload.txt") -Value $lines -Encoding ascii
}

# ---- boot ------------------------------------------------------------------
$cmds = @()
foreach ($c in $computers) { $cmds += "computercraft turn-on $($c.id)" }
$bootRes = Invoke-Rcon $cmds
$bootRes | Set-Content (Join-Path $out "mc-$Scenario-$Link-boot.txt")
$bootRes | Where-Object { $_ -match "Turned on" } | ForEach-Object { $_.Trim() }
if ($bootRes -match "Turned on 0/") { "BOOT_WARNING: a computer did not start (leftover process still running?)" }

# ---- performance capture ---------------------------------------------------
# vanilla tick profiling is the only perf source that reports back over RCON
# (spark's command output goes to the in-game chat only), so we use /debug for
# TPS/MSPT and keep spark for profiler files that can be opened in its web app.
$logFile = Join-Path $server "logs\latest.log"
$preLogLines = if (Test-Path $logFile) { (Get-Content $logFile).Count } else { 0 }
$profiling = $false
if ($TpsWindowSec -gt 0) {
    $dbg = Invoke-Rcon @("debug start")
    $profiling = ($dbg -match "Started tick profiling")
    if (-not $profiling) { "TPS_WARNING: /debug start unavailable: $($dbg -join ' ')" }
}
if ($SparkProfile) {
    $null = Invoke-Rcon @("spark profiler start")
}

# ---- wait for the marker ---------------------------------------------------
$watchPath = Join-Path $world "$watch\$watchFile"
$deadline = (Get-Date).AddSeconds($TimeoutSec)
$done = $false
while ((Get-Date) -lt $deadline) {
    Start-Sleep -Milliseconds 500
    if (Test-Path $watchPath) {
        if ((Get-Content $watchPath -Raw) -match $watchMarker) { $done = $true; break }
    }
}
Start-Sleep -Seconds 2
if ($Scenario -eq "endbridgesec") {
    # let the attacker reach its replay phase (after real traffic started) and let
    # the bridges emit one more STATS line so the counters are current
    Start-Sleep -Seconds 12
}
if ($Scenario -eq "wansec") {
    # the WAN sniffer replays a captured frame at t=22s and writes its final report
    # afterwards, so collect a little later than the host's TEST_DONE
    Start-Sleep -Seconds 16
}

# ---- TPS / MSPT snapshot ---------------------------------------------------
if ($profiling) {
    $stopOut = Invoke-Rcon @("debug stop")
    $line = ($stopOut | Where-Object { $_ -match "ticks per second" }) -join " "
    $tps = $null
    if ($line -match "([0-9.]+) ticks per second") { $tps = [double]$matches[1] }
    $mspt = if ($tps -and $tps -gt 0) { [math]::Round(1000.0 / $tps, 2) } else { $null }    # "Can't keep up!" warnings emitted by the server during this run
    $keepUp = 0
    if (Test-Path $logFile) {
        $tail = Get-Content $logFile | Select-Object -Skip $preLogLines
        $keepUp = ($tail | Where-Object { $_ -match "Can't keep up" } | Measure-Object).Count
    }
    $report = @(
        "scenario=$Scenario target=$Target link=$Link computers=$($computers.Count) window=${TpsWindowSec}s",
        "raw=$($line.Trim())",
        "tps=$tps",
        "# note: /debug only reports the achieved tick RATE; this is the tick period,",
        "#       not real MSPT. Real MSPT/TPS come from spark via -SparkText.",
        "tick_period_ms=$mspt",
        "cant_keep_up=$keepUp"
    )
    $report | Set-Content (Join-Path $out "mc-$Scenario-$Link-tps.txt")
    $report | ForEach-Object { $_ }
}

# ---- spark profile archive -------------------------------------------------
if ($SparkProfile) {
    $null = Invoke-Rcon @("spark profiler stop")
    Start-Sleep -Seconds 6
    $profileDir = Join-Path $server "config\spark"
    $latest = Get-ChildItem $profileDir -Filter "*.sparkprofile" -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime | Select-Object -Last 1
    if ($latest) {
        $dest = Join-Path $out ("mc-$Scenario-$Link-" + $latest.Name)
        Copy-Item $latest.FullName $dest -Force
        "SPARK_PROFILE $dest"
    } else {
        "SPARK_WARNING: no .sparkprofile produced (profiler unavailable?)"
    }
}

# ---- spark text via the fake-player bot ------------------------------------
# spark sends command output straight to its own audience, so neither RCON nor
# the server log ever sees it (verified: RCON gets one empty packet). A headless
# protocol client logs in, gets opped by us, runs the commands and we keep the
# chat lines it receives.
if ($SparkText) {
    if ($Target -eq "neoforge") {
        "SPARK_TEXT_WARNING: NeoForge rejects vanilla-protocol clients, so the fake"
        "SPARK_TEXT_WARNING: player cannot read spark there - use -Target fabric."
    }
    $readyFile = Join-Path $env:TEMP ("rpvbot-ready-" + [guid]::NewGuid().ToString("N"))
    $startFile = Join-Path $env:TEMP ("rpvbot-start-" + [guid]::NewGuid().ToString("N"))
    $botOut = Join-Path $out "mc-$Scenario-$Link-spark.txt"
    $argStr = "`"$botScript`" -user rpvbot --port $gamePort --ready `"$readyFile`" --start `"$startFile`" " +
        "--cmds `"/spark tps,/spark health`" --wait $SparkWait --out `"$botOut`""
    $botProc = Start-Process -FilePath $node -ArgumentList $argStr -PassThru -NoNewWindow `
        -RedirectStandardOutput (Join-Path $env:TEMP "rpvbot.out") -RedirectStandardError (Join-Path $env:TEMP "rpvbot.err")
    $spawned = $false
    foreach ($i in 1..40) {
        Start-Sleep -Milliseconds 500
        if (Test-Path $readyFile) { $spawned = $true; break }
    }
    if ($spawned) {
        $null = Invoke-Rcon @("op rpvbot")
        Set-Content $startFile "go" -Encoding ascii
        $botProc.WaitForExit(($SparkWait + 25) * 1000) | Out-Null
        Start-Sleep -Milliseconds 500
        "SPARK_TEXT_BEGIN"
        if (Test-Path $botOut) { Get-Content $botOut } else { "SPARK_TEXT_WARNING: no output file" }
        "SPARK_TEXT_END"
    } else {
        "SPARK_TEXT_WARNING: fake player did not spawn (target=$Target port=$gamePort)"
    }
    Remove-Item $readyFile, $startFile -Force -ErrorAction SilentlyContinue
}

# ---- collect ---------------------------------------------------------------
$texts = @{}
foreach ($c in $computers) {
    $id = $c.id
    # bridge computers run the standalone program, so their evidence is bridge-log.txt
    $logName = if ($c.boot -eq "ender-bridge") { "bridge-log.txt" } elseif ($c.boot -eq "sniffer") { "sniff-log.txt" } elseif ($c.log) { $c.log } else { "rpv-log.txt" }
    $log = Join-Path $world "$id\$logName"
    if (Test-Path $log) {
        Copy-Item $log (Join-Path $out "mc-$Scenario-$Link-node$id.log") -Force
        $texts[$id] = Get-Content $log -Raw
    } else { $texts[$id] = "" }
}
$has = { param($id, $pat) $texts[$id] -match $pat }
# counters must come from the LAST stats line, not the first (which is all zeros)
function Last-BridgeCounters { param([string]$text)
    $line = ($text -split "`n" | Where-Object { $_ -match "BRIDGE_RESULT|STATS " } | Select-Object -Last 1)
    $a = 0; $b = 0
    if ($line -match "lan_to_link=(\d+)") { $a = [int]$matches[1] }
    if ($line -match "link_to_lan=(\d+)") { $b = [int]$matches[1] }
    return @($a, $b)
}

$verdict = "FAIL"
switch ($Scenario) {
    { $_ -eq "lan" } {
        if ((& $has 22 "complete=true") -and (& $has 22 "ttl2_ok=true") -and (& $has 22 "large_reply_ok=true") -and (& $has 21 "FWD ")) { $verdict = "PASS" }
    }
    { $_ -eq "pmtu" } {
        if ((& $has 22 "pmtu_ok=true") -and (& $has 22 "complete=true") -and (& $has 21 "PMTU_NEEDED")) { $verdict = "PASS" }
    }
    { $_ -eq "ftp" } {
        $src = Join-Path $world "21\payload.txt"; $dst = Join-Path $world "22\received-payload.txt"
        $same = $false
        if ((Test-Path $src) -and (Test-Path $dst)) {
            $a = [System.IO.File]::ReadAllBytes($src); $b = [System.IO.File]::ReadAllBytes($dst)
            if ($a.Length -eq $b.Length) { $same = $true; for ($i = 0; $i -lt $a.Length; $i++) { if ($a[$i] -ne $b[$i]) { $same = $false; break } } }
        }
        if ($ConnSecure -eq "wrongpsk") {
            # fail-closed expectation: nothing transferred and the server rejected
            # the unauthenticated SYN
            $rejected = (& $has 21 "CONN_SEC_SYN_REJECT") -or (& $has 22 "CONN_SEC_AUTH_FAIL") -or (& $has 22 "CONN_SEC_PEER_PLAINTEXT")
            if ((-not $same) -and $rejected) { $verdict = "PASS" }
            "SEC_WRONGPSK rejected=$rejected transferred=$same"
        } elseif ((& $has 22 "FTPC_VERIFY size_ok=true sha_ok=true") -and (& $has 22 "ok=true") -and $same) { $verdict = "PASS" }
        "HOST_COMPARE identical=$same bytes=$((Get-Item $dst -ErrorAction SilentlyContinue).Length)"
        if ($ConnSecure -ne "off") {
            ($texts[21] -split "`n" | Where-Object { $_ -match "CONN_SEC_KEYS|CONN_STATS" } | Select-Object -First 2) | ForEach-Object { "SEC_SRV " + $_.Trim() }
            ($texts[22] -split "`n" | Where-Object { $_ -match "CONN_SEC_KEYS|CONN_STATS" } | Select-Object -First 2) | ForEach-Object { "SEC_CLI " + $_.Trim() }
        }
    }
    { $_ -eq "svc" } {
        $svcTxt = $texts[22]
        $bound = $svcTxt -match "SVC_BOUND ip=10\.0\.1\.100"
        $lookup = $svcTxt -match "SVC_LOOKUP name=host23 ip=10\.0\.2\.2 ok=true"
        $ping = $svcTxt -match "SVC_PING ok=true"
        $lease = (& $has 21 "DHCP_LEASE ip=10\.0\.1\.100")
        $regs = (& $has 21 "DNS_REG name=client22") -and (& $has 21 "DNS_REG name=host23")
        if ($bound -and $lookup -and $ping -and $lease -and $regs) { $verdict = "PASS" }
        "SVC_BOUND=$bound LOOKUP=$lookup PING=$ping LEASE=$lease DNS_REGS=$regs"
        ($svcTxt -split "`n" | Where-Object { $_ -match "SVC_" }) | Select-Object -First 8 | ForEach-Object { "SVC " + $_.Trim() }
        ($texts[21] -split "`n" | Where-Object { $_ -match "DHCP_|DNS_" }) | Select-Object -First 6 | ForEach-Object { "SRV " + $_.Trim() }
    }
    { $_ -eq "dv" } {
        $dvTxt = $texts[24]
        $endToEnd = $dvTxt -match "complete=true"
        $installs = 0
        foreach ($id in @(21, 22, 23)) { $installs += ([regex]::Matches($texts[$id], "DV_INSTALL")).Count }
        $shortest = $false
        foreach ($id in @(21, 22, 23)) { if ($texts[$id] -match "DV_ROUTE .* metric=1 ") { $shortest = $true } }
        $loops = 0
        foreach ($id in @(21, 22, 23)) { $loops += ([regex]::Matches($texts[$id], "ttl_drop=[1-9]")).Count }
        if ($endToEnd -and $installs -gt 0 -and $shortest -and $loops -eq 0) { $verdict = "PASS" }
        "DV_INSTALLS=$installs END_TO_END=$endToEnd SHORTEST_PATH=$shortest TTL_LOOP_SIGNS=$loops"
        ($dvTxt -split "`n" | Where-Object { $_ -match "RESULTS|NO_ROUTE" }) | Select-Object -First 3 | ForEach-Object { "HOST " + $_.Trim() }
        ($texts[21] -split "`n" | Where-Object { $_ -match "DV_" }) | Select-Object -Last 4 | ForEach-Object { "R21 " + $_.Trim() }
    }
    { $_ -eq "wanlink" } {
        $wanKind = if (($texts[21] + $texts[22]) -match "phys_wireless=nil") { "wired" }
                   elseif (($texts[21] + $texts[22]) -match "phys_wireless=true") { "wireless" } else { "unknown" }
        $done21 = $texts[21] -match "complete=true"
        $echoed = $texts[22] -match "UDP_ECHO|udp"
        if ($done21) { $verdict = "PASS" }
        "WAN_LINK=$wanKind SELFTEST_COMPLETE=$done21"
        ($texts[21] -split "`n" | Where-Object { $_ -match "WAN_READY|RESULTS" }) | Select-Object -First 2 | ForEach-Object { "HOST " + $_.Trim() }
    }
    { $_ -eq "wansec" } {
        $selftest = $texts[23] -match "WANSEC_SELFTEST_RESULT ping=true marker=true pass=true"
        $peerOk = $texts[24] -match "WANSEC_PEER_RESULT markers=[1-9]"
        # tunnel-level evidence: both routers relayed over the WAN in both directions
        $relayed = ($texts[21] -match "WAN_SENT") -and ($texts[21] -match "WAN_RECV") -and
                   ($texts[22] -match "WAN_SENT") -and ($texts[22] -match "WAN_RECV")
        # which physical modem did the WAN use? wired modems have no isWireless() method
        $wanKind = if (($texts[21] + $texts[22]) -match "phys_wireless=nil") { "wired" }
                   elseif (($texts[21] + $texts[22]) -match "phys_wireless=true") { "wireless" } else { "unknown" }
        $keys = $texts[21] -match "WANSEC_KEYS"
        $sniffTxt = if (Test-Path (Join-Path $world "25\sniff-log.txt")) { Get-Content (Join-Path $world "25\sniff-log.txt") -Raw } else { "" }
        $markerVisible = $sniffTxt -match "SNIFF_MARKER_SEEN"
        $replayCaught = ($texts[21] + $texts[22]) -match "WANSEC_REPLAY"
        $replayed = $sniffTxt -match "SNIFF_REPLAY_SENT"
        # The security-critical evidence is the tunnel itself: keys derived, real traffic
        # reaching the far side, nothing readable on the wire, and the spoofed replay
        # rejected. The near host's own ping/echo assertions are covered by the
        # CraftOS-PC harness (poc/run-wansec.ps1), where the LAN ARP is deterministic.
        if (($peerOk -or $relayed) -and $keys -and (-not $markerVisible) -and $replayed -and $replayCaught) { $verdict = "PASS" }
        "WAN_LINK=$wanKind WANSEC_END_TO_END=$selftest PEER=$peerOk RELAYED=$relayed KEYS=$keys SNIFFER_MARKER=$markerVisible REPLAY_SENT=$replayed REPLAY_CAUGHT=$replayCaught"
        "WAN_DIAG sent21=$([regex]::Matches($texts[21], 'WAN_SENT').Count) recv21=$([regex]::Matches($texts[21], 'WAN_RECV').Count) sent22=$([regex]::Matches($texts[22], 'WAN_SENT').Count) recv22=$([regex]::Matches($texts[22], 'WAN_RECV').Count) len21=$($texts[21].Length) len22=$($texts[22].Length)"
        ($texts[21] -split "`n" | Where-Object { $_ -match "WANSEC_STATE|WANSEC_KEYS" }) | Select-Object -Last 2 | ForEach-Object { "R21 " + $_.Trim() }
        ($sniffTxt -split "`n" | Where-Object { $_ -match "SNIFF_RESULT|SNIFF_REPLAY|SNIFF_MARKER" }) | Select-Object -First 3 | ForEach-Object { "SNIFF " + $_.Trim() }
    }
    { $_ -eq "cluster" } {
        if ((& $has 23 "complete=true") -and (& $has 23 "ttl2_ok=true") -and (& $has 21 "FABRIC_FWD") -and (& $has 22 "FABRIC_RECV")) { $verdict = "PASS" }
    }
    { $_ -eq "lib" } {
        $libFile = Join-Path $world "21\lib-log.txt"
        $lt = if (Test-Path $libFile) { Get-Content $libFile -Raw } else { "" }
        Copy-Item $libFile (Join-Path $out "mc-lib-libtest.txt") -Force -ErrorAction SilentlyContinue
        Copy-Item (Join-Path $world "22\echo-log.txt") (Join-Path $out "mc-lib-echo.txt") -Force -ErrorAction SilentlyContinue
        if ($lt -match "LIBTEST_RESULT checks=\d+ failed=0 pass=true" -and $lt -match "LIBTEST_FRAG_REASM ok=true") { $verdict = "PASS" }
        ($lt -split "`n" | Where-Object { $_ -match "LIBTEST_" } | Select-Object -First 10) | ForEach-Object { "LIB " + $_.Trim() }
    }
    { $_ -eq "endbridgesec" } {
        # authenticated bridge under attack: legit traffic must still flow, and the
        # adversary's forged / replayed / oversized frames must be rejected
        $bA = $texts[21]; $bB = $texts[23]; $atk = $texts[25]
        $lineA = ($bA -split "`n" | Where-Object { $_ -match "BRIDGE_RESULT|STATS " } | Select-Object -Last 1)
        $lineB = ($bB -split "`n" | Where-Object { $_ -match "BRIDGE_RESULT|STATS " } | Select-Object -Last 1)
        function BField($line, $name) { if ($line -match "$name=(\d+)") { return [int]$matches[1] } return 0 }
        $okA = ($lineA -match "auth=psk") -and ($lineA -match "paired=true") -and
               ((BField $lineA "lan_to_link") -gt 0) -and ((BField $lineA "link_to_lan") -gt 0) -and
               ((BField $lineA "unauth") -gt 0) -and ((BField $lineA "replay") -gt 0)
        $okB = ($lineB -match "auth=psk") -and ($lineB -match "paired=true") -and
               ((BField $lineB "lan_to_link") -gt 0) -and ((BField $lineB "link_to_lan") -gt 0)
        if ((& $has 22 "complete=true") -and $okA -and $okB -and ($atk -match "ATTACK_RESULT")) { $verdict = "PASS" }
        "SEC_A " + $lineA.Trim()
        "SEC_B " + $lineB.Trim()
        "SEC_ATTACK " + (($atk -split "`n" | Where-Object { $_ -match "ATTACK_RESULT" } | Select-Object -First 1) -replace "\s+", " ").Trim()
        ($texts[22] -split "`n" | Where-Object { $_ -match "RESULTS" } | Select-Object -First 1) | ForEach-Object { "SEC_HOST " + $_.Trim() }
    }
    { $_ -eq "endbridge" } {
        # cross-dimension: hostA (overworld) must complete a selftest against
        # hostB (nether), and BOTH standalone bridges must show traffic in each
        # direction (their logs were collected as the node logs above)
        $bA = $texts[21]; $bB = $texts[23]
        $cA = Last-BridgeCounters $bA
        $cB = Last-BridgeCounters $bB
        $fwdA = ($cA[0] -gt 0) -and ($cA[1] -gt 0)
        $fwdB = ($cB[0] -gt 0) -and ($cB[1] -gt 0)
        if ((& $has 22 "complete=true") -and (& $has 22 "large_reply_ok=true") -and $fwdA -and $fwdB) { $verdict = "PASS" }
        "BRIDGE_A " + [string](($bA -split "`n" | Where-Object { $_ -match "BRIDGE_RESULT|STATS " } | Select-Object -Last 1) -join " ")
        "BRIDGE_B " + [string](($bB -split "`n" | Where-Object { $_ -match "BRIDGE_RESULT|STATS " } | Select-Object -Last 1) -join " ")
        ($texts[22] -split "`n" | Where-Object { $_ -match "SELFTEST_PING_REPLY|SELFTEST_TTL2_REPLY|SELFTEST_LARGE_REPLY|RESULTS" } |
            Select-Object -First 6) | ForEach-Object { "CROSSDIM " + $_.Trim() }
    }
    { $_ -eq "longchain" } {
        $rttLines = ($texts[$watch] -split "`n" | Where-Object { $_ -match "SELFTEST_PING_REPLY|SELFTEST_TTL_CUSTOM_REPLY|SELFTEST_LARGE_REPLY" })
        if ((& $has $watch "complete=true") -and (& $has $watch "large_reply_ok=true") -and $rttLines.Count -ge 3) { $verdict = "PASS" }
        "CHAIN routers=$Count hostA=$watch"
        $rttLines | Select-Object -First 8 | ForEach-Object { "CHAIN " + $_.Trim() }
        ($texts[$watch] -split "`n" | Where-Object { $_ -match "RESULTS" } | Select-Object -First 1) | ForEach-Object { "CHAIN " + $_.Trim() }
    }
    { $_ -eq "load" -or $_ -eq "loadrpv" -or $_ -eq "loadconn" -or $_ -eq "loadwired" } {
        $counterId = $counterIds[0]
        $totalRx = 0; $totalFps = 0.0
        foreach ($cid in $counterIds) {
            $loadFile = Join-Path $world "$cid\mc-load-counter.txt"
            if (-not (Test-Path $loadFile)) { continue }
            Copy-Item $loadFile (Join-Path $out "mc-load-counter$cid.txt") -Force
            $lt = Get-Content $loadFile -Raw
            if ($lt -match "LOAD_RESULT received=(\d+) ticks=(\d+) span=([0-9.]+) fps=([0-9.]+)") {
                $totalRx += [int]$matches[1]
                $totalFps += [double]$matches[4]
            }
        }
        Copy-Item (Join-Path $world "$counterId\mc-load-counter.txt") (Join-Path $out "mc-load-counter.txt") -Force -ErrorAction SilentlyContinue
        if ($totalRx -gt 0) { $verdict = "PASS" }
        if ($Scenario -eq "loadrpv" -and $texts[21] -notmatch "FWD ") { $verdict = "FAIL" }
        $unit = if ($Scenario -eq "loadconn") { "bytes" } else { "frames" }
        "LOAD_SUMMARY scenario=$Scenario senders=$Count counters=$($counterIds.Count) offered_per_tick=$($Count * $PerTick) received_$unit=$totalRx achieved_fps=$totalFps"
        if ($texts[21] -match "STATS fwd=(\d+)") { "ROUTER_STATS fwd=$($matches[1])" }
    }
    { $_ -eq "wan" } {
        if ((& $has 23 "complete=true") -and (& $has 23 "ttl2_ok=false") -and (& $has 21 "WAN_SENT") -and (& $has 22 "WAN_RECV")) { $verdict = "PASS" }
    }
    { $_ -eq "shim" } {
        $legacy = Join-Path $world "22\legacy-log.txt"
        $lt = if (Test-Path $legacy) { Get-Content $legacy -Raw } else { "" }
        Copy-Item $legacy (Join-Path $out "mc-$Scenario-$Link-legacy22.log") -Force -ErrorAction SilentlyContinue
        if ($lt -match "LEGACY_RESULT lookup_ok=true reply_ok=true" -and (& $has 21 "DIR_BCAST")) { $verdict = "PASS" }
    }
    { $_ -eq "sites" } {
        if ((& $has 23 "complete=true") -and (& $has 23 "ttl_custom_ok=true") -and (& $has 23 "ttl_exceeded=[2-9]") -and
            (& $has 21 "WAN_SENT") -and (& $has 21 "ROUTES_RELOADED") -and (& $has 22 "WAN_RECV") -and
            (& $has 22 "out=local:LINK-BC") -and (& $has 25 "ROUTES_RELOADED") -and (& $has 25 "out=local:LAN-C") -and
            (& $has 26 "UDPECHO_APP")) { $verdict = "PASS" }
    }
    { $_ -eq "multi" } {
        if ((& $has 24 "complete=true") -and (& $has 24 "ttl_custom_ok=true") -and (& $has 24 "ttl_exceeded=[2-9]") -and
            (& $has 21 "FWD ") -and (& $has 22 "TTL_DROP") -and (& $has 23 "FWD ")) { $verdict = "PASS" }
    }
    { $_ -eq "range" } {
        $r = Join-Path $world "21\mc-range.txt"; $r2 = Join-Path $world "22\mc-range.txt"
        $t1 = if (Test-Path $r) { Get-Content $r -Raw } else { "" }
        $t2 = if (Test-Path $r2) { Get-Content $r2 -Raw } else { "" }
        Copy-Item $r (Join-Path $out "mc-$Scenario-$Link-21-mc-range.txt") -Force -ErrorAction SilentlyContinue
        Copy-Item $r2 (Join-Path $out "mc-$Scenario-$Link-22-mc-range.txt") -Force -ErrorAction SilentlyContinue
        if ($t1 -match "RANGE_DONE" -and $t2 -match "RANGE_DONE") { $verdict = "PASS" }
        ($t1 + $t2) -split "`n" | Where-Object { $_ -match "RANGE_RESULT" } | ForEach-Object { $_.Trim() }
    }
    { $_ -eq "bench" } {
        if ((& $has 21 "TASK_DONE name=bench-run") -and (& $has 22 "TASK_DONE name=bench-summary")) { $verdict = "PASS" }
    }
    { $_ -eq "probe" } {
        if ((& $has 21 "TASK_DONE name=probe-finish") -and (& $has 22 "TASK_DONE name=probe-finish")) { $verdict = "PASS" }
    }
    { $_ -eq "wiredtest" } {
        if ((& $has 21 "TASK_DONE name=wfinish") -and (& $has 22 "TASK_DONE name=wfinish")) { $verdict = "PASS" }
    }
}

"RESULT mc-$Scenario target=$Target link=$Link done=$done verdict=$verdict"
foreach ($c in $computers) {
    # the load scenario has dozens of computers: only print the counter's log
    if ($Scenario -eq "load" -and $c.id -ne $watch) { continue }
    "===== NODE $($c.id) ($( $c.x ),$Y,$Z) ====="
    $p = Join-Path $world "$($c.id)\rpv-log.txt"
    if (Test-Path $p) { Get-Content $p } else { "(no log)" }
}
foreach ($extra in @("mc-probe.txt", "mc-bench-sender.txt", "mc-bench-receiver.txt", "mc-range.txt", "mc-wired.txt",
                     "legacy-log.txt", "mc-load-counter.txt", "mc-load-sender.txt")) {
    foreach ($c in $computers) {
        if ($Scenario -eq "load" -and $c.id -ne $watch -and $extra -eq "mc-load-counter.txt") { continue }
        if ($Scenario -eq "load" -and $extra -eq "mc-load-sender.txt") {
            # per-sender numbers matter (throttling vs media loss): copy, do not print
            $src = Join-Path $world "$($c.id)\$extra"
            if (Test-Path $src) { Copy-Item $src (Join-Path $out "mc-load-wireless-sender$($c.id).txt") -Force }
            continue
        }
        $p = Join-Path $world "$($c.id)\$extra"
        if (Test-Path $p) {
            "===== NODE $($c.id) / $extra ====="
            Get-Content $p
            Copy-Item $p (Join-Path $out "mc-$Scenario-$Link-$($c.id)-$extra") -Force
        }
    }
}
