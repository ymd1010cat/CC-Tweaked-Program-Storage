#!/usr/bin/env bash
# Write/boot order probe for a Minecraft CraftOS computer: does a startup.lua written before
# the first boot run, or does the computer have to boot once first? Both orders are tried and
# the marker files are reported.
set -u

RPV="${RPV:-/c/Users/ymd10/Documents/DSHWork/cc_tweaked/rpv1}"
PY="${RPV_PYTHON:-/c/Users/ymd10/.dsh/dsh-runtimes/dsh-primary-runtime/dependencies/python/python.exe}"
RCON_PY="$RPV/poc/mc/rcon.py"
WORLD="${RPV_MC_WORLD:-$RPV/mc-server-fabric/world/computercraft/computer}"
DIR="$WORLD/20"

rcon() { "$PY" "$RCON_PY" 127.0.0.1 25576 rpvtest "$1" 2>&1 | tr -d '\r'; }

reset_computer() {
    rcon "forceload add -48 -16 400 16" >/dev/null
    rcon "computercraft shutdown" >/dev/null
    sleep 3
    rcon "fill -48 -60 0 400 -60 2 air" >/dev/null
    rcon "setblock 0 -60 0 computercraft:computer_normal[facing=north]" >/dev/null
    rcon "setblock 1 -60 0 computercraft:wireless_modem_normal[facing=west]" >/dev/null
    rcon "data merge block 0 -60 0 {ComputerId:20,On:0b}" >/dev/null
    mkdir -p "$DIR"
    rm -f "$DIR"/*
}

echo "=== ORDER A: write startup.lua first, then turn on ==="
reset_computer
cat > "$DIR/startup.lua" <<'LUA'
local f = fs.open("/probeA.log", "w")
f.writeLine("A ran at " .. tostring(os.clock()))
f.close()
LUA
echo "  turn-on: $(rcon "computercraft turn-on 20")"
sleep 25
a=no
[ -f "$DIR/probeA.log" ] && a=yes
echo "  probeA.log exists: $a"
echo "  dir files        : $(ls "$DIR" 2>/dev/null | tr '\n' ' ')"

echo "=== ORDER B: boot once, then shutdown, write, boot again ==="
rcon "computercraft shutdown" >/dev/null
sleep 3
rcon "computercraft turn-on 20" >/dev/null
sleep 15
echo "  dir after plain boot: $(ls "$DIR" 2>/dev/null | tr '\n' ' ')"
cat > "$DIR/startup.lua" <<'LUA'
local f = fs.open("/probeB.log", "w")
f.writeLine("B ran at " .. tostring(os.clock()))
f.close()
LUA
rcon "computercraft shutdown" >/dev/null
sleep 3
rcon "computercraft turn-on 20" >/dev/null
sleep 25
b=no
[ -f "$DIR/probeB.log" ] && b=yes
echo "  probeB.log exists: $b"
echo "  dir files        : $(ls "$DIR" 2>/dev/null | tr '\n' ' ')"
[ -f "$DIR/probeA.log" ] && echo "  A content: $(cat "$DIR/probeA.log")"
[ -f "$DIR/probeB.log" ] && echo "  B content: $(cat "$DIR/probeB.log")"
verdict=FAIL
if [ "$a" = yes ] && [ "$b" = yes ]; then verdict=PASS; fi
echo "RESULT ush-mc-probe orderA=$a orderB=$b verdict=$verdict"
