# P4 acceptance: full config hot reload while the network runs.
#
#   21 = router (LAN-A 10.0.1.1, LAN-B 10.0.2.1)   <- its files are rewritten mid-run
#   22 = near host 10.0.1.2 (app=hotreload-selftest:10.0.3.2)
#   23 = second router (LAN-B 10.0.2.3, LAN-C 10.0.3.1)
#   24 = far host 10.0.3.2 (udp-echo)
#
# At t~9s the harness writes routes.txt (route to 10.0.3.0/24 via 10.0.2.3), appends a
# safe key (stats_at) and a restart-required key (app) to role.txt, and adds a
# hosts.txt entry. The router must pick all of that up without a restart:
#   ROUTES_RELOADED (file change) / CFG_RELOAD + CFG_CHANGED + CFG_RELOAD_RESTART_REQUIRED
#   HOSTS_RELOADED, and the near host's second ping must succeed.
#
#   pwsh -File poc\run-hotreload.ps1
param([int]$TimeoutSec = 150, [string]$Root = $env:RPV_ROOT)

$root = $Root
if (-not $root) { $root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path) }
$data = Join-Path $root "craftos-hotreload"
$exe = "C:\Program Files\CraftOS-PC\CraftOS-PC_console.exe"
$bootstrap = Join-Path $root "poc\node2\startup.lua"
$rpvdir = Join-Path $root "poc\rpv"
$appsdir = Join-Path $root "poc\apps"
$compatdir = Join-Path $root "poc\compat"
$out = Join-Path $root "poc\out"
New-Item -ItemType Directory -Force -Path $out | Out-Null
if (Test-Path $data) { Remove-Item -Recurse -Force $data }

$roles = @{}
$roles[21] = "role=router`niface=back|LAN-A|10.0.1.1/24|4801|512|wired`n" +
    "iface=left|LAN-B|10.0.2.1/24|4802|512|wired`nstats_at=40`nspawn=22,23,24`n"
$roles[22] = "role=host`niface=back|LAN-A|10.0.1.2/24|4801|512|wired`ngw=10.0.1.1`n" +
    "app=hotreload-selftest:10.0.3.2`nstart_delay=5`n"
$roles[23] = "role=router`niface=back|LAN-B|10.0.2.3/24|4802|512|wired`n" +
    "iface=left|LAN-C|10.0.3.1/24|4803|512|wired`nstats_at=40`n"
$roles[24] = "role=host`niface=back|LAN-C|10.0.3.2/24|4803|512|wired`ngw=10.0.3.1`napp=udp-echo:7`n"

foreach ($id in @(21, 22, 23, 24)) {
    $dir = Join-Path $data "computer\$id"
    foreach ($sub in @("rpv", "apps", "compat")) { New-Item -ItemType Directory -Force -Path (Join-Path $dir $sub) | Out-Null }
    Copy-Item (Join-Path $rpvdir "*.lua") (Join-Path $dir "rpv") -Force
    Copy-Item (Join-Path $appsdir "*.lua") (Join-Path $dir "apps") -Force
    Copy-Item (Join-Path $compatdir "*.lua") (Join-Path $dir "compat") -Force
    Copy-Item $bootstrap (Join-Path $dir "startup.lua") -Force
    Set-Content -Path (Join-Path $dir "role.txt") -Value $roles[$id] -Encoding ascii
}
# the far router needs a static return route to LAN-A (this run is about router 21 reloading)
Set-Content -Path (Join-Path $data "computer\23\routes.txt") -Encoding ascii -Value "10.0.1.0/24 via 10.0.2.1`n"

