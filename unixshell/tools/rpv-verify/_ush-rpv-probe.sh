#!/usr/bin/env bash
# Single computer probe of the unixshell rpv transport on CraftOS-PC.
#
# Writes a driver into computer 20 of a scratch data directory, boots it, and prints what
# the driver saw: the backend it picked, the interface fields, whether the stack's udp_send
# works and whether rpvnet.send works. A message addressed to the machine's own computer id
# is handed to the wire (only 127/8 is delivered locally), so RECV staying nil is expected
# here -- two computers are needed to prove delivery (see _ush-rpv-verify3.sh).
set -u

TOOL_HOME="${RPV_TOOL_HOME:-/c/Users/ymd10/AppData/Local/rpv-craftos}"
DATA="${1:-$TOOL_HOME/work/ush-rpv-test/craftos}"
EXE="${CRAFTOS_EXE:-/c/Program Files/CraftOS-PC/CraftOS-PC_console.exe}"
DIR="$DATA/computer/20"
TIMEOUT="${TIMEOUT:-60}"

if [ ! -f "$EXE" ]; then echo "error: CraftOS-PC console build not found at $EXE" >&2; exit 1; fi
if [ ! -f "$DIR/lib/rpvnet.lua" ]; then echo "error: computer 20 has no lib/rpvnet.lua (deploy first)" >&2; exit 1; fi

cat > "$DIR/startup.lua" <<'LUA'
local function log(fmt, ...)
    local f = fs.open("/probe.log", "a")
    f.writeLine(string.format("%.2f " .. fmt, os.clock(), ...))
    f.close()
end
log("BOOT id=%d", os.getComputerID())
if periphemu then pcall(function() return periphemu.create("back", "modem") end) end
fs.makeDir("/etc")
local cf = fs.open("/etc/network.conf", "w")
cf.writeLine("transport=rpv")
cf.writeLine("rpv_side=back")
cf.writeLine("rpv_channel=4700")
cf.close()
os.sleep(2)
package.path = package.path .. ";/lib/?.lua;/usr/?.lua"
package.loaded["rpvnet"] = nil
local ok, rpvnet = pcall(require, "rpvnet")
log("REQUIRE ok=%s", tostring(ok))
if not ok then return end
log("BACKEND %s", tostring(rpvnet.transport()))
local n = rpvnet.node()
if not n then log("NODE nil") return end
local iface = n.ifaces[1]
log("IFACE ip=%s(%s) net=%s(%s) prefix=%s(%s) mac=%s(%s)", tostring(iface.ip), type(iface.ip),
    tostring(iface.net), type(iface.net), tostring(iface.prefix), type(iface.prefix),
    tostring(n.mac), type(n.mac))
local okr, errr = pcall(rpvnet.receive, "probe-never", 0.2)
log("RECV(empty) ok=%s err=%s", tostring(okr), tostring(errr))
local rpv = rpvnet.stack()
local ok1, err1 = pcall(rpv.udp_send, n, iface.ip, 20001, 20001, "raw-probe")
log("RAW udp_send(dst=iface.ip) ok=%s err=%s", tostring(ok1), tostring(err1))
local ok2, err2 = pcall(rpvnet.send, os.getComputerID(), "adapter-probe", "probe-never")
log("ADAPTER send ok=%s err=%s", tostring(ok2), tostring(err2))
local ok3, err3 = pcall(rpvnet.send, os.getComputerID(), "adapter-probe", "ush-test")
log("ADAPTER send2 ok=%s err=%s", tostring(ok3), tostring(err3))
local sender, blob = rpvnet.receive("ush-test", 3)
log("RECV sender=%s blob=%s", tostring(sender), tostring(blob))
LUA
rm -f "$DIR/startup-real.lua" "$DIR/probe.log"

DATA_W="$(cygpath -w "$DATA")"
"$EXE" -d "$DATA_W" --headless --id 20 >"$DATA/probe.out.txt" 2>"$DATA/probe.err.txt" &
pid=$!
deadline=$(( $(date +%s) + TIMEOUT ))
while [ "$(date +%s)" -lt "$deadline" ]; do
    sleep 1
    if [ -f "$DIR/probe.log" ] && grep -q "RECV sender" "$DIR/probe.log"; then break; fi
    if ! kill -0 "$pid" 2>/dev/null; then break; fi
done
sleep 1
kill "$pid" 2>/dev/null
wait "$pid" 2>/dev/null

echo "=== probe.log ==="
if [ -f "$DIR/probe.log" ]; then cat "$DIR/probe.log"; else echo "(no log)"; fi
err="$(cat "$DATA/probe.err.txt" 2>/dev/null)"
if [ -n "$err" ]; then echo "=== stderr ==="; echo "$err" | head -5; fi
