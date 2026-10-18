# One-command regression / CI entry point: runs the rpv harnesses and reports
# PASS/FAIL. Point a CI job at this (CraftOS-PC console build required).
#
#   pwsh -File poc\run-all.ps1                 # everything (~8 min)
#   pwsh -File poc\run-all.ps1 -Only m1,demo   # subset
param(
    [string]$Only = "",
    [string]$Root = $env:RPV_ROOT
)

$root = $Root
if (-not $root) { $root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path) }
$env:RPV_ROOT = $root

# name, script, parameters, pattern in the harness output that means PASS
$jobs = @(
    @{ name = "m1";         script = "run-m1.ps1";        params = @{ Scenario = "m1" };       pass = "verdict=PASS" },
    @{ name = "lib";        script = "run-lib.ps1";       params = $null;                      pass = "verdict=PASS" },
    @{ name = "lib-bundle"; script = "run-lib.ps1";       params = @{ Mode = "bundle" };       pass = "verdict=PASS" },
    @{ name = "lib-install"; script = "run-lib.ps1";      params = @{ Mode = "install" };      pass = "verdict=PASS" },
    @{ name = "bridge";     script = "run-bridge.ps1";    params = @{ Mode = "normal" };       pass = "verdict=PASS" },
    @{ name = "svc";        script = "run-svc.ps1";       params = $null;                      pass = "verdict=PASS" },
    @{ name = "dv-ring";    script = "run-dv.ps1";        params = @{ Topology = "ring" };     pass = "verdict=PASS" },
    @{ name = "dv-chain";   script = "run-dv.ps1";        params = @{ Topology = "chain" };    pass = "verdict=PASS" },
    @{ name = "p2c-nat";    script = "run-p2c.ps1";       params = @{ Scenario = "nat" };      pass = "verdict=PASS" },
    @{ name = "p2c-mcast";  script = "run-p2c.ps1";       params = @{ Scenario = "mcast" };    pass = "verdict=PASS" },
    @{ name = "qos";        script = "run-qos.ps1";       params = $null;                      pass = "verdict=PASS" },
    @{ name = "wansec-plain"; script = "run-wansec.ps1";  params = @{ Mode = "plain" };        pass = "verdict=PASS" },
    @{ name = "wansec";     script = "run-wansec.ps1";    params = @{ Mode = "secure" };       pass = "verdict=PASS" },
    @{ name = "wansec-wrongpsk"; script = "run-wansec.ps1"; params = @{ Mode = "wrongpsk" };   pass = "verdict=PASS" },
    @{ name = "p3";         script = "run-p3.ps1";        params = $null;                      pass = "verdict=PASS" },
    @{ name = "offline";    script = "run-offline.ps1";   params = $null;                      pass = "verdict=PASS" },
    @{ name = "hotreload";  script = "run-hotreload.ps1"; params = $null;                      pass = "verdict=PASS" },
    @{ name = "topo";       script = "run-topo.ps1";      params = $null;                      pass = "verdict=PASS" },
    @{ name = "stp-chain";  script = "run-stp.ps1";       params = @{ Mode = "chain" };        pass = "verdict=PASS" },
    @{ name = "stp-loop";   script = "run-stp.ps1";       params = @{ Mode = "loop" };         pass = "verdict=PASS" },
    @{ name = "stp-failover"; script = "run-stp.ps1";     params = @{ Mode = "failover" };     pass = "verdict=PASS" },
    @{ name = "mesh";       script = "run-mesh.ps1";      params = $null;                      pass = "verdict=PASS" },
    @{ name = "scale-z";    script = "run-scale.ps1";     params = @{ Stage = "Z" };           pass = "verdict=PASS" },
    @{ name = "addr";       script = "run-addr.ps1";      params = $null;                      pass = "verdict=PASS" },
    @{ name = "bridge-wrongpsk"; script = "run-bridge.ps1"; params = @{ Mode = "wrongpsk" };   pass = "verdict=PASS" },
    @{ name = "routectl";   script = "run-m1.ps1";        params = @{ Scenario = "routectl" }; pass = "verdict=PASS" },
    @{ name = "badcfg";     script = "run-m1.ps1";        params = @{ Scenario = "badcfg" };   pass = "verdict=PASS" },
    @{ name = "lan";        script = "run-demo.ps1";      params = $null;                      pass = "verdict=PASS" },
    @{ name = "cluster";    script = "run-cluster.ps1";   params = $null;                      pass = "verdict=PASS" },
    @{ name = "wan";        script = "run-wan.ps1";       params = $null;                      pass = "verdict=PASS" },
    @{ name = "linktype";   script = "run-linktype.ps1";  params = $null;                      pass = "CHANNEL_WARN" },
    @{ name = "crypto";     script = "run-crypto.ps1";    params = $null;                      pass = "SELFTEST_FAILS=0" },
    @{ name = "wpa";        script = "run-wpa.ps1";       params = @{ Scenario = "normal" };   pass = "verdict=PASS" },
    @{ name = "wpa-wrong";  script = "run-wpa.ps1";       params = @{ Scenario = "wrongpsk" }; pass = "verdict=PASS" },
    @{ name = "m3-shim";    script = "run-m3-shim.ps1";   params = $null;                      pass = "verdict=PASS" },
    @{ name = "m3-mon";     script = "run-m3-apps.ps1";   params = @{ Scenario = "mon" };      pass = "verdict=PASS" },
    @{ name = "m3-ftp";     script = "run-m3-apps.ps1";   params = @{ Scenario = "ftp" };      pass = "verdict=PASS" },
    @{ name = "m4-reload";  script = "run-m4.ps1";        params = @{ Scenario = "reload" };   pass = "verdict=PASS" },
    @{ name = "m4-panel";   script = "run-m4.ps1";        params = @{ Scenario = "panel" };    pass = "verdict=PASS" },
    @{ name = "m4-watchdog"; script = "run-m4.ps1";       params = @{ Scenario = "watchdog" }; pass = "verdict=PASS" },
    @{ name = "m2-pmtu";    script = "run-m2.ps1";        params = @{ Scenario = "pmtu" };     pass = "verdict=PASS" },
    @{ name = "m2-advert";  script = "run-m2.ps1";        params = @{ Scenario = "advert" };   pass = "verdict=PASS" },
    @{ name = "m2-fabfrag"; script = "run-m2.ps1";        params = @{ Scenario = "fabricfrag" }; pass = "verdict=PASS" },
    @{ name = "m2-channels"; script = "run-m2.ps1";       params = @{ Scenario = "channels" }; pass = "verdict=PASS" },
    @{ name = "conn";       script = "run-m3-apps.ps1";   params = @{ Scenario = "ftp"; FtpTransport = "conn"; DropEvery = 0 }; pass = "verdict=PASS" },
    @{ name = "conn-sec";   script = "run-m3-apps.ps1";   params = @{ Scenario = "ftp"; FtpTransport = "conn"; ConnSecure = "psk" }; pass = "verdict=PASS" },
    @{ name = "conn-sec-wrongpsk"; script = "run-m3-apps.ps1"; params = @{ Scenario = "ftp"; FtpTransport = "conn"; ConnSecure = "wrongpsk" }; pass = "verdict=PASS" },
    @{ name = "conn-loss";  script = "run-m3-apps.ps1";   params = @{ Scenario = "ftp"; FtpTransport = "conn"; DropEvery = 5 }; pass = "verdict=PASS" }
)

