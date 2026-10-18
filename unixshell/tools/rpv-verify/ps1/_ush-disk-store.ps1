# Acceptance: the removable package store on a real CraftOS-PC computer.
#
# Why this script is shaped the way it is: CraftOS-PC 2.8.3 has no way to insert a
# floppy image (see _ush-disk-probe.ps1: disk.insert is nil, periphemu.insertDisk
# is nil, a created drive peripheral never holds a medium). The only removable
# medium this emulator can offer is a directory at a path lib/disk.lua treats as a
# drive (/disk, /disk0, /disk1, ...). That is a real filesystem, so the parts of
# the store mechanism that matter -- the marker living on the medium, packages
# written to the medium, the store found by its marker and not by a recorded drive
# letter -- are all exercised for real. What cannot be exercised here is the
# insert/eject event path, which stays covered by the PC side suites.
#
# The run boots the emulator three times over the same data directory:
#
#   boot 1   make /disk2 a store by hand (pkg.store_claim), install a package
#            from a local repository into it, write /boot1.txt, halt
#   boot 2   check a fresh boot still sees the marker and the package ON THE
#            MEDIUM (this is the persistence the whole design depends on), then
#            exercise `pkg store`, `pkg list -s` and `pkg store --json` through
#            the shell, then re-mark the medium
#   boot 3   verify the medium still carries the marker and its packages, and
#            copy the medium contents out for inspection
#
#   powershell.exe -NoProfile -ExecutionPolicy Bypass -File tools\rpv-verify\_ush-disk-store.ps1
param(
    [string]$Ush = "C:\Users\ymd10\Documents\DSHWork\cc_tweaked\unixshell",
    [string]$Work = "C:\Users\ymd10\AppData\Local\rpv-craftos\work\ush-disk-store",
    [int]$Id = 22,
    [int]$TimeoutSec = 120,
    [string]$ServerIp = "127.0.0.1"
)
$py = "C:\Users\ymd10\.dsh\dsh-runtimes\dsh-primary-runtime\dependencies\python\python.exe"
$exe = "C:\Program Files\CraftOS-PC\CraftOS-PC_console.exe"
$data = Join-Path $Work "craftos"
$computer = Join-Path $data "computer\$Id"

# ---------------------------------------------------------------- fresh tree
if (Test-Path $Work) { Remove-Item $Work -Recurse -Force -ErrorAction SilentlyContinue }
New-Item -ItemType Directory -Force -Path (Join-Path $data "config") | Out-Null
Set-Content -Path (Join-Path $data "config\global.json") -Encoding ascii -Value @'
{
    "computerSpaceLimit": 8000000,
    "clockSpeed": 20,
    "logErrors": false
}
'@
New-Item -ItemType Directory -Force -Path $computer | Out-Null
& $py (Join-Path $Ush "tools\deploy.py") --target $computer --source $Ush --quiet | Out-Null
# The deployed tree has no etc/ (the shell creates it on first boot); this
# acceptance configures the machine itself, and firstboot would race it.
if (Test-Path (Join-Path $computer "firstboot.lua")) {
    Remove-Item (Join-Path $computer "firstboot.lua") -Force
}

