# Two computer acceptance for the Pyromputer OS rpv transport, on the dedicated Fabric
# server (game 25566, rcon 25576). The harness places two computers with wireless modems,
# deploys Pyromputer OS into both (its own tools/deploy.py) and boots them with a driver that
# sends over rpv and expects an answer.
#
#   computer 20 (client) : transport=rpv, static peer map, sends to 21, then repeats on a
#                          second protocol with the map removed, so discovery is exercised
#   computer 21 (server) : transport=rpv, answers whoever speaks
#
# -Server points at the SERVER DIRECTORY (the one holding fabric-server-launch.jar), so the
# same script drives the original copy under <rpv1>\mc-server-fabric and a copy somewhere
# else; -RconPort follows that copy's rcon.port (a second instance cannot share rcon 25576,
# even when it runs alone, because the scripts are also used against a running server).
param(
    [string]$Psh = "C:\Users\ymd10\Documents\DSHWork\cc_tweaked\pyromputer-os",
    [string]$Server = "C:\Users\ymd10\Documents\DSHWork\cc_tweaked\rpv1\mc-server-fabric",
    [int]$RconPort = 25576,
    [string]$RconPassword = "rpvtest",
    [int]$TimeoutSec = 240
)
$py = "C:\Users\ymd10\.dsh\dsh-runtimes\dsh-primary-runtime\dependencies\python\python.exe"
# rcon.py lives in the rpv1 checkout whatever server it talks to; <Server>\.. is that
# checkout for the original layout, and for a copy elsewhere the path is passed in full.
$rconPy = Join-Path (Split-Path $Server -Parent) "poc\mc\rcon.py"
if (-not (Test-Path $rconPy)) {
    $rconPy = "C:\Users\ymd10\Documents\DSHWork\cc_tweaked\rpv1\poc\mc\rcon.py"
}
$world = Join-Path $Server "world\computercraft\computer"

function Rcon([string]$cmd) {
    $out = & $py $rconPy 127.0.0.1 $RconPort $RconPassword $cmd 2>&1
    return ($out -join " ")
}
function Place([int]$id, [int]$x) {
    $null = Rcon "setblock $x -60 0 computercraft:computer_normal[facing=north]"
    # a modem only becomes a peripheral when it faces the computer: one on each side, each
    # turned towards the computer, and the driver picks whichever one attaches
    $null = Rcon "setblock $($x - 1) -60 0 computercraft:wireless_modem_normal[facing=east]"
    $null = Rcon "setblock $($x + 1) -60 0 computercraft:wireless_modem_normal[facing=west]"
    $null = Rcon "setblock $x -60 -1 computercraft:wireless_modem_normal[facing=south]"
    $null = Rcon "setblock $x -60 1 computercraft:wireless_modem_normal[facing=north]"
    $null = Rcon "data merge block $x -60 0 {ComputerId:$id,On:0b}"
    return "placed computer $id at $x -60 0 with a wireless modem on its left"
}

# ---- clean band and place both computers -----------------------------------------
$null = Rcon "forceload add -48 -16 400 16"
$null = Rcon "computercraft shutdown"
Start-Sleep -Seconds 4
$null = Rcon "fill -48 -60 0 400 -60 2 air"
Place 20 0
Place 21 12

# ---- deploy Pyromputer OS into both computer directories (before they boot) -----------
foreach ($id in @(20, 21)) {
    $dir = Join-Path $world "$id"
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    Get-ChildItem $dir -Force -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
    # only what the transport needs: the full tree is 1,037,846 B and CraftOS refuses to
    # boot a computer whose filesystem is over computer_space_limit (1,000,000 default)
    Copy-Item -Recurse -Force (Join-Path $Psh "lib") (Join-Path $dir "lib")
    Copy-Item -Recurse -Force (Join-Path $Psh "rpv") (Join-Path $dir "rpv")
    $size = (Get-ChildItem $dir -Recurse -Force -File | Measure-Object -Property Length -Sum).Sum
    "  computer $id tree: $size bytes"
    if (-not (Test-Path (Join-Path $dir "lib\rpvnet.lua"))) { throw "deploy missed lib/rpvnet.lua for computer $id" }
    if (-not (Test-Path (Join-Path $dir "rpv\loader.lua"))) { throw "deploy missed rpv/loader.lua for computer $id" }
}
"deployed Pyromputer OS into computer 20 and 21"

