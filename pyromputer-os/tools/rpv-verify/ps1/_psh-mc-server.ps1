# Start / stop / inspect a Minecraft Fabric server copy.
#
# The acceptance scripts can start a server themselves, but they also kill one they find
# running (they raise computer_space_limit and restart so the new limit is read), and a
# server started as a child of a killed shell dies with it -- both of which cost a run.
# This script owns the lifecycle so a run can be pointed at a server that is already up
# (-ServerAlreadyRunning) and so "is it up, on which ports, with which mods" has one
# answer.
#
#   powershell -File tools\rpv-verify\_psh-mc-server.ps1 -Action start
#   powershell -File tools\rpv-verify\_psh-mc-server.ps1 -Action status
#   powershell -File tools\rpv-verify\_psh-mc-server.ps1 -Action stop
#   powershell -File tools\rpv-verify\_psh-mc-server.ps1 -Action restart
#   powershell -File tools\rpv-verify\_psh-mc-server.ps1 -Action logs -Tail 40
#
# -Server selects the copy (the directory holding fabric-server-launch.jar), so the same
# script drives <rpv1>\mc-server-fabric and the workspace copy at <cc_tweaked>\mc-server.
param(
    [ValidateSet("start", "stop", "restart", "status", "logs")]
    [string]$Action = "status",
    [string]$Server = "C:\Users\ymd10\Documents\DSHWork\cc_tweaked\mc-server",
    [int]$TimeoutSec = 300,
    [int]$Tail = 20,
    [int]$MemoryMb = 3072
)
$script:log = Join-Path $Server "ws-server.log"
$script:err = Join-Path $Server "ws-server.err"

function Get-Config {
    param([string]$Path, [string]$Key, [string]$Default)
    if (-not (Test-Path $Path)) { return $Default }
    foreach ($line in Get-Content $Path) {
        if ($line -match "^\s*$([regex]::Escape($Key))\s*=\s*(.+)$") { return $Matches[1].Trim() }
    }
    return $Default
}

function Get-ServerInfo {
    $props = Join-Path $Server "server.properties"
    $toml = Join-Path $Server "config\computercraft-server.toml"
    $mods = @()
    $modsDir = Join-Path $Server "mods"
    if (Test-Path $modsDir) { $mods = (Get-ChildItem $modsDir -Filter *.jar | ForEach-Object { $_.Name }) }
    [pscustomobject]@{
        server = $Server
        game = [int](Get-Config $props "server-port" "25565")
        rcon = [int](Get-Config $props "rcon.port" "25575")
        rconPassword = Get-Config $props "rcon.password" ""
        motd = Get-Config $props "motd" ""
        spaceLimit = (Get-Config $toml "computer_space_limit" "?")
        mods = $mods
        world = Test-Path (Join-Path $Server "world")
        log = $script:log
    }
}

function Get-Listener {
    param([int]$Port)
    $c = Get-NetTCPConnection -State Listen -LocalPort $Port -ErrorAction SilentlyContinue
    if ($c) { return ($c | Select-Object -First 1).OwningProcess }
    return $null
}

function Wait-Server {
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 2
        if (Test-Path $script:log) {
            $tail = Get-Content $script:log -Tail 80 -ErrorAction SilentlyContinue
            # "Done (" or the RCON line: the launcher opens its port a moment before the
            # server is ready to take connections, so the port alone is not the signal.
            if (($tail -join "`n") -match 'Done \(|RCON running') { return $true }
        }
        if (-not (Get-Process java -ErrorAction SilentlyContinue)) { return $false }
    }
    return $false
}

function Start-Server {
    $info = Get-ServerInfo
    if (Get-Listener $info.game) { "already running (pid $((Get-Listener $info.game))) on port $($info.game)"; return }
    $jar = Join-Path $Server "fabric-server-launch.jar"
    if (-not (Test-Path $jar)) { "no fabric-server-launch.jar in $Server"; exit 1 }
    "starting $Server (xmx ${MemoryMb}m), log $script:log"
    $proc = Start-Process -FilePath "java" -ArgumentList @("-Xmx${MemoryMb}M", "-jar", "fabric-server-launch.jar", "nogui") `
        -WorkingDirectory $Server -RedirectStandardOutput $script:log -RedirectStandardError $script:err `
        -PassThru -NoNewWindow
    "java launcher pid $($proc.Id)"
    if (Wait-Server) {
        $owner2 = Get-Listener $info.game
        "up: game $($info.game), rcon $($info.rcon), pid $owner2"
        Get-Content $script:log -Tail 3
    } else {
        "did not come up; see $script:log"
        Get-Content $script:log -Tail 20 -ErrorAction SilentlyContinue
    }
}

function Stop-Server {
    $info = Get-ServerInfo
    $killed = 0
    $owner = Get-Listener $info.game
    if ($owner) {
        try { Stop-Process -Id $owner -Force -ErrorAction SilentlyContinue; $killed++ } catch {}
    }
    # the launcher can outlive the server process it started
    Get-CimInstance Win32_Process -Filter "Name='java.exe'" | ForEach-Object {
        if ($_.CommandLine -and $_.CommandLine -match "fabric-server-launch\.jar") {
            Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
            $killed++
        }
    }
    Start-Sleep -Seconds 3
    "stopped ($killed process(es)); game port free: $((Get-Listener $info.game) -eq $null)"
}

$info = Get-ServerInfo
switch ($Action) {
    "status" {
        $owner = Get-Listener $info.game
        "server      : $($info.server)"
        "mods        : $($info.mods -join ', ')"
        "motd        : $($info.motd)"
        "game port   : $($info.game)  listening: $($owner -ne $null)$(if ($owner) { " (pid $owner)" })"
        "rcon port   : $($info.rcon)  listening: $((Get-Listener $info.rcon) -ne $null)"
        "rcon passwd : $($info.rconPassword)"
        "world       : $(if ($info.world) { 'present' } else { 'absent (generated on first start)' })"
        "space limit : $($info.spaceLimit)"
        "log         : $($info.log) $(if (Test-Path $info.log) { "($([math]::Round((Get-Item $info.log).Length/1KB))KB)" } else { '(none yet)' })"
    }
    "start" { Start-Server }
    "stop" { Stop-Server }
    "restart" { Stop-Server; Start-Server }
    "logs" {
        if (-not (Test-Path $info.log)) { "no log at $($info.log)"; exit 1 }
        Get-Content $info.log -Tail $Tail
    }
}
