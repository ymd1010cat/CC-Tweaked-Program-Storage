# Bridge link-security acceptance (CraftOS-PC): does an authenticated bridge relay
# only authenticated bytes, and does it reject an off-path adversary?
#
#   20 bridge A (server role)   LAN-A ch 4300  <-> link ch 4999   (spawns the rest)
#   21 bridge B (client role)   LAN-B ch 4301  <-> link ch 4999
#   22 attacker                 on link ch 4999: forge / HELLO / replay / oversize / bad tag
#   23 host A (rpv)             10.0.9.2 on LAN-A -- hosts use the library normally
#   24 host B (rpv)             10.0.9.3 on LAN-B
#
# Modes:
#   normal    both bridges share the PSK  -> hosts must talk across, attack rejected
#   wrongpsk  bridge B has a different PSK -> NO pairing, ZERO relayed, hosts cannot talk
#
#   pwsh -File poc\run-bridge.ps1 [-Mode normal|wrongpsk]
param(
    [ValidateSet("normal", "wrongpsk")]
    [string]$Mode = "normal",
    [int]$TimeoutSec = 90,
    [string]$Root = $env:RPV_ROOT
)

$root = $Root
if (-not $root) { $root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path) }
$data = Join-Path $root "craftos-bridge-$Mode"
$exe = "C:\Program Files\CraftOS-PC\CraftOS-PC_console.exe"
$out = Join-Path $root "poc\out"
New-Item -ItemType Directory -Force -Path $out | Out-Null

$PSK = "00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff"
$PSK_B = if ($Mode -eq "wrongpsk") { "ffeeddccbbaa99887766554433221100ffeeddccbbaa99887766554433221100" } else { $PSK }

if (Test-Path $data) { Remove-Item -Recurse -Force $data }

function Bridge-Config {
    param([string]$Role, [int]$LanCh, [string]$Psk)
    return @"
bridge_role=$Role
bridge_id=rpv1
bridge_local=back
bridge_ender=top
bridge_lan_channel=$LanCh
bridge_link_channel=4999
bridge_secs=24
bridge_psk=$Psk
bridge_psk_iter=64
bridge_allow_ethertypes=0800,0806
bridge_broadcast_per_sec=200
bridge_max_frame=4096
"@
}

# ---- 20: bridge A (server) + spawner wrapper -------------------------------
$dir = Join-Path $data "computer\20"
New-Item -ItemType Directory -Force -Path $dir | Out-Null
Copy-Item (Join-Path $root "poc\mc\ender-bridge.lua") $dir -Force
Set-Content -Path (Join-Path $dir "bridge.txt") -Value (Bridge-Config -Role "server" -LanCh 4300 -Psk $PSK) -Encoding ascii
# emulator-only glue: boot the other four computers, then hand over to the bridge
# (spawn them with a gap: opening several emulators in a tight loop makes
# CraftOS-PC race on loading its BIOS file and some instances fail to boot)
Set-Content -Path (Join-Path $dir "startup.lua") -Encoding ascii -Value @"
if ccemux and ccemux.openEmu then
    for _, id in ipairs({21, 22, 23, 24}) do
        ccemux.openEmu(id)
        os.sleep(0.8)
    end
end
os.sleep(1.5)
local fn = loadfile("ender-bridge.lua")
if fn then return fn() end
print("bridge program missing")
"@

# ---- 21: bridge B (client) --------------------------------------------------
$dir = Join-Path $data "computer\21"
New-Item -ItemType Directory -Force -Path $dir | Out-Null
Copy-Item (Join-Path $root "poc\mc\ender-bridge.lua") (Join-Path $dir "startup.lua") -Force
Set-Content -Path (Join-Path $dir "bridge.txt") -Value (Bridge-Config -Role "client" -LanCh 4301 -Psk $PSK_B) -Encoding ascii

# ---- 22: attacker -----------------------------------------------------------
$dir = Join-Path $data "computer\22"
New-Item -ItemType Directory -Force -Path $dir | Out-Null
Copy-Item (Join-Path $root "poc\mc\bridge-attacker.lua") (Join-Path $dir "startup.lua") -Force
Set-Content -Path (Join-Path $dir "attack.txt") -Encoding ascii -Value @"
attack_side=top
attack_channel=4999
attack_secs=18
attack_id=rpv1
attack_forge=20
attack_hellos=8
attack_oversize=4096
"@

# ---- 23/24: rpv hosts (use the library the normal way) ---------------------
$rpvdir = Join-Path $root "poc\rpv"
$appsdir = Join-Path $root "poc\apps"
$compatdir = Join-Path $root "poc\compat"
$bootstrap = Join-Path $root "poc\node2\startup.lua"
$hostRoles = @{
    23 = "role=host`niface=back|LAN|10.0.9.2/24|4300|256|wireless`napp=rpv-selftest:10.0.9.3`nstart_delay=6`nlarge_bytes=900`nexpect_pings=4`nexpect_ttl2=1`nexpect_ttl_exceeded=0`n"
    24 = "role=host`niface=back|LAN|10.0.9.3/24|4301|256|wireless`napp=udp-echo:7`n"
}
foreach ($id in @(23, 24)) {
    $hdir = Join-Path $data "computer\$id"
    foreach ($sub in @("rpv", "apps", "compat")) { New-Item -ItemType Directory -Force -Path (Join-Path $hdir $sub) | Out-Null }
    Copy-Item (Join-Path $rpvdir "*.lua") (Join-Path $hdir "rpv") -Force
    Copy-Item (Join-Path $appsdir "*.lua") (Join-Path $hdir "apps") -Force
    Copy-Item (Join-Path $compatdir "*.lua") (Join-Path $hdir "compat") -Force
    Copy-Item $bootstrap (Join-Path $hdir "startup.lua") -Force
    Set-Content -Path (Join-Path $hdir "role.txt") -Value $hostRoles[$id] -Encoding ascii
}

