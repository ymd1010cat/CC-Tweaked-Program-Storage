# Start / stop / inspect the dedicated Minecraft servers used for RPV1 tests.
#
#   pwsh -File poc\mc\server.ps1 -Action start  [-Target neoforge|fabric]
#   pwsh -File poc\mc\server.ps1 -Action status [-Target neoforge|fabric]
#   pwsh -File poc\mc\server.ps1 -Action stop   [-Target neoforge|fabric]
#
# neoforge : mc-server\        game 25565  rcon 25575   (reference loader)
# fabric   : mc-server-fabric\ game 25566  rcon 25576   (accepts vanilla-protocol
#            clients, so the fake-player bot can read spark's chat-only output)
param(
    [ValidateSet("start", "stop", "status")]
    [string]$Action = "status",
    [ValidateSet("neoforge", "fabric")]
    [string]$Target = "neoforge",
    [string]$Root = $env:RPV_ROOT,
    [string]$Java = ""
)

$root = $Root
if (-not $root) {
    if ($MyInvocation.MyCommand.Path) { $root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path) }
    else { $root = "C:\Users\ymd10\Documents\DSHWork\cc_tweaked\rpv1" }
}
$env:RPV_ROOT = $root

$targets = @{
    neoforge = @{ dir = "mc-server";        rcon = 25575; game = 25565; kind = "neoforge" }
    fabric   = @{ dir = "mc-server-fabric"; rcon = 25576; game = 25566; kind = "fabric" }
}
$t = $targets[$Target]
$server = Join-Path $root $t.dir
# resolve the JDK: -Java wins, then JAVA_HOME, then the known install roots. The path
# used to be hard coded to one Microsoft build; when that build was replaced the server
# could no longer start, so it is discovered now.
if ($Java) {
    $java = $Java
} else {
    $candidates = @()
    if ($env:JAVA_HOME) { $candidates += (Join-Path $env:JAVA_HOME "bin\java.exe") }
    $candidates += "C:\Program Files\Microsoft\jdk-25.0.3.9-hotspot\bin\java.exe"
    foreach ($dir in @("C:\Program Files\Java", "C:\Program Files\Eclipse Adoptium",
                       "C:\Program Files\Microsoft", "C:\Program Files\Zulu")) {
        if (Test-Path $dir) {
            $candidates += (Get-ChildItem $dir -Recurse -Filter "java.exe" -ErrorAction SilentlyContinue -Depth 3 |
                            ForEach-Object { $_.FullName })
        }
    }
    $java = $null
    foreach ($c in $candidates) { if ($c -and (Test-Path $c)) { $java = $c; break } }
    if (-not $java) { throw "no java.exe found; pass -Java <path to java.exe>" }
}
$py = "C:\Users\ymd10\.dsh\dsh-runtimes\dsh-primary-runtime\dependencies\python\python.exe"
$rcon = Join-Path $root "poc\mc\rcon.py"

function Test-Running {
    $out = & $py $rcon 127.0.0.1 $t.rcon rpvtest "list" 2>&1
    return ($out -match "players online")
}

switch ($Action) {
    "status" {
        if (Test-Running) { "$Target : RUNNING (game $($t.game), rcon $($t.rcon))" }
        else { "$Target : not reachable" }
    }
    "start" {
        if (Test-Running) { "$Target already running"; break }
        if ($t.kind -eq "neoforge") {
            Start-Process -FilePath $java `
                -ArgumentList @("-Xmx3G", "-Xms1G", "-XX:+UseG1GC",
                    "@libraries/net/neoforged/neoforge/21.1.253/win_args.txt", "nogui") `
                -WorkingDirectory $server -WindowStyle Hidden
        } else {
            Start-Process -FilePath $java `
                -ArgumentList @("-Xmx3G", "-Xms1G", "-XX:+UseG1GC", "-jar", "fabric-server-launch.jar", "nogui") `
                -WorkingDirectory $server -WindowStyle Hidden
        }
        "starting $Target, waiting for RCON $($t.rcon)..."
        foreach ($i in 1..90) {
            Start-Sleep -Seconds 2
            if (Test-Running) { "$Target : RUNNING"; break }
        }
    }
    "stop" {
        if (-not (Test-Running)) { "$Target not running"; break }
        $null = & $py $rcon 127.0.0.1 $t.rcon rpvtest "stop" 2>&1
        "sent stop"
        foreach ($i in 1..40) {
            Start-Sleep -Seconds 2
            if (-not (Test-Running)) { "$Target : stopped"; break }
        }
    }
}