$client = @'
local m0 = fs.open('MARKER-START', 'w') if m0 then m0.writeLine('started ' .. tostring(os.clock())) m0.close() end
local function log(fmt, ...)
    local f = fs.open("/mcush-client.log", "a")
    f.writeLine(string.format("%.2f " .. fmt, os.clock(), ...))
    f.close()
end
log("BOOT id=%d", os.getComputerID())
local okm, errm = true, nil
if periphemu then okm, errm = pcall(function() return periphemu.create("back", "modem") end) end
log("MODEM create ok=%s err=%s", tostring(okm), tostring(errm))
fs.makeDir("/etc")
local id = os.getComputerID()
local names = peripheral.getNames()
local mside = nil
for _, nm in ipairs(names) do
    if peripheral.getType(nm) == "modem" then mside = nm break end
end
log("PERIPHERALS %s chosen=%s", table.concat(names, ","), tostring(mside))
local function conf(peerline)
    local cf = fs.open("/etc/network.conf", "w")
    cf.writeLine("transport=rpv")
    if mside then cf.writeLine("rpv_side=" .. mside) cf.writeLine("modem_side=" .. mside) end
    cf.writeLine("rpv_channel=4700")
    if peerline then cf.writeLine(peerline) end
    cf.close()
end
conf("rpv_peer_21=10.0.4.21")
os.sleep(3)
package.path = package.path .. ";/lib/?.lua;/usr/?.lua"
package.loaded["rpvnet"] = nil
local ok, rpvnet = pcall(require, "rpvnet")
log("REQUIRE ok=%s", tostring(ok))
if not ok then log("SELFTEST ok=false reason=require") return end
local ab, aw = rpvnet.available()
local tb, tw = pcall(rpvnet.transport)
log("BACKEND avail=%s why=%s transport=%s terr=%s", tostring(ab), tostring(aw),
    tostring(tb and tw or "ERROR"), tostring(not tb and tw or ""))
if not ab then
    log("SELFTEST ok=false reason=unavailable why=%s", tostring(aw))
    return
end
if not tb or tw ~= "rpv" then log("SELFTEST ok=false reason=backend terr=%s", tostring(tw)) return end
-- phase 1: static peer map, plain exchange
local phase1 = false
for i = 1, 20 do
    local sent, serr = rpvnet.send(21, "hello-over-rpv", "psh-test")
    if sent then
        local sender, blob = rpvnet.receive("psh-test", 5)
        if sender then
            log("PHASE1 reply from=%s blob=%s", tostring(sender), tostring(blob))
            phase1 = (sender == 21 and blob == "reply-from-21")
            break
        end
    else
        log("PHASE1 send try=%d err=%s", i, tostring(serr))
    end
    os.sleep(1)
end
log("PHASE1 ok=%s", tostring(phase1))
-- phase 2: same thing with the static map removed, so discovery has to resolve the peer
conf(nil)
netcfg = nil
package.loaded["netcfg"] = nil
package.loaded["rpvnet"] = nil
local ok2, rpvnet2 = pcall(require, "rpvnet")
local phase2 = false
if ok2 and rpvnet2.transport() == "rpv" then
    for i = 1, 12 do
        local sent, serr = rpvnet2.send(21, "hello-discovery", "psh-disc")
        if sent then
            local sender, blob = rpvnet2.receive("psh-disc", 5)
            if sender then
                log("PHASE2 reply from=%s blob=%s", tostring(sender), tostring(blob))
                phase2 = (sender == 21 and blob == "reply-disc")
                break
            end
        else
            log("PHASE2 send try=%d err=%s", i, tostring(serr))
        end
        os.sleep(1)
    end
else
    log("PHASE2 skipped ok=%s", tostring(ok2))
end
log("PHASE2 ok=%s", tostring(phase2))
local st = rpvnet2 and rpvnet2.stats and rpvnet2.stats() or {}
local n = rpvnet2 and rpvnet2.node and rpvnet2.node() or nil
log("SELFTEST ok=%s phase1=%s phase2=%s backend=%s own_ip=%s node_tx=%s node_rx=%s",
    tostring(phase1 or phase2), tostring(phase1), tostring(phase2), tostring(st.backend),
    tostring(st.own_ip), tostring(n and n.stats and n.stats.tx), tostring(n and n.stats and n.stats.rx))
