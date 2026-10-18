# WPA2-inspired security demo: 4-way handshake + AEAD data frames + replay test.
#
#   71 = authenticator (AP)   spawns 72, does M1/M3, opens data frames
#   72 = supplicant (STA)     does M2/M4, sends sealed frames + one replay
#
# Scenarios:
#   normal   both sides share the passphrase -> expect ESTABLISHED, 3 data
#            frames accepted, replay rejected
#   wrongpsk the station uses a wrong passphrase -> expect MIC failure at M2
param(
    [string]$Scenario = "normal",
    [int]$TimeoutSec = 120,
    [string]$Root = $env:RPV_ROOT
)

$root = $Root
if (-not $root) { $root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path) }
$data = Join-Path $root "craftos-wpa"
$exe = "C:\Program Files\CraftOS-PC\CraftOS-PC_console.exe"
$sec = Join-Path $root "poc\security"

if (Test-Path $data) { Remove-Item -Recurse -Force $data }
New-Item -ItemType Directory -Force -Path $data | Out-Null

$psk = "correct horse battery staple"
$ap = @"
role=ap
peer=22
net=rpv-lab
psk=$psk
iters=256
start_delay=1
spawn=22
"@
$sta = @"
role=sta
peer=21
net=rpv-lab
psk=$psk
iters=256
messages=3
replay=1
"@
if ($Scenario -eq "wrongpsk") { $sta = $sta -replace "replay=1", "replay=0`nwrong_psk=1" }

foreach ($id in @(21, 22)) {
    $dir = Join-Path $data "computer\$id"
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    Copy-Item (Join-Path $sec "crypto.lua") $dir -Force
    New-Item -ItemType Directory -Force -Path (Join-Path $dir "rpv") | Out-Null
    Copy-Item (Join-Path $root "poc\rpv\crypto.lua") (Join-Path $dir "rpv\crypto.lua") -Force   # library-module crypto (crypto.lua is a shim)
    Copy-Item (Join-Path $sec "wpa.lua") $dir -Force
    Copy-Item (Join-Path $sec "wpa-node.lua") (Join-Path $dir "startup.lua") -Force
}
Set-Content -Path (Join-Path $data "computer\21\wpa.txt") -Value $ap -Encoding ascii
Set-Content -Path (Join-Path $data "computer\22\wpa.txt") -Value $sta -Encoding ascii

$stdout = Join-Path $root "poc\out\wpa-$Scenario.stdout.txt"
$stderr = Join-Path $root "poc\out\wpa-$Scenario.stderr.txt"
$proc = Start-Process -FilePath $exe -ArgumentList @("-d", "`"$data`"", "--headless", "--id", "21") `
    -RedirectStandardOutput $stdout -RedirectStandardError $stderr -PassThru -NoNewWindow

$staLog = Join-Path $data "computer\22\wpa-log.txt"
$apLog = Join-Path $data "computer\21\wpa-log.txt"
$deadline = (Get-Date).AddSeconds($TimeoutSec)
$done = $false
while ((Get-Date) -lt $deadline) {
    Start-Sleep -Milliseconds 400
    if ($proc.HasExited) { break }
    if (Test-Path $staLog) { if ((Get-Content $staLog -Raw) -match "TEST_DONE") { $done = $true; break } }
}
Start-Sleep -Milliseconds 1200
if (-not $done -and (Test-Path $staLog)) { if ((Get-Content $staLog -Raw) -match "TEST_DONE") { $done = $true } }
if (-not $proc.HasExited) { $proc.Kill() }
Start-Sleep -Milliseconds 300

foreach ($pair in @(@(71, "ap"), @(72, "sta"))) {
    $src = Join-Path $data "computer\$($pair[0])\wpa-log.txt"
    if (Test-Path $src) { Copy-Item $src (Join-Path $root "poc\out\wpa-$Scenario-node$($pair[0]).log") -Force }
}

$staText = if (Test-Path $staLog) { Get-Content $staLog -Raw } else { "" }
$apText = if (Test-Path $apLog) { Get-Content $apLog -Raw } else { "" }
$verdict = "UNKNOWN"
if ($Scenario -eq "normal") {
    $ok = ($staText -match "WPA_ESTABLISHED") -and ($apText -match "WPA_ESTABLISHED") -and
          ($apText -match "WPA_REPLAY_REJECTED") -and ($staText -match "TEST_DONE ok=true")
    $verdict = if ($ok) { "PASS" } else { "FAIL" }
} elseif ($Scenario -eq "wrongpsk") {
    $ok = ($apText -match "WPA_HANDSHAKE_FAIL stage=M2") -and ($staText -match "TEST_DONE ok=false")
    $verdict = if ($ok) { "PASS" } else { "FAIL" }
}

"RESULT scenario=$Scenario done=$done verdict=$verdict"
"===== NODE 71 (authenticator) ====="
if ($apText) { Get-Content $apLog }
"===== NODE 72 (supplicant) ====="
if ($staText) { Get-Content $staLog }
"===== STDERR ====="
if (Test-Path $stderr) { Get-Content $stderr -Raw }
