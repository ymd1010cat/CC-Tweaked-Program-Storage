# The transport acceptance: two CraftOS-PC computers in one emulator process,
# transport=rpv on both, a request/answer round trip with a static peer map and
# then one through discovery. This is the emulator twin of _ush-mc-verify.ps1.
#
#   computer 20   peer: spawns 21 and answers two phases
#   computer 21   client: asks phase 1 (rpv_peer_20 set) and phase 2 (no map)
#
# Both drivers are top level startup.lua files: a CraftOS-PC wireless modem only
# reaches computers in the same emulator process, and a chunk made by loadfile has
# no package/require, so the code must run as the startup chunk itself.
param(
    [string]$Ush = "C:\Users\ymd10\Documents\DSHWork\cc_tweaked\unixshell",
    [string]$Work = "C:\Users\ymd10\AppData\Local\rpv-craftos\work\ush-rpv-verify3",
    [int]$Peer = 20,
    [int]$Client = 21,
    [int]$TimeoutSec = 300
)
$py = "C:\Users\ymd10\.dsh\dsh-runtimes\dsh-primary-runtime\dependencies\python\python.exe"
$exe = "C:\Program Files\CraftOS-PC\CraftOS-PC_console.exe"
$data = Join-Path $Work "craftos"
if (Test-Path $data) { Remove-Item $data -Recurse -Force -ErrorAction SilentlyContinue }
New-Item -ItemType Directory -Force -Path $data | Out-Null

New-Item -ItemType Directory -Force -Path (Join-Path $data "config") | Out-Null
Set-Content -Path (Join-Path $data "config\global.json") -Encoding ascii -Value @'
{
    "computerSpaceLimit": 4000000,
    "clockSpeed": 20,
    "logErrors": false
}
'@

foreach ($id in @($Peer, $Client)) {
    $target = Join-Path $data "computer\$id"
    New-Item -ItemType Directory -Force -Path $target | Out-Null
    & $py (Join-Path $Ush "tools\deploy.py") --target $target --source $Ush --quiet | Out-Null
    $etc = Join-Path $target "etc"
    New-Item -ItemType Directory -Force -Path $etc | Out-Null
    Set-Content -Path (Join-Path $etc "network.conf") -Encoding ascii -Value @(
        "transport=rpv",
        "rpv_side=back",
        "rpv_channel=4700",
        "rpv_mtu=512",
        "rpv_reasm_bytes=524288",
        "rpv_reasm_entries=128",
        # phase 1 answers over a known address; the client removes this line before
        # phase 2 so the discovery broadcast and its responder carry the lookup
        "rpv_peer_20=10.0.4.20"
    )
    Set-Content -Path (Join-Path $etc "pkg.conf") -Encoding ascii -Value @(
        "channel=ush-verify3",
        "key=rpv-verify3",
        "modem_side=back",
        "timeout=10",
        "retries=4"
    )
}
"deployed $Peer (peer) and $Client (client)"

$peerLua = @'
-- peer: answer a request/reply round trip in two phases.
local function mark(where, s)
    local f = fs.open(where, "a")
    f.writeLine(string.format("%.2f %s", os.clock(), s))
    f.close()
end

mark("/srv.log", "peer start id=" .. tostring(os.getComputerID()))
if ccemux and ccemux.openEmu then
    local ok, res = pcall(ccemux.openEmu, 21)
    mark("/srv.log", "openEmu 21 ok=" .. tostring(ok) .. " res=" .. tostring(res))
    os.sleep(1.0)
end

-- create the modem only when the side does not already answer with one
local okm, errm = true, "already present"
for _ = 1, 20 do
    if peripheral.getType("back") == "modem" then break end
    okm, errm = pcall(function() return periphemu.create("back", "modem") end)
    if peripheral.getType("back") == "modem" then break end
    os.sleep(0.25)
end
mark("/srv.log", "modem ok=" .. tostring(okm) .. " type=" .. tostring(peripheral.getType("back")))
os.sleep(1)

package.path = package.path .. ";/lib/?.lua;/usr/?.lua"
local rpvnet = require("rpvnet")
local netcfg = require("netcfg")

local avail, why = rpvnet.available()
mark("/srv.log", "avail=" .. tostring(avail) .. " why=" .. tostring(why))
local okt, backend = pcall(rpvnet.transport)
mark("/srv.log", "transport ok=" .. tostring(okt) .. " backend=" .. tostring(backend))
local opened, oerr = netcfg.open()
mark("/srv.log", "open=" .. tostring(opened) .. " err=" .. tostring(oerr))

