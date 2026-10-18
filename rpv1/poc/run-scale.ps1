# Large-scale acceptance (approved CraftOS-PC id range 100-300).
#
#   pwsh -File poc\run-scale.ps1 -Stage A     4x4 router grid + 6 hosts   (22 computers)
#   pwsh -File poc\run-scale.ps1 -Stage B     6x6 router grid + 8 hosts   (44 computers)
#   pwsh -File poc\run-scale.ps1 -Stage C     8x8 router grid + 8 hosts   (72 computers)
#   pwsh -File poc\run-scale.ps1 -Stage D     10 clusters x 10 routers + 10 hosts (110 computers)
#
# Grid: row segments (channel 5200+i) and column segments (channel 5300+j); router (i,j)
# sits on row i and column j and runs DV, so hosts on different rows reach each other
# through the mesh. The hop ceiling is INF=16, so stage C (8x8 -> diameter 15) is the
# largest grid that still fits; stage D therefore uses 10 clusters of 10 routers (a star
# per cluster, cluster heads in a ring: diameter ~9).
#
# Every computer writes its own log; the verdict comes from how many actually booted, how
# many routers converged, how many host-to-host pings crossed the mesh, and the measured
# timer drift (the "is the emulator keeping up" number).
param(
    [ValidateSet("T", "Z", "Y", "A", "B", "C", "D")]
    [string]$Stage = "A",
    [switch]$Trace,
    [int]$TimeoutSec = 0,
    [string]$Root = $env:RPV_ROOT
)

$root = $Root
if (-not $root) { $root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path) }
$exe = "C:\Program Files\CraftOS-PC\CraftOS-PC_console.exe"
$bootstrap = Join-Path $root "poc\node2\startup.lua"
$rpvdir = Join-Path $root "poc\rpv"
$appsdir = Join-Path $root "poc\apps"
$compatdir = Join-Path $root "poc\compat"
$out = Join-Path $root "poc\out"
$data = Join-Path $root "craftos-scale-$Stage"
New-Item -ItemType Directory -Force -Path $out | Out-Null
if (Test-Path $data) { Remove-Item -Recurse -Force $data }

$cfg = @{
    T = @{ topo = "grid"; rows = 3; cols = 3; hosts = 3; secs = 70; trace = $true; iv = 2; to = 30; jit = 0 }
    Z = @{ topo = "grid"; rows = 2; cols = 2; hosts = 2; secs = 60; iv = 2; to = 30; jit = 0 }
    Y = @{ topo = "grid"; rows = 3; cols = 3; hosts = 2; secs = 70; iv = 2; to = 30; jit = 0 }
    A = @{ topo = "grid"; rows = 4; cols = 4; hosts = 6; secs = 110; iv = 6; to = 45; jit = 0.3 }
    B = @{ topo = "grid"; rows = 6; cols = 6; hosts = 8; secs = 150; iv = 16; to = 75; jit = 0.5 }
    C = @{ topo = "grid"; rows = 8; cols = 8; hosts = 8; secs = 180; iv = 14; to = 80; jit = 0.4 }
    D = @{ topo = "clusters"; clusters = 10; per = 10; hosts = 10; secs = 210; iv = 24; to = 130; jit = 0.5 }
}[$Stage]
if ($TimeoutSec -le 0) { $TimeoutSec = $cfg.secs + 150 }

# ---- build the computer plan -------------------------------------------------
$plan = @{}          # id -> role text
$routers = @()
$hosts = @()
$dv = "dv=1`ndv_interval=$($cfg.iv)`ndv_timeout=$($cfg.to)`ndv_jitter=$($cfg.jit)`n"
$chRow = 5200
$chCol = 5300
$chCl = 5400
$chRing = 5500

