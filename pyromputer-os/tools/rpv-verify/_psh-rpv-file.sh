#!/usr/bin/env bash
# Chunked file transfer acceptance on CraftOS-PC: two computers in one emulator process,
# transport=rpv, the real rget and rput command entry points, and a file large enough that
# the stream path in lib/xfer.lua runs for many chunks (and, with a 4096 byte chunk against
# the rpv MTU of 512, IP fragmentation and reassembly run too).
#
#   computer 20   spawns 21, then acts as the peer: serves /big.bin, stores the pushed copy
#                 in /var/net/incoming and compares it with the source
#   computer 21   the client: netcmds.main as "rget" then "rput"
#
# One process because a CraftOS-PC wireless modem only reaches computers inside the same
# emulator process; ccemux.openEmu is what makes the second computer exist, so both drivers
# are top level startup.lua files (a chunk loaded with loadfile has no package/require).
#
# A CraftOS computer refuses to boot when its filesystem is over computer_space_limit, and
# the shell tree is about 1.0 MB on its own, so the limit is raised in the data directory's
# config before anything is deployed (the option is read at startup). Ported from
# ps1/_psh-rpv-file.ps1; the acceptance logic is unchanged.
set -u

TOOL_HOME="${RPV_TOOL_HOME:-/c/Users/ymd10/AppData/Local/rpv-craftos}"
PSH="${PSH:-/c/Users/ymd10/Documents/DSHWork/cc_tweaked/pyromputer-os}"
WORK="${1:-$TOOL_HOME/work/psh-rpv-file}"
PY="${RPV_PYTHON:-/c/Users/ymd10/.dsh/dsh-runtimes/dsh-primary-runtime/dependencies/python/python.exe}"
EXE="${CRAFTOS_EXE:-/c/Program Files/CraftOS-PC/CraftOS-PC_console.exe}"
PEER="${PEER:-20}"
CLIENT="${CLIENT:-21}"
BYTES="${BYTES:-200000}"
CHUNK="${CHUNK:-4096}"
TIMEOUT="${TIMEOUT:-900}"
DATA="$WORK/craftos"

[ -f "$EXE" ] || { echo "error: emulator not found at $EXE" >&2; exit 1; }
[ -f "$PSH/lib/rpvnet.lua" ] || { echo "error: Pyromputer OS workspace not found at $PSH" >&2; exit 1; }

rm -rf "$DATA"
mkdir -p "$DATA/config"
cat > "$DATA/config/global.json" <<'JSON'
{
    "computerSpaceLimit": 8000000,
    "clockSpeed": 20,
    "logErrors": false
}
JSON

for id in "$PEER" "$CLIENT"; do
    target="$DATA/computer/$id"
    mkdir -p "$target/etc"
    "$PY" "$PSH/tools/deploy.py" --target "$(cygpath -w "$target")" --source "$(cygpath -w "$PSH")" --quiet >/dev/null
    cat > "$target/etc/network.conf" <<'CONF'
transport=rpv
rpv_side=back
rpv_channel=4700
rpv_mtu=512
rpv_reasm_bytes=524288
rpv_reasm_entries=128
# Small on purpose: this run moves 200 KB and the node logs every frame event (about
# 14.5 KB of log per 200 KB moved), so a 8 KB cap is passed several times and the
# rotation is exercised on a real runtime instead of only in the PC suite. A real
# machine can leave the default (131072) or set 0 to turn the cap off.
rpv_log_max_bytes=8192
CONF
    cat > "$target/etc/pkg.conf" <<CONF
channel=psh-file
key=rpv-file-acceptance
modem_side=back
chunk_size=$CHUNK
timeout=15
retries=6
CONF
done

# The payload, on disk before the emulator starts so the peer can serve it at once.
"$PY" -c "import sys; n=int(sys.argv[2]); open(sys.argv[1],'wb').write(bytes((32 + (i*7) % 95) for i in range(n)))" \
    "$(cygpath -w "$DATA/computer/$PEER/big.bin")" "$BYTES"
echo "deployed $PEER (peer) and $CLIENT (client); payload $BYTES bytes, chunk $CHUNK bytes"

cat > "$DATA/computer/$PEER/startup.lua" <<'LUA'
-- peer: boot the client, serve one pull, accept one push, compare the copy.
local function mark(where, s)
    local f = fs.open(where, "a")
    f.writeLine(string.format("%.2f %s", os.clock(), s))
    f.close()
end

mark("/srv.log", "peer start id=" .. tostring(os.getComputerID()))
mark("/srv.log", "ccemux=" .. tostring(ccemux ~= nil) ..
     " openEmu=" .. tostring(ccemux and ccemux.openEmu ~= nil))

if ccemux and ccemux.openEmu then
    local spawned, serr = pcall(ccemux.openEmu, 21)
    mark("/srv.log", "openEmu 21 ok=" .. tostring(spawned) .. " err=" .. tostring(serr))
    os.sleep(1.0)
end

