# itn-pass offline test runner.
#
#   pwsh -File itn-pass\tests\run-tests.ps1
#
# Stages the itn-pass deploy layout (sha256.lua, itnpass_net.lua, auth/, system/)
# plus tests/ on a throwaway headless CraftOS-PC computer, runs tests/startup.lua
# and parses the OFFLINE_* / TEST_FAIL markers. No game, modem, disk drive or
# second computer is involved: tests/run.lua installs the fakes. The staging
# directory (itn-pass/.offline by default) is removed after a passing run and
# kept for debugging when the run fails; -KeepStaging keeps it even on success
# (useful to read logs/suite.log).
param(
    [int]$TimeoutSec = 600,
    [string]$DataDir = $env:ITNPASS_OFFLINE_DIR,
    [switch]$KeepStaging
)

$ErrorActionPreference = 'Stop'

$testsDir = $PSScriptRoot
$root = Split-Path -Parent $testsDir
$exe = 'C:\Program Files\CraftOS-PC\CraftOS-PC_console.exe'
if (-not (Test-Path $exe)) {
    throw "CraftOS-PC console not found: $exe"
}
if (-not $DataDir) {
    $DataDir = Join-Path $root '.offline'
}

# CraftOS-PC keeps a handle on its data dir for a moment after exit.
for ($attempt = 0; $attempt -lt 5; $attempt++) {
    if (-not (Test-Path $DataDir)) { break }
    try {
        Remove-Item -Recurse -Force $DataDir -ErrorAction Stop
        break
    } catch {
        Start-Sleep -Milliseconds 400
    }
}

$computer = Join-Path $DataDir 'computer\20'
foreach ($sub in @('auth', 'system', 'tests', 'logs')) {
    New-Item -ItemType Directory -Force (Join-Path $computer $sub) | Out-Null
}

# Deploy layout exactly as documented in itn-pass/README.md, plus the shared
# net constants (/itnpass_net.lua sits next to /sha256.lua at the root).
$copies = [ordered]@{
    'common\sha256.lua'                = 'sha256.lua'
    'common\itnpass_net.lua'           = 'itnpass_net.lua'
    'server\auth\itnpass_config.lua'   = 'auth\itnpass_config.lua'
    'server\auth\itnpass_store.lua'    = 'auth\itnpass_store.lua'
    'server\system\disk_writer.lua'    = 'system\disk_writer.lua'
    'server\system\itnpass_server.lua' = 'system\itnpass_server.lua'
    'server\system\itnpass_admin.lua'  = 'system\itnpass_admin.lua'
    'terminal\auth\itnpass_client.lua' = 'auth\itnpass_client.lua'
    'terminal\auth\itnpass_login.lua'  = 'auth\itnpass_login.lua'
    'terminal\auth\session.lua'        = 'auth\session.lua'
    'terminal\system\netcheck.lua'     = 'system\netcheck.lua'
    'terminal\system\sandbox.lua'      = 'system\sandbox.lua'
    'terminal\system\kernel.lua'       = 'system\kernel.lua'
    'terminal\system\ui.lua'           = 'system\ui.lua'
}
foreach ($pair in $copies.GetEnumerator()) {
    $source = Join-Path $root $pair.Key
    if (-not (Test-Path $source)) {
        throw "missing source file: $source"
    }
    Copy-Item $source (Join-Path $computer $pair.Value) -Force
}

