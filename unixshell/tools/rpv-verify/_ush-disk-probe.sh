#!/usr/bin/env bash
# What removable media can CraftOS-PC 2.8.3 actually provide? The disk acceptance script
# needs a real removable medium, and the emulator's answer is not the one CraftOS documents.
#
# Findings (first run 2026-10-10 on 2.8.3 with the locally built ccemux plugin):
#
#   periphemu.create(side, "drive")   works, every side, type="drive"
#   disk.eject / disk.isPresent       present
#   disk.getMountPath / disk.setLabel present
#   disk.insert(side, path)           NIL -- a floppy image cannot be inserted
#   periphemu.insertDisk              NIL
#
# So there is no image-file route: a drive peripheral exists but never holds a medium and
# disk.isPresent stays false. The only route left is a plain directory at a path the shell
# treats as removable (/disk, /disk0, ...). Those paths are PREFIXES, so /disk2 also answers
# for /disk unless a path probe appends a separator; the probe prints both spellings.
#
# Ported from ps1/_ush-disk-probe.ps1 with one deliberate change: the scratch computer is id
# 22 instead of 7, because this machine reserves 20-30 and 100-300 for this work.
set -u

TOOL_HOME="${RPV_TOOL_HOME:-/c/Users/ymd10/AppData/Local/rpv-craftos}"
WORK="${1:-$TOOL_HOME/work/ush-disk-probe}"
EXE="${CRAFTOS_EXE:-/c/Program Files/CraftOS-PC/CraftOS-PC_console.exe}"
COMPUTER="${COMPUTER:-22}"
TIMEOUT="${TIMEOUT:-90}"
DATA="$WORK/craftos"
DIR="$DATA/computer/$COMPUTER"

[ -f "$EXE" ] || { echo "error: emulator not found at $EXE" >&2; exit 1; }

rm -rf "$WORK"
mkdir -p "$DATA/config" "$DIR"
cat > "$DATA/config/global.json" <<'JSON'
{
    "computerSpaceLimit": 8000000,
    "clockSpeed": 20,
    "logErrors": false
}
JSON

# a blank 1440 KB floppy image, and a directory medium next to it
head -c 1474560 /dev/zero > "$WORK/blank.img"
mkdir -p "$WORK/medium-dir"
echo "on the medium" > "$WORK/medium-dir/hello.txt"
cp "$WORK/blank.img" "$DIR/medium.img"

cat > "$DIR/startup.lua" <<'LUA'
local function log(...)
    local parts = {}
    for i = 1, select("#", ...) do parts[#parts + 1] = tostring((select(i, ...))) end
    local f = fs.open("/probe.log", "a")
    f.writeLine(table.concat(parts, " "))
    f.close()
end
-- pcall returns (ok, value): the second value is what the call answered, not an error
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
fs.makeDir("/disk2")
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
LUA

"$EXE" -d "$(cygpath -w "$DATA")" --headless --id "$COMPUTER" \
    >"$WORK/emu.out.txt" 2>"$WORK/emu.err.txt" &
pid=$!
done_file="$DIR/PROBE-DONE"
deadline=$(( $(date +%s) + TIMEOUT ))
while [ "$(date +%s)" -lt "$deadline" ]; do
    sleep 1
    [ -f "$done_file" ] && break
    kill -0 "$pid" 2>/dev/null || break
done
sleep 2
kill "$pid" 2>/dev/null
wait "$pid" 2>/dev/null

echo "----- probe.log -----"
if [ -f "$DIR/probe.log" ]; then cat "$DIR/probe.log"; else echo "(no probe.log)"; fi
echo "----- emulator stderr (tail) -----"
[ -f "$WORK/emu.err.txt" ] && tail -10 "$WORK/emu.err.txt"
