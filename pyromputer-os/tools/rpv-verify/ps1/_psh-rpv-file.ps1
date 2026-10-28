# The chunked file transfer acceptance: two CraftOS-PC computers in one emulator
# process, transport=rpv, the real rget and rput commands, and a file large
# enough that the stream path in lib/xfer.lua runs for many chunks (and, with the
# default 4096 byte chunk against the rpv MTU of 512, that IP fragmentation and
# reassembly run too).
#
#   computer 20   spawns 21, then acts as the peer: serves /big.bin, stores the
#                 pushed copy in /var/net/incoming and compares it with the source
#   computer 21   the client: /usr/cmd/rget.lua then /usr/cmd/rput.lua
#
# Why one process: a CraftOS-PC wireless modem only reaches computers inside the
# same emulator process. Two processes each create their own modem medium, so a
# sender hears only itself. `ccemux.openEmu` (the CCEmuX plugin) is what makes a
# second computer exist; both drivers are therefore top level startup.lua files
# and must not use loadfile (a chunk loaded that way has no package/require).
param(
    [string]$Psh = "C:\Users\ymd10\Documents\DSHWork\cc_tweaked\pyromputer-os",
    [string]$Work = "C:\Users\ymd10\AppData\Local\rpv-craftos\work\psh-rpv-file",
    [int]$Peer = 20,
    [int]$Client = 21,
    [int]$Bytes = 200000,
    [int]$Chunk = 4096,
    [int]$TimeoutSec = 900
)
$py = "C:\Users\ymd10\.dsh\dsh-runtimes\dsh-primary-runtime\dependencies\python\python.exe"
$exe = "C:\Program Files\CraftOS-PC\CraftOS-PC_console.exe"
$data = Join-Path $Work "craftos"
if (Test-Path $data) { Remove-Item $data -Recurse -Force -ErrorAction SilentlyContinue }
New-Item -ItemType Directory -Force -Path $data | Out-Null

# A CraftOS computer refuses to boot when its filesystem is over
# computer_space_limit, and the shell tree is ~1.0 MB on its own: raise it before
# deploying anything (the option is read at startup). The payload adds another
# 200 KB, and the pushed copy one more.
New-Item -ItemType Directory -Force -Path (Join-Path $data "config") | Out-Null
Set-Content -Path (Join-Path $data "config\global.json") -Encoding ascii -Value @'
{
    "computerSpaceLimit": 8000000,
    "clockSpeed": 20,
    "logErrors": false
}
'@

foreach ($id in @($Peer, $Client)) {
    $target = Join-Path $data "computer\$id"
    New-Item -ItemType Directory -Force -Path $target | Out-Null
    & $py (Join-Path $Psh "tools\deploy.py") --target $target --source $Psh --quiet | Out-Null
    $etc = Join-Path $target "etc"
    New-Item -ItemType Directory -Force -Path $etc | Out-Null
    Set-Content -Path (Join-Path $etc "network.conf") -Encoding ascii -Value @(
        "transport=rpv",
        "rpv_side=back",
        "rpv_channel=4700",
        "rpv_mtu=512",
        "rpv_reasm_bytes=524288",
        "rpv_reasm_entries=128"
    )
    Set-Content -Path (Join-Path $etc "pkg.conf") -Encoding ascii -Value @(
        "channel=psh-file",
        "key=rpv-file-acceptance",
        "modem_side=back",
        "chunk_size=$Chunk",
        "timeout=15",
        "retries=6"
    )
}

# The payload, on disk before the emulator starts so the peer can serve it at once.
$buf = New-Object byte[] $Bytes
for ($i = 0; $i -lt $Bytes; $i++) { $buf[$i] = [byte](32 + (($i * 7) % 95)) }
[IO.File]::WriteAllBytes((Join-Path $data "computer\$Peer\big.bin"), $buf)
"deployed $Peer (peer) and $Client (client); payload $Bytes bytes, chunk $Chunk bytes"

$peerLua = @'
-- peer: boot the client, serve one pull, accept one push, compare the copy.
local function mark(where, s)
    local f = fs.open(where, "a")
    f.writeLine(string.format("%.2f %s", os.clock(), s))
    f.close()
end

