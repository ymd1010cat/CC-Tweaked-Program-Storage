# pyroet-os/tests/run-tests.ps1 -- P2 acceptance: run the offline suite.
#
#   pwsh -NoProfile -File pyroet-os\tests\run-tests.ps1
#   pwsh -NoProfile -File pyroet-os\tests\run-tests.ps1 -Keep      # keep staging
#
# Stages a throw-away CraftOS-PC data directory at pyroet-os/.tests:
#
#     .tests/computer/20/startup.lua             generated shim -> /tests/run.lua
#     .tests/computer/20/system/startup.lua      pyroet-os/system/startup.lua
#     .tests/computer/20/system/boot.lua         pyroet-os/system/boot.lua
#     .tests/computer/20/system/kernel/*.lua     kernel, apps, permissions, installer, ota
#     .tests/computer/20/system/rpv/*.lua        the vendored rpv subset (SHA-256)
#     .tests/computer/20/system/net/*.lua        network service + static hosts
#     .tests/computer/20/system/system/*.app     launcher, settings, net (system apps)
#     .tests/computer/20/recovery/*.lua          pyroet-os/recovery/*.lua (dev tools)
#     .tests/computer/20/ota/*.lua               pyroet-os/ota/*.lua (distribution side, not image)
#     .tests/computer/20/install.set             pyroet-os/install.set (budget assertions)
#     .tests/computer/20/tests/*.lua             this directory's runner + suites
#     .tests/computer/20/tests/root-startup.lua  the ROM stub pyroet-os/startup.lua
#
# Since P6-3 the whole image sits under /system, with the system apps one level
# deeper in /system/system, so every dofile() in a test uses the path a real
# machine uses. /apps and /etc stay at the root because they are user data, not
# image content.
#
# then boots it headless with the CraftOS-PC console build, de-duplicates the
# OFFLINE_* markers out of stdout, prints them and exits 0 only when an
# OFFLINE_PASS line was seen, an OFFLINE_GROUPS line was seen and no OFFLINE_FAIL
# line reported a non-zero count.
#
# Everything the script writes lives under pyroet-os/.tests and is removed again
# unless -Keep is passed, so a run leaves the work tree clean.
param(
    [int]$TimeoutSec = 180,
    [string]$Exe = "C:\Program Files\CraftOS-PC\CraftOS-PC_console.exe",
    [switch]$Keep
)

$ErrorActionPreference = "Stop"

$here = Split-Path -Parent $MyInvocation.MyCommand.Path      # pyroet-os/tests
$osRoot = Split-Path -Parent $here                          # pyroet-os
$stage = Join-Path $osRoot ".tests"
$comp = Join-Path $stage "computer\20"
$stdout = Join-Path $stage "stdout.txt"
$stderr = Join-Path $stage "stderr.txt"

if (-not (Test-Path $Exe)) {
    Write-Output "OFFLINE_ERROR missing emulator: $Exe"
    exit 2
}
foreach ($required in @("startup.lua", "system\startup.lua", "system\boot.lua",
        "system\kernel\init.lua", "system\kernel\apps.lua", "system\kernel\permissions.lua",
        "system\kernel\installer.lua", "system\kernel\ota.lua",
        "system\rpv\crypto.lua", "system\rpv\loader.lua",
        "system\net\hosts.lua", "system\net\service.lua",
        "system\system\net.app\manifest.lua", "system\system\net.app\main.lua",
        "system\system\launcher.app\manifest.lua", "system\system\launcher.app\main.lua",
        "system\system\settings.app\manifest.lua", "system\system\settings.app\main.lua",
        "recovery\proto.lua", "recovery\flash.lua", "recovery\bootstrap.lua",
        "ota\server.lua", "install.set")) {
    if (-not (Test-Path (Join-Path $osRoot $required))) {
        Write-Output "OFFLINE_ERROR missing source: pyroet-os/$required"
        exit 2
    }
}

function Cleanup {
    if ($Keep) {
        Write-Output "OFFLINE_STAGE kept at $stage"
        return
    }
    if (Test-Path $stage) { Remove-Item -Recurse -Force $stage -ErrorAction SilentlyContinue }
}

