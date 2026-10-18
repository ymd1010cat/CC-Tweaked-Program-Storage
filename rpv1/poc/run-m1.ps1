# M1 acceptance: modular rpv library + UDP socket API + ping/traceroute/routectl.
#
# Computer IDs stay inside 20-30 (reserved for this harness; other IDs belong to
# other DSH sessions).
#
#   21 = router  : LAN-A 10.0.1.1/24 (ch 4001), LAN-B 10.0.2.1/24 (ch 4002)
#   22 = host A  : 10.0.1.2, gw 10.0.1.1, app=socket-echo:9000
#   23 = host B  : 10.0.2.2, gw 10.0.2.1, app=m1-selftest:10.0.1.2:9000
#
# Scenarios:
#   m1        the selftest app (public API only) must report traceroute hops >= 2
#             (router then host), 3 ping replies and a working socket exchange
#   routectl  the router runs app=routectl and must print its interface/route/
#             socket report
param(
    [string]$Scenario = "m1",
    [int]$TimeoutSec = 120,
    [string]$Root = $env:RPV_ROOT
)

$root = $Root
if (-not $root) { $root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path) }
$data = Join-Path $root "craftos-m1-$Scenario"
$exe = "C:\Program Files\CraftOS-PC\CraftOS-PC_console.exe"
$bootstrap = Join-Path $root "poc\node2\startup.lua"
$rpvdir = Join-Path $root "poc\rpv"
$appsdir = Join-Path $root "poc\apps"

if (Test-Path $data) { Remove-Item -Recurse -Force $data }
New-Item -ItemType Directory -Force -Path $data | Out-Null

$routerApp = if ($Scenario -eq "routectl") { "app=routectl:all`n" } else { "" }
$routerStats = if ($Scenario -eq "routectl") { "stats_at=3`n" } else { "stats_at=12`n" }

$roles = @{}
if ($Scenario -eq "badcfg") {
    # duplicate channel + overlapping subnets + MTU below 68 + reserved channel
    $roles[21] = "role=router`niface=back|LAN-A|10.0.1.1/24|4001|256|wired`niface=left|LAN-B|10.0.1.128/25|4001|64|wired`niface=top|LAN-C|192.168.9.1/24|65535|256|wired`nstats_at=4`n"
} else {
    $roles[21] = "role=router`niface=back|LAN-A|10.0.1.1/24|4001|256|wired`niface=left|LAN-B|10.0.2.1/24|4002|256|wired`n${routerApp}spawn=22,23`n$routerStats"
}
$roles[22] = "role=host`niface=back|LAN-A|10.0.1.2/24|4001|256|wired`ngw=10.0.1.1`napp=socket-echo:9000`nstats_at=12`n"
$roles[23] = "role=host`niface=back|LAN-B|10.0.2.2/24|4002|256|wired`ngw=10.0.2.1`napp=m1-selftest:10.0.1.2:9000`n"

foreach ($id in @(21, 22, 23)) {
    $dir = Join-Path $data "computer\$id"
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    New-Item -ItemType Directory -Force -Path (Join-Path $dir "rpv") | Out-Null
    New-Item -ItemType Directory -Force -Path (Join-Path $dir "apps") | Out-Null
    Copy-Item (Join-Path $rpvdir "*.lua") (Join-Path $dir "rpv") -Force
    Copy-Item (Join-Path $appsdir "*.lua") (Join-Path $dir "apps") -Force
    Copy-Item $bootstrap (Join-Path $dir "startup.lua") -Force
    Set-Content -Path (Join-Path $dir "role.txt") -Value $roles[$id] -Encoding ascii
}

