# What removable media can CraftOS-PC 2.8.3 actually provide? This probe exists
# because the disk acceptance script needs a real removable medium, and the
# emulator's answer is not the one CraftOS documents.
#
# Findings (run 2026-10-10, CraftOS-PC 2.8.3 + the locally built ccemux plugin):
#
#   periphemu.create(side, "drive")      works, every side, type="drive"
#   disk.eject / disk.isPresent          present
#   disk.getMountPath / disk.setLabel    present
#   disk.insert(side, path)              NIL -- a floppy image cannot be inserted
#   periphemu.insertDisk                 NIL
#
# So there is no image-file route: a drive peripheral exists but never holds a
# medium, and `disk.isPresent` stays false. The only route left to a medium is a
# plain directory at a path the shell treats as removable (/disk, /disk0, ...,
# see lib/disk.lua disk.sources()).
#
# That route has a real limitation which is worth knowing before trusting it as a
# stand-in for a floppy: those paths are PREFIXES, so a directory /disk2 answers
# `fs.exists("/disk" .. something)` as well as /disk does unless every path probe
# appends a separator. This probe prints the result for both spellings.
#
#   powershell.exe -NoProfile -ExecutionPolicy Bypass -File tools\rpv-verify\_ush-disk-probe.ps1
param(
    [string]$Work = "C:\Users\ymd10\AppData\Local\rpv-craftos\work\ush-disk-probe",
    [int]$TimeoutSec = 90
)
$exe = "C:\Program Files\CraftOS-PC\CraftOS-PC_console.exe"
if (Test-Path $Work) { Remove-Item $Work -Recurse -Force -ErrorAction SilentlyContinue }
$data = Join-Path $Work "craftos"
New-Item -ItemType Directory -Force -Path (Join-Path $data "config") | Out-Null
Set-Content -Path (Join-Path $data "config\global.json") -Encoding ascii -Value @'
{
    "computerSpaceLimit": 8000000,
    "clockSpeed": 20,
    "logErrors": false
}
'@
New-Item -ItemType Directory -Force -Path (Join-Path $data "computer\7") | Out-Null

$img = Join-Path $Work "blank.img"
[IO.File]::WriteAllBytes($img, (New-Object byte[] 1474560))
$dirMedium = Join-Path $Work "medium-dir"
New-Item -ItemType Directory -Force -Path $dirMedium | Out-Null
Set-Content -Path (Join-Path $dirMedium "hello.txt") -Encoding ascii -Value "on the medium"

$lua = @'
local function log(...)
    local parts = {}
    for i = 1, select("#", ...) do parts[#parts + 1] = tostring((select(i, ...))) end
    local f = fs.open("/probe.log", "a")
    f.writeLine(table.concat(parts, " "))
    f.close()
end
-- pcall returns (ok, value): the second value is what the call answered, not an
-- error, which the first version of this probe got wrong.
local function answered(fn, ...)
    local ok, val = pcall(fn, ...)
    if not ok then return "raised: " .. tostring(val) end
    return tostring(val)
end

log("disk.insert=" .. tostring(disk.insert) ..
    " disk.eject=" .. tostring(disk.eject ~= nil) ..
    " disk.isPresent=" .. tostring(disk.isPresent ~= nil) ..
    " disk.getMountPath=" .. tostring(disk.getMountPath ~= nil))
log("periphemu.insertDisk=" .. tostring(periphemu and periphemu.insertDisk))

log("--- a drive peripheral can be created ---")
local created = {}
for _, side in ipairs({ "left", "right", "top", "bottom", "front", "back" }) do
    if peripheral.getType(side) == nil then
        pcall(periphemu.create, side, "drive")
        created[#created + 1] = side
    end
end
for _, side in ipairs(created) do
    log("drive " .. side .. " type=" .. tostring(peripheral.getType(side)) ..
        " isPresent=" .. answered(disk.isPresent, side) ..
        " mount=" .. answered(disk.getMountPath, side))
end
if disk.insert then
    for _, side in ipairs(created) do
        log("disk.insert(" .. side .. ") = " .. answered(disk.insert, side, "/medium.img"))
    end
else
    log("no disk.insert: a drive peripheral can never hold a medium here")
end

log("--- a directory at a removable-looking path ---")
local okdir = fs.makeDir("/disk2")
fs.makeDir("/disk2/usr")
local f = fs.open("/disk2/marker", "w")
f.writeLine("here")
f.close()
log("made /disk2, exists=" .. tostring(fs.exists("/disk2")) ..
    " isDir=" .. tostring(fs.isDir("/disk2")))
log("the path is a prefix: fs.exists('/disk2') does NOT answer for '/disk'")
log("  exists('/disk')=" .. tostring(fs.exists("/disk")) ..
    " exists('/disk2')=" .. tostring(fs.exists("/disk2")))
package.path = package.path .. ";/lib/?.lua"
local okm, disks = pcall(require, "disk")
log("disk module ok=" .. tostring(okm) ..
    (okm and (" sources=" .. table.concat(disks.sources(), ",")) or (" err=" .. tostring(disks))))
if okm then
    for _, source in ipairs(disks.sources()) do
        log("  source " .. source .. " removable=" .. tostring(disks.removable(source)) ..
            " present=" .. tostring(disks.present(source)))
    end
    local mounted = { pcall(disks.scan) }
    log("scan ok=" .. tostring(mounted[1]) ..
        " report=" .. tostring(mounted[2] and table.concat(mounted[2], " | ") or mounted[2]))
end

local done = fs.open("/PROBE-DONE", "w")
done.writeLine("done")
done.close()
'@
Set-Content -Path (Join-Path $data "computer\7\startup.lua") -Value $lua -Encoding ascii
Copy-Item $img (Join-Path $data "computer\7\medium.img") -Force

$out = Join-Path $Work "emu.out.txt"
$err = Join-Path $Work "emu.err.txt"
$proc = Start-Process -FilePath $exe -ArgumentList @("-d", "`"$data`"", "--headless", "--id", "7") `
    -RedirectStandardOutput $out -RedirectStandardError $err -PassThru -NoNewWindow
$done = Join-Path $data "computer\7\PROBE-DONE"
$deadline = (Get-Date).AddSeconds($TimeoutSec)
while ((Get-Date) -lt $deadline) {
    Start-Sleep -Milliseconds 500
    if (Test-Path $done) { break }
    if ($proc.HasExited) { break }
}
Start-Sleep -Seconds 2
if (-not $proc.HasExited) { $proc.Kill() }
"----- probe.log -----"
$log = Join-Path $data "computer\7\probe.log"
if (Test-Path $log) { Get-Content $log } else { "(no probe.log)" }
"----- emulator stderr (tail) -----"
if (Test-Path $err) { Get-Content $err -Tail 10 }