try {
    if (Test-Path $stage) { Remove-Item -Recurse -Force $stage }
    New-Item -ItemType Directory -Force -Path (Join-Path $comp "system") | Out-Null
    New-Item -ItemType Directory -Force -Path (Join-Path $comp "system\kernel") | Out-Null
    New-Item -ItemType Directory -Force -Path (Join-Path $comp "system\rpv")    | Out-Null
    New-Item -ItemType Directory -Force -Path (Join-Path $comp "system\net")    | Out-Null
    New-Item -ItemType Directory -Force -Path (Join-Path $comp "system\system") | Out-Null
    New-Item -ItemType Directory -Force -Path (Join-Path $comp "recovery") | Out-Null
    New-Item -ItemType Directory -Force -Path (Join-Path $comp "ota") | Out-Null
    New-Item -ItemType Directory -Force -Path (Join-Path $comp "system\system\net.app") | Out-Null
    New-Item -ItemType Directory -Force -Path (Join-Path $comp "system\system\launcher.app") | Out-Null
    New-Item -ItemType Directory -Force -Path (Join-Path $comp "system\system\settings.app") | Out-Null
    New-Item -ItemType Directory -Force -Path (Join-Path $comp "tests")  | Out-Null

    Copy-Item (Join-Path $osRoot "system\boot.lua")            (Join-Path $comp "system\boot.lua")    -Force
    Copy-Item (Join-Path $osRoot "system\startup.lua")         (Join-Path $comp "system\startup.lua") -Force
    Copy-Item (Join-Path $osRoot "system\kernel\*.lua")        (Join-Path $comp "system\kernel")      -Force
    # the real SHA-256 implementation, so the modules' default loader is tested
    Copy-Item (Join-Path $osRoot "system\rpv\*.lua")           (Join-Path $comp "system\rpv")         -Force
    Copy-Item (Join-Path $osRoot "system\net\*.lua")           (Join-Path $comp "system\net")         -Force
    # the system apps are image payload (G1), so they are staged with the other
    # image content; there is no /examples copy to drift against
    Copy-Item (Join-Path $osRoot "system\system\net.app\*") (Join-Path $comp "system\system\net.app") -Force
    Copy-Item (Join-Path $osRoot "recovery\*.lua")             (Join-Path $comp "recovery")           -Force
    # the distribution side (ota/server.lua) is a dev tool like recovery/: it is
    # staged so t_ota_server can drive it, and it is NOT in install.set
    Copy-Item (Join-Path $osRoot "ota\*.lua")                  (Join-Path $comp "ota")                -Force
    Copy-Item (Join-Path $osRoot "install.set")                (Join-Path $comp "install.set")        -Force
    Copy-Item (Join-Path $osRoot "system\system\launcher.app\*") (Join-Path $comp "system\system\launcher.app") -Force
    Copy-Item (Join-Path $osRoot "system\system\settings.app\*") (Join-Path $comp "system\system\settings.app") -Force
    Copy-Item (Join-Path $here "*.lua")                 (Join-Path $comp "tests")               -Force
    # the ROM stub is not staged as /startup.lua (that is the shim); the layout
    # suite loads this copy and drives it with a stubbed loadfile/print
    Copy-Item (Join-Path $osRoot "startup.lua")         (Join-Path $comp "tests\root-startup.lua") -Force

    # CraftOS runs /startup.lua at boot; the shim runs the suite and makes a
    # crash visible as a normal OFFLINE_FAIL instead of a dead console.
    $shim = @(
        "-- generated by pyroet-os/tests/run-tests.ps1",
        "local ok, err = pcall(dofile, `"/tests/run.lua`")",
        "if not ok then",
        "    local text = tostring(err):gsub(`"%s+`", `" `")",
        "    print(`"OFFLINE_FAIL_AT harness.boot `" .. text)",
        "    print(`"OFFLINE_FAIL 1`")",
        "    print(`"OFFLINE_DONE`")",
        "end"
    )
    Set-Content -Path (Join-Path $comp "startup.lua") -Value $shim -Encoding ascii

    $proc = Start-Process -FilePath $Exe -ArgumentList @("-d", "`"$stage`"", "--headless", "--id", "20") `
        -RedirectStandardOutput $stdout -RedirectStandardError $stderr -PassThru -NoNewWindow

    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    $done = $false
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 250
        if ($proc.HasExited) { break }
        if (Test-Path $stdout) {
            $probe = Get-Content $stdout -Raw
            if ($probe -match "OFFLINE_DONE") { $done = $true; break }
        }
    }
    Start-Sleep -Milliseconds 300
    if (-not $proc.HasExited) { $proc.Kill() }
    Start-Sleep -Milliseconds 200

    $text = if (Test-Path $stdout) { (Get-Content $stdout -Raw) -replace "`r", "" } else { "" }

    # Authoritative record: the console redraws partial lines, so the suite also
    # writes one self-contained line per failure to a file inside the staging
    # directory. Read that first; the stdout markers are the fallback.
    $report = Join-Path $comp "offline-report.txt"
    $reportGroups = @()
    $reportFails = @()
    $counts = $null
    if (Test-Path $report) {
        $rawReport = (Get-Content $report -Raw) -replace "`r", ""
        foreach ($line in ($rawReport -split "`n")) {
            if ($line -match "^COUNTS pass=(\d+) fail=(\d+) groups=(\d+)") {
                $counts = @{ pass = [int]$Matches[1]; fail = [int]$Matches[2]; groups = [int]$Matches[3] }
            } elseif ($line -match "^GROUP (.+)$") {
                $reportGroups += $Matches[1].Trim()
            } elseif ($line -match "^FAIL (.+)$") {
                $reportFails += $Matches[1].Trim()
            }
        }
    }

    function Get-Uniq([string]$pattern) {
        @([regex]::Matches($text, $pattern) | ForEach-Object { $_.Value.Trim() } | Select-Object -Unique)
    }

    Write-Output "--- offline suite (de-duplicated markers) ---"
    if ($reportGroups.Count -gt 0) {
        foreach ($group in $reportGroups) { Write-Output "OFFLINE_GROUP $group" }
    } else {
        foreach ($line in (Get-Uniq "OFFLINE_GROUP [\w\.\-]+")) { Write-Output $line }
    }
    foreach ($failure in $reportFails) { Write-Output "OFFLINE_FAIL_AT $failure" }
    if ($counts) {
        $total = $counts.pass + $counts.fail
        Write-Output ("OFFLINE_ASSERTS " + $total + " pass=" + $counts.pass + " fail=" + $counts.fail)
        Write-Output ("OFFLINE_GROUPS " + $counts.groups)
        Write-Output ("OFFLINE_PASS " + $counts.pass)
        Write-Output ("OFFLINE_FAIL " + $counts.fail)
    } else {
        $asserts  = (Get-Uniq "OFFLINE_ASSERTS \d+ pass=\d+ fail=\d+" | Select-Object -Last 1)
        $passLine = (Get-Uniq "OFFLINE_PASS \d+" | Select-Object -Last 1)
        $failLine = (Get-Uniq "OFFLINE_FAIL \d+" | Select-Object -Last 1)
        $groupLine = (Get-Uniq "OFFLINE_GROUPS \d+" | Select-Object -Last 1)
        if ($asserts) { Write-Output $asserts }
        if ($passLine) { Write-Output $passLine }
        if ($failLine) { Write-Output $failLine }
        if ($groupLine) { Write-Output $groupLine }
    }
    if (-not $done) { Write-Output "OFFLINE_ERROR no OFFLINE_DONE marker before timeout" }
    Write-Output "--- end offline suite ---"

    $failed = -not $done
    if ($counts) {
        if ($counts.fail -gt 0) { $failed = $true }
        if ($counts.groups -lt 1) { $failed = $true }
    } else {
        $failed = $true
    }

    if (-not $failed) {
        Write-Output ("OFFLINE_RESULT PASS pass=" + $counts.pass + " fail=0 groups=" + $counts.groups)
        Cleanup
        exit 0
    }
    if (-not $text) { Write-Output "OFFLINE_ERROR emulator produced no stdout (see $stderr)" }
    Write-Output "OFFLINE_RESULT FAIL"
    Cleanup
    exit 1
}
catch {
    Write-Output ("OFFLINE_ERROR " + $_.Exception.Message)
    Cleanup
    exit 2
}