local phases = { false, false }
local deadline = os.epoch("utc") + 240 * 1000
while os.epoch("utc") < deadline do
    local sender, blob = rpvnet.receive("ush-verify3", 5)
    if sender then
        -- the payload is a plain string on purpose: a table cannot be handed to
        -- rpvnet.send directly, string concatenation would turn it into "table: ..."
        local text = tostring(blob)
        local phase = tonumber(text:match("phase(%d)")) or 0
        mark("/srv.log", "RX from=" .. tostring(sender) .. " phase=" .. tostring(phase) ..
             " bytes=" .. tostring(#text))
        if phase >= 1 and phase <= 2 and not phases[phase] then
            phases[phase] = true
            local sent, serr = rpvnet.send(sender, "reply-phase" .. phase, "ush-verify3")
            mark("/srv.log", "replied phase" .. phase .. " ok=" .. tostring(sent) ..
                 " err=" .. tostring(serr))
        end
    end
    if phases[1] and phases[2] then break end
end

mark("/srv.log", "SERVER_VERDICT phases=" .. tostring(phases[1]) .. "/" .. tostring(phases[2]))
local o = fs.open("/server-result", "w")
o.writeLine((phases[1] and phases[2]) and "PASS" or "FAIL")
o.close()
'@

$clientLua = @'
-- client: phase 1 with the static peer map, phase 2 through discovery.
local function mark(where, s)
    local f = fs.open(where, "a")
    f.writeLine(string.format("%.2f %s", os.clock(), s))
    f.close()
end

mark("/cli.log", "client start id=" .. tostring(os.getComputerID()))
local okm, errm = true, "already present"
for _ = 1, 20 do
    if peripheral.getType("back") == "modem" then break end
    okm, errm = pcall(function() return periphemu.create("back", "modem") end)
    if peripheral.getType("back") == "modem" then break end
    os.sleep(0.25)
end
mark("/cli.log", "modem ok=" .. tostring(okm) .. " type=" .. tostring(peripheral.getType("back")))
os.sleep(2)

package.path = package.path .. ";/lib/?.lua;/usr/?.lua"
local rpvnet = require("rpvnet")
local netcfg = require("netcfg")

local avail, why = rpvnet.available()
mark("/cli.log", "avail=" .. tostring(avail) .. " why=" .. tostring(why))
local okt, backend = pcall(rpvnet.transport)
mark("/cli.log", "transport ok=" .. tostring(okt) .. " backend=" .. tostring(backend))
local opened, oerr = netcfg.open()
mark("/cli.log", "open=" .. tostring(opened) .. " err=" .. tostring(oerr))

local function phase(n, label)
    for attempt = 1, 12 do
        local sent, serr = rpvnet.send(20, "phase" .. n, "ush-verify3")
        mark("/cli.log", label .. " attempt=" .. attempt .. " sent=" .. tostring(sent) ..
             " err=" .. tostring(serr))
        if sent then
            local sender, blob = rpvnet.receive("ush-verify3", 8)
            if sender then
                mark("/cli.log", label .. " REPLY from=" .. tostring(sender) .. " text=" ..
                     tostring(blob))
                return tostring(blob) == ("reply-phase" .. n)
            end
            local st = rpvnet.stats()
            mark("/cli.log", label .. " no reply; bound=" .. tostring(st.bound) ..
                 " queued=" .. tostring(st.queued) .. " dropped=" .. tostring(st.dropped))
        end
        os.sleep(1)
    end
    return false
end

local ok1 = phase(1, "PHASE1")
mark("/cli.log", "PHASE1 ok=" .. tostring(ok1))

-- drop the static map and reload the configuration: the lookup now has to go
-- through the discovery broadcast on port 19999 and the responder that owns the id
if fs.exists("/etc/network.conf") then
    local lines = {}
    local f = fs.open("/etc/network.conf", "r")
    while true do
        local line = f.readLine()
        if line == nil then break end
        if not line:match("^%s*rpv_peer_") then table.insert(lines, line) end
    end
    f.close()
    local out = fs.open("/etc/network.conf", "w")
    for _, line in ipairs(lines) do out.writeLine(line) end
    out.close()
    netcfg.reload()
    mark("/cli.log", "static peer map removed: rpv_peer_20=" .. tostring(netcfg.get("rpv_peer_20")))
end

local ok2 = phase(2, "PHASE2")
mark("/cli.log", "PHASE2 ok=" .. tostring(ok2))
mark("/cli.log", "CLIENT_VERDICT " .. ((ok1 and ok2) and "PASS" or "FAIL"))

local o = fs.open("/client-result", "w")
o.writeLine((ok1 and ok2) and "PASS" or "FAIL")
o.close()
os.sleep(5)
'@

Set-Content -Path (Join-Path $data "computer\$Peer\startup.lua") -Value $peerLua -Encoding ascii
Set-Content -Path (Join-Path $data "computer\$Client\startup.lua") -Value $clientLua -Encoding ascii
"drivers written"

$proc = Start-Process -FilePath $exe -ArgumentList @("-d", "`"$data`"", "--headless", "--id", "$Peer") `
    -RedirectStandardOutput (Join-Path $Work "emu.out.txt") -RedirectStandardError (Join-Path $Work "emu.err.txt") -PassThru -NoNewWindow
$deadline = (Get-Date).AddSeconds($TimeoutSec)
while ((Get-Date) -lt $deadline) {
    Start-Sleep -Milliseconds 1000
    if (Test-Path (Join-Path $data "computer\$Client\client-result")) { break }
    if ($proc.HasExited) { break }
}
Start-Sleep -Seconds 2
if (-not $proc.HasExited) { $proc.Kill() }
"emulator exited early: $($proc.HasExited)"

foreach ($f in @("$Peer\srv.log", "$Client\cli.log")) {
    $p = Join-Path $data "computer\$f"
    "----- $f -----"
    if (Test-Path $p) { Get-Content $p } else { "(missing)" }
}

$srv = Join-Path $data "computer\$Peer\server-result"
$cli = Join-Path $data "computer\$Client\client-result"
$sv = if (Test-Path $srv) { (Get-Content $srv -Raw).Trim() } else { "MISSING" }
$cv = if (Test-Path $cli) { (Get-Content $cli -Raw).Trim() } else { "MISSING" }
"RESULT ush-rpv-verify3 server=$sv client=$cv"