mark("/srv.log", "peer start id=" .. tostring(os.getComputerID()))
mark("/srv.log", "ccemux=" .. tostring(ccemux ~= nil) ..
     " openEmu=" .. tostring(ccemux and ccemux.openEmu ~= nil))

-- Spawn the client with a gap: opening several emulators in a tight loop makes
-- CraftOS-PC race on loading its BIOS and some instances never boot.
if ccemux and ccemux.openEmu then
    local spawned, serr = pcall(ccemux.openEmu, 21)
    mark("/srv.log", "openEmu 21 ok=" .. tostring(spawned) .. " err=" .. tostring(serr))
    os.sleep(1.0)
end

-- A modem is a peripheral only when one faces the computer, and creating a modem
-- on a side that already has one would replace it: create it only when the side
-- does not answer with "modem" already.
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

-- Two machines in one process share no filesystem, so the peer cannot wait for a
-- marker file the client wrote: it binds its port and starts serving right away,
-- giving the client time to boot first, and the client retries if it is early.
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
    -- the client pushes /marker.txt as its last act, so an arriving request for it
    -- means both transfers are over
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
'@

$clientLua = @'
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

-- open the node, and announce ourselves on the data channel: the peer learns our
-- address from that datagram, so neither side needs a static peer map
local okc, cerr = require("netcfg").open()
mark("/cli.log", "open=" .. tostring(okc) .. " err=" .. tostring(cerr))
rpvnet.broadcast("client-online", "psh-file")
mark("/cli.log", "announced")

local out = {}
local writer = {}
function writer.write(text)
    table.insert(out, tostring(text))
end

-- The dispatch of the command files, called the way the shell calls them. A
-- chunk made by loadfile has no package library in CraftOS, so /usr/cmd/rget.lua
-- itself cannot be the entry point here: its require() call would fail. The
-- dispatcher it wraps is the same code, and the shell front ends stay covered by
-- the PC side suites.
local netcmds = require("netcmds")
mark("/cli.log", "netcmds main=" .. tostring(netcmds.main))

-- The two computers live in one process but share no filesystem, so the client
-- cannot wait for a marker file from the peer. It retries a short transfer
-- instead: a timeout (exit 124) means the peer was not listening yet, and the
-- retry also covers the discovery broadcast that has to arrive after the peer
-- bound its port.
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
    -- The peer drains the leftovers of the pull before it can take the push: a
    -- request that arrives while it is busy gets no answer, and the shell retries.
    -- (A 4096 byte chunk is one 6 KB datagram, thirteen IP fragments; a burst that
    -- overruns the node's reassembly byte cap is dropped, which is what makes the
    -- peer busy for a while after each transfer.)
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
'@

Set-Content -Path (Join-Path $data "computer\$Peer\startup.lua") -Value $peerLua -Encoding ascii
Set-Content -Path (Join-Path $data "computer\$Client\startup.lua") -Value $clientLua -Encoding ascii
"drivers written"

$out = Join-Path $Work "emu.out.txt"
$err = Join-Path $Work "emu.err.txt"
$proc = Start-Process -FilePath $exe -ArgumentList @("-d", "`"$data`"", "--headless", "--id", "$Peer") `
    -RedirectStandardOutput $out -RedirectStandardError $err -PassThru -NoNewWindow

$doneFile = Join-Path $data "computer\$Peer\server-result"
$deadline = (Get-Date).AddSeconds($TimeoutSec)
while ((Get-Date) -lt $deadline) {
    Start-Sleep -Milliseconds 1000
    if (Test-Path $doneFile) { break }
    if ($proc.HasExited) { break }
}
Start-Sleep -Seconds 3
if (-not $proc.HasExited) { $proc.Kill() }
Start-Sleep -Milliseconds 500
"emulator exited early: $($proc.HasExited)"

foreach ($f in @("$Peer\srv.log", "$Client\cli.log")) {
    $p = Join-Path $data "computer\$f"
    "----- $f -----"
    if (Test-Path $p) { Get-Content $p } else { "(missing)" }
}

$result = if (Test-Path $doneFile) { (Get-Content $doneFile -Raw).Trim() } else { "MISSING" }
"RESULT psh-rpv-file server=$result"
