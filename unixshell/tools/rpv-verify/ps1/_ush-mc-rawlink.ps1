param(
    [string]$Server = "C:\Users\ymd10\Documents\DSHWork\cc_tweaked\rpv1\mc-server-fabric",
    [int]$RconPort = 25576,
    [string]$RconPassword = "rpvtest"
)
$py = "C:\Users\ymd10\.dsh\dsh-runtimes\dsh-primary-runtime\dependencies\python\python.exe"
# rcon.py comes from the rpv1 checkout; the server may be a copy elsewhere.
$rconPy = Join-Path (Split-Path $Server -Parent) "poc\mc\rcon.py"
if (-not (Test-Path $rconPy)) {
    $rconPy = "C:\Users\ymd10\Documents\DSHWork\cc_tweaked\rpv1\poc\mc\rcon.py"
}
$world = Join-Path $Server "world\computercraft\computer"
function Rcon([string]$c) { $o = & $py $rconPy 127.0.0.1 $RconPort $RconPassword $c 2>&1; return ($o -join " ") }
$null = Rcon "forceload add -48 -16 400 16"
$null = Rcon "computercraft shutdown"
Start-Sleep -Seconds 4
$null = Rcon "fill -48 -60 -2 400 -60 2 air"
$null = Rcon "setblock 0 -60 0 computercraft:computer_normal[facing=north]"
$null = Rcon "setblock 12 -60 0 computercraft:computer_normal[facing=north]"
foreach ($x in @(0, 12)) {
    $null = Rcon "setblock $($x - 1) -60 0 computercraft:wireless_modem_normal[facing=east]"
    $null = Rcon "setblock $($x + 1) -60 0 computercraft:wireless_modem_normal[facing=west]"
    $null = Rcon "setblock $x -60 -1 computercraft:wireless_modem_normal[facing=south]"
    $null = Rcon "setblock $x -60 1 computercraft:wireless_modem_normal[facing=north]"
}
$null = Rcon "data merge block 0 -60 0 {ComputerId:20,On:0b}"
$null = Rcon "data merge block 12 -60 0 {ComputerId:21,On:0b}"

$raw = @"
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
"@
foreach ($id in @(20, 21)) {
    $d = Join-Path $world "$id"
    New-Item -ItemType Directory -Force -Path $d | Out-Null
    Get-ChildItem $d -Force -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
    Set-Content -Path (Join-Path $d "startup.lua") -Value $raw -Encoding ascii
}
"placed raw-link test on 20 and 21"
"turn-on 20: " + (Rcon "computercraft turn-on 20")
"turn-on 21: " + (Rcon "computercraft turn-on 21")
Start-Sleep -Seconds 40
foreach ($id in @(20, 21)) {
    "----- computer $id raw.log -----"
    $p = Join-Path $world "$id\raw.log"
    if (Test-Path $p) { Get-Content $p | Select-Object -First 10 } else { "(no log - driver did not run)" }
}
