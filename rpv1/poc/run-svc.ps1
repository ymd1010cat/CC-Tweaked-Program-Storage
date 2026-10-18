# DHCP-lite + lookup-lite acceptance (CraftOS-PC).
#
#   21 = DHCP + name server on LAN-A (10.0.1.1/24, pool 10.0.1.100-150), also a
#        router to LAN-B (10.0.2.1/24)
#   22 = client with ONLY a placeholder address (10.254.0.22/16): it must lease
#        10.0.1.100, adopt the gateway, register "client22" and resolve+ping a name
#   23 = host on LAN-B (10.0.2.2) registered as "host23" -- reachable only through
#        the router the client just learned from DHCP
#
#   pwsh -File poc\run-svc.ps1
param([int]$TimeoutSec = 120, [string]$Root = $env:RPV_ROOT)

$root = $Root
if (-not $root) { $root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path) }
$data = Join-Path $root "craftos-svc"
$exe = "C:\Program Files\CraftOS-PC\CraftOS-PC_console.exe"
$bootstrap = Join-Path $root "poc\node2\startup.lua"
$rpvdir = Join-Path $root "poc\rpv"
$appsdir = Join-Path $root "poc\apps"
$compatdir = Join-Path $root "poc\compat"
$out = Join-Path $root "poc\out"
New-Item -ItemType Directory -Force -Path $out | Out-Null
if (Test-Path $data) { Remove-Item -Recurse -Force $data }

$roles = @{}
$roles[21] = "role=router`n" +
    "iface=back|LAN-A|10.0.1.1/24|4001|256|wired`n" +
    "iface=left|LAN-B|10.0.2.1/24|4002|256|wired`n" +
    "dhcp_pool=10.0.1.100-10.0.1.150`ndhcp_gw=10.0.1.1`ndhcp_dns=10.0.1.1`ndhcp_lease=600`n" +
    "dns=1`nname=svc-server`nspawn=22,23`nstats_at=25`n"
$roles[22] = "role=host`n" +
    "iface=back|LAN-A|10.254.0.22/16|4001|256|wired`n" +
    "dhcp=1`nname=client22`ndns_server=10.0.1.1`ndhcp_t1=4`n" +
    "app=svc-selftest:host23`nstart_delay=2`ndhcp_timeout=20`nsvc_hold=14`n"
$roles[23] = "role=host`n" +
    "iface=back|LAN-B|10.0.2.2/24|4002|256|wired`ngw=10.0.2.1`n" +
    "name=host23`ndns_server=10.0.1.1`napp=udp-echo:7`n"

foreach ($id in @(21, 22, 23)) {
    $dir = Join-Path $data "computer\$id"
    foreach ($sub in @("rpv", "apps", "compat")) { New-Item -ItemType Directory -Force -Path (Join-Path $dir $sub) | Out-Null }
    Copy-Item (Join-Path $rpvdir "*.lua") (Join-Path $dir "rpv") -Force
    Copy-Item (Join-Path $appsdir "*.lua") (Join-Path $dir "apps") -Force
    Copy-Item (Join-Path $compatdir "*.lua") (Join-Path $dir "compat") -Force
    Copy-Item $bootstrap (Join-Path $dir "startup.lua") -Force
    Set-Content -Path (Join-Path $dir "role.txt") -Value $roles[$id] -Encoding ascii
}

$stdout = Join-Path $out "svc.stdout.txt"
$stderr = Join-Path $out "svc.stderr.txt"
$proc = Start-Process -FilePath $exe -ArgumentList @("-d", "`"$data`"", "--headless", "--id", "21") `
    -RedirectStandardOutput $stdout -RedirectStandardError $stderr -PassThru -NoNewWindow

$clientLog = Join-Path $data "computer\22\svc-log.txt"
$deadline = (Get-Date).AddSeconds($TimeoutSec)
$done = $false
while ((Get-Date) -lt $deadline) {
    Start-Sleep -Milliseconds 400
    if ($proc.HasExited) { break }
    if (Test-Path $clientLog) { if ((Get-Content $clientLog -Raw) -match "TEST_DONE") { $done = $true; break } }
}
Start-Sleep -Milliseconds 1500
if (-not $proc.HasExited) { $proc.Kill() }
Start-Sleep -Milliseconds 300

foreach ($id in @(21, 22, 23)) {
    foreach ($f in @("svc-log.txt", "rpv-log.txt")) {
        $src = Join-Path $data "computer\$id\$f"
        if (Test-Path $src) { Copy-Item $src (Join-Path $out "svc-node$id-$f") -Force }
    }
}

$svc = if (Test-Path $clientLog) { Get-Content $clientLog -Raw } else { "" }
$srvP = Join-Path $data "computer\21\rpv-log.txt"
$srv = if (Test-Path $srvP) { Get-Content $srvP -Raw } else { "" }
$h23P = Join-Path $data "computer\23\rpv-log.txt"
$h23 = if (Test-Path $h23P) { Get-Content $h23P -Raw } else { "" }

$verdict = "FAIL"
$bound = $svc -match "SVC_BOUND ip=10\.0\.1\.100"
$lookup = $svc -match "SVC_LOOKUP name=host23 ip=10\.0\.2\.2 ok=true"
$ping = $svc -match "SVC_PING ok=true"
$lease = $srv -match "DHCP_LEASE ip=10\.0\.1\.100"
$regs = ($srv -match "DNS_REG name=client22") -and ($srv -match "DNS_REG name=host23")
# T1 renewal: the client asks again before the lease lapses and the server records it
$cliNodeLog = Join-Path $data "computer\22\rpv-log.txt"
$cliNode = if (Test-Path $cliNodeLog) { Get-Content $cliNodeLog -Raw } else { "" }
$renewCli = $cliNode -match "DHCP_RENEW"
$renewSrv = $srv -match "renew=true"
$t1 = $cliNode -match "DHCP_BOUND .*t1=4s"
if ($bound -and $lookup -and $ping -and $lease -and $regs -and $renewCli -and $renewSrv) { $verdict = "PASS" }

"RESULT svc done=$done verdict=$verdict"
"BOUND    $bound"
"LOOKUP   $lookup"
"PING     $ping"
"LEASE    $lease"
"DNS_REGS $regs"
"RENEW    client=$renewCli server=$renewSrv t1=$t1"
"===== NODE 22 (dhcp client, app=svc-selftest) ====="
if ($svc) { Get-Content $clientLog }
"===== NODE 21 (dhcp+dns server, router) ====="
if ($srv) { Get-Content $srvP | Where-Object { $_ -match "DHCP_|DNS_|HOSTS_|NO_ROUTE" } }
"===== NODE 23 (host23) ====="
if ($h23) { Get-Content $h23P | Where-Object { $_ -match "DNS_REGISTER|ICMP_ECHO|DNS_" } }
