# IPv4 reserved-segment acceptance (CraftOS-PC).
#
#   21 = router 10.0.1.1/24 on LAN-A          (IFACE_CLASS class=private)
#   22 = host   10.0.1.2/24  app=addr-selftest:10.0.1.3   (the behaviour under test)
#   23 = host   10.0.1.3/24  app=addr-peer               (directed-broadcast responder)
#   24 = host   8.8.8.2/24   (deliberately public)       (CFG_WARN ADDR_NOT_PRIVATE)
#
#   pwsh -File poc\run-addr.ps1
param([int]$TimeoutSec = 150, [string]$Root = $env:RPV_ROOT)

$root = $Root
if (-not $root) { $root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path) }
$data = Join-Path $root "craftos-addr"
$exe = "C:\Program Files\CraftOS-PC\CraftOS-PC_console.exe"
$bootstrap = Join-Path $root "poc\node2\startup.lua"
$rpvdir = Join-Path $root "poc\rpv"
$appsdir = Join-Path $root "poc\apps"
$compatdir = Join-Path $root "poc\compat"
$out = Join-Path $root "poc\out"
New-Item -ItemType Directory -Force -Path $out | Out-Null
if (Test-Path $data) { Remove-Item -Recurse -Force $data }

$roles = @{}
$roles[21] = "role=router`niface=back|LAN-A|10.0.1.1/24|4300|512|wireless`nspawn=22,23,24`nstats_at=45`n"
$roles[22] = "role=host`niface=back|LAN-A|10.0.1.2/24|4300|512|wireless`ngw=10.0.1.1`n" +
    "app=addr-selftest:10.0.1.3`nbroadcast=10.0.1.255`nstart_delay=8`nstats_at=45`n"
$roles[23] = "role=host`niface=back|LAN-A|10.0.1.3/24|4300|512|wireless`ngw=10.0.1.1`n" +
    "app=addr-peer`nstart_delay=2`nstats_at=45`n"
$roles[24] = "role=host`niface=back|PUBLIC|8.8.8.2/24|4300|512|wireless`nstats_at=45`n"

foreach ($id in @(21, 22, 23, 24)) {
    $dir = Join-Path $data "computer\$id"
    foreach ($sub in @("rpv", "apps", "compat")) { New-Item -ItemType Directory -Force -Path (Join-Path $dir $sub) | Out-Null }
    Copy-Item (Join-Path $rpvdir "*.lua") (Join-Path $dir "rpv") -Force
    Copy-Item (Join-Path $appsdir "*.lua") (Join-Path $dir "apps") -Force
    Copy-Item (Join-Path $compatdir "*.lua") (Join-Path $dir "compat") -Force
    Copy-Item $bootstrap (Join-Path $dir "startup.lua") -Force
    Set-Content -Path (Join-Path $dir "role.txt") -Value $roles[$id] -Encoding ascii
}

$stdout = Join-Path $out "addr.stdout.txt"
$stderr = Join-Path $out "addr.stderr.txt"
$proc = Start-Process -FilePath $exe -ArgumentList @("-d", "`"$data`"", "--headless", "--id", "21") `
    -RedirectStandardOutput $stdout -RedirectStandardError $stderr -PassThru -NoNewWindow

$watch = Join-Path $data "computer\22\addr-log.txt"
$deadline = (Get-Date).AddSeconds($TimeoutSec)
$done = $false
while ((Get-Date) -lt $deadline) {
    Start-Sleep -Milliseconds 500
    if ($proc.HasExited) { break }
    if (Test-Path $watch) { if ((Get-Content $watch -Raw) -match "TEST_DONE") { $done = $true; break } }
}
Start-Sleep -Seconds 3
if (-not $proc.HasExited) { $proc.Kill() }
Start-Sleep -Milliseconds 500

$logs = @{}
foreach ($id in @(21, 22, 23, 24)) {
    $p = Join-Path $data "computer\$id\rpv-log.txt"
    $logs[$id] = if (Test-Path $p) { Get-Content $p -Raw; Copy-Item $p (Join-Path $out "addr-node$id.log") -Force } else { "" }
}
$appLog = if (Test-Path $watch) { Get-Content $watch -Raw; Copy-Item $watch (Join-Path $out "addr-app22.log") -Force } else { "" }

$resultLine = ($appLog -split "`n" | Where-Object { $_ -match "ADDR_RESULT" } | Select-Object -Last 1)
$appPass = $resultLine -match "pass=true"
# explicit regex objects: $Matches is clobbered by nested -match operators
$mTx = [regex]::Match($appLog, 'ADDR_LOOPBACK reply=(\w+) tx_before=(\d+) tx_after=(\d+)')
$loopback = $mTx.Success -and $mTx.Groups[1].Value -eq 'true'
$noTx = $mTx.Success -and $mTx.Groups[2].Value -eq $mTx.Groups[3].Value
$loUdp = [regex]::IsMatch($appLog, 'ADDR_LOOPBACK_UDP got=loopback-udp no_tx=true')
$mRes = [regex]::Match($appLog, 'ADDR_RESERVED drops_before=(\d+) drops_after=(\d+)')
$reserved = $mRes.Success -and ([int]$mRes.Groups[2].Value -gt [int]$mRes.Groups[1].Value)
$transmittable = [regex]::IsMatch($appLog, 'ADDR_TRANSMITTABLE extra_drops=0')
$bcast = [regex]::IsMatch($appLog, 'ADDR_DIRECTED_BCAST replies=[1-9]\d*')
$peerPong = [regex]::IsMatch($appLog, 'ADDR_PEER_PING pongs=[2-9]\d*')
$routerClass = $logs[21] -match "IFACE_CLASS side=back name=LAN-A addr=10\.0\.1\.1/24 class=private private=true"
$hostClass = $logs[22] -match "IFACE_CLASS .* class=private private=true"
$publicWarn = $logs[24] -match "CFG_WARN ADDR_NOT_PRIVATE"
$publicClass = $logs[24] -match "IFACE_CLASS .* class=public private=false"
$addrSummary = $logs[24] -match "ADDR_WARN_SUMMARY warnings=([1-9]\d*)"

$verdict = "FAIL"
if ($done -and $appPass -and $loopback -and $noTx -and $loUdp -and $reserved -and $bcast -and $peerPong `
        -and $routerClass -and $hostClass -and $publicWarn -and $publicClass) { $verdict = "PASS" }

"RESULT addr done=$done verdict=$verdict"
"$($resultLine -replace '^.*ADDR_RESULT', 'ADDR_RESULT')"
"CHECKS app_pass=$appPass loopback=$loopback no_modem_tx=$noTx loopback_udp=$loUdp reserved_drop=$reserved transmittable=$transmittable directed_bcast=$bcast peer_ping=$peerPong"
"CLASS  router_private=$routerClass host_private=$hostClass public_warn=$publicWarn public_class=$publicClass addr_summary_nonzero=$addrSummary"
($appLog -split "`n" | Where-Object { $_ -match "ADDR_(LOOPBACK|RESERVED|DIRECTED|PEER|RESULT)" }) | Select-Object -First 8 | ForEach-Object { "APP " + $_.Trim() }
($logs[21] -split "`n" | Where-Object { $_ -match "IFACE_CLASS|WAN_READY" }) | Select-Object -First 3 | ForEach-Object { "R21 " + $_.Trim() }
($logs[24] -split "`n" | Where-Object { $_ -match "IFACE_CLASS|CFG_WARN|ADDR_WARN" }) | Select-Object -First 4 | ForEach-Object { "H24 " + $_.Trim() }
