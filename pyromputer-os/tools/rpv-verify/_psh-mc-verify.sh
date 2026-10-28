#!/usr/bin/env bash
# Two computer acceptance for the Pyromputer OS rpv transport, on the dedicated Fabric server
# (game 25566, rcon 25576).
#
# Places two computers with wireless modems on all four sides (a modem is a peripheral only
# when it faces the computer), deploys only lib/ and rpv/ into both -- the full shell tree is
# 1,037,846 bytes and a CraftOS computer refuses to boot over computer_space_limit
# (1,000,000 by default) -- and boots a driver that sends over rpv and expects an answer.
#
#   computer 20 (client) : static peer map round trip, then the same again with the map
#                          removed so discovery and its responder are exercised
#   computer 21 (server) : answers whoever speaks on either protocol
set -u

PSH="${PSH:-/c/Users/ymd10/Documents/DSHWork/cc_tweaked/pyromputer-os}"
RPV="${RPV:-/c/Users/ymd10/Documents/DSHWork/cc_tweaked/rpv1}"
PY="${RPV_PYTHON:-/c/Users/ymd10/.dsh/dsh-runtimes/dsh-primary-runtime/dependencies/python/python.exe}"
RCON_PY="$RPV/poc/mc/rcon.py"
WORLD="${RPV_MC_WORLD:-$RPV/mc-server-fabric/world/computercraft/computer}"
TIMEOUT="${TIMEOUT:-240}"

if [ ! -f "$RCON_PY" ]; then echo "error: rcon helper not found at $RCON_PY" >&2; exit 1; fi
if [ ! -f "$PSH/lib/rpvnet.lua" ]; then echo "error: Pyromputer OS workspace not found at $PSH" >&2; exit 1; fi

rcon() { "$PY" "$RCON_PY" 127.0.0.1 25576 rpvtest "$1" 2>&1 | tr -d '\r'; }

place() {
    local id="$1" x="$2"
    rcon "setblock $x -60 0 computercraft:computer_normal[facing=north]" >/dev/null
    rcon "setblock $((x - 1)) -60 0 computercraft:wireless_modem_normal[facing=east]" >/dev/null
    rcon "setblock $((x + 1)) -60 0 computercraft:wireless_modem_normal[facing=west]" >/dev/null
    rcon "setblock $x -60 -1 computercraft:wireless_modem_normal[facing=south]" >/dev/null
    rcon "setblock $x -60 1 computercraft:wireless_modem_normal[facing=north]" >/dev/null
    rcon "data merge block $x -60 0 {ComputerId:$id,On:0b}" >/dev/null
    echo "  placed computer $id at ($x,-60,0) with a modem on each side"
}

echo "=== clean the test band and place both computers ==="
rcon "forceload add -48 -16 400 16" >/dev/null
rcon "computercraft shutdown" >/dev/null
sleep 4
rcon "fill -48 -60 -2 400 -60 2 air" >/dev/null
place 20 0
place 21 12

echo "=== deploy lib/ and rpv/ (under the computer space limit) ==="
for id in 20 21; do
    d="$WORLD/$id"
    rm -rf "$d"
    mkdir -p "$d"
    cp -r "$PSH/lib" "$d/lib"
    cp -r "$PSH/rpv" "$d/rpv"
    echo "  computer $id tree: $(du -sb "$d" | cut -f1) bytes"
done

cat > "$WORLD/20/startup.lua" <<'LUA'
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
    if mside then
        cf.writeLine("rpv_side=" .. mside)
        cf.writeLine("modem_side=" .. mside)
    end
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
if not ab then log("SELFTEST ok=false reason=unavailable why=%s", tostring(aw)) return end
if not tb or tw ~= "rpv" then log("SELFTEST ok=false reason=backend terr=%s", tostring(tw)) return end
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
conf(nil)
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
log("SELFTEST ok=%s phase1=%s phase2=%s backend=%s own_ip=%s", tostring(phase1 or phase2),
    tostring(phase1), tostring(phase2), tostring(st.backend), tostring(st.own_ip))
LUA

cat > "$WORLD/21/startup.lua" <<'LUA'
local function log(fmt, ...)
    local f = fs.open("/mcush-server.log", "a")
    f.writeLine(string.format("%.2f " .. fmt, os.clock(), ...))
    f.close()
end
log("BOOT id=%d", os.getComputerID())
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
if mside then
    cf.writeLine("rpv_side=" .. mside)
    cf.writeLine("modem_side=" .. mside)
end
cf.writeLine("rpv_channel=4700")
cf.close()
os.sleep(2)
package.path = package.path .. ";/lib/?.lua;/usr/?.lua"
package.loaded["rpvnet"] = nil
local ok, rpvnet = pcall(require, "rpvnet")
log("REQUIRE ok=%s", tostring(ok))
if not ok then return end
local sab, saw = rpvnet.available()
local stb, stw = pcall(rpvnet.transport)
log("SERVER avail=%s why=%s transport=%s terr=%s", tostring(sab), tostring(saw),
    tostring(stb and stw or "ERROR"), tostring(not stb and stw or ""))
if not sab then return end
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
LUA

echo "=== boot them ==="
echo "  turn-on 20: $(rcon "computercraft turn-on 20")"
echo "  turn-on 21: $(rcon "computercraft turn-on 21")"

clog="$WORLD/20/mcush-client.log"
slog="$WORLD/21/mcush-server.log"
deadline=$(( $(date +%s) + TIMEOUT ))
done_flag=no
while [ "$(date +%s)" -lt "$deadline" ]; do
    sleep 3
    if [ -f "$clog" ] && grep -q "SELFTEST" "$clog"; then done_flag=yes; break; fi
done

p1=no; p2=no; got=no
if [ -f "$clog" ] && grep -q "PHASE1 ok=true" "$clog"; then p1=yes; fi
if [ -f "$clog" ] && grep -q "PHASE2 ok=true" "$clog"; then p2=yes; fi
if [ -f "$slog" ] && grep -q "GOT psh-test from=20 blob=hello-over-rpv" "$slog"; then got=yes; fi

verdict=FAIL
if [ "$done_flag" = yes ] && [ "$p1" = yes ] && [ "$got" = yes ]; then verdict=PASS; fi
echo "RESULT psh-rpv-mc done=$done_flag verdict=$verdict phase1=$p1 phase2=$p2 server_got=$got"
echo "----- client -----"
[ -f "$clog" ] && grep -E "BOOT|MODEM|PERIPHERALS|REQUIRE|BACKEND|PHASE|SELFTEST" "$clog" | head -12
echo "----- server -----"
[ -f "$slog" ] && grep -E "BOOT|PERIPHERALS|REQUIRE|SERVER|GOT|REPLIED" "$slog" | head -10
