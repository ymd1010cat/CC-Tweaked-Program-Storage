# The chunked file transfer acceptance on a real Minecraft server (game 25566,
# rcon 25576): two CraftOS computers on the dedicated Fabric server, the full
# shell deployed into both, transport=rpv, a 200 KB file pulled and pushed back
# with the real rget / rput commands. This is the real hardware twin of
# _psh-rpv-file.ps1 (CraftOS-PC).
#
#   computer 20   peer: builds /big.bin, serves it with xfer.serve, stores the
#                 pushed copy in /var/net/incoming and compares the two
#   computer 21   client: rget then rput, with a short timeout so a slow start
#                 is retried instead of failing
#
# -Server points at the SERVER DIRECTORY (the one holding fabric-server-launch.jar),
# so this script drives either the original copy under <rpv1>\mc-server-fabric or a
# copy elsewhere; -RconPort follows that copy's rcon.port. A copy in a fresh world
# needs no preparation: the computer directories are created here before the
# computers boot, and CraftOS adopts a directory that is already there.
#
# Fragment pacing is OFF by default (-FragPace 1 turns it on, -FragPaceMs sets the
# gap). Read the note in tools\rpv-verify\README.md before turning it on: at 10 ms a
# paced run pulled the file correctly but then hung during the push, so the safe setting
# is the unpaced path the successes were measured with.
#
# The server has to be running (see the head of this file for its ports) and its
# computercraft-server.toml needs computer_space_limit above the shell tree: the
# full tree is about 1.1 MB and a computer over the limit refuses to boot
# silently. The script raises the limit itself and restarts the server, because
# the option is read at startup.
param(
    [string]$Psh = "C:\Users\ymd10\Documents\DSHWork\cc_tweaked\pyromputer-os",
    [string]$Server = "C:\Users\ymd10\Documents\DSHWork\cc_tweaked\rpv1\mc-server-fabric",
    [int]$RconPort = 25576,
    [string]$RconPassword = "rpvtest",
    [int]$Bytes = 200000,
    [int]$Chunk = 4096,
    [int]$TimeoutSec = 900,
    [int]$SpaceLimit = 8000000,
    [int]$FragPace = 0,
    [int]$FragPaceMs = 20,
    [switch]$ClientTrace,
    [switch]$ServerAlreadyRunning
)
$py = "C:\Users\ymd10\.dsh\dsh-runtimes\dsh-primary-runtime\dependencies\python\python.exe"
# rcon.py comes from the rpv1 checkout; the server may be a copy elsewhere.
$rconPy = Join-Path (Split-Path $Server -Parent) "poc\mc\rcon.py"
if (-not (Test-Path $rconPy)) {
    $rconPy = "C:\Users\ymd10\Documents\DSHWork\cc_tweaked\rpv1\poc\mc\rcon.py"
}
$mc = $Server
$world = Join-Path $mc "world\computercraft\computer"
$toml = Join-Path $mc "config\computercraft-server.toml"

function Rcon([string]$cmd) {
    $out = & $py $rconPy 127.0.0.1 $RconPort $RconPassword $cmd 2>&1
    return ($out -join " ")
}
function Place([int]$id, [int]$x) {
    $null = Rcon "setblock $x -60 0 computercraft:computer_normal[facing=north]"
    # a modem is a peripheral only when it faces the computer
    $null = Rcon "setblock $($x - 1) -60 0 computercraft:wireless_modem_normal[facing=east]"
    $null = Rcon "setblock $($x + 1) -60 0 computercraft:wireless_modem_normal[facing=west]"
    $null = Rcon "setblock $x -60 -1 computercraft:wireless_modem_normal[facing=south]"
    $null = Rcon "setblock $x -60 1 computercraft:wireless_modem_normal[facing=north]"
    $null = Rcon "data merge block $x -60 0 {ComputerId:$id,On:0b}"
    return "placed computer $id at $x -60 0"
}

