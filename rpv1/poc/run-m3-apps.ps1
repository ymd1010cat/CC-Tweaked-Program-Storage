# M3 (2/3 telemetry, 3/3 file transfer) acceptance.
#
#   21 = router
#   mon: 21 collector (app=monitor-host:4200), 22/23 agents (app=monitor-agent)
#   ftp: 21 router, 22 server (app=ftp-server:4300), 23 client (app=ftp-client),
#        payload.txt pre-created in the server's folder; the harness also
#        compares the received file byte-for-byte on the host side.
param(
    [string]$Scenario = "mon",
    [int]$FtpWindow = 4,
    [string]$FtpTransport = "udp",
    [int]$DropEvery = 0,
    # secure connection mode (P1 control-plane AEAD): off | psk | wrongpsk
    #   psk      -> both sides share the key, the transfer must stay byte-exact
    #   wrongpsk -> client uses another key: the handshake must fail closed
    [ValidateSet("off", "psk", "wrongpsk")]
    [string]$ConnSecure = "off",
    [string]$ConnPsk = "00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff",
    [int]$TimeoutSec = 180,
    [string]$Root = $env:RPV_ROOT
)

$root = $Root
if (-not $root) { $root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path) }
$data = Join-Path $root "craftos-m3-$Scenario"
$exe = "C:\Program Files\CraftOS-PC\CraftOS-PC_console.exe"
$bootstrap = Join-Path $root "poc\node2\startup.lua"
$rpvdir = Join-Path $root "poc\rpv"
$appsdir = Join-Path $root "poc\apps"
$compatdir = Join-Path $root "poc\compat"
$crypto = Join-Path $root "poc\security\crypto.lua"

if (Test-Path $data) { Remove-Item -Recurse -Force $data }
New-Item -ItemType Directory -Force -Path $data | Out-Null

$lanA = "iface=back|LAN-A|10.0.1.1/24|4001|256|wired"
$lanB = "iface=left|LAN-B|10.0.2.1/24|4002|256|wired"
$roles = @{}
if ($Scenario -eq "mon") {
    $roles[21] = "role=router`n$lanA`n$lanB`napp=monitor-host:4200`nspawn=22,23`nstats_at=20`n"
    $roles[22] = "role=host`niface=back|LAN-A|10.0.1.2/24|4001|256|wired`ngw=10.0.1.1`napp=monitor-agent:10.0.1.1:4200`nmon_interval=3`n"
    $roles[23] = "role=host`niface=back|LAN-B|10.0.2.2/24|4002|256|wired`ngw=10.0.2.1`napp=monitor-agent:10.0.1.1:4200`nmon_interval=3`n"
    $watchId = 21
} else {
    $roles[21] = "role=router`n$lanA`n$lanB`nspawn=22,23`nstats_at=25`n"
    $secSrv = ""
    $secCli = ""
    if ($ConnSecure -eq "psk") {
        $secSrv = "conn_secure=1`nconn_psk=$ConnPsk`n"
        $secCli = "conn_secure=1`nconn_psk=$ConnPsk`n"
    } elseif ($ConnSecure -eq "wrongpsk") {
        $secSrv = "conn_secure=1`nconn_psk=$ConnPsk`n"
        $secCli = "conn_secure=1`nconn_psk=ffeeddccbbaa99887766554433221100ffeeddccbbaa99887766554433221100`n"
    }
    $roles[22] = "role=host`niface=back|LAN-A|10.0.1.2/24|4001|256|wired`ngw=10.0.1.1`napp=ftp-server:4300`nftp_block=256`nftp_window=$FtpWindow`nftp_retx=0.4`nftp_transport=$FtpTransport`ndrop_every=$DropEvery`n${secSrv}"
    $roles[23] = "role=host`niface=back|LAN-B|10.0.2.2/24|4002|256|wired`ngw=10.0.2.1`napp=ftp-client:10.0.1.2:4300:payload.txt`nftp_transport=$FtpTransport`n${secCli}"
    $watchId = 23
}

foreach ($id in @(21, 22, 23)) {
    $dir = Join-Path $data "computer\$id"
    foreach ($sub in @("rpv", "apps", "compat")) { New-Item -ItemType Directory -Force -Path (Join-Path $dir $sub) | Out-Null }
    Copy-Item (Join-Path $rpvdir "*.lua") (Join-Path $dir "rpv") -Force
    Copy-Item (Join-Path $appsdir "*.lua") (Join-Path $dir "apps") -Force
    Copy-Item (Join-Path $compatdir "*.lua") (Join-Path $dir "compat") -Force
    Copy-Item $crypto (Join-Path $dir "crypto.lua") -Force
    New-Item -ItemType Directory -Force -Path (Join-Path $dir "rpv") | Out-Null
    Copy-Item (Join-Path $root "poc\rpv\crypto.lua") (Join-Path $dir "rpv\crypto.lua") -Force   # library-module crypto (crypto.lua is a shim)
    Copy-Item $bootstrap (Join-Path $dir "startup.lua") -Force
    Set-Content -Path (Join-Path $dir "role.txt") -Value $roles[$id] -Encoding ascii
}
if ($Scenario -eq "ftp") {
    $lines = 1..200 | ForEach-Object { "rpv-payload-line-{0:D3}" -f $_ }
    Set-Content -Path (Join-Path $data "computer\22\payload.txt") -Value $lines -Encoding ascii
}

