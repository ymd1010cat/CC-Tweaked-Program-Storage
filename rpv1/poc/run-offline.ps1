# P4 acceptance (part 1): offline unit tests + static lint.
#
#   pwsh -File poc\run-offline.ps1
#
# Stages rpv/, tests/, tools/ and the pure app-layer modules (apps/http_*.lua,
# hosts.lua, wan_acl.lua, router.lua) on a single headless computer: no role.txt,
# no running apps, no modems, no second computer, no topology. node2/startup.lua is
# staged under node2/ so the router tests can exercise its app loader. The tests
# exercise the pure logic (codecs, route table, crypto KATs, WAN AEAD state machine,
# NAT rewrite, multicast domains, QoS classes, HTTP framing/server/client/secure,
# the adaptive router UI) and tools/lint.lua checks every Lua file.
#
# The same suite runs under desktop Lua 5.1 with the shim in tests/host.lua:
#   lua -e 'dofile("tests/host.lua")' tests/run.lua
param([int]$TimeoutSec = 120, [string]$Root = $env:RPV_ROOT)

$root = $Root
if (-not $root) { $root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path) }
$data = Join-Path $root "craftos-offline"
$exe = "C:\Program Files\CraftOS-PC\CraftOS-PC_console.exe"
$out = Join-Path $root "poc\out"
New-Item -ItemType Directory -Force -Path $out | Out-Null
if (Test-Path $data) { Remove-Item -Recurse -Force $data }

$dir = Join-Path $data "computer\20"
foreach ($sub in @("rpv", "tests", "tools", "apps", "node2")) { New-Item -ItemType Directory -Force -Path (Join-Path $dir $sub) | Out-Null }
Copy-Item (Join-Path $root "poc\rpv\*.lua") (Join-Path $dir "rpv") -Force
Copy-Item (Join-Path $root "poc\tests\*.lua") (Join-Path $dir "tests") -Force
Copy-Item (Join-Path $root "poc\tools\*.lua") (Join-Path $dir "tools") -Force
Copy-Item (Join-Path $root "poc\apps\http_*.lua") (Join-Path $dir "apps") -Force
Copy-Item (Join-Path $root "poc\apps\hosts.lua") (Join-Path $dir "apps") -Force
Copy-Item (Join-Path $root "poc\apps\wan_acl.lua") (Join-Path $dir "apps") -Force
Copy-Item (Join-Path $root "poc\apps\router.lua") (Join-Path $dir "apps") -Force
Copy-Item (Join-Path $root "poc\tests\startup.lua") (Join-Path $dir "startup.lua") -Force
# the bootstrap is staged under node2/ so tests/t_router.lua can load its app loader
# (RPV_BOOT_TEST hook) without booting: same relative path as in the repo
Copy-Item (Join-Path $root "poc\node2\startup.lua") (Join-Path $dir "node2\startup.lua") -Force

$stdout = Join-Path $out "offline.stdout.txt"
$stderr = Join-Path $out "offline.stderr.txt"
$proc = Start-Process -FilePath $exe -ArgumentList @("-d", "`"$data`"", "--headless", "--id", "20") `
    -RedirectStandardOutput $stdout -RedirectStandardError $stderr -PassThru -NoNewWindow

$deadline = (Get-Date).AddSeconds($TimeoutSec)
$done = $false
while ((Get-Date) -lt $deadline) {
    Start-Sleep -Milliseconds 400
    if ($proc.HasExited) { break }
    if (Test-Path $stdout) {
        $text = Get-Content $stdout -Raw
        if ($text -match "TEST_DONE") { $done = $true; break }
    }
}
Start-Sleep -Milliseconds 500
if (-not $proc.HasExited) { $proc.Kill() }
Start-Sleep -Milliseconds 300

$text = if (Test-Path $stdout) { (Get-Content $stdout -Raw) -replace "`r", "" } else { "" }
Copy-Item $stdout (Join-Path $out "offline-run.txt") -Force -ErrorAction SilentlyContinue

# CraftOS-PC redraws partial lines, so every fragment can appear several times: match
# with regex over the whole text and de-duplicate instead of splitting into lines
function Get-Uniq([string]$pattern) {
    @([regex]::Matches($text, $pattern) | ForEach-Object { $_.Value.Trim() } | Select-Object -Unique)
}
$passLine = (Get-Uniq "OFFLINE_PASS \d+" | Select-Object -Last 1)
$failLine = (Get-Uniq "OFFLINE_FAIL \d+" | Select-Object -Last 1)
$grpLine = (Get-Uniq "OFFLINE_GROUPS \d+" | Select-Object -Last 1)
$lintErrLine = (Get-Uniq "LINT_ERRORS \d+" | Select-Object -Last 1)
$lintWarnLine = (Get-Uniq "LINT_WARNINGS \d+" | Select-Object -Last 1)
$lintFilesLine = (Get-Uniq "LINT_FILES \d+" | Select-Object -Last 1)
$result = "$passLine | $failLine | $grpLine"
$lint = "$lintErrLine | $lintWarnLine | $lintFilesLine"
$groups = Get-Uniq "TEST \w+ ok=(true|false)"
$fails = Get-Uniq "(TEST_FAIL|OFFLINE_FAILURE|LINT_ERROR|OFFLINE_CRASH) [^\n]*"

$verdict = "FAIL"
$passZero = $failLine -match "OFFLINE_FAIL 0"
$lintClean = $lintErrLine -match "LINT_ERRORS 0"
if ($done -and $passZero -and $lintClean) { $verdict = "PASS" }

"RESULT offline done=$done verdict=$verdict"
"$result"
"$lint"
"GROUPS $($groups.Count)"
$groups | ForEach-Object { "  " + $_ }
if ($fails.Count -gt 0) { "FAILURES:"; $fails | Select-Object -First 12 | ForEach-Object { "  " + $_ } }
