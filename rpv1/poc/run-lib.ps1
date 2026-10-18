# Library acceptance test (RPV1 as a library) in all three distribution forms:
#
#   -Mode tree     folder layout  : /rpv.lua + /rpv/*.lua        (require("rpv"))
#   -Mode bundle   single file    : /rpv-bundle.lua              (dofile)
#   -Mode install  installer      : /install.lua + /src tree     (copy + verify)
#
# Two plain computers, each running an example program installed AS startup.lua.
# No role.txt, no node2 bootstrap, nothing from poc/apps -- only the public API.
#
#   pwsh -File poc\run-lib.ps1 [-Mode tree|bundle|install]
param(
    [ValidateSet("tree", "bundle", "install")]
    [string]$Mode = "tree",
    [int]$TimeoutSec = 90,
    [string]$Root = $env:RPV_ROOT
)

$root = $Root
if (-not $root) { $root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path) }
$data = Join-Path $root "craftos-lib-$Mode"
$exe = "C:\Program Files\CraftOS-PC\CraftOS-PC_console.exe"
$rpvdir = Join-Path $root "poc\rpv"
$rpventry = Join-Path $root "poc\rpv.lua"
$examples = Join-Path $root "poc\examples"
$dist = Join-Path $root "dist"
$out = Join-Path $root "poc\out"
New-Item -ItemType Directory -Force -Path $out | Out-Null

if (Test-Path $data) { Remove-Item -Recurse -Force $data }

function Stage-Example {
    param([int]$Id, [string]$Program, [switch]$SpawnPeer)
    $dir = Join-Path $data "computer\$Id"
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $src = Join-Path $examples $Program
    if ($SpawnPeer) {
        # emulator-only trick to boot a second computer in the same process
        $text = Get-Content $src -Raw
        $text = $text.Replace('local SPAWN_IDS  = ""', 'local SPAWN_IDS  = "21"')
        Set-Content -Path (Join-Path $dir "startup.lua") -Value $text -Encoding ascii -NoNewline
    } else {
        Copy-Item $src (Join-Path $dir "startup.lua") -Force
    }
    return $dir
}

switch ($Mode) {
    "tree" {
        foreach ($spec in @(@{ id = 20; prog = "rpv-libtest.lua"; spawn = $true }, @{ id = 21; prog = "rpv-echo.lua"; spawn = $false })) {
            $dir = Stage-Example -Id $spec.id -Program $spec.prog -SpawnPeer:$spec.spawn
            New-Item -ItemType Directory -Force -Path (Join-Path $dir "rpv") | Out-Null
            Copy-Item (Join-Path $rpvdir "*.lua") (Join-Path $dir "rpv") -Force
            Copy-Item $rpventry (Join-Path $dir "rpv.lua") -Force
        }
    }
    "bundle" {
        if (-not (Test-Path (Join-Path $dist "rpv-bundle.lua"))) { throw "run poc\build-dist.ps1 first (no dist\rpv-bundle.lua)" }
        foreach ($spec in @(@{ id = 20; prog = "rpv-libtest.lua"; spawn = $true }, @{ id = 21; prog = "rpv-echo.lua"; spawn = $false })) {
            $dir = Stage-Example -Id $spec.id -Program $spec.prog -SpawnPeer:$spec.spawn
            Copy-Item (Join-Path $dist "rpv-bundle.lua") (Join-Path $dir "rpv-bundle.lua") -Force
        }
    }
    "install" {
        if (-not (Test-Path (Join-Path $dist "MANIFEST.txt"))) { throw "run poc\build-dist.ps1 first (no dist\MANIFEST.txt)" }
        $dir = Join-Path $data "computer\20"
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
        # the release tree lands in /src, the installer runs from / and copies + verifies it
        Copy-Item $dist (Join-Path $dir "src") -Recurse -Force
        Copy-Item (Join-Path $dist "install.lua") (Join-Path $dir "install.lua") -Force
        $wrapper = @'
-- headless install acceptance: install the release from /src into /, then verify
shell.run("/install.lua", "/src", "--target", "/", "--log", "/install-log.txt")
'@
        Set-Content -Path (Join-Path $dir "startup.lua") -Value $wrapper -Encoding ascii
    }
}

$stdout = Join-Path $out "lib-$Mode.stdout.txt"
$stderr = Join-Path $out "lib-$Mode.stderr.txt"
$proc = Start-Process -FilePath $exe -ArgumentList @("-d", "`"$data`"", "--headless", "--id", "20") `
    -RedirectStandardOutput $stdout -RedirectStandardError $stderr -PassThru -NoNewWindow

$log20 = Join-Path $data "computer\20\lib-log.txt"
$installLog = Join-Path $data "computer\20\install-log.txt"
$deadline = (Get-Date).AddSeconds($TimeoutSec)
$done = $false
while ((Get-Date) -lt $deadline) {
    Start-Sleep -Milliseconds 400
    if ($proc.HasExited) { break }
    if (Test-Path $log20) { if ((Get-Content $log20 -Raw) -match "TEST_DONE") { $done = $true; break } }
    if (Test-Path $installLog) { if ((Get-Content $installLog -Raw) -match "INSTALL_VERIFY") { $done = $true; break } }
}
Start-Sleep -Milliseconds 1200
if (-not $proc.HasExited) { $proc.Kill() }
Start-Sleep -Milliseconds 300

foreach ($id in @(20, 21)) {
    foreach ($f in @("lib-log.txt", "echo-log.txt", "install-log.txt")) {
        $src = Join-Path $data "computer\$id\$f"
        if (Test-Path $src) { Copy-Item $src (Join-Path $out "lib-$Mode-node$id-$f") -Force }
    }
}

$lib = if (Test-Path $log20) { Get-Content $log20 -Raw } else { "" }
$inst = if (Test-Path $installLog) { Get-Content $installLog -Raw } else { "" }
$echoPath = Join-Path $data "computer\21\echo-log.txt"
$echoText = if (Test-Path $echoPath) { Get-Content $echoPath -Raw } else { "" }

$verdict = "FAIL"
if ($Mode -eq "install") {
    $installed = @("rpv.lua", "rpv\node.lua", "rpv-bundle.lua", "install.lua", "API.md", "examples\rpv-libtest.lua")
    $missing = @()
    foreach ($f in $installed) {
        if (-not (Test-Path (Join-Path (Join-Path $data "computer\20") $f))) { $missing += $f }
    }
    if ($inst -match "INSTALL_OK files=\d+ verified=\d+" -and
        $inst -match "INSTALL_VERIFY ok=true version=RPV1 modules=\d+" -and
        $missing.Count -eq 0) { $verdict = "PASS" }
    "INSTALLED_MISSING " + ($missing -join ",")
} else {
    if ($lib -match "LIBTEST_RESULT checks=\d+ failed=0 pass=true" -and
        $lib -match "LIBTEST_PING ok=true" -and
        $lib -match "LIBTEST_UDP ok=true" -and
        $lib -match "LIBTEST_FRAG_REASM ok=true" -and
        $echoText -match "ECHO_READY") { $verdict = "PASS" }
}

"RESULT lib mode=$Mode done=$done verdict=$verdict"
"===== NODE 20 ($Mode) ====="
if ($Mode -eq "install") { if ($inst) { Get-Content $installLog } } elseif ($lib) { Get-Content $log20 }
"===== NODE 21 (peer) ====="
if (Test-Path $echoPath) { Get-Content $echoPath }