New-Item -ItemType Directory -Force -Path (Join-Path $root "poc\out") | Out-Null
$stdout = Join-Path $root "poc\out\m3-$Scenario.stdout.txt"
$stderr = Join-Path $root "poc\out\m3-$Scenario.stderr.txt"
$proc = Start-Process -FilePath $exe -ArgumentList @("-d", "`"$data`"", "--headless", "--id", "21") `
    -RedirectStandardOutput $stdout -RedirectStandardError $stderr -PassThru -NoNewWindow

$watchLog = Join-Path $data "computer\$watchId\rpv-log.txt"
$deadline = (Get-Date).AddSeconds($TimeoutSec)
$done = $false
while ((Get-Date) -lt $deadline) {
    Start-Sleep -Milliseconds 400
    if ($proc.HasExited) { break }
    if (Test-Path $watchLog) { if ((Get-Content $watchLog -Raw) -match "TEST_DONE") { $done = $true; break } }
}
Start-Sleep -Milliseconds 2000
if (-not $done -and (Test-Path $watchLog)) { if ((Get-Content $watchLog -Raw) -match "TEST_DONE") { $done = $true } }
if (-not $proc.HasExited) { $proc.Kill() }
Start-Sleep -Milliseconds 300

foreach ($id in @(21, 22, 23)) {
    $src = Join-Path $data "computer\$id\rpv-log.txt"
    if (Test-Path $src) { Copy-Item $src (Join-Path $root "poc\out\m3-$Scenario-node$id.log") -Force }
}

$texts = @{}
foreach ($id in @(21, 22, 23)) {
    $p = Join-Path $data "computer\$id\rpv-log.txt"
    $texts[$id] = if (Test-Path $p) { Get-Content $p -Raw } else { "" }
}

$verdict = "FAIL"
if ($Scenario -eq "mon") {
    if ($texts[21] -match "MON_RESULT nodes=(\d+) ok=true" -and $texts[21] -match "MON_RECV node=22" -and $texts[21] -match "MON_RECV node=23") {
        $verdict = "PASS"
    }
} else {
    $srcFile = Join-Path $data "computer\22\payload.txt"
    $dstFile = Join-Path $data "computer\23\received-payload.txt"
    $sameBytes = $false
    if ((Test-Path $srcFile) -and (Test-Path $dstFile)) {
        $a = [System.IO.File]::ReadAllBytes($srcFile)
        $b = [System.IO.File]::ReadAllBytes($dstFile)
        if ($a.Length -eq $b.Length) {
            $diff = 0
            for ($i = 0; $i -lt $a.Length; $i++) { if ($a[$i] -ne $b[$i]) { $diff++; break } }
            $sameBytes = ($diff -eq 0)
        }
    }
    if ($texts[23] -match "FTPC_VERIFY size_ok=true sha_ok=true" -and
        $texts[23] -match "FTPC_RESULT .* ok=true" -and
        $texts[22] -match "FTP_SENT_ALL" -and $sameBytes) {
        $verdict = "PASS"
    }
    "HOST_COMPARE source_bytes=$((Get-Item $srcFile -ErrorAction SilentlyContinue).Length) received_bytes=$((Get-Item $dstFile -ErrorAction SilentlyContinue).Length) identical=$sameBytes"

    if ($ConnSecure -ne "off") {
        # secure-mode evidence: keys derived on both sides and nothing leaked
        foreach ($id in @(22, 23)) {
            ($texts[$id] -split "`n" | Where-Object { $_ -match "CONN_SEC_KEYS" } | Select-Object -First 1) |
                ForEach-Object { "SEC_KEYS node=$id " + $_.Trim() }
            ($texts[$id] -split "`n" | Where-Object { $_ -match "CONN_STATS" } | Select-Object -Last 1) |
                ForEach-Object { "SEC_STATS node=$id " + $_.Trim() }
        }
        ($texts[23] -split "`n" | Where-Object { $_ -match "CONN_SEC_AUTH_FAIL|CONN_SEC_PEER_PLAINTEXT|CONN_SEC_SYN_REJECT" }) |
            Select-Object -First 3 | ForEach-Object { "SEC_REJECT " + $_.Trim() }
        ($texts[22] -split "`n" | Where-Object { $_ -match "CONN_SEC_SYN_REJECT|CONN_SEC_AUTH_FAIL" }) |
            Select-Object -First 3 | ForEach-Object { "SEC_REJECT_SRV " + $_.Trim() }
    }
    if ($ConnSecure -eq "wrongpsk") {
        # fail-closed expectation: no transfer, no received file, and the server
        # rejected the unauthenticated SYN (or the client never established)
        $rejected = ($texts[22] -match "CONN_SEC_SYN_REJECT") -or ($texts[23] -match "CONN_SEC_AUTH_FAIL") -or
                    ($texts[23] -match "CONN_SEC_PEER_PLAINTEXT") -or ($texts[23] -match "CONN_HANDSHAKE_RETX")
        $verdict = if ((-not $sameBytes) -and (-not ($texts[23] -match "FTPC_RESULT .* ok=true")) -and $rejected) { "PASS" } else { "FAIL" }
        "SEC_WRONGPSK rejected=$rejected transferred=$sameBytes"
    }
}

"RESULT m3-$Scenario done=$done verdict=$verdict"
foreach ($id in @(21, 22, 23)) {
    "===== NODE $id ====="
    if ($texts[$id]) {
        if ($Scenario -eq "mon") { Get-Content (Join-Path $data "computer\$id\rpv-log.txt") | Where-Object { $_ -match "MON_|MONITOR_HOST|TASK_|SPAWN|STATS" } }
        else { Get-Content (Join-Path $data "computer\$id\rpv-log.txt") | Where-Object { $_ -match "FTP|TASK_|SPAWN|STATS|UDP_" } }
    } else { "(no log)" }
}
"===== STDERR ====="
if (Test-Path $stderr) { Get-Content $stderr -Raw }