# Every test module is staged automatically, so adding t_*.lua needs no edit
# here (tests/run.lua discovers them the same way).
foreach ($file in (Get-ChildItem -Path $testsDir -File -Filter '*.lua')) {
    Copy-Item $file.FullName (Join-Path $computer ('tests\' + $file.Name)) -Force
}
Copy-Item (Join-Path $testsDir 'startup.lua') (Join-Path $computer 'startup.lua') -Force

# Static gate: the whole itn-pass tree stays pure ASCII (repo rule); the suite
# itself is checked too, so a stray non-ASCII character fails the run.
$staticProblems = @()
$nonAscii = @(Get-ChildItem -Path $root -Recurse -File |
    Where-Object { $_.Extension -eq '.lua' -or $_.Extension -eq '.ps1' } |
    Where-Object { (Get-Content $_.FullName -Raw -Encoding utf8) -match '[^\x00-\x7F]' })
foreach ($file in $nonAscii) {
    $staticProblems += "non-ASCII byte in " + $file.FullName
}
if (-not (Test-Path (Join-Path $computer 'tests\run.lua'))) {
    $staticProblems += 'tests\run.lua was not staged'
}
if (-not (Test-Path (Join-Path $computer 'sha256.lua'))) {
    $staticProblems += 'sha256.lua was not staged'
}

$stdout = Join-Path $DataDir 'offline.stdout.txt'
$stderr = Join-Path $DataDir 'offline.stderr.txt'
# CraftOS-PC buffers redirected stdout, so the suite also appends every result
# line to this file inside the computer; that copy drives the verdict.
$logFile = Join-Path $computer 'logs\suite.log'

$proc = Start-Process -FilePath $exe -ArgumentList @('-d', "`"$DataDir`"", '--headless', '--id', '20') `
    -RedirectStandardOutput $stdout -RedirectStandardError $stderr -PassThru -NoNewWindow

$deadline = (Get-Date).AddSeconds($TimeoutSec)
$done = $false
while ((Get-Date) -lt $deadline) {
    Start-Sleep -Milliseconds 300
    if ($proc.HasExited) { break }
    if (Test-Path $logFile) {
        if ((Get-Content $logFile -Raw) -match 'TEST_DONE') { $done = $true; break }
    }
    if (Test-Path $stdout) {
        $probe = Get-Content $stdout -Raw
        if ($probe -match 'TEST_DONE') { $done = $true; break }
    }
}
Start-Sleep -Milliseconds 500
if (-not $proc.HasExited) {
    try { $proc.Kill() } catch { }
    try { $proc.WaitForExit(5000) | Out-Null } catch { }
}

$stdoutText = if (Test-Path $stdout) { (Get-Content $stdout -Raw) -replace "`r", "" } else { "" }
$logText = if (Test-Path $logFile) { (Get-Content $logFile -Raw) -replace "`r", "" } else { "" }
$text = $stdoutText + "`n" + $logText

# CraftOS-PC redraws partial lines, so match with regex over the whole text and
# de-duplicate instead of splitting into lines.
function Get-Uniq([string]$pattern) {
    @([regex]::Matches($text, $pattern) | ForEach-Object { $_.Value.Trim() } |
        Select-Object -Unique)
}

$passLine = (Get-Uniq 'OFFLINE_PASS \d+' | Select-Object -Last 1)
$failLine = (Get-Uniq 'OFFLINE_FAIL \d+' | Select-Object -Last 1)
$grpLine = (Get-Uniq 'OFFLINE_GROUPS \d+' | Select-Object -Last 1)
$crashes = Get-Uniq 'OFFLINE_CRASH [^\n]*'
$fails = @(Get-Uniq 'TEST_FAIL [^\n]*' | Sort-Object)
if (-not $passLine) { $passLine = 'OFFLINE_PASS 0' }
if (-not $failLine) { $failLine = 'OFFLINE_FAIL 1' }
if (-not $grpLine) { $grpLine = 'OFFLINE_GROUPS 0' }

$passCount = [int]([regex]::Match($passLine, '\d+').Value)
$failCount = [int]([regex]::Match($failLine, '\d+').Value)
$groupCount = [int]([regex]::Match($grpLine, '\d+').Value)
# The process may exit (shutdown) before the poll loop sees the marker.
if ($text -match 'TEST_DONE') { $done = $true }

$verdict = 'FAIL'
if ($done -and $failCount -eq 0 -and $passCount -gt 0 -and $staticProblems.Count -eq 0) {
    $verdict = 'PASS'
}

"RESULT offline done=$done verdict=$verdict data=$DataDir"
"$passLine | $failLine | $grpLine"
"BASELINE OFFLINE_PASS=$passCount OFFLINE_FAIL=$failCount OFFLINE_GROUPS=$groupCount"
if ($staticProblems.Count -gt 0) {
    "STATIC_FAILURES:"
    $staticProblems | ForEach-Object {
        '  ' + $_
        [Console]::Error.WriteLine('STATIC_FAIL ' + $_)
    }
}
if ($fails.Count -gt 0) {
    "FAILURES:"
    $fails | Select-Object -First 40 | ForEach-Object {
        '  ' + $_
        [Console]::Error.WriteLine($_)
    }
}
if ($crashes.Count -gt 0) {
    "CRASHES:"
    $crashes | Select-Object -First 5 | ForEach-Object {
        '  ' + $_
        [Console]::Error.WriteLine($_)
    }
}
if ($verdict -ne 'PASS' -and (Test-Path $stderr)) {
    [string]$errText = (Get-Content $stderr -Raw)
    $errText = $errText -replace "`r", ""
    if ($errText.Trim() -ne '') {
        "STDERR:"
        ($errText -split "`n" | Select-Object -First 20) | ForEach-Object { '  ' + $_ }
    }
}
if ($verdict -ne 'PASS') {
    [Console]::Error.WriteLine('itn-pass offline suite FAILED (staging kept at ' + $DataDir + ')')
    exit 1
}

# Passing runs leave no staging behind (unless the caller asked to keep it).
if ($KeepStaging) {
    "STORAGE kept at $DataDir (KeepStaging)"
    exit 0
}
for ($attempt = 0; $attempt -lt 5; $attempt++) {
    try {
        Remove-Item -Recurse -Force $DataDir -ErrorAction Stop
        break
    } catch {
        Start-Sleep -Milliseconds 300
    }
}
exit 0
