# Local CI / pre-release regression entry point.
#
# Deliberately NOT wired to GitHub (project decision): this is the local
# equivalent — run it before releasing or after a batch of changes.
#
#   pwsh -File poc\ci.ps1                 # everything (~8 min)
#   pwsh -File poc\ci.ps1 -Only m1,m4-panel
#
# exit code 0 = all harnesses passed, 1 = at least one failed.
param(
    [string]$Only = "",
    [string]$Root = $env:RPV_ROOT
)

$root = $Root
if (-not $root) { $root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path) }
$env:RPV_ROOT = $root

$stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$report = Join-Path $root "poc\out\ci-$stamp.txt"
"CI report will be written to: $report"

$sb = [scriptblock]::Create((Get-Content (Join-Path $root "poc\run-all.ps1") -Raw))
if ($Only -ne "") { & $sb -Only $Only *> $report } else { & $sb *> $report }
$code = $LASTEXITCODE
if ($null -eq $code) { $code = 0 }

Get-Content $report | Select-Object -Last 24
""
"CI report: $report (exit=$code)"
exit $code