$selected = if ($Only -eq "") { $jobs } else {
    $want = $Only.Split(",") | ForEach-Object { $_.Trim() }
    $jobs | Where-Object { $want -contains $_.name }
}

$results = @()
foreach ($j in $selected) {
    $outFile = Join-Path $root ("poc\out\runall-" + $j.name + ".txt")
    $sb = [scriptblock]::Create((Get-Content (Join-Path $root ("poc\" + $j.script)) -Raw))
    $p = $j.params
    # one retry: with 20-40 emulators per job a neighbouring job's shutdown can starve
    # a run, and a genuine failure fails both attempts
    $ok = $false
    $attempts = 0
    while (-not $ok -and $attempts -lt 2) {
        $attempts++
        try {
            if ($p) { & $sb @p *> $outFile } else { & $sb *> $outFile }
        } catch {
            "HARNESS_EXCEPTION $_" | Set-Content $outFile
        }
        $text = if (Test-Path $outFile) { Get-Content $outFile -Raw } else { "" }
        $ok = $text -match [regex]::Escape($j.pass)
    }
    $results += [pscustomobject]@{ harness = $j.name; pass_marker = $j.pass; result = if ($ok) { "PASS" } else { "FAIL" } }
    "{0,-10} {1}{2}" -f $j.name, $results[-1].result, $(if ($attempts -gt 1) { " (retry $attempts)" } else { "" })
}

""
"===== summary ====="
$results | Format-Table -AutoSize | Out-String
$failed = @($results | Where-Object { $_.result -ne "PASS" }).Count
"TOTAL=$($results.Count) FAILED=$failed"
if ($failed -gt 0) { exit 1 }