if ($cfg.topo -eq "grid") {
    for ($i = 1; $i -le $cfg.rows; $i++) {
        for ($j = 1; $j -le $cfg.cols; $j++) {
            $id = 100 + ($i - 1) * $cfg.cols + ($j - 1)
            $routers = $routers + @($id)
            # addresses must be unique WITHIN a segment: on a row segment the column index
            # makes them unique, on a column segment the row index does
            $plan[$id] = "role=router`n" +
                "iface=back|ROW$i|10.$i.0.$($j + 1)/24|$($chRow + $i)|512|wireless`n" +
                "iface=left|COL$j|10.$(100 + $j).0.$($i + 1)/24|$($chCol + $j)|512|wireless`n" +
                "${dv}stats_at=60`n"
        }
    }
    # hosts: one per row while they last, addressed above the routers in that row
    $hostFirst = @{}
    for ($h = 1; $h -le $cfg.hosts; $h++) {
        $row = (($h - 1) % $cfg.rows) + 1
        $idx = [math]::Floor(($h - 1) / $cfg.rows) + 1
        $id = 250 + $h
        $hosts = $hosts + @($id)
        $addr = "10.$row.0.$($cfg.cols + 1 + $idx)"
        if (-not $hostFirst.ContainsKey($row)) { $hostFirst[$row] = $addr }
        $plan[$id] = "role=host`niface=back|ROW$row|$addr/24|$($chRow + $row)|512|wireless`n" +
            "gw=10.$row.0.2`napp=scale-ping`npeers=__PEERS__`nrounds=3`ninterval=2`n" +
            "start_delay=$([int](30 + $h))`nstats_at=90`n"
    }
    foreach ($h in 1..$cfg.hosts) {
        $id = 250 + $h
        $row = (($h - 1) % $cfg.rows) + 1
        $list = @()
        foreach ($r2 in 1..$cfg.rows) {
            if ($r2 -ne $row -and $hostFirst.ContainsKey($r2)) { $list = $list + @($hostFirst[$r2]) }
        }
        $plan[$id] = $plan[$id].Replace("__PEERS__", ($list -join ','))
    }
} else {
    # clusters: `per` routers per cluster (a star around router 1), all heads on ONE ring
    for ($c = 1; $c -le $cfg.clusters; $c++) {
        for ($m = 1; $m -le $cfg.per; $m++) {
            $id = 100 + ($c - 1) * $cfg.per + ($m - 1)
            $routers = $routers + @($id)
            $ifaces = "iface=back|CL$c|10.$c.0.$m/24|$($chCl + $c)|512|wireless`n"
            if ($m -eq 1) {
                $ifaces += "iface=left|RING|10.200.0.$c/24|$chRing|512|wireless`n"
            }
            $plan[$id] = "role=router`n${ifaces}${dv}stats_at=90`n"
        }
    }
    for ($h = 1; $h -le $cfg.hosts; $h++) {
        $c = (($h - 1) % $cfg.clusters) + 1
        $idx = [math]::Floor(($h - 1) / $cfg.clusters) + 1
        $id = 250 + $h
        $hosts = $hosts + @($id)
        $peers = @()
        for ($c2 = 1; $c2 -le $cfg.clusters; $c2++) {
            if ($c2 -ne $c) { $peers = $peers + @("10.$c2.0.$($cfg.per + 1)") }
        }
        $plan[$id] = "role=host`niface=back|CL$c|10.$c.0.$($cfg.per + $idx)/24|$($chCl + $c)|512|wireless`n" +
            "gw=10.$c.0.1`napp=scale-ping`npeers=$($peers -join ',')`nrounds=3`ninterval=2`n" +
            "start_delay=$([int](40 + $h * 2))`nstats_at=90`n"
    }
}

# ---- address sanity: no two interfaces may share (channel, ip) ----
# (this class of mistake already produced two bogus "protocol bugs": with duplicate
#  addresses the ARP owners fight over the address and every ping looks broken)
$seenAddr = @{}
$addrClash = @()
foreach ($id in @($plan.Keys)) {
    if ("$id".StartsWith("__")) { continue }
    foreach ($line in ($plan[$id] -split "`n")) {
        if ($line -match "^iface=([^|]+)\|([^|]+)\|([^|]+)\|([^|]+)\|") {
            $addr = $Matches[3]
            $chan = $Matches[4]
            $key = "$chan/$addr"
            if ($seenAddr.ContainsKey($key)) {
                $addrClash = $addrClash + @("ch$chan $addr : computer $($seenAddr[$key]) and computer $id")
            } else {
                $seenAddr[$key] = $id
            }
        }
    }
}
if ($addrClash.Count -gt 0) {
    foreach ($c in $addrClash) { Write-Output "ADDR_CLASH $c" }
    throw "address conflict: $($addrClash.Count) duplicate (channel,address) pair(s) -- fix the plan before booting"
}
Write-Output "ADDR_CHECK ok sites=$($plan.Count) addresses=$($seenAddr.Count)"

$allIds = @($plan.Keys | Sort-Object)
$spawner = $allIds[0]

# ---- optional per-packet tracing (trace=1 on every node of this stage) -------
if ($cfg.trace -or $Trace) {
    foreach ($k in @($plan.Keys)) { $plan[$k] = $plan[$k] + "trace=1`n" }
}

# ---- stage the files (one shared template, then a fast recursive copy) -------
$tpl = Join-Path $data "_tpl"
foreach ($sub in @("rpv", "apps", "compat")) { New-Item -ItemType Directory -Force -Path (Join-Path $tpl $sub) | Out-Null }
Copy-Item (Join-Path $rpvdir "*.lua") (Join-Path $tpl "rpv") -Force
Copy-Item (Join-Path $appsdir "*.lua") (Join-Path $tpl "apps") -Force
Copy-Item (Join-Path $compatdir "*.lua") (Join-Path $tpl "compat") -Force
Copy-Item $bootstrap (Join-Path $tpl "startup.lua") -Force