# ---- disk quota, then the server so it picks the new limit up ---------------------
if (-not $ServerAlreadyRunning) {
    "stopping the server if it runs"
    Get-Process java -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 3
    $text = Get-Content $toml -Raw
    if ($text -notmatch "(?m)^computer_space_limit\s*=\s*$SpaceLimit") {
        $text = $text -replace "(?m)^computer_space_limit\s*=\s*\d+", "computer_space_limit = $SpaceLimit"
        Set-Content -Path $toml -Value $text -Encoding utf8
    }
    "computer_space_limit: " + ((Select-String -Path $toml -Pattern "^computer_space_limit").Line.Trim())
    "starting the server (this takes a while)"
    $log = Join-Path $mc "psh-mc-file-server.log"
    $proc = Start-Process -FilePath "java" -ArgumentList @("-Xmx3G", "-jar", "fabric-server-launch.jar", "nogui") `
        -WorkingDirectory $mc -RedirectStandardOutput $log -RedirectStandardError (Join-Path $mc "psh-mc-file-server.err") `
        -PassThru -NoNewWindow
    $deadline = (Get-Date).AddSeconds(300)
    $up = $false
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 5
        if (Test-Path $log) {
            $tail = Get-Content $log -Tail 40 -ErrorAction SilentlyContinue
            if (($tail -join "`n") -match 'Done \(') { $up = $true; break }
            if ($proc.HasExited) { break }
        }
    }
    if (-not $up) { "server did not come up; see $log"; exit 1 }
    "server is up"
}

# ---- a clean band and two computers ----------------------------------------------
$null = Rcon "forceload add -48 -16 400 16"
$null = Rcon "computercraft shutdown"
Start-Sleep -Seconds 4
$null = Rcon "fill -48 -60 0 400 -60 2 air"
Place 20 0
Place 21 12

# ---- deploy the full shell into both, before they boot --------------------------
foreach ($id in @(20, 21)) {
    $dir = Join-Path $world "$id"
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    Get-ChildItem $dir -Force -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
    & $py (Join-Path $Psh "tools\deploy.py") --target $dir --source $Psh --quiet | Out-Null
    $etc = Join-Path $dir "etc"
    New-Item -ItemType Directory -Force -Path $etc | Out-Null
    $netconf = Join-Path $etc "network.conf"
    Set-Content -Path $netconf -Encoding ascii -Value @(
        "transport=rpv",
        "rpv_channel=4700",
        "rpv_mtu=512",
        "rpv_reasm_bytes=524288",
        "rpv_reasm_entries=128",
        # Fragment pacing: on real hardware a whole datagram handed to the modem in one
        # loop can be dropped (a 4096 byte chunk is thirteen fragments; a run before this
        # knob existed logged FRAGMENTED 144 and REASSEMBLED 0). The values are spliced
        # in afterwards on purpose: inside a single quoted here-string the parameters
        # would be written literally, which is how a paced run once went out unpaced.
        "rpv_frag_pace=__FRAG_PACE__",
        "rpv_frag_pace_ms=__FRAG_PACE_MS__",
        "rpv_peer_20=10.0.4.20"
    )
    $nettext = Get-Content $netconf -Raw
    $nettext = $nettext.Replace("__FRAG_PACE__", "$FragPace").Replace("__FRAG_PACE_MS__", "$FragPaceMs")
    [IO.File]::WriteAllText($netconf, $nettext, (New-Object Text.UTF8Encoding($false)))
    Set-Content -Path (Join-Path $etc "pkg.conf") -Encoding ascii -Value @(
        "channel=psh-mc-file",
        "key=rpv-mc-file",
        "chunk_size=$Chunk",
        "timeout=15",
        "retries=6"
    )
    $size = (Get-ChildItem $dir -Recurse -Force -File | Measure-Object -Property Length -Sum).Sum
    "  computer $id tree: $size bytes"
    if (-not (Test-Path (Join-Path $dir "lib\rpvnet.lua"))) { throw "deploy missed lib/rpvnet.lua for $id" }
}