-- a modem is a peripheral only when one faces the computer, and creating a modem on a side
-- that already has one would replace it: create it only when the side is not a modem already
local okm, errm = true, "already present"
for _ = 1, 20 do
    if peripheral.getType("back") == "modem" then break end
    okm, errm = pcall(function() return periphemu.create("back", "modem") end)
    if peripheral.getType("back") == "modem" then break end
    os.sleep(0.25)
end
mark("/srv.log", "modem ok=" .. tostring(okm) .. " err=" .. tostring(errm) ..
     " type=" .. tostring(peripheral.getType("back")))
os.sleep(1)

package.path = package.path .. ";/lib/?.lua;/usr/?.lua"
local rpvnet   = require("rpvnet")
local netcfg   = require("netcfg")
local xfer     = require("xfer")
local checksum = require("checksum")

local avail, why = rpvnet.available()
mark("/srv.log", "avail=" .. tostring(avail) .. " why=" .. tostring(why))
local okt, backend = pcall(rpvnet.transport)
mark("/srv.log", "transport ok=" .. tostring(okt) .. " backend=" .. tostring(backend))

local opened, oerr = netcfg.open()
mark("/srv.log", "open=" .. tostring(opened) .. " err=" .. tostring(oerr))

local f = fs.open("/big.bin", "r")
local src = f.readAll()
f.close()
mark("/srv.log", "serving /big.bin size=" .. #src ..
     " crc=" .. string.format("%08x", checksum.crc32(src)))

-- two machines in one process share no filesystem, so the peer cannot wait for a marker file
-- the client wrote: it binds its port and serves right away, and the client retries if early
os.sleep(5)

local deadline = os.epoch("utc") + 600 * 1000
while os.epoch("utc") < deadline do
    local t0 = os.clock()
    local sender, blob = rpvnet.receive("psh-file", 5)
    mark("/srv.log", string.format("recv wait=%.2fs sender=%s", os.clock() - t0, tostring(sender)))
    if sender ~= nil then
        local msg = netcfg.unpack(blob)
        if msg and msg.action == xfer.ACTION then
            mark("/srv.log", "request op=" .. tostring(msg.op) .. " from=" .. tostring(sender))
            local sok, info = xfer.serve(sender, msg, {
                save_dir = "/var/net/incoming", root = "/var/net/incoming", overwrite = true,
            })
            mark("/srv.log", "served ok=" .. tostring(sok) .. " info=" .. tostring(info))
        else
            mark("/srv.log", "ignored a message from " .. tostring(sender))
        end
    end
    if fs.exists("/var/net/incoming/marker.txt") then break end
end

local verdict = "NO-PUSH"
if fs.exists("/var/net/incoming/big.bin") then
    local rf = fs.open("/var/net/incoming/big.bin", "r")
    local got = rf.readAll()
    rf.close()
    mark("/srv.log", "pushed size=" .. #got ..
         " crc=" .. string.format("%08x", checksum.crc32(got)) ..
         " same_as_source=" .. tostring(got == src))
    verdict = (got == src) and "PASS" or "FAIL"
else
    mark("/srv.log", "no pushed file arrived")
end
mark("/srv.log", "SERVER_VERDICT " .. verdict)

local o = fs.open("/server-result", "w")
o.writeLine(verdict)
o.close()
LUA

cat > "$DATA/computer/$CLIENT/startup.lua" <<'LUA'
-- client: the real rget and rput command entry points, over the rpv transport.
local function mark(where, s)
    local f = fs.open(where, "a")
    f.writeLine(string.format("%.2f %s", os.clock(), s))
    f.close()
end

mark("/cli.log", "client start id=" .. tostring(os.getComputerID()))
local okm, errm = pcall(function() return periphemu.create("back", "modem") end)
mark("/cli.log", "modem ok=" .. tostring(okm) .. " err=" .. tostring(errm))
os.sleep(2)

package.path = package.path .. ";/lib/?.lua;/usr/?.lua"
local rpvnet   = require("rpvnet")
local checksum = require("checksum")

local avail, why = rpvnet.available()
mark("/cli.log", "avail=" .. tostring(avail) .. " why=" .. tostring(why))
local okt, backend = pcall(rpvnet.transport)
mark("/cli.log", "transport ok=" .. tostring(okt) .. " backend=" .. tostring(backend))

-- open the node and announce ourselves on the data channel: the peer learns our address
-- from that datagram, so neither side needs a static peer map
local okc, cerr = require("netcfg").open()
mark("/cli.log", "open=" .. tostring(okc) .. " err=" .. tostring(cerr))
rpvnet.broadcast("client-online", "psh-file")
mark("/cli.log", "announced")

local out = {}
local writer = {}
function writer.write(text)
    table.insert(out, tostring(text))
end

-- The xfer state machine writes its own account of the conversation here. Without it a
-- run says only that the transfer passed or failed; with it the log shows which branch
-- was taken, which is what a failure needs to be read from. For a push the opening now
-- reads "put request sent (attempt 1/2) with block 1/N" followed by "put answer: ack" --
-- the block's answer standing in for the `ready` that used to be the single point of
-- failure. See ROADMAP.md section 1.2.
local xfer = require("xfer")
xfer.trace = function(line) mark("/cli.log", "trace| " .. line) end
mark("/cli.log", "xfer.trace installed")

