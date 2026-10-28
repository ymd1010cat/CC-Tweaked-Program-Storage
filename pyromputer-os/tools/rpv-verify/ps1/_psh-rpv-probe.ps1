# Locate the string address that reaches rpv's masked(): log the interface field types,
# then call the stack's udp_send directly with explicit numbers to separate "the stack is
# fine, my adapter passes something wrong" from "the node itself was built wrong".
param(
    [string]$Data = "C:\Users\ymd10\AppData\Local\rpv-craftos\work\psh-rpv-test\craftos",
    [int]$TimeoutSec = 60,
    [string]$R = "C:\Users\ymd10\Documents\DSHWork\cc_tweaked\rpv1",
    [string]$ExtraServer = "C:\Users\ymd10\Documents\DSHWork\cc_tweaked\mc-server"
)
"=== MC server directories ==="
$candidates = @((Join-Path $R "mc-server"), (Join-Path $R "mc-server-fabric"), $ExtraServer)
foreach ($p in $candidates) {
    $libs = Join-Path $p "libraries"
    $logs = Join-Path $p "logs"
    $mods = Join-Path $p "mods"
    "  {0,-52} dir={1} libraries={2} logs={3} mods={4} world={5}" -f $p, (Test-Path $p), (Test-Path $libs), (Test-Path $logs), (Test-Path $mods), (Test-Path (Join-Path $p "world"))
}
$exe = "C:\Program Files\CraftOS-PC\CraftOS-PC_console.exe"
$dir = Join-Path $Data "computer\20"
if (-not (Test-Path (Join-Path $dir "lib\rpvnet.lua"))) { throw "computer 20 has no lib/rpvnet.lua" }
Remove-Item (Join-Path $dir "probe.log") -Force -ErrorAction SilentlyContinue

$driver = @'
local function log(fmt, ...)
    local f = fs.open("/probe.log", "a")
    f.writeLine(string.format("%.2f " .. fmt, os.clock(), ...))
    f.close()
end
log("BOOT id=%d", os.getComputerID())
pcall(function() return periphemu.create("back", "modem") end)
fs.makeDir("/etc")
local id = os.getComputerID()
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
if not iface then log("NO IFACE") return end
log("IFACE ip=%s(%s) net=%s(%s) prefix=%s(%s) mac=%s(%s)", tostring(iface.ip), type(iface.ip),
    tostring(iface.net), type(iface.net), tostring(iface.prefix), type(iface.prefix),
    tostring(n.mac), type(n.mac))
log("LO ip=%s(%s)", tostring(n.lo and n.lo.ip), type(n.lo and n.lo.ip))
local okr, errr = pcall(rpvnet.receive, "probe-never", 0.2)
log("RECV(empty) ok=%s err=%s", tostring(okr), tostring(errr))
-- clear the adapter out of the picture: call the stack itself with plain numbers
local rpv = rpvnet.stack()
local ok1, err1 = pcall(rpv.udp_send, n, iface.ip, 20001, 20001, "raw-probe")
log("RAW udp_send(dst=iface.ip) ok=%s err=%s", tostring(ok1), tostring(err1))
local ok2, err2 = pcall(rpvnet.send, id, "adapter-probe", "probe-never")
log("ADAPTER send ok=%s err=%s", tostring(ok2), tostring(err2))
-- and the same through the adapter's own port
local ok3, err3 = pcall(rpvnet.send, id, "adapter-probe", "psh-test")
log("ADAPTER send2 ok=%s err=%s", tostring(ok3), tostring(err3))
local sender, blob = rpvnet.receive("psh-test", 3)
log("RECV sender=%s blob=%s", tostring(sender), tostring(blob))
'@

Set-Content -Path (Join-Path $dir "startup.lua") -Value $driver -Encoding ascii
Remove-Item (Join-Path $dir "startup-real.lua") -Force -ErrorAction SilentlyContinue
$proc = Start-Process -FilePath $exe -ArgumentList @("-d", $Data, "--headless", "--id", "20") `
    -RedirectStandardOutput (Join-Path $Data "probe.out.txt") -RedirectStandardError (Join-Path $Data "probe.err.txt") -PassThru -NoNewWindow
$log = Join-Path $dir "probe.log"
$deadline = (Get-Date).AddSeconds($TimeoutSec)
while ((Get-Date) -lt $deadline) {
    Start-Sleep -Milliseconds 500
    if ($proc.HasExited) { break }
    if (Test-Path $log) { if ((Get-Content $log -Raw) -match "RECV sender") { break } }
}
Start-Sleep -Seconds 1
if (-not $proc.HasExited) { $proc.Kill() }
Start-Sleep -Milliseconds 400
"=== probe.log ==="
if (Test-Path $log) { Get-Content $log } else { "(no log)" }

