#!/usr/bin/env bash
# Raw modem link test between two Minecraft computers: it isolates layer 2 from the rpv
# stack. Both computers open channel 4700, announce themselves every few seconds and log
# whatever they hear, so a silent pair means the radio link (or the modem placement) is at
# fault rather than the protocol.
set -u

RPV="${RPV:-/c/Users/ymd10/Documents/DSHWork/cc_tweaked/rpv1}"
PY="${RPV_PYTHON:-/c/Users/ymd10/.dsh/dsh-runtimes/dsh-primary-runtime/dependencies/python/python.exe}"
RCON_PY="$RPV/poc/mc/rcon.py"
WORLD="${RPV_MC_WORLD:-$RPV/mc-server-fabric/world/computercraft/computer}"
WAIT="${WAIT:-40}"

rcon() { "$PY" "$RCON_PY" 127.0.0.1 25576 rpvtest "$1" 2>&1 | tr -d '\r'; }

rcon "forceload add -48 -16 400 16" >/dev/null
rcon "computercraft shutdown" >/dev/null
sleep 4
rcon "fill -48 -60 -2 400 -60 2 air" >/dev/null
for x in 0 12; do
    rcon "setblock $x -60 0 computercraft:computer_normal[facing=north]" >/dev/null
    rcon "setblock $((x - 1)) -60 0 computercraft:wireless_modem_normal[facing=east]" >/dev/null
    rcon "setblock $((x + 1)) -60 0 computercraft:wireless_modem_normal[facing=west]" >/dev/null
    rcon "setblock $x -60 -1 computercraft:wireless_modem_normal[facing=south]" >/dev/null
    rcon "setblock $x -60 1 computercraft:wireless_modem_normal[facing=north]" >/dev/null
done
rcon "data merge block 0 -60 0 {ComputerId:20,On:0b}" >/dev/null
rcon "data merge block 12 -60 0 {ComputerId:21,On:0b}" >/dev/null
echo "  placed raw link test on 20 and 21"

for id in 20 21; do
    d="$WORLD/$id"
    rm -rf "$d"
    mkdir -p "$d"
    cat > "$d/startup.lua" <<'LUA'
local function log(fmt, ...)
    local f = fs.open("/raw.log", "a")
    f.writeLine(string.format("%.2f " .. fmt, os.clock(), ...))
    f.close()
end
local side = nil
for _, n in ipairs(peripheral.getNames()) do
    if peripheral.getType(n) == "modem" then side = n break end
end
log("START id=%d side=%s", os.getComputerID(), tostring(side))
if not side then log("NO MODEM") return end
log("WIRELESS=%s", tostring(peripheral.call(side, "isWireless")))
peripheral.call(side, "open", 4700)
log("OPEN 4700 done")
os.startTimer(1)
while true do
    local ev, p1, p2, p3, p4 = os.pullEvent()
    if ev == "timer" then
        peripheral.call(side, "transmit", 4700, 4700, "HELLO-" .. tostring(os.getComputerID()))
        log("TX HELLO-%d", os.getComputerID())
        os.startTimer(3)
    elseif ev == "modem_message" then
        log("RX ch=%s reply=%s msg=%s", tostring(p2), tostring(p3), tostring(p4))
    end
end
LUA
done

echo "  turn-on 20: $(rcon "computercraft turn-on 20")"
echo "  turn-on 21: $(rcon "computercraft turn-on 21")"
sleep "$WAIT"

verdict=FAIL
ok20=no; ok21=no
[ -f "$WORLD/20/raw.log" ] && grep -q "RX .*HELLO-21" "$WORLD/20/raw.log" && ok20=yes
[ -f "$WORLD/21/raw.log" ] && grep -q "RX .*HELLO-20" "$WORLD/21/raw.log" && ok21=yes
if [ "$ok20" = yes ] && [ "$ok21" = yes ]; then verdict=PASS; fi
echo "RESULT psh-mc-rawlink verdict=$verdict computer20_heard_21=$ok20 computer21_heard_20=$ok21"
for id in 20 21; do
    echo "----- computer $id raw.log -----"
    [ -f "$WORLD/$id/raw.log" ] && head -10 "$WORLD/$id/raw.log" || echo "(no log: the driver did not run)"
done