'@

$server = @'
local m0 = fs.open('MARKER-START', 'w') if m0 then m0.writeLine('started ' .. tostring(os.clock())) m0.close() end
local function log(fmt, ...)
    local f = fs.open("/mcush-server.log", "a")
    f.writeLine(string.format("%.2f " .. fmt, os.clock(), ...))
    f.close()
end
log("BOOT id=%d", tostring(os.getComputerID()))
local okm, errm = true, nil
if periphemu then okm, errm = pcall(function() return periphemu.create("back", "modem") end) end
log("MODEM create ok=%s err=%s", tostring(okm), tostring(errm))
fs.makeDir("/etc")
local names = peripheral.getNames()
local mside = nil
for _, nm in ipairs(names) do
    if peripheral.getType(nm) == "modem" then mside = nm break end
end
log("PERIPHERALS %s chosen=%s", table.concat(names, ","), tostring(mside))
local cf = fs.open("/etc/network.conf", "w")
cf.writeLine("transport=rpv")
if mside then cf.writeLine("rpv_side=" .. mside) cf.writeLine("modem_side=" .. mside) end
cf.writeLine("rpv_channel=4700")
cf.close()
os.sleep(2)
package.path = package.path .. ";/lib/?.lua;/usr/?.lua"
package.loaded["rpvnet"] = nil
local ok, rpvnet = pcall(require, "rpvnet")
local sab, saw = rpvnet.available()
local stb, stw = pcall(rpvnet.transport)
log("SERVER avail=%s why=%s transport=%s terr=%s", tostring(sab), tostring(saw),
    tostring(stb and stw or "ERROR"), tostring(not stb and stw or ""))
if not ok then return end
for i = 1, 70 do
    local sender, blob = rpvnet.receive("psh-test", 3)
    if sender then
        log("GOT psh-test from=%s blob=%s", tostring(sender), tostring(blob))
        local sent, serr = rpvnet.send(sender, "reply-from-21", "psh-test")
        log("REPLIED psh-test ok=%s err=%s", tostring(sent), tostring(serr))
    end
    local sender2, blob2 = rpvnet.receive("psh-disc", 3)
    if sender2 then
        log("GOT psh-disc from=%s blob=%s", tostring(sender2), tostring(blob2))
        local sent2, serr2 = rpvnet.send(sender2, "reply-disc", "psh-disc")
        log("REPLIED psh-disc ok=%s err=%s", tostring(sent2), tostring(serr2))
    end
end
log("server done")
'@

Set-Content -Path (Join-Path $world "20\startup.lua") -Value $client -Encoding ascii
Set-Content -Path (Join-Path $world "21\startup.lua") -Value $server -Encoding ascii

# ---- boot them -------------------------------------------------------------------
Start-Sleep -Seconds 2
"turn-on: " + (Rcon "computercraft turn-on 20")
"turn-on: " + (Rcon "computercraft turn-on 21")

$clog = Join-Path $world "20\mcush-client.log"
$slog = Join-Path $world "21\mcush-server.log"
$deadline = (Get-Date).AddSeconds($TimeoutSec)
$done = $false
while ((Get-Date) -lt $deadline) {
    Start-Sleep -Seconds 3
    if (Test-Path $clog) { if ((Get-Content $clog -Raw) -match "SELFTEST") { $done = $true; break } }
}
$c = if (Test-Path $clog) { Get-Content $clog -Raw } else { "" }
$s = if (Test-Path $slog) { Get-Content $slog -Raw } else { "" }
$p1 = $c -match "PHASE1 ok=true"
$p2 = $c -match "PHASE2 ok=true"
$got = $s -match "GOT psh-test from=20 blob=hello-over-rpv"
$verdict = "FAIL"
if ($done -and $p1 -and $got) { $verdict = "PASS" }
"RESULT psh-rpv-mc done=$done verdict=$verdict phase1=$p1 phase2=$p2 server_got=$got"
"----- client -----"
($c -split "`n") | Where-Object { $_ -match "BOOT|MODEM|REQUIRE|BACKEND|PERIPHERALS|PHASE|SELFTEST" } | Select-Object -First 12
"----- server -----"
($s -split "`n") | Where-Object { $_ -match "BOOT|REQUIRE|PERIPHERALS|SERVER avail|GOT|REPLIED" } | Select-Object -First 8