# ---- run --------------------------------------------------------------------
$stdout = Join-Path $out "bridge-$Mode.stdout.txt"
$stderr = Join-Path $out "bridge-$Mode.stderr.txt"
$proc = Start-Process -FilePath $exe -ArgumentList @("-d", "`"$data`"", "--headless", "--id", "20") `
    -RedirectStandardOutput $stdout -RedirectStandardError $stderr -PassThru -NoNewWindow

$hostLog = Join-Path $data "computer\23\rpv-log.txt"
$bridgeA = Join-Path $data "computer\20\bridge-log.txt"
$bridgeB = Join-Path $data "computer\21\bridge-log.txt"
$atkLog = Join-Path $data "computer\22\attack-log.txt"
$deadline = (Get-Date).AddSeconds($TimeoutSec)
$done = $false
while ((Get-Date) -lt $deadline) {
    Start-Sleep -Milliseconds 500
    if ($proc.HasExited) { break }
    $haveA = (Test-Path $bridgeA) -and ((Get-Content $bridgeA -Raw) -match "BRIDGE_RESULT")
    $haveB = (Test-Path $bridgeB) -and ((Get-Content $bridgeB -Raw) -match "BRIDGE_RESULT")
    $haveAtk = (Test-Path $atkLog) -and ((Get-Content $atkLog -Raw) -match "ATTACK_RESULT")
    $haveHost = (Test-Path $hostLog) -and ((Get-Content $hostLog -Raw) -match "TEST_DONE")
    if ($haveA -and $haveB -and $haveAtk -and $haveHost) { $done = $true; break }
}
Start-Sleep -Seconds 1
if (-not $proc.HasExited) { $proc.Kill() }
Start-Sleep -Milliseconds 400
# NOTE: no blanket "kill all CraftOS-PC" here on purpose -- other DSH sessions use
# computers 0-10 in their own emulators; only the process we started is stopped.

foreach ($id in @(20, 21, 22, 23, 24)) {
    foreach ($f in @("bridge-log.txt", "attack-log.txt", "rpv-log.txt")) {
        $src = Join-Path $data "computer\$id\$f"
        if (Test-Path $src) { Copy-Item $src (Join-Path $out "bridge-$Mode-node$id-$f") -Force }
    }
}

$txtA = if (Test-Path $bridgeA) { Get-Content $bridgeA -Raw } else { "" }
$txtB = if (Test-Path $bridgeB) { Get-Content $bridgeB -Raw } else { "" }
$atkPath = Join-Path $data "computer\22\attack-log.txt"
$txtAtk = if (Test-Path $atkPath) { Get-Content $atkPath -Raw } else { "" }
$txtHost = if (Test-Path $hostLog) { Get-Content $hostLog -Raw } else { "" }

# last BRIDGE_RESULT / STATS line, parsed into a hasthable
function Bridge-Stats {
    param([string]$Text)
    $line = ($Text -split "`n" | Where-Object { $_ -match "BRIDGE_RESULT|STATS " } | Select-Object -Last 1)
    $s = @{ line = "$line".Trim() }
    foreach ($k in @("relayed", "lan_to_link", "link_to_lan", "dropped", "unauth", "replay", "policy", "rate", "size", "future", "bad")) {
        if ($line -match "$k=(\d+)") { $s[$k] = [int]$matches[1] } else { $s[$k] = 0 }
    }
    $s["paired"] = ($line -match "paired=true")
    return $s
}
$a = Bridge-Stats $txtA
$b = Bridge-Stats $txtB
$attackDone = ($txtAtk -match "ATTACK_RESULT")
$attackSent = 0
if ($txtAtk -match "ATTACK_RESULT forge=(\d+)") { $attackSent = [int]$matches[1] }
$hostComplete = ($txtHost -match "complete=true")

$verdict = "FAIL"
if ($Mode -eq "normal") {
    if ($hostComplete -and $a.paired -and $b.paired -and $a.relayed -gt 0 -and $b.relayed -gt 0 `
        -and $a.unauth -gt 0 -and $a.replay -gt 0 -and $attackDone) { $verdict = "PASS" }
} else {
    # fail-closed: nothing relayed, no pairing, and the hosts could not talk
    if ((-not $a.paired) -and (-not $b.paired) -and $a.relayed -eq 0 -and $b.relayed -eq 0 `
        -and (-not $hostComplete) -and $a.unauth -gt 0 -and $attackDone) { $verdict = "PASS" }
}

"RESULT bridge mode=$Mode done=$done verdict=$verdict"
"BRIDGE_A $($a.line)"
"BRIDGE_B $($b.line)"
"ATTACK   " + (($txtAtk -split "`n" | Where-Object { $_ -match "ATTACK_RESULT|FORGE|HELLO|REPLAY|OVERSIZE|BADTAG" }) -join " | ")
"HOST_A   complete=$hostComplete"
if ($Mode -eq "wrongpsk") {
    "WRONGPSK_EVIDENCE " + (($txtA -split "`n" | Where-Object { $_ -match "AUTH_FAIL" } | Select-Object -First 2) -join " | ")
}