$stdout = Join-Path $out "hotreload.stdout.txt"
$stderr = Join-Path $out "hotreload.stderr.txt"
$proc = Start-Process -FilePath $exe -ArgumentList @("-d", "`"$data`"", "--headless", "--id", "21") `
    -RedirectStandardOutput $stdout -RedirectStandardError $stderr -PassThru -NoNewWindow

# wait until the near host has reported its "before" phase, then rewrite the router's files
$watchLog = Join-Path $data "computer\22\rpv-log.txt"
$deadline = (Get-Date).AddSeconds($TimeoutSec)
$reloaded = $false
while ((Get-Date) -lt $deadline) {
    Start-Sleep -Milliseconds 400
    if ($proc.HasExited) { break }
    if (-not $reloaded -and (Test-Path $watchLog)) {
        if ((Get-Content $watchLog -Raw) -match "HR_BEFORE") {
            # 1. give the router the missing static route
            Set-Content -Path (Join-Path $data "computer\21\routes.txt") -Encoding ascii `
                -Value "10.0.3.0/24 via 10.0.2.3`n"
            # 2. a safe key change and a restart-required one
            $roleTxt = Get-Content (Join-Path $data "computer\21\role.txt") -Raw
            Set-Content -Path (Join-Path $data "computer\21\role.txt") -Encoding ascii `
                -Value ($roleTxt + "stats_at=45`n" + "app=udp-echo:7`n")
            # 3. a new static name mapping (on the router and on the host whose lookup
            #    is asserted, so both reload paths are exercised)
            Set-Content -Path (Join-Path $data "computer\21\hosts.txt") -Encoding ascii `
                -Value "printer 10.0.3.2`n"
            Set-Content -Path (Join-Path $data "computer\22\hosts.txt") -Encoding ascii `
                -Value "printer 10.0.3.2`n"
            $reloaded = $true
            "HARNESS rewrote routes.txt / role.txt / hosts.txt on computer 21"
        }
    }
    if (Test-Path $watchLog) { if ((Get-Content $watchLog -Raw) -match "TEST_DONE") { break } }
}
Start-Sleep -Seconds 1
if (-not $proc.HasExited) { $proc.Kill() }
Start-Sleep -Milliseconds 400

$logs = @{}
foreach ($id in @(21, 22, 23, 24)) {
    $p = Join-Path $data "computer\$id\rpv-log.txt"
    $logs[$id] = if (Test-Path $p) { Get-Content $p -Raw } else { "" }
    if ($logs[$id]) { Copy-Item $p (Join-Path $out "hotreload-node$id.log") -Force }
}

$hr = ($logs[22] -split "`n" | Where-Object { $_ -match "HR_RESULT" } | Select-Object -Last 1)
$before = $logs[22] -match "HR_BEFORE ping_ok=false"
$after = $logs[22] -match "HR_AFTER ping_ok=true"
$lookBefore = $logs[22] -match "HR_LOOKUP_BEFORE ok=false"
$lookAfter = $logs[22] -match "HR_LOOKUP_AFTER ok=true"
$routesReloaded = $logs[21] -match "ROUTES_RELOADED n=\d+ \(file change\)"
$cfgReload = $logs[21] -match "CFG_RELOAD changed=\d+ restart_required=\d+ \(file change\)"
$cfgChanged = $logs[21] -match "CFG_CHANGED stats_at="
$cfgRestart = $logs[21] -match "CFG_RELOAD_RESTART_REQUIRED key=app"
$hostsReloaded = $logs[21] -match "HOSTS_RELOADED"

$verdict = "FAIL"
if ($before -and $after -and $lookBefore -and $lookAfter -and $routesReloaded -and $cfgReload `
    -and $cfgChanged -and $cfgRestart -and $hostsReloaded) { $verdict = "PASS" }

"RESULT hotreload done=$([bool]$hr) verdict=$verdict"
"HR_RESULT   $($hr -replace '^.*HR_RESULT', 'HR_RESULT')"
"CHECKS before_blocked=$before after_ok=$after lookup_before_failed=$lookBefore lookup_after=$lookAfter"
"CHECKS routes_reloaded=$routesReloaded cfg_reload=$cfgReload cfg_changed=$cfgChanged restart_key=$cfgRestart hosts_reloaded=$hostsReloaded"
($logs[21] -split "`n" | Where-Object { $_ -match "ROUTES_RELOADED|CFG_RELOAD|CFG_CHANGED|HOSTS_RELOADED" }) | Select-Object -First 6 | ForEach-Object { "R21 " + $_.Trim() }
($logs[22] -split "`n" | Where-Object { $_ -match "HR_" }) | Select-Object -First 8 | ForEach-Object { "HOST " + $_.Trim() }