$peer = @'
-- peer: build the payload, answer the hello, serve one pull and one push.
local function log(fmt, ...)
    local f = fs.open("/mcfile-peer.log", "a")
    f.writeLine(string.format("%.2f " .. fmt, os.clock(), ...))
    f.close()
end

log("BOOT id=%d", os.getComputerID())
-- the shell tree is deployed before the computer boots, so this runs instead of
-- the first boot wizard: the driver is the startup chunk itself
local names = peripheral.getNames()
local mside = nil
for _, nm in ipairs(names) do
    if peripheral.getType(nm) == "modem" then mside = nm break end
end
log("PERIPHERALS %s chosen=%s", table.concat(names, ","), tostring(mside))
-- The network configuration the harness wrote is KEPT and only completed here. An
-- earlier version rewrote /etc/network.conf from scratch on boot, which silently threw
-- away everything the script had put in it -- the fragment pacing setting among them,
-- so a run that was meant to be paced went out unpaced and the log could not say why.
local function conf()
    local kept = {}
    local rf = fs.open("/etc/network.conf", "r")
    if rf then
        local text = rf.readAll()
        rf.close()
        for line in text:gmatch("[^\r\n]+") do
            local key = line:match("^%s*([%w_]+)%s*=")
            -- the modem side is discovered here, so that one line is replaced, and a
            -- trailing empty line is dropped
            if line:match("%S") and key ~= "rpv_side" and key ~= "modem_side" then
                kept[#kept + 1] = line
            end
        end
    end
    local cf = fs.open("/etc/network.conf", "w")
    for _, line in ipairs(kept) do cf.writeLine(line) end
    if not table.concat(kept, "\n"):find("transport=", 1, true) then
        cf.writeLine("transport=rpv")
    end
    cf.writeLine("rpv_channel=4700")
    if mside then cf.writeLine("rpv_side=" .. mside) cf.writeLine("modem_side=" .. mside) end
    if not table.concat(kept, "\n"):find("rpv_reasm_bytes=", 1, true) then
        cf.writeLine("rpv_reasm_bytes=524288")
        cf.writeLine("rpv_reasm_entries=128")
    end
    cf.close()
    local lf = fs.open("/mcfile-peer.log", "a")
    local vf = fs.open("/etc/network.conf", "r")
    lf.writeLine("CONF " .. vf.readAll():gsub("\n", " | "))
    lf.close()
    vf.close()
end
conf()
os.sleep(3)

package.path = package.path .. ";/lib/?.lua;/usr/?.lua"
package.loaded["rpvnet"] = nil
package.loaded["netcfg"] = nil
local rpvnet = require("rpvnet")
local netcfg = require("netcfg")
local xfer = require("xfer")
local checksum = require("checksum")

local ab, aw = rpvnet.available()
local tb, twn = pcall(rpvnet.transport)
log("BACKEND avail=%s why=%s transport=%s", tostring(ab), tostring(aw),
    tostring(tb and twn or "ERROR"))
if not ab then log("PEER_VERDICT FAIL reason=no-rpv") return end

-- the payload: deterministic, built here so the peer really owns it. The size is
-- a constant line the script rewrites from its -Bytes parameter.
local size = 200000
local parts = {}
for i = 1, size do
    parts[#parts + 1] = string.char(32 + (i * 7) % 95)
end
local src = table.concat(parts)
local f = fs.open("/big.bin", "w") f.write(src) f.close()
local crc = string.format("%08x", checksum.crc32(src))
log("PAYLOAD %d bytes crc=%s", #src, crc)

local opened, oerr = netcfg.open()
log("OPEN ok=%s err=%s", tostring(opened), tostring(oerr))

-- The peer keeps its own trace when the run asks for one: it is a different computer, so
-- the two logs are what let a failure be read from both ends at once.
__PEER_TRACE__

-- hello phase: the client announces itself, this answers, then the loop serves
for i = 1, 120 do
    local sender, blob = rpvnet.receive("psh-mc-hello", 5)
    if sender then
        log("HELLO from=%s", tostring(sender))
        rpvnet.send(sender, "peer-here", "psh-mc-hello")
        break
    end
end

local deadline = os.epoch("utc") + 600 * 1000
-- The peer answers one request at a time, which is what a daemon does. A request that
-- arrives while a transfer is running is queued by xfer itself and drained here before the
-- peer goes back to waiting: without that drain the queued request would never be served,
-- which is how a client's push used to be lost while the peer finished the previous pull.
local serve_opts = {
    save_dir = "/var/net/incoming", root = "/var/net/incoming", overwrite = true,
    report = function(line) log("queued: %s", line) end,
}
while os.epoch("utc") < deadline do
    local sender, blob = rpvnet.receive("psh-mc-file", 5)
    if sender ~= nil then
        local msg = netcfg.unpack(blob)
        if msg and msg.action == xfer.ACTION then
            log("REQUEST op=%s from=%s", tostring(msg.op), tostring(sender))
            if msg.op == nil then
                -- A request that decoded to the right action but has no operation is the
                -- shape a stalled push shows up as. Print what DID arrive: which keys are
                -- present says whether the sender built a short table or the datagram lost
                -- part of itself on the way.
                local keys = {}
                for k in pairs(msg) do keys[#keys + 1] = tostring(k) end
                table.sort(keys)
                log("MALFORMED op=nil keys=%s blob=%d bytes", table.concat(keys, ","), #blob)
            end
            local ok, info = xfer.serve(sender, msg, serve_opts)
            log("SERVED ok=%s info=%s", tostring(ok), tostring(info))
            local queued = xfer.serve_pending(serve_opts)
            if queued > 0 then log("DRAINED %d queued request(s)", queued) end
        else
            log("IGNORED action=%s op=%s", tostring(msg and msg.action), tostring(msg and msg.op))
        end
    end
    if fs.exists("/var/net/incoming/marker.txt") then break end
end

local verdict = "NO-PUSH"
if fs.exists("/var/net/incoming/big.bin") then
    local rf = fs.open("/var/net/incoming/big.bin", "r")
    local got = rf.readAll()
    rf.close()
    local same = (got == src)
    log("PUSHED %d bytes crc=%s same=%s", #got, string.format("%08x", checksum.crc32(got)),
        tostring(same))
    verdict = same and "PASS" or "FAIL"
else
    log("no pushed file arrived")
end
log("PEER_VERDICT %s", verdict)
local r = fs.open("/peer-result", "w") r.writeLine(verdict) r.close()
'@

$client = @'
-- client: the real rget and rput commands over rpv.
local function log(fmt, ...)
    local f = fs.open("/mcfile-client.log", "a")
    f.writeLine(string.format("%.2f " .. fmt, os.clock(), ...))
    f.close()
end

log("BOOT id=%d", os.getComputerID())
local names = peripheral.getNames()
local mside = nil
for _, nm in ipairs(names) do
    if peripheral.getType(nm) == "modem" then mside = nm break end
end
log("PERIPHERALS %s chosen=%s", table.concat(names, ","), tostring(mside))
-- The configuration written by the harness is kept and only completed here: see the
-- note in the peer driver, an earlier version threw the harness settings away.
local function conf()
    local kept = {}
    local rf = fs.open("/etc/network.conf", "r")
    if rf then
        local text = rf.readAll()
        rf.close()
        for line in text:gmatch("[^\r\n]+") do
            local key = line:match("^%s*([%w_]+)%s*=")
            if line:match("%S") and key ~= "rpv_side" and key ~= "modem_side" then
                kept[#kept + 1] = line
            end
        end
    end
    local flat = table.concat(kept, "\n")
    local cf = fs.open("/etc/network.conf", "w")
    for _, line in ipairs(kept) do cf.writeLine(line) end
    if not flat:find("transport=", 1, true) then cf.writeLine("transport=rpv") end
    cf.writeLine("rpv_channel=4700")
    if mside then cf.writeLine("rpv_side=" .. mside) cf.writeLine("modem_side=" .. mside) end
    if not flat:find("rpv_reasm_bytes=", 1, true) then
        cf.writeLine("rpv_reasm_bytes=524288")
        cf.writeLine("rpv_reasm_entries=128")
    end
    cf.close()
    local lf = fs.open("/mcfile-client.log", "a")
    local vf = fs.open("/etc/network.conf", "r")
    lf.writeLine("CONF " .. vf.readAll():gsub("\n", " | "))
    lf.close()
    vf.close()
end
conf()
os.sleep(4)

package.path = package.path .. ";/lib/?.lua;/usr/?.lua"
package.loaded["rpvnet"] = nil
package.loaded["netcfg"] = nil
local rpvnet = require("rpvnet")
local netcfg = require("netcfg")
local checksum = require("checksum")
local netcmds = require("netcmds")

-- Instrumentation point. The trace hook is spliced in below when the run asks for it;
-- with tracing off this is empty and the run is byte for byte what it always was.
__CLIENT_TRACE__

local ab, aw = rpvnet.available()
local tb, twn = pcall(rpvnet.transport)
log("BACKEND avail=%s why=%s transport=%s", tostring(ab), tostring(aw),
    tostring(tb and twn or "ERROR"))
if not ab then log("CLIENT_VERDICT FAIL reason=no-rpv") return end
netcfg.open()

local function out_collect()
    local lines = {}
    return lines, { _out = { write = function(text) lines[#lines + 1] = tostring(text) end } }
end

-- hello: keep announcing until the peer answers, so neither side has to guess
-- when the other finished booting
local hello = false
for i = 1, 120 do
    rpvnet.send(20, "client-here", "psh-mc-hello")
    local sender, blob = rpvnet.receive("psh-mc-hello", 5)
    if sender then
        log("HELLO reply from=%s blob=%s", tostring(sender), tostring(blob))
        hello = true
        break
    end
    os.sleep(2)
end
log("HELLO ok=%s", tostring(hello))
if not hello then log("CLIENT_VERDICT FAIL reason=no-hello") return end

-- pull, retrying a short attempt so a slow peer start is not a failure
local code, attempts = 1, 0
local lines
while attempts < 12 do
    attempts = attempts + 1
    lines = out_collect()
    code = netcmds.main({ "-t", "20", "-o", "/copy.bin", "/big.bin", "-w", "15", "-r", "4" },
                        lines[2], { title = "rget" })
    log("RGET attempt=%d exit=%s", attempts, tostring(code))
    if code == 0 then break end
    os.sleep(3)
end
for _, line in ipairs(lines[1] or {}) do log("RGET| %s", line) end
local pulled, pcrc = 0, "nil"
if fs.exists("/copy.bin") then
    local h = fs.open("/copy.bin", "r") local body = h.readAll() h.close()
    pulled = #body
    pcrc = string.format("%08x", checksum.crc32(body))
end
log("PULLED %d bytes crc=%s", pulled, pcrc)

if code == 0 and pulled > 0 then
    local mf = fs.open("/marker.txt", "w") mf.writeLine("client done") mf.close()
    local t2
    t2 = out_collect()
    local code2 = netcmds.main({ "-t", "20", "-p", "/var/net/incoming/big.bin", "-f", "/copy.bin" },
                               t2[2], { title = "rput" })
    for _, line in ipairs(t2[1]) do log("RPUT| %s", line) end
    log("RPUT exit=%s", tostring(code2))
    local t3 = out_collect()
    local code3 = netcmds.main({ "-t", "20", "-p", "/var/net/incoming/marker.txt", "-f", "/marker.txt" },
                               t3[2], { title = "rput" })
    log("MARKER exit=%s", tostring(code3))
    log("CLIENT_VERDICT %s", ((code2 == 0 and code3 == 0) and "PASS" or "FAIL"))
else
    log("CLIENT_VERDICT FAIL reason=no-file")
end
local r = fs.open("/client-result", "w") r.writeLine("done") r.close()
'@

Set-Content -Path (Join-Path $world "20\startup.lua") -Value $peer -Encoding ascii
Set-Content -Path (Join-Path $world "21\startup.lua") -Value $client -Encoding ascii
"drivers written (payload $Bytes bytes, chunk $Chunk)"

if ($ClientTrace) {
    # The peer's own trace: it is a different computer, so it writes its own file.
    $peertrace = @'
local xfermod = require("xfer")
local ptrace_start = os.clock()
xfermod.trace = function(line)
    local f = fs.open("/mcfile-peer-trace.log", "a")
    f.writeLine(string.format("%.2f X %s", os.clock() - ptrace_start, line))
    f.close()
end
local lf = fs.open("/mcfile-peer.log", "a")
lf.writeLine("TRACE armed on xfer (peer side)")
lf.close()
'@
    $peer = $peer.Replace("__PEER_TRACE__", $peertrace)
    # The client trace wraps the two functions every transfer goes through, so the log answers
    # "did the sender hand each chunk to the stack, and did it ever get an answer":
    #   SEND t=<type> seq=<n> bytes=<n>   a message leaving through xfer.send_message
    #   RECV t=<type> seq=<n> wait=<ms>   what wait_message returned, and after how long
    #   CHUNK seq=<n> at=<clock>          a chunk on its way out
    $trace = @'
-- Client trace. The layers below the command are xfer -> rpvnet -> node, and xfer's
-- message helpers are module locals (not table fields), so the hook goes on rpvnet, the
-- one place every protocol message passes through either way:
--   SEND  a datagram the client handed to the stack, and what the call answered
--   RECV  a receive that returned (with what) or that timed out
--   PUMP  how long the stack was driven for, so a stall can be told from a wait
local rpv = require("rpvnet")
local trace_start = os.clock()
local function trace_line(fmt, ...)
    local f = fs.open("/mcfile-trace.log", "a")
    f.writeLine(string.format("%.2f " .. fmt, os.clock() - trace_start, ...))
    f.close()
end
local real_send = rpv.send
local real_receive = rpv.receive
local real_pump = rpv.pump
rpv.send = function(target, blob, protocol)
    local bytes = type(blob) == "string" and #blob or -1
    local ok, res = pcall(real_send, target, blob, protocol)
    trace_line("SEND to=%s proto=%s bytes=%d ok=%s res=%s", tostring(target),
        tostring(protocol), bytes, tostring(ok), tostring(res))
    return res
end
rpv.receive = function(protocol, timeout)
    local ok, a, b = pcall(real_receive, protocol, timeout)
    trace_line("RECV proto=%s ok=%s sender=%s bytes=%s", tostring(protocol), tostring(ok),
        tostring(a), tostring(type(b) == "string" and #b or b))
    return a, b
end
rpv.pump = function(seconds)
    local ok, res = pcall(real_pump, seconds)
    trace_line("PUMP %.2fs ok=%s", tonumber(seconds) or -1, tostring(ok))
    return res
end
-- The sender's own state machine reports which branch it took: the wire log says what
-- left, not whether the code was waiting for a chunk, a ready, or a result.
local xfermod = require("xfer")
xfermod.trace = function(line) trace_line("X %s", line) end
trace_line("TRACE armed on rpvnet and xfer")
'@
    $client = $client.Replace("__CLIENT_TRACE__", $trace)
    Set-Content -Path (Join-Path $world "21\startup.lua") -Value $client -Encoding ascii
} else {
    $client = $client.Replace("__CLIENT_TRACE__", "")
    $peer = $peer.Replace("__PEER_TRACE__", "")
    Set-Content -Path (Join-Path $world "21\startup.lua") -Value $client -Encoding ascii
}
Set-Content -Path (Join-Path $world "20\startup.lua") -Value $peer -Encoding ascii

# the payload size is a parameter of the driver: it is written as a constant
$p = Join-Path $world "20\startup.lua"
$text = Get-Content $p -Raw
$text = $text -replace "local size = \d+", "local size = $Bytes"
Set-Content -Path $p -Value $text -Encoding ascii

# ---- boot them -------------------------------------------------------------------
Start-Sleep -Seconds 2
"turn-on: " + (Rcon "computercraft turn-on 20")
"turn-on: " + (Rcon "computercraft turn-on 21")

$clog = Join-Path $world "21\mcfile-client.log"
$plog = Join-Path $world "20\mcfile-peer.log"
$deadline = (Get-Date).AddSeconds($TimeoutSec)
$done = $false
while ((Get-Date) -lt $deadline) {
    Start-Sleep -Seconds 5
    if (Test-Path $clog) { if ((Get-Content $clog -Raw) -match "CLIENT_VERDICT") { $done = $true; break } }
}
$c = if (Test-Path $clog) { Get-Content $clog -Raw } else { "" }
$s = if (Test-Path $plog) { Get-Content $plog -Raw } else { "" }
$cv = if ($c -match "CLIENT_VERDICT PASS") { "PASS" } else { "FAIL" }
$pv = if ($s -match "PEER_VERDICT PASS") { "PASS" } else { "FAIL" }
"RESULT psh-mc-file done=$done client=$cv peer=$pv"

# Report by PATTERN, not by tail. The last ten matching lines hid a sequence of three
# failed requests in one run, making a repeated failure look like a single event: the
# question is "what happened, and how often", and a tail answers it only while the log
# is short. log_summary.py groups equal lines with a count and lists every timestamp, so
# a repeat cannot be missed, and it prints the verdicts whatever the pattern says.
# The full logs are still on disk, and the xfer trace below is printed in order.
$summary = Join-Path (Split-Path $PSCommandPath -Parent) "..\log_summary.py"
$pyExe = $py
if (Test-Path $summary) {
    foreach ($pair in @(@("client", $clog), @("peer", $plog))) {
        $name = $pair[0]; $path = $pair[1]
        if (Test-Path $path) {
            & $pyExe $summary $path --title $name
        } else {
            "----- $name -----"
            "  (no log: the file is not there)"
        }
    }
} else {
    "note: log_summary.py is not next to this script; falling back to a tail"
    # -match is case insensitive in PowerShell, so these patterns cover both the MC
    # driver's uppercase vocabulary and the emulator driver's lowercase one.
    "----- client -----"
    ($c -split "`n") | Where-Object { $_ -match "BOOT|BACKEND|HELLO|RGET exit|RGET\||PULLED|RPUT|MARKER|CLIENT_VERDICT|client start|transport|trace" } | Select-Object -Last 10
    "----- peer -----"
    ($s -split "`n") | Where-Object { $_ -match "BOOT|BACKEND|PAYLOAD|HELLO|REQUEST|SERVED|PUSHED|PEER_VERDICT|peer start|transport|serving" } | Select-Object -Last 10
}

# The xfer state machine's account of the conversation, in order, when -ClientTrace was
# given: the opening line says which shape the push used ("with block 1/N"), which is the
# thing a reader checks first now.
if ($ClientTrace) {
    foreach ($pair in @(@("client", $clog), @("peer", (Join-Path $world "20\mcfile-peer-trace.log")))) {
        $name = $pair[0]; $path = $pair[1]
        if (Test-Path $path) {
            $tr = Get-Content $path -Raw
            if ($tr -match "trace") {
                "----- $name (xfer trace) -----"
                ($tr -split "`n") | Where-Object { $_ -match "trace" } | Select-Object -First 40
            }
        }
    }
}
