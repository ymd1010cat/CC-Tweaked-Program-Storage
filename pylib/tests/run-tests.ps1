# pylib offline test runner.
#
#   pwsh -NoProfile -File pylib\tests\run-tests.ps1
#
# Stages the exported pylib package (pkg/pylib/pythonlib.lua + the 15 .py
# modules, plus pkg/py.lua as /legacy-py.lua) on a throwaway headless
# CraftOS-PC computer, runs tests/startup.lua and reads the PYLIB_* / TEST_FAIL
# / MODULE markers back.
#
# CraftOS-PC block-buffers redirected stdout, so the suite appends every
# result line to <computer>/logs/suite.log as well and this script decides the
# verdict from that file (same pattern as itn-pass/tests/run-tests.ps1).
# A passing run deletes the staging directory; a failing one keeps it for
# debugging, and -KeepStaging keeps it even on success (to read suite.log).
param(
    [int]$TimeoutSec = 600,
    [string]$DataDir = $env:PYLIB_OFFLINE_DIR,
    [switch]$KeepStaging
)

$ErrorActionPreference = 'Stop'

$testsDir = $PSScriptRoot
$root = Split-Path -Parent $testsDir
$pkg = Join-Path $root 'pkg'
$exe = 'C:\Program Files\CraftOS-PC\CraftOS-PC_console.exe'
if (-not (Test-Path $exe)) {
    throw "CraftOS-PC console not found: $exe"
}
if (-not $DataDir) {
    $DataDir = Join-Path $root '.tests'
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
foreach ($sub in @('pylib', 'tests', 'logs')) {
    New-Item -ItemType Directory -Force (Join-Path $computer $sub) | Out-Null
}

# The interpreter resolves `import x` against /pylib/x.py, so the .py modules
# are staged exactly where they are deployed.
$copyFailures = @()
foreach ($py in (Get-ChildItem -Path (Join-Path $pkg 'pylib') -File -Filter '*.py')) {
    Copy-Item $py.FullName (Join-Path $computer ('pylib\' + $py.Name)) -Force
}
Copy-Item (Join-Path $pkg 'pylib\pythonlib.lua') (Join-Path $computer 'pythonlib.lua') -Force
# The superseded interpreter is staged as /legacy-py.lua (its historic name) so
# the suite can prove the archive copy really is the one the README describes.
Copy-Item (Join-Path $pkg 'py.lua') (Join-Path $computer 'legacy-py.lua') -Force

# Test modules are discovered by /tests/run.lua, so adding t_*.lua needs no
# edit here or in run.lua.
foreach ($file in (Get-ChildItem -Path $testsDir -File -Filter '*.lua')) {
    Copy-Item $file.FullName (Join-Path $computer ('tests\' + $file.Name)) -Force
}
Copy-Item (Join-Path $testsDir 'startup.lua') (Join-Path $computer 'startup.lua') -Force

# Static gate: every Lua/PowerShell file under pylib/ stays pure ASCII. The
# exported pythonlib.lua and the .py modules are ASCII today, so a regression
# here is a real finding, not a nuisance.
$staticProblems = @()
foreach ($file in (Get-ChildItem -Path $root -Recurse -File |
        Where-Object { $_.Extension -eq '.lua' -or $_.Extension -eq '.ps1' })) {
    $text = Get-Content $file.FullName -Raw -Encoding utf8
    if ($text -match '[^\x00-\x7F]') {
        $staticProblems += ('non-ASCII byte in ' + $file.FullName)
    }
}
$stagedPy = @(Get-ChildItem -Path (Join-Path $computer 'pylib') -File -Filter '*.py')
if ($stagedPy.Count -ne 15) {
    $staticProblems += ("expected 15 staged .py modules, found " + $stagedPy.Count)
}
foreach ($needed in @('pythonlib.lua', 'legacy-py.lua', 'tests\run.lua',
                      'tests\harness.lua')) {
    if (-not (Test-Path (Join-Path $computer $needed))) {
        $staticProblems += ($needed + ' was not staged')
    }
}

$stdout = Join-Path $DataDir 'offline.stdout.txt'
$stderr = Join-Path $DataDir 'offline.stderr.txt'
$logFile = Join-Path $computer 'logs\suite.log'

$proc = Start-Process -FilePath $exe -ArgumentList @('-d', "`"$DataDir`"", '--headless', '--id', '20') `
    -RedirectStandardOutput $stdout -RedirectStandardError $stderr -PassThru -NoNewWindow

$deadline = (Get-Date).AddSeconds($TimeoutSec)
$done = $false
while ((Get-Date) -lt $deadline) {
    Start-Sleep -Milliseconds 300
    if ($proc.HasExited) { break }
    if (Test-Path $logFile) {
        if ((Get-Content $logFile -Raw) -match 'PYLIB_DONE') { $done = $true; break }
    }
    if (Test-Path $stdout) {
        $probe = Get-Content $stdout -Raw
        if ($probe -match 'PYLIB_DONE') { $done = $true; break }
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

# CraftOS-PC redraws partial lines, so match over the whole text and
# de-duplicate instead of splitting into lines.
function Get-Uniq([string]$pattern) {
    @([regex]::Matches($text, $pattern) | ForEach-Object { $_.Value.Trim() } |
        Select-Object -Unique)
}

$passLine = (Get-Uniq 'PYLIB_PASS \d+' | Select-Object -Last 1)
$failLine = (Get-Uniq 'PYLIB_FAIL \d+' | Select-Object -Last 1)
$grpLine = (Get-Uniq 'PYLIB_GROUPS \d+' | Select-Object -Last 1)
$crashes = Get-Uniq 'PYLIB_CRASH [^\n]*'
$fails = @(Get-Uniq 'TEST_FAIL [^\n]*' | Sort-Object)
$modules = @(Get-Uniq 'MODULE [A-Za-z_0-9.]+ status=[a-z_]+[^\n]*' | Sort-Object)
$perfs = @(Get-Uniq 'PERF [^\n]*' | Sort-Object)
if (-not $passLine) { $passLine = 'PYLIB_PASS 0' }
if (-not $failLine) { $failLine = 'PYLIB_FAIL 1' }
if (-not $grpLine) { $grpLine = 'PYLIB_GROUPS 0' }

$passCount = [int]([regex]::Match($passLine, '\d+').Value)
$failCount = [int]([regex]::Match($failLine, '\d+').Value)
$groupCount = [int]([regex]::Match($grpLine, '\d+').Value)
if ($text -match 'PYLIB_DONE') { $done = $true }

$verdict = 'FAIL'
if ($done -and $failCount -eq 0 -and $passCount -gt 0 -and $staticProblems.Count -eq 0) {
    $verdict = 'PASS'
}

"RESULT pylib offline done=$done verdict=$verdict data=$DataDir"
"$passLine | $failLine | $grpLine"
"BASELINE PYLIB_PASS=$passCount PYLIB_FAIL=$failCount PYLIB_GROUPS=$groupCount"
if ($modules.Count -gt 0) {
    'MODULES:'
    $modules | ForEach-Object { '  ' + $_ }
}
if ($perfs.Count -gt 0) {
    'PERF:'
    $perfs | ForEach-Object { '  ' + $_ }
}
if ($staticProblems.Count -gt 0) {
    'STATIC_FAILURES:'
    $staticProblems | ForEach-Object {
        '  ' + $_
        [Console]::Error.WriteLine('STATIC_FAIL ' + $_)
    }
}
if ($fails.Count -gt 0) {
    'FAILURES:'
    $fails | Select-Object -First 40 | ForEach-Object {
        '  ' + $_
        [Console]::Error.WriteLine($_)
    }
}
if ($crashes.Count -gt 0) {
    'CRASHES:'
    $crashes | Select-Object -First 5 | ForEach-Object {
        '  ' + $_
        [Console]::Error.WriteLine($_)
    }
}
if ($verdict -ne 'PASS' -and (Test-Path $stderr)) {
    [string]$errText = (Get-Content $stderr -Raw)
    $errText = $errText -replace "`r", ""
    if ($errText.Trim() -ne '') {
        'STDERR:'
        ($errText -split "`n" | Select-Object -First 20) | ForEach-Object { '  ' + $_ }
    }
}
if ($verdict -ne 'PASS') {
    [Console]::Error.WriteLine('pylib offline suite FAILED (staging kept at ' + $DataDir + ')')
    exit 1
}

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
