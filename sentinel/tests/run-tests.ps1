# Sentinel offline test runner.
#
#   pwsh -File tests\run-tests.ps1
#
# Stages the Sentinel deploy layout (auth/, system/, sha256.lua) plus tests/ on
# a throwaway headless CraftOS-PC computer, runs tests/startup.lua and parses
# the OFFLINE_* / TEST_* markers. No game, modem, redstone or second computer
# is involved. The staging directory (sentinel/.offline by default) is removed
# after a passing run (it is kept for debugging when the run fails).
param(
    [int]$TimeoutSec = 180,
    [string]$DataDir = $env:SENTINEL_OFFLINE_DIR
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

$copies = [ordered]@{
    'common\sha256.lua'                = 'sha256.lua'
    'common\role_policy.lua'           = 'auth\role_policy.lua'
    'terminal\auth\user_manager.lua'   = 'auth\user_manager.lua'
    'terminal\auth\psk.lua'            = 'auth\psk.lua'
    'terminal\auth\login.lua'          = 'auth\login.lua'
    'terminal\auth\login_client.lua'   = 'auth\login_client.lua'
    'terminal\auth\login_standalone.lua' = 'auth\login_standalone.lua'
    'auth_server\auth\server_crypto.lua' = 'auth\server_crypto.lua'
    'auth_server\auth\terminal_keys.lua' = 'auth\terminal_keys.lua'
    'audit_server\auth\audit_config.lua' = 'auth\audit_config.lua'
    'auth_server\system\auth_server.lua' = 'system\auth_server.lua'
    'auth_server\system\user_admin.lua'  = 'system\user_admin.lua'
    'audit_server\system\audit_server.lua' = 'system\audit_server.lua'
    'terminal\system\audit.lua'        = 'system\audit.lua'
    'terminal\system\netcheck.lua'     = 'system\netcheck.lua'
    'terminal\system\ui.lua'           = 'system\ui.lua'
    'terminal\system\kernel.lua'       = 'system\kernel.lua'
    'tests\run.lua'                    = 'tests\run.lua'
    'tests\startup.lua'                = 'startup.lua'
}
foreach ($pair in $copies.GetEnumerator()) {
    $source = Join-Path $root $pair.Key
    if (-not (Test-Path $source)) {
        throw "missing source file: $source"
    }
    Copy-Item $source (Join-Path $computer $pair.Value) -Force
}

# Repo-level cleanup assertions: the single-machine mode must really be gone
# and no protocol-v4 token may survive in any Lua file.
$repoLua = Get-ChildItem -Path $root -Recurse -File -Filter '*.lua' |
    Where-Object { $_.FullName -notmatch '\\tests\\' }
$v4Hits = @($repoLua | Select-String -Pattern 'secure_auth_v4' -SimpleMatch)
$modeFile = Join-Path $root 'terminal\auth\mode.lua'
$loginFile = Join-Path $root 'terminal\auth\login.lua'
$standaloneRef = @(Select-String -Path $loginFile -Pattern 'login_standalone' -SimpleMatch -ErrorAction SilentlyContinue)

$stdout = Join-Path $DataDir 'offline.stdout.txt'
$stderr = Join-Path $DataDir 'offline.stderr.txt'

$proc = Start-Process -FilePath $exe -ArgumentList @('-d', "`"$DataDir`"", '--headless', '--id', '20') `
    -RedirectStandardOutput $stdout -RedirectStandardError $stderr -PassThru -NoNewWindow

$deadline = (Get-Date).AddSeconds($TimeoutSec)
$done = $false
while ((Get-Date) -lt $deadline) {
    Start-Sleep -Milliseconds 300
    if ($proc.HasExited) { break }
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

$text = if (Test-Path $stdout) { (Get-Content $stdout -Raw) -replace "`r", "" } else { "" }

# CraftOS-PC redraws partial lines, so match with regex over the whole text and
# de-duplicate instead of splitting into lines.
function Get-Uniq([string]$pattern) {
    @([regex]::Matches($text, $pattern) | ForEach-Object { $_.Value.Trim() } | Select-Object -Unique)
}

$passLine = (Get-Uniq 'OFFLINE_PASS \d+' | Select-Object -Last 1)
$failLine = (Get-Uniq 'OFFLINE_FAIL \d+' | Select-Object -Last 1)
$grpLine = (Get-Uniq 'OFFLINE_GROUPS \d+' | Select-Object -Last 1)
$crashes = Get-Uniq 'OFFLINE_CRASH [^\n]*'
$fails = Get-Uniq 'TEST_FAIL [^\n]*'
if (-not $passLine) { $passLine = 'OFFLINE_PASS 0' }
if (-not $failLine) { $failLine = 'OFFLINE_FAIL 1' }
if (-not $grpLine) { $grpLine = 'OFFLINE_GROUPS 0' }

$passCount = [int]([regex]::Match($passLine, '\d+').Value)
$failCount = [int]([regex]::Match($failLine, '\d+').Value)
$staticProblems = @()
if ($v4Hits.Count -gt 0) {
    $staticProblems += "secure_auth_v4 remains in: " + (($v4Hits | ForEach-Object { $_.Path }) -join ', ')
}
if (Test-Path $modeFile) {
    $staticProblems += "terminal/auth/mode.lua still exists"
}
if ($standaloneRef.Count -gt 0) {
    $staticProblems += "terminal/auth/login.lua still references login_standalone"
}

$verdict = 'FAIL'
if ($done -and $failCount -eq 0 -and $passCount -gt 0 -and $staticProblems.Count -eq 0) {
    $verdict = 'PASS'
}

"RESULT offline done=$done verdict=$verdict data=$DataDir"
"$passLine | $failLine | $grpLine"
if ($staticProblems.Count -gt 0) {
    "STATIC_FAILURES:"
    $staticProblems | ForEach-Object { '  ' + $_ }
}
if ($fails.Count -gt 0) {
    "FAILURES:"
    $fails | Select-Object -First 20 | ForEach-Object { '  ' + $_ }
}
if ($crashes.Count -gt 0) {
    "CRASHES:"
    $crashes | Select-Object -First 5 | ForEach-Object { '  ' + $_ }
}
if ($verdict -ne 'PASS' -and (Test-Path $stderr)) {
    [string]$errText = (Get-Content $stderr -Raw)
    $errText = $errText -replace "`r", ""
    if ($errText.Trim() -ne '') {
        "STDERR:"
        ($errText -split "`n" | Select-Object -First 10) | ForEach-Object { '  ' + $_ }
    }
}

if ($verdict -eq 'PASS') {
    # Keep the workspace clean; failing runs keep the staging dir for debugging.
    for ($attempt = 0; $attempt -lt 5; $attempt++) {
        try {
            Remove-Item -Recurse -Force $DataDir -ErrorAction Stop
            break
        } catch {
            Start-Sleep -Milliseconds 300
        }
    }
    exit 0
}
exit 1
