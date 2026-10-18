# Link-type / channel-reservation self-check (modular library, poc/rpv/node.lua).
#   20 declares: back=wireless (emulator reports wired -> warning), left=ender,
#                right=channel 65535 (rednet broadcast -> warning)
param([int]$TimeoutSec = 20, [string]$Root = $env:RPV_ROOT)

$root = $Root
if (-not $root) { $root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path) }
$data = Join-Path $root "craftos-linktype"
$exe = "C:\Program Files\CraftOS-PC\CraftOS-PC_console.exe"
$bootstrap = Join-Path $root "poc\node2\startup.lua"
$rpvdir = Join-Path $root "poc\rpv"
$appsdir = Join-Path $root "poc\apps"
$compatdir = Join-Path $root "poc\compat"

if (Test-Path $data) { Remove-Item -Recurse -Force $data }
$dir = Join-Path $data "computer\20"
foreach ($sub in @("rpv", "apps", "compat")) { New-Item -ItemType Directory -Force -Path (Join-Path $dir $sub) | Out-Null }
Copy-Item (Join-Path $rpvdir "*.lua") (Join-Path $dir "rpv") -Force
Copy-Item (Join-Path $appsdir "*.lua") (Join-Path $dir "apps") -Force
Copy-Item (Join-Path $compatdir "*.lua") (Join-Path $dir "compat") -Force
Copy-Item $bootstrap (Join-Path $dir "startup.lua") -Force
Set-Content -Path (Join-Path $dir "role.txt") -Encoding ascii -Value @"
role=host
iface=back|A|10.10.1.1/24|4999|256|wireless
iface=left|B|10.10.2.1/24|4998|256|ender
iface=right|C|10.10.3.1/24|65535|256|wired
"@

$stdout = Join-Path $root "poc\out\linktype.stdout.txt"
$stderr = Join-Path $root "poc\out\linktype.stderr.txt"
$proc = Start-Process -FilePath $exe -ArgumentList @("-d", "`"$data`"", "--headless", "--id", "20") `
    -RedirectStandardOutput $stdout -RedirectStandardError $stderr -PassThru -NoNewWindow
$deadline = (Get-Date).AddSeconds($TimeoutSec)
while ((Get-Date) -lt $deadline -and -not $proc.HasExited) { Start-Sleep -Milliseconds 400 }
if (-not $proc.HasExited) { $proc.Kill() }
Start-Sleep -Milliseconds 300

$log = Join-Path $data "computer\20\rpv-log.txt"
if (Test-Path $log) {
    Copy-Item $log (Join-Path $root "poc\out\linktype-node20.log") -Force
    Get-Content $log
} else { "(no log)" }