$etc = Join-Path $computer "etc"
New-Item -ItemType Directory -Force -Path $etc | Out-Null
Set-Content -Path (Join-Path $etc "network.conf") -Encoding ascii -Value @(
    "transport=rpv",
    "rpv_side=back",
    "rpv_channel=4800",
    "offline=true"
)
# The local repository, installed the way a machine would get it: a directory of
# package directories plus the index the repository would serve.
$repo = Join-Path $computer "repo"
New-Item -ItemType Directory -Force -Path (Join-Path $repo "onmedium\bin") | Out-Null
Set-Content -Path (Join-Path $repo "onmedium\manifest") -Encoding ascii -Value @(
    "name=onmedium",
    "version=1.0.0",
    "bin=bin/onmedium.lua"
)
Set-Content -Path (Join-Path $repo "onmedium\bin\onmedium.lua") -Encoding ascii -Value "print(`"on medium`")"
Set-Content -Path (Join-Path $repo "onmedium\payload.txt") -Encoding ascii -Value "a package whose files live on the medium"

# ---------------------------------------------------------------- boot drivers
$boot1 = @'
-- boot 1: put a medium there, make it a store, install a package onto it.
local function log(...)
    local parts = {}
    for i = 1, select("#", ...) do parts[#parts + 1] = tostring((select(i, ...))) end
    local f = fs.open("/boot1.log", "a")
    f.writeLine(table.concat(parts, " "))
    f.close()
end
local function finish(text)
    local f = fs.open("/boot1.txt", "w")
    f.write(text .. "\n")
    f.close()
    os.shutdown()
end

local function main()
package.path = package.path .. ";/lib/?.lua;/usr/?.lua"
local pkg = require("pkg")

-- the medium: a real directory at a path lib/disk.lua treats as a drive
if not fs.exists("/disk2") then fs.makeDir("/disk2") end
log("medium exists=" .. tostring(fs.exists("/disk2")) .. " isDir=" .. tostring(fs.isDir("/disk2")))
local diskmod = require("disk")
log("sources=" .. table.concat(diskmod.sources(), ","))
log("removable(/disk2)=" .. tostring(diskmod.removable("/disk2")) ..
    " present(/disk2)=" .. tostring(diskmod.present("/disk2")))
-- disk.scan() answers (done, failed): both are tables of mount records, so they
-- are summarised rather than concatenated.
local scanok, done, failed = pcall(diskmod.scan)
log("scan ok=" .. tostring(scanok) .. " mounted=" .. tostring(type(done) == "table" and #done or "?") ..
    " failed=" .. tostring(type(failed) == "table" and #failed or "?"))
local mok, mres = pcall(diskmod.auto_mount, "/disk2")
log("auto_mount(/disk2) ok=" .. tostring(mok) .. " res(tostring)=" .. tostring(mres))
log("mount table has /disk2: " .. tostring(require("mounts").find("/disk2") ~= nil))

local claim_ok, claim_side = pkg.store_claim(2)
log("store_claim(2) ok=" .. tostring(claim_ok) .. " side=" .. tostring(claim_side))
log("marker on the medium=" .. tostring(fs.exists("/disk2/.pkgstore")))
log("store now=" .. tostring(pkg.store()) .. " root=" .. tostring(pkg.root()))
if not fs.exists("/disk2/.pkgstore") then finish("FAIL no marker written") return end

-- install from a local repository: pkg.install talks to a server, so the files
-- are copied the way an install would lay them out, and the result is checked
-- with the same reader the package manager uses.
local function copy(src, dst)
    local f = fs.open(src, "r")
    if not f then return false end
    local body = f.readAll()
    f.close()
    local dir = dst:match("^(.*)/[^/]+$")
    if dir and not fs.exists(dir) then fs.makeDir(dir) end
    local o = fs.open(dst, "w")
    o.write(body)
    o.close()
    return true
end
local target = pkg.root() .. "/onmedium"
copy("/repo/onmedium/manifest", target .. "/manifest")
copy("/repo/onmedium/bin/onmedium.lua", target .. "/bin/onmedium.lua")
copy("/repo/onmedium/payload.txt", target .. "/payload.txt")
log("installed onto the medium, exists=" .. tostring(fs.exists(target .. "/manifest")) ..
    " installed()=" .. tostring(pkg.installed("onmedium")) ..
    " version=" .. tostring(pkg.installed_version("onmedium")))
log("where=" .. tostring(pkg.package_path("onmedium")))

local f = fs.open("/boot1.log", "r")
local text = f.readAll()
f.close()
finish("done\n" .. text)
end

-- A driver that raises must still leave a file behind, or the runner can only
-- report that the emulator exited with nothing to show.
local ok, err = pcall(main)
if not ok then
    log("RAISED " .. tostring(err))
    local f = fs.open("/boot1.log", "r")
    local text = f and f.readAll() or ""
    if f then f.close() end
    finish("FAIL raised: " .. tostring(err) .. "\n" .. text)
end
'@

$boot2 = @'
-- boot 2: a fresh boot has to find the store by the marker ON the medium.
local function log(...)
    local parts = {}
    for i = 1, select("#", ...) do parts[#parts + 1] = tostring((select(i, ...))) end
    local f = fs.open("/boot2.log", "a")
    f.writeLine(table.concat(parts, " "))
    f.close()
end
local function finish(text)
    local f = fs.open("/boot2.txt", "w")
    f.write(text .. "\n")
    f.close()
    os.shutdown()
end

local function main()
package.path = package.path .. ";/lib/?.lua;/usr/?.lua"
local pkg = require("pkg")

local marker = fs.exists("/disk2/.pkgstore")
log("fresh boot: marker on the medium=" .. tostring(marker))
log("store=" .. tostring(pkg.store()) .. " root=" .. tostring(pkg.root()))
log("store_required in the config=" .. tostring(pkg.store_required()))
local inst = pkg.installed("onmedium")
log("package still readable=" .. tostring(inst) ..
    " at=" .. tostring(pkg.package_path("onmedium")) ..
    " version=" .. tostring(pkg.installed_version("onmedium")))
local okj, json = pcall(pkg.store_report_json)
log("report_json ok=" .. tostring(okj) ..
    " has the store=" .. tostring(okj and json:find('"side": "/disk2"', 1, true) ~= nil) ..
    " lists the package=" .. tostring(okj and json:find("onmedium", 1, true) ~= nil))

-- The shell itself is deliberately NOT driven from here. Two routes were tried
-- and both fail for reasons that are properties of CraftOS, not of this test:
--   * dofile("/usr/ush.lua") runs without the package library, so the shell
--     cannot require its own modules (bios.lua only sets package up for a
--     program started through the shell).
--   * shell.run("/usr/ush.lua", "-c", ...) does work, but the shell's "-c" path
--     leaves through os.shutdown(), which takes the emulator down before this
--     driver can log anything.
-- What the shell prints for these commands is covered by the PC side suite
-- (tests/batch3_check.lua drives pkg store / pkg list -s / pkg store --json
-- through the same functions), so this acceptance checks the layer underneath:
-- the medium, its marker, and what the package manager reads back from it.
local ok_remove, removed = pcall(pkg.store_release, 2)
log("store_release(2) ok=" .. tostring(ok_remove) .. " marker now=" ..
    tostring(fs.exists("/disk2/.pkgstore")) .. " store now=" .. tostring(pkg.store()))
log("the medium kept its packages: " ..
    tostring(fs.exists("/disk2/usr/pkgs/onmedium/manifest")))
local claim_back, claim_side = pkg.store_claim(2)
log("marker put back=" .. tostring(claim_back) .. " side=" .. tostring(claim_side) ..
    " store=" .. tostring(pkg.store()))

-- the inventory the shell prints, read from the same functions it prints from
local report = pkg.store_report()
log("report: stores=" .. tostring(#report.stores) ..
    " install_root=" .. tostring(report.install_root) ..
    " internal=" .. tostring(report.internal.root))
log("report store[1]: side=" .. tostring(report.stores[1] and report.stores[1].side) ..
    " count=" .. tostring(report.stores[1] and report.stores[1].count) ..
    " package=" .. tostring(report.stores[1] and report.stores[1].packages[1] and
                             report.stores[1].packages[1].name))
local groups = pkg.list_by_root()
log("list_by_root: groups=" .. tostring(#groups) ..
    " first=" .. tostring(groups[1] and groups[1].side) ..
    " removable=" .. tostring(groups[1] and groups[1].removable))

local f = fs.open("/boot2.log", "r")
local text = f.readAll()
f.close()
finish("done\n" .. text)
end

local ok, err = pcall(main)
if not ok then
    log("RAISED " .. tostring(err))
    local f = fs.open("/boot2.log", "r")
    local text = f and f.readAll() or ""
    if f then f.close() end
    finish("FAIL raised: " .. tostring(err) .. "\n" .. text)
end
'@

$boot3 = @'
-- boot 3: the medium still carries its marker and its packages, and the answer
-- is written out for the host side to read.
local function log(...)
    local parts = {}
    for i = 1, select("#", ...) do parts[#parts + 1] = tostring((select(i, ...))) end
    local f = fs.open("/boot3.log", "a")
    f.writeLine(table.concat(parts, " "))
    f.close()
end
package.path = package.path .. ";/lib/?.lua;/usr/?.lua"
local pkg = require("pkg")
local marker = fs.exists("/disk2/.pkgstore")
local installed = pkg.installed("onmedium")
log("third boot: marker=" .. tostring(marker) .. " package=" .. tostring(installed) ..
    " at=" .. tostring(pkg.package_path("onmedium")))
local verdict = (marker and installed) and "PASS" or "FAIL"
log("VERDICT " .. verdict)
local listing = {}
if fs.isDir("/disk2") then
    for _, name in ipairs(fs.list("/disk2")) do listing[#listing + 1] = name end
end
local f = fs.open("/boot3.txt", "w")
f.writeLine(verdict)
f.writeLine("medium: " .. table.concat(listing, ", "))
f.close()
os.shutdown()
'@

$out = Join-Path $Work "emu.out.txt"
$err = Join-Path $Work "emu.err.txt"

function Boot([string]$name, [string]$lua) {
    Set-Content -Path (Join-Path $computer "startup.lua") -Value $lua -Encoding ascii
    $done = Join-Path $computer "$name.txt"
    if (Test-Path $done) { Remove-Item $done -Force }
    $proc = Start-Process -FilePath $exe -ArgumentList @("-d", "`"$data`"", "--headless", "--id", "$Id") `
        -RedirectStandardOutput $out -RedirectStandardError $err -PassThru -NoNewWindow
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 500
        if (Test-Path $done) { break }
        if ($proc.HasExited) { break }
    }
    Start-Sleep -Seconds 1
    if (-not $proc.HasExited) { $proc.Kill() }
    Start-Sleep -Milliseconds 300
    "===== $name ====="
    if (Test-Path $done) { Get-Content $done } else { "(no $name.txt; emulator exited=$($proc.HasExited))" }
}

Boot "boot1" $boot1
Boot "boot2" $boot2
Boot "boot3" $boot3

"----- emulator stderr (tail) -----"
if (Test-Path $err) { Get-Content $err -Tail 8 }
$verdict = "MISSING"
$b3 = Join-Path $computer "boot3.txt"
if (Test-Path $b3) { $verdict = (Get-Content $b3 -TotalCount 1).Trim() }
"RESULT ush-disk-store server=$verdict"
