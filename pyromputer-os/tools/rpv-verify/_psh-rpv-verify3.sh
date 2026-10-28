#!/usr/bin/env bash
# Two computer acceptance for the Pyromputer OS rpv transport on CraftOS-PC.
#
# Same exchange as _psh-mc-verify.sh but on the emulator: computer 20 spawns 21 with
# ccemux.openEmu (the plugin provides the API; two separate OS processes do not share a
# modem medium), both deploy only lib/ and rpv/ to stay under computer_space_limit, and the
# client proves a static peer map round trip and then a discovery round trip.
#
# Note: the client driver lives inside computer 20's startup.lua rather than in a second
# file loaded with loadfile. In this CraftOS-PC build a chunk loaded through loadfile does
# not see the shell's `package` table, so `package.path = ...` inside it fails with
# "attempt to index a nil value (global 'package')".
set -u

TOOL_HOME="${RPV_TOOL_HOME:-/c/Users/ymd10/AppData/Local/rpv-craftos}"
PSH="${PSH:-/c/Users/ymd10/Documents/DSHWork/cc_tweaked/pyromputer-os}"
DATA="${1:-$TOOL_HOME/work/psh-rpv-test/craftos}"
EXE="${CRAFTOS_EXE:-/c/Program Files/CraftOS-PC/CraftOS-PC_console.exe}"
TIMEOUT="${TIMEOUT:-150}"

if [ ! -f "$EXE" ]; then echo "error: CraftOS-PC console build not found at $EXE" >&2; exit 1; fi
if [ ! -f "$PSH/lib/rpvnet.lua" ]; then echo "error: Pyromputer OS workspace not found at $PSH" >&2; exit 1; fi

rm -rf "$DATA"
for id in 20 21; do
    d="$DATA/computer/$id"
    mkdir -p "$d"
    cp -r "$PSH/lib" "$d/lib"
    cp -r "$PSH/rpv" "$d/rpv"
    echo "  computer $id tree: $(du -sb "$d" | cut -f1) bytes"
done

cat > "$DATA/computer/20/startup.lua" <<'LUA'
local function log(fmt, ...)
    local f = fs.open("/emu-client.log", "a")
    f.writeLine(string.format("%.2f " .. fmt, os.clock(), ...))
    f.close()
end
log("BOOT id=%d", os.getComputerID())
if ccemux and ccemux.openEmu then
    for _, id in ipairs({ 21 }) do
        ccemux.openEmu(id)
        os.sleep(0.8)
    end
end
if periphemu then pcall(function() return periphemu.create("back", "modem") end) end
log("SPAWNED peripheral=%s", tostring(peripheral.getType("back")))
fs.makeDir("/etc")
local function conf(peerline)
    local cf = fs.open("/etc/network.conf", "w")
    cf.writeLine("transport=rpv")
    cf.writeLine("rpv_side=back")
    cf.writeLine("modem_side=back")
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
if not ab or not tb or tw ~= "rpv" then log("SELFTEST ok=false reason=backend") return end
local phase1 = false
for i = 1, 15 do
    local sent = rpvnet.send(21, "hello-over-rpv", "psh-test")
    if sent then
        local sender, blob = rpvnet.receive("psh-test", 5)
        if sender then
            log("PHASE1 reply from=%s blob=%s", tostring(sender), tostring(blob))
            phase1 = (sender == 21 and blob == "reply-from-21")
            break
        end
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
        local sent = rpvnet2.send(21, "hello-discovery", "psh-disc")
        if sent then
            local sender, blob = rpvnet2.receive("psh-disc", 5)
            if sender then
                log("PHASE2 reply from=%s blob=%s", tostring(sender), tostring(blob))
                phase2 = (sender == 21 and blob == "reply-disc")
                break
            end
        end
        os.sleep(1)
    end
end
log("PHASE2 ok=%s", tostring(phase2))
log("SELFTEST ok=%s phase1=%s phase2=%s", tostring(phase1 or phase2), tostring(phase1),
    tostring(phase2))
LUA
rm -f "$DATA/computer/20/startup-real.lua" "$DATA/computer/20/emu-client.log"

cat > "$DATA/computer/21/startup.lua" <<'LUA'
local function log(fmt, ...)
    local f = fs.open("/emu-server.log", "a")
    f.writeLine(string.format("%.2f " .. fmt, os.clock(), ...))
    f.close()
end
log("BOOT id=%d", os.getComputerID())
if periphemu then pcall(function() return periphemu.create("back", "modem") end) end
fs.makeDir("/etc")
local cf = fs.open("/etc/network.conf", "w")
cf.writeLine("transport=rpv")
cf.writeLine("rpv_side=back")
cf.writeLine("modem_side=back")
cf.writeLine("rpv_channel=4700")
cf.close()
os.sleep(2)
package.path = package.path .. ";/lib/?.lua;/usr/?.lua"
package.loaded["rpvnet"] = nil
local ok, rpvnet = pcall(require, "rpvnet")
log("REQUIRE ok=%s", tostring(ok))
if not ok then return end
log("SERVER backend=%s avail=%s", tostring(rpvnet.transport()), tostring(select(1, rpvnet.available())))
for i = 1, 60 do
    local sender, blob = rpvnet.receive("psh-test", 3)
    if sender then
        log("GOT psh-test from=%s blob=%s", tostring(sender), tostring(blob))
        rpvnet.send(sender, "reply-from-21", "psh-test")
    end
    local sender2, blob2 = rpvnet.receive("psh-disc", 3)
    if sender2 then
        log("GOT psh-disc from=%s blob=%s", tostring(sender2), tostring(blob2))
        rpvnet.send(sender2, "reply-disc", "psh-disc")
    end
end
log("server done")
LUA

DATA_W="$(cygpath -w "$DATA")"
"$EXE" -d "$DATA_W" --headless --id 20 >"$DATA/emu.out.txt" 2>"$DATA/emu.err.txt" &
pid=$!
deadline=$(( $(date +%s) + TIMEOUT ))
while [ "$(date +%s)" -lt "$deadline" ]; do
    sleep 2
    if [ -f "$DATA/computer/20/emu-client.log" ] && grep -q "SELFTEST" "$DATA/computer/20/emu-client.log"; then break; fi
    if ! kill -0 "$pid" 2>/dev/null; then break; fi
done
sleep 2
kill "$pid" 2>/dev/null
wait "$pid" 2>/dev/null

clog="$DATA/computer/20/emu-client.log"
slog="$DATA/computer/21/emu-server.log"
p1=no; p2=no; got=no
[ -f "$clog" ] && grep -q "PHASE1 ok=true" "$clog" && p1=yes
[ -f "$clog" ] && grep -q "PHASE2 ok=true" "$clog" && p2=yes
[ -f "$slog" ] && grep -q "GOT psh-test from=20 blob=hello-over-rpv" "$slog" && got=yes
verdict=FAIL
if [ "$p1" = yes ] && [ "$got" = yes ]; then verdict=PASS; fi
echo "RESULT psh-rpv-emu verdict=$verdict phase1=$p1 phase2=$p2 server_got=$got"
echo "----- client -----"
[ -f "$clog" ] && grep -E "BOOT|SPAWNED|REQUIRE|BACKEND|PHASE|SELFTEST" "$clog" | head -10
echo "----- server -----"
[ -f "$slog" ] && grep -E "BOOT|REQUIRE|SERVER|GOT" "$slog" | head -8
