# Find out when a CraftOS computer is willing to run a startup.lua that was written by
# the harness: ORDER A writes the file before the first boot, ORDER B boots once (so the
# computer materialises its directory), then shuts down, writes and boots again.
#
# The answer (run 2026-10-10, verified again against a fresh world): ORDER A works, and
# it is the order the other MC scripts rely on -- a directory created on the host is
# adopted by the computer when it boots, so a server with a brand new world needs no
# preparation.
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
$d = Join-Path $Server "world\computercraft\computer\20"
function Rcon([string]$c) { $o = & $py $rconPy 127.0.0.1 $RconPort $RconPassword $c 2>&1; return ($o -join " ") }
function Listing { if (Test-Path $d) { return ((Get-ChildItem $d -Force -File | ForEach-Object { $_.Name }) -join ", ") } return "(no dir)" }

$null = Rcon "forceload add -48 -16 400 16"
$null = Rcon "computercraft shutdown"
Start-Sleep -Seconds 2
$null = Rcon "fill -48 -60 0 400 -60 2 air"
$null = Rcon "setblock 0 -60 0 computercraft:computer_normal[facing=north]"
$null = Rcon "setblock 1 -60 0 computercraft:wireless_modem_normal[facing=left]"
$null = Rcon "data merge block 0 -60 0 {ComputerId:20,On:0b}"
New-Item -ItemType Directory -Force -Path $d | Out-Null
Get-ChildItem $d -Force -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue

"=== ORDER A: write startup.lua first, then turn on ==="
Set-Content -Path (Join-Path $d "startup.lua") -Encoding ascii -Value 'local f=fs.open("/probeA.log","w") f.writeLine("A ran at " .. tostring(os.clock())) f.close()'
"  turn-on: " + (Rcon "computercraft turn-on 20")
Start-Sleep -Seconds 25
"  probeA.log exists : " + (Test-Path (Join-Path $d "probeA.log"))
"  dir files         : " + (Listing)

"=== ORDER B: boot once, then shutdown, write, boot again ==="
$null = Rcon "computercraft shutdown"
Start-Sleep -Seconds 3
$null = Rcon "computercraft turn-on 20"
Start-Sleep -Seconds 15
"  dir after plain boot: " + (Listing)
Set-Content -Path (Join-Path $d "startup.lua") -Encoding ascii -Value 'local f=fs.open("/probeB.log","w") f.writeLine("B ran at " .. tostring(os.clock())) f.close()'
$null = Rcon "computercraft shutdown"
Start-Sleep -Seconds 3
$null = Rcon "computercraft turn-on 20"
Start-Sleep -Seconds 25
"  probeB.log exists : " + (Test-Path (Join-Path $d "probeB.log"))
"  dir files         : " + (Listing)
if (Test-Path (Join-Path $d "probeA.log")) { "  A content: " + ((Get-Content (Join-Path $d "probeA.log")) -join " ") }
if (Test-Path (Join-Path $d "probeB.log")) { "  B content: " + ((Get-Content (Join-Path $d "probeB.log")) -join " ") }
