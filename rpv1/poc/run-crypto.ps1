# Pure-Lua crypto: known-answer tests + benchmarks (isolated computer 20).
param([int]$TimeoutSec = 180, [string]$Root = $env:RPV_ROOT)

$root = $Root
if (-not $root) { $root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path) }
$data = Join-Path $root "craftos-crypto"
$exe = "C:\Program Files\CraftOS-PC\CraftOS-PC_console.exe"
$lib = Join-Path $root "poc\security\crypto.lua"
$test = Join-Path $root "poc\security\test-crypto.lua"

if (Test-Path $data) { Remove-Item -Recurse -Force $data }
$dir = Join-Path $data "computer\20"
New-Item -ItemType Directory -Force -Path $dir | Out-Null
Copy-Item $lib (Join-Path $dir "crypto.lua") -Force
    New-Item -ItemType Directory -Force -Path (Join-Path $dir "rpv") | Out-Null
    Copy-Item (Join-Path $root "poc\rpv\crypto.lua") (Join-Path $dir "rpv\crypto.lua") -Force   # library-module crypto (crypto.lua is a shim)

$stdout = Join-Path $root "poc\out\crypto.stdout.txt"
$stderr = Join-Path $root "poc\out\crypto.stderr.txt"
$proc = Start-Process -FilePath $exe -ArgumentList @("-d", "`"$data`"", "--headless", "--id", "20", "--script", "`"$test`"") `
    -RedirectStandardOutput $stdout -RedirectStandardError $stderr -PassThru -NoNewWindow

$report = Join-Path $dir "crypto-report.txt"
$deadline = (Get-Date).AddSeconds($TimeoutSec)
$done = $false
while ((Get-Date) -lt $deadline) {
    Start-Sleep -Milliseconds 500
    if ($proc.HasExited) { break }
    if (Test-Path $report) { if ((Get-Content $report -Raw) -match "DONE") { $done = $true; break } }
}
Start-Sleep -Milliseconds 500
if (-not $proc.HasExited) { $proc.Kill() }
Start-Sleep -Milliseconds 300
if (-not $done -and (Test-Path $report)) {
    if ((Get-Content $report -Raw) -match "DONE") { $done = $true }
}

"RESULT done=$done"
if (Test-Path $report) {
    Copy-Item $report (Join-Path $root "poc\out\crypto-report.txt") -Force
    Get-Content $report
} else { "(no report)" }
"===== STDERR ====="
if (Test-Path $stderr) { Get-Content $stderr -Raw }