$t0 = Get-Date
foreach ($id in $allIds) {
    $dir = Join-Path $data "computer\$id"
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    Copy-Item (Join-Path $tpl "*") $dir -Recurse -Force
    Set-Content -Path (Join-Path $dir "role.txt") -Value $plan[$id] -Encoding ascii
}
if ($allIds.Count -gt 1) {
    # the first computer opens all the others, then runs its own node
    $others = ($allIds | Where-Object { $_ -ne $spawner })
    $lines = @("if ccemux and ccemux.openEmu then")
    foreach ($id in $others) { $lines += "    ccemux.openEmu($id) os.sleep(0.35)" }
    $lines += @("end", "os.sleep(2)", "local fn = loadfile(""startup-real.lua"")", "if fn then return fn() end", "print(""bootstrap missing"")")
    $dir = Join-Path $data "computer\$spawner"
    Move-Item (Join-Path $dir "startup.lua") (Join-Path $dir "startup-real.lua") -Force
    Set-Content -Path (Join-Path $dir "startup.lua") -Value ($lines -join "`n") -Encoding ascii
}
Remove-Item $tpl -Recurse -Force
$stageSec = ((Get-Date) - $t0).TotalSeconds

# ---- boot -------------------------------------------------------------------
$stdout = Join-Path $out "scale-$Stage.stdout.txt"
$stderr = Join-Path $out "scale-$Stage.stderr.txt"
$proc = Start-Process -FilePath $exe -ArgumentList @("-d", "`"$data`"", "--headless", "--id", "$spawner") `
    -RedirectStandardOutput $stdout -RedirectStandardError $stderr -PassThru -NoNewWindow

# wait until every host either finished its ping sweep or the deadline passes
$hostLogs = @{}
foreach ($h in $hosts) { $hostLogs[$h] = Join-Path $data "computer\$h\scale-log.txt" }
$deadline = (Get-Date).AddSeconds($TimeoutSec)
$done = 0
while ((Get-Date) -lt $deadline) {
    Start-Sleep -Seconds 3
    if ($proc.HasExited) { break }
    $done = 0
    foreach ($h in $hosts) {
        if ((Test-Path $hostLogs[$h]) -and ((Get-Content $hostLogs[$h] -Raw) -match "TEST_DONE")) { $done = $done + 1 }
    }
    if ($done -eq $hosts.Count) { break }
}
$bootSec = ((Get-Date) - $t0).TotalSeconds
Start-Sleep -Seconds 3
if (-not $proc.HasExited) { $proc.Kill() }
Start-Sleep -Milliseconds 500

# ---- collect ----------------------------------------------------------------
$booted = 0
$dvRouters = 0
$hostsLogged = 0
$pingOk = 0
$pingTotal = 0
$lagSum = 0.0
$lagMax = 0.0
$lagN = 0
foreach ($id in $allIds) {
    $rf = Join-Path $data "computer\$id\rpv-log.txt"
    if (-not (Test-Path $rf)) { continue }
    $txt = Get-Content $rf -Raw
    Copy-Item $rf (Join-Path $out "scale-$Stage-node$id.log") -Force
    if ($txt -match "NODE id=$id") { $booted = $booted + 1 }
    if ($txt -match "DV_INSTALL|DV_UPDATE") { $dvRouters = $dvRouters + 1 }
}
foreach ($h in $hosts) {
    $lf = $hostLogs[$h]
    if (-not (Test-Path $lf)) { continue }
    $txt = Get-Content $lf -Raw
    if ($txt -match "TEST_DONE") { $hostsLogged = $hostsLogged + 1 }
    Copy-Item $lf (Join-Path $out "scale-$Stage-host$h.log") -Force
    if ($txt -match "SCALE_RESULT peers=(\d+) ok=(\d+)") { $pingTotal += [int]$Matches[1]; $pingOk += [int]$Matches[2] }
    if ($txt -match "SCALE_LAG avg_ms=([\d\.]+) max_ms=([\d\.]+)") {
        $lagSum += [double]$Matches[1]; $lagN = $lagN + 1
        if ([double]$Matches[2] -gt $lagMax) { $lagMax = [double]$Matches[2] }
    }
}
Remove-Item $data -Recurse -Force -ErrorAction SilentlyContinue

$pct = if ($pingTotal -gt 0) { [math]::Round($pingOk / $pingTotal * 100, 1) } else { 0 }
$bootPct = [math]::Round($booted / $allIds.Count * 100, 1)
$verdict = "FAIL"
if ($booted -ge [math]::Floor($allIds.Count * 0.9) -and $dvRouters -ge [math]::Ceiling($routers.Count * 0.6) -and $pct -ge 50) { $verdict = "PASS" }

"RESULT scale-$Stage computers=$($allIds.Count) routers=$($routers.Count) hosts=$($hosts.Count) verdict=$verdict"
"CHECKS booted=$booted/$($allIds.Count) ($bootPct%) dv_routers=$dvRouters/$($routers.Count) hosts_done=$hostsLogged/$($hosts.Count) ping_ok=$pingOk/$pingTotal ($pct%)"
"TIMING stage_s=$([int]$stageSec) total_s=$([int]$bootSec) timer_lag_avg_ms=$(if ($lagN -gt 0) { [int]($lagSum / $lagN) } else { -1 }) lag_max_ms=$([int]$lagMax) samples=$lagN"