New-Item -ItemType Directory -Force -Path (Join-Path $root "poc\out") | Out-Null
$stdout = Join-Path $root "poc\out\m1-$Scenario.stdout.txt"
$stderr = Join-Path $root "poc\out\m1-$Scenario.stderr.txt"
$proc = Start-Process -FilePath $exe -ArgumentList @("-d", "`"$data`"", "--headless", "--id", "21") `
    -RedirectStandardOutput $stdout -RedirectStandardError $stderr -PassThru -NoNewWindow

$log21 = Join-Path $data "computer\21\rpv-log.txt"
$log23 = Join-Path $data "computer\23\rpv-log.txt"
$needle = if ($Scenario -eq "routectl" -or $Scenario -eq "badcfg") { if ($Scenario -eq "badcfg") { "CFG_SUMMARY" } else { "ROUTECTL_DONE" } } else { "TEST_DONE" }
$watch = if ($Scenario -eq "routectl" -or $Scenario -eq "badcfg") { $log21 } else { $log23 }
$deadline = (Get-Date).AddSeconds($TimeoutSec)
$done = $false
while ((Get-Date) -lt $deadline) {
    Start-Sleep -Milliseconds 400
    if ($proc.HasExited) { break }
    if (Test-Path $watch) { if ((Get-Content $watch -Raw) -match $needle) { $done = $true; break } }
}
Start-Sleep -Milliseconds 2000
if (-not $done -and (Test-Path $watch)) { if ((Get-Content $watch -Raw) -match $needle) { $done = $true } }
if (-not $proc.HasExited) { $proc.Kill() }
Start-Sleep -Milliseconds 300

foreach ($id in @(21, 22, 23)) {
    $src = Join-Path $data "computer\$id\rpv-log.txt"
    if (Test-Path $src) { Copy-Item $src (Join-Path $root "poc\out\m1-$Scenario-node$id.log") -Force }
}

$routerText = if (Test-Path $log21) { Get-Content $log21 -Raw } else { "" }
$selftest = if (Test-Path $log23) { Get-Content $log23 -Raw } else { "" }
$echoLog = Join-Path $data "computer\22\rpv-log.txt"
$echo = if (Test-Path $echoLog) { Get-Content $echoLog -Raw } else { "" }

$verdict = "FAIL"
if ($Scenario -eq "routectl") {
    if ($routerText -match "ROUTECTL iface LAN-A addr=10\.0\.1\.1/24" -and
        $routerText -match "ROUTECTL route 10\.0\.2\.0/24" -and
        $routerText -match "ROUTECTL_DONE") { $verdict = "PASS" }
} elseif ($Scenario -eq "badcfg") {
    $n = ([regex]::Matches($routerText, "CFG_WARN ")).Count
    if ($n -ge 4 -and
        $routerText -match "CFG_WARN duplicate channel=4001" -and
        $routerText -match "CFG_WARN overlapping subnets" -and
        $routerText -match "CFG_WARN mtu=64" -and
        $routerText -match "CFG_WARN channel=65535") { $verdict = "PASS" }
} else {
    if ($selftest -match "SELFTEST_RESULT hops=(\d+) hop1=([\d\.]+) hop2=([\d\.]+) pings=(\d+) socket_ok=(\w+) complete=(\w+)") {
        $hops = [int]$Matches[1]; $h1 = $Matches[2]; $h2 = $Matches[3]; $pings = [int]$Matches[4]; $sock = $Matches[5]; $complete = $Matches[6]
        if ($hops -ge 2 -and $h1 -eq "10.0.2.1" -and $h2 -eq "10.0.1.2" -and $pings -ge 3 -and $sock -eq "true" -and $complete -eq "true" -and $echo -match "ECHO_APP recv") {
            $verdict = "PASS"
        }
    }
}

"RESULT m1 scenario=$Scenario done=$done verdict=$verdict"
"===== NODE 21 (router) ====="
if ($routerText) { Get-Content $log21 }
"===== NODE 22 (host A, socket-echo app) ====="
if (Test-Path $echoLog) { Get-Content $echoLog }
"===== NODE 23 (host B, m1-selftest app) ====="
if (Test-Path $log23) { Get-Content $log23 }
"===== STDERR ====="
if (Test-Path $stderr) { Get-Content $stderr -Raw }
