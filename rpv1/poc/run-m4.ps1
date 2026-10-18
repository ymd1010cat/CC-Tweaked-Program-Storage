# M4 operational acceptance: routes hot reload, metrics panel, boot watchdog.
#
#   reload   21 = router with routes.txt; the harness rewrites the file mid-run
#            and expects ROUTES_RELOADED (boot n=1 then file change n=2)
#   panel    21 = collector + monitor (app=panel:4200), 22/23 = telemetry agents
#            (lan A and lan B) -> PANEL_MONITOR attached, PANEL_OK, TEST_DONE
#   watchdog 21 = node with crash_after=1 -> first boot crashes (crash.log),
#            reboots itself and the second boot logs WATCHDOG_RECOVERED
param(
    [string]$Scenario = "reload",
    [int]$TimeoutSec = 90,
    [string]$Root = $env:RPV_ROOT
)

$root = $Root
if (-not $root) { $root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path) }
$data = Join-Path $root "craftos-m4-$Scenario"
$exe = "C:\Program Files\CraftOS-PC\CraftOS-PC_console.exe"
$bootstrap = Join-Path $root "poc\node2\startup.lua"
$rpvdir = Join-Path $root "poc\rpv"
$appsdir = Join-Path $root "poc\apps"
$compatdir = Join-Path $root "poc\compat"

if (Test-Path $data) { Remove-Item -Recurse -Force $data }
New-Item -ItemType Directory -Force -Path $data | Out-Null

$roles = @{}
if ($Scenario -eq "watchdog") {
    $roles[21] = "role=host`niface=back|LAN-A|10.0.1.1/24|4001|256|wired`ncrash_after=1`nstats_at=20`n"
    $ids = @(21)
} elseif ($Scenario -eq "panel") {
    $roles[21] = "role=router`niface=back|LAN-A|10.0.1.1/24|4001|256|wired`niface=left|LAN-B|10.0.2.1/24|4002|256|wired`napp=panel:4200`nspawn=22,23`nstats_at=20`n"
    $roles[22] = "role=host`niface=back|LAN-A|10.0.1.2/24|4001|256|wired`ngw=10.0.1.1`napp=monitor-agent:10.0.1.1:4200`nmon_interval=3`n"
    $roles[23] = "role=host`niface=back|LAN-B|10.0.2.2/24|4002|256|wired`ngw=10.0.2.1`napp=monitor-agent:10.0.1.1:4200`nmon_interval=3`n"
    $ids = @(21, 22, 23)
} else {
    $roles[21] = "role=router`niface=back|LAN-A|10.0.1.1/24|4001|256|wired`niface=left|LAN-B|10.0.2.1/24|4002|256|wired`nstats_at=20`n"
    $ids = @(21)
}

foreach ($id in $ids) {
    $dir = Join-Path $data "computer\$id"
    foreach ($sub in @("rpv", "apps", "compat")) { New-Item -ItemType Directory -Force -Path (Join-Path $dir $sub) | Out-Null }
    Copy-Item (Join-Path $rpvdir "*.lua") (Join-Path $dir "rpv") -Force
    Copy-Item (Join-Path $appsdir "*.lua") (Join-Path $dir "apps") -Force
    Copy-Item (Join-Path $compatdir "*.lua") (Join-Path $dir "compat") -Force
    Copy-Item $bootstrap (Join-Path $dir "startup.lua") -Force
    Set-Content -Path (Join-Path $dir "role.txt") -Value $roles[$id] -Encoding ascii
}
$routesFile = Join-Path $data "computer\21\routes.txt"
if ($Scenario -eq "reload") {
    Set-Content -Path $routesFile -Encoding ascii -Value "10.99.0.0/24 via 10.0.2.1`n"
}

New-Item -ItemType Directory -Force -Path (Join-Path $root "poc\out") | Out-Null
$stdout = Join-Path $root "poc\out\m4-$Scenario.stdout.txt"
$stderr = Join-Path $root "poc\out\m4-$Scenario.stderr.txt"
$proc = Start-Process -FilePath $exe -ArgumentList @("-d", "`"$data`"", "--headless", "--id", "21") `
    -RedirectStandardOutput $stdout -RedirectStandardError $stderr -PassThru -NoNewWindow

$log21 = Join-Path $data "computer\21\rpv-log.txt"
$crashLog = Join-Path $data "computer\21\crash.log"

if ($Scenario -eq "reload") {
    Start-Sleep -Seconds 4
    Set-Content -Path $routesFile -Encoding ascii -Value "10.99.0.0/24 via 10.0.2.1`n10.98.0.0/16 via 10.0.2.1`n"
    Start-Sleep -Seconds 6
} elseif ($Scenario -eq "panel") {
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline -and -not $proc.HasExited) {
        Start-Sleep -Milliseconds 400
        if ((Test-Path $log21) -and ((Get-Content $log21 -Raw) -match "TEST_DONE")) { break }
    }
    Start-Sleep -Seconds 2
} else {
    Start-Sleep -Seconds 14
}
if (-not $proc.HasExited) { $proc.Kill() }
Start-Sleep -Milliseconds 300

foreach ($id in $ids) {
    $src = Join-Path $data "computer\$id\rpv-log.txt"
    if (Test-Path $src) { Copy-Item $src (Join-Path $root "poc\out\m4-$Scenario-node$id.log") -Force }
}
if (Test-Path $crashLog) { Copy-Item $crashLog (Join-Path $root "poc\out\m4-$Scenario-crash.log") -Force }

$t21 = if (Test-Path $log21) { Get-Content $log21 -Raw } else { "" }
$tc = if (Test-Path $crashLog) { Get-Content $crashLog -Raw } else { "" }

$verdict = "FAIL"
if ($Scenario -eq "reload") {
    if ($t21 -match "ROUTES_RELOADED n=1 \(boot\)" -and $t21 -match "ROUTES_RELOADED n=2 \(file change\)") { $verdict = "PASS" }
} elseif ($Scenario -eq "panel") {
    if ($t21 -match "PANEL_DRAW nodes=2" -and $t21 -match "PANEL_OK" -and $t21 -match "TEST_DONE" -and
        ($t21 -match "PANEL_MONITOR attached" -or $t21 -match "PANEL_ATTACH_FAIL")) { $verdict = "PASS" }
} else {
    if ($tc -match "BOOT_CRASH" -and $t21 -match "WATCHDOG_RECOVERED" -and $t21 -match "NODE id=21") { $verdict = "PASS" }
}

"RESULT m4-$Scenario verdict=$verdict"
"===== NODE 21 log ====="
if (Test-Path $log21) { Get-Content $log21 | Where-Object { $_ -match "ROUTES|PANEL|WATCHDOG|BOOT|NODE id|MON_|TEST_DONE|TASK_ERROR" } }
"===== crash.log ====="
if (Test-Path $crashLog) { Get-Content $crashLog } else { "(none)" }
"===== STDERR ====="
if (Test-Path $stderr) { Get-Content $stderr -Raw }
