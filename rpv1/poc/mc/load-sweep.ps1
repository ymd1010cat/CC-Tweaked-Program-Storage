# pps-ceiling sweep: ramp the offered modem load and record achieved pps + real
# MSPT (spark, read by the fake player; Fabric server only).
#
#   pwsh -File poc\mc\load-sweep.ps1 -Count 8 -PerTick 1,4,16,64 -Secs 12
#
# Each run places 1 counter + Count senders on one wireless channel; every sender
# pushes PerTick frames per tick. Output: poc\out\mc-load-curve.txt
param(
    [int]$Count = 8,
    [int[]]$PerTick = @(1, 4, 16, 64),
    [int]$Secs = 12,
    [ValidateSet("neoforge", "fabric")]
    [string]$Target = "fabric",
    [switch]$SparkText,
    [string]$Root = $env:RPV_ROOT
)

$root = $Root
if (-not $root) { $root = "C:\Users\ymd10\Documents\DSHWork\cc_tweaked\rpv1" }
$env:RPV_ROOT = $root
$out = Join-Path $root "poc\out"
New-Item -ItemType Directory -Force -Path $out | Out-Null
$run = Join-Path $root "poc\mc\run-mc.ps1"
$curve = Join-Path $out "mc-load-curve.txt"

$rows = @()
foreach ($k in $PerTick) {
    $log = Join-Path $out "_load-$k.txt"
    $sb = [scriptblock]::Create((Get-Content $run -Raw))
    $args = @{ Scenario = "load"; Count = $Count; PerTick = $k; LoadSecs = $Secs; Target = $Target; TimeoutSec = ($Secs + 90) }
    if ($SparkText) { $args["SparkText"] = $true }
    & $sb @args *> $log

    $text = Get-Content $log -Raw
    $fps = 0.0; $perTickAchieved = 0.0; $recv = 0
    if ($text -match "LOAD_SUMMARY .*received=(\d+) achieved_fps=([0-9.]+) achieved_per_tick=([0-9.]+)") {
        $recv = [int]$matches[1]; $fps = [double]$matches[2]; $perTickAchieved = [double]$matches[3]
    }
    # sender-side self-report: did each sender actually get its 20 ticks/s?
    $senderTicks = @(); $senderFps = @()
    Get-ChildItem $out -Filter "mc-load-wireless-sender*.txt" -ErrorAction SilentlyContinue | ForEach-Object {
        $st = Get-Content $_.FullName -Raw
        if ($st -match "LOAD_SENT total=(\d+) ticks=(\d+) span=([0-9.]+) fps=([0-9.]+)") {
            $senderTicks += [double]$matches[2]
            $senderFps += [double]$matches[4]
        }
    }
    $ticksAvg = if ($senderTicks.Count) { [math]::Round((($senderTicks | Measure-Object -Average).Average), 1) } else { 0 }
    $senderFpsAvg = if ($senderFps.Count) { [math]::Round((($senderFps | Measure-Object -Average).Average), 0) } else { 0 }
    $senderFpsTotal = if ($senderFps.Count) { [math]::Round((($senderFps | Measure-Object -Sum).Sum), 0) } else { 0 }
    $tps = ""; $tick_ms = ""
    if ($text -match "(?m)^tps=(\S+.*)$") { $tps = $matches[1].Trim() }
    if ($text -match "(?m)^tick_ms=(\S+.*)$") { $tick_ms = $matches[1].Trim() }
    $verdict = if ($text -match "verdict=PASS") { "PASS" } else { "FAIL" }

    $offered = $Count * $k
    $rows += [pscustomobject]@{
        senders        = $Count
        per_tick       = $k
        offered_per_tick = $offered
        offered_fps    = $offered * 20
        achieved_fps   = $fps
        achieved_per_tick = $perTickAchieved
        received       = $recv
        sender_ticks_avg = $ticksAvg
        sender_fps_total = $senderFpsTotal
        tps            = $tps
        tick_ms        = $tick_ms
        verdict        = $verdict
    }
    "k=$k offered_per_tick=$offered achieved_fps=$fps achieved_per_tick=$perTickAchieved sender_ticks_avg=$ticksAvg sender_fps_total=$senderFpsTotal verdict=$verdict"
    Remove-Item $log -Force -ErrorAction SilentlyContinue
    Get-ChildItem $out -Filter "mc-load-wireless-sender*.txt" -ErrorAction SilentlyContinue | Remove-Item -Force
}

$header = "senders per_tick offered_frames_per_tick offered_fps achieved_fps achieved_per_tick received sender_ticks_avg sender_fps_total tps tick_ms verdict"
$lines = @($header)
foreach ($r in $rows) {
    $lines += ("{0} {1} {2} {3} {4} {5} {6} {7} {8} `"{9}`" `"{10}`" {11}" -f $r.senders, $r.per_tick, $r.offered_per_tick,
        $r.offered_fps, $r.achieved_fps, $r.achieved_per_tick, $r.received, $r.sender_ticks_avg, $r.sender_fps_total,
        $r.tps, $r.tick_ms, $r.verdict)
}
$lines += ("# target=$Target secs=$Secs count=$Count generated=" + (Get-Date -Format "yyyy-MM-dd HH:mm:ss"))
$lines | Set-Content $curve
""
"===== curve ($curve) ====="
$lines | ForEach-Object { $_ }