-- the dispatch of the command files, called the way the shell calls them (a chunk made by
-- loadfile has no package library, so /usr/cmd/rget.lua itself cannot be the entry point)
local netcmds = require("netcmds")
mark("/cli.log", "netcmds main=" .. tostring(netcmds.main))

local code, attempts = 1, 0
local started = os.epoch("utc")
while attempts < 10 do
    attempts = attempts + 1
    out = {}
    code = netcmds.main({ "-t", "20", "-o", "/copy.bin", "/big.bin", "-w", "5", "-r", "3" },
                        { _out = writer }, { title = "rget" })
    mark("/cli.log", "rget attempt " .. attempts .. " exit=" .. tostring(code))
    if code == 0 then break end
    os.sleep(2)
end
mark("/cli.log", "rget attempts=" .. attempts .. " exit=" .. tostring(code) ..
     " in " .. string.format("%.1f", (os.epoch("utc") - started) / 1000) .. "s")
for _, line in ipairs(out) do mark("/cli.log", "rget| " .. line) end

local arrived, crc = 0, "nil"
if fs.exists("/copy.bin") then
    local cf = fs.open("/copy.bin", "r")
    local body = cf.readAll()
    cf.close()
    arrived = #body
    crc = string.format("%08x", checksum.crc32(body))
end
mark("/cli.log", "pulled size=" .. arrived .. " crc=" .. crc)

if code == 0 and arrived > 0 then
    local out2 = {}
    local writer2 = {}
    function writer2.write(text)
        table.insert(out2, tostring(text))
    end
    local mf = fs.open("/marker.txt", "w")
    mf.writeLine("client done")
    mf.close()

    local started2 = os.epoch("utc")
    local code2, tries = 1, 0
    local push_opts = { "-t", "20", "-p", "/var/net/incoming/big.bin", "-f", "/copy.bin",
                        "-w", "5", "-r", "3" }
    while tries < 20 do
        tries = tries + 1
        out2 = {}
        code2 = netcmds.main(push_opts, { _out = writer2 }, { title = "rput" })
        mark("/cli.log", "rput attempt " .. tries .. " exit=" .. tostring(code2))
        if code2 == 0 then break end
        os.sleep(2)
    end
    mark("/cli.log", "rput attempts=" .. tries .. " exit=" .. tostring(code2) .. " in " ..
         string.format("%.1f", (os.epoch("utc") - started2) / 1000) .. "s")
    for _, line in ipairs(out2) do mark("/cli.log", "rput| " .. line) end

    -- the marker goes last: when the peer has stored it, both transfers are over
    local code3 = netcmds.main(
        { "-t", "20", "-p", "/var/net/incoming/marker.txt", "-f", "/marker.txt" },
        { _out = writer2 }, { title = "rput" })
    mark("/cli.log", "marker rput exit=" .. tostring(code3))
    mark("/cli.log", "CLIENT_VERDICT " ..
         ((code2 == 0 and code3 == 0) and "PASS" or "FAIL"))
else
    mark("/cli.log", "CLIENT_VERDICT FAIL")
end

os.sleep(10)
LUA

echo "drivers written"
"$EXE" -d "$(cygpath -w "$DATA")" --headless --id "$PEER" >"$WORK/emu.out.txt" 2>"$WORK/emu.err.txt" &
pid=$!
done_file="$DATA/computer/$PEER/server-result"
deadline=$(( $(date +%s) + TIMEOUT ))
while [ "$(date +%s)" -lt "$deadline" ]; do
    sleep 1
    [ -f "$done_file" ] && break
    kill -0 "$pid" 2>/dev/null || break
done
sleep 3
kill "$pid" 2>/dev/null
wait "$pid" 2>/dev/null
echo "emulator stopped"

for f in "$PEER/srv.log" "$CLIENT/cli.log"; do
    # A summary by pattern, not a tail: a repeated failure has to stay visible, and the
    # full logs are on disk either way. See log_summary.py for why (a ten line tail once
    # turned three failed requests into one).
    if [ -f "$DATA/computer/$f" ]; then
        "$PY" "$(dirname "$0")/log_summary.py" "$DATA/computer/$f" --title "$f"
    else
        echo "----- $f -----"
        echo "  (missing)"
    fi
done

# The xfer state machine's own account, when the run installed one.
for f in "$CLIENT/cli.log"; do
    if [ -f "$DATA/computer/$f" ] && grep -q "^[0-9.]* trace|" "$DATA/computer/$f" 2>/dev/null; then
        echo "----- $f (xfer trace) -----"
        grep -E "^[0-9.]* trace\|" "$DATA/computer/$f" | sed 's/^[0-9.]* trace| /  /'
    fi
done

result="MISSING"
[ -f "$done_file" ] && result="$(tr -d ' \r\n' < "$done_file")"
echo "RESULT psh-rpv-file server=$result"
