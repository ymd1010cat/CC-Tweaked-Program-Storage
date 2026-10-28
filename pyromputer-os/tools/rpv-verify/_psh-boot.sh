#!/usr/bin/env bash
# The BOOT acceptance: does the machine really start the session command that
# /etc/session.conf names, and does leaving that session really land on psh?
#
# WHY THIS SCRIPT EXISTS, AND WHY IT IS NOT A SIBLING OF _psh-desktop.sh
#   Every other acceptance replaces the computer's /startup.lua with a probe, so
#   startup.lua's session_command() -- the reader of /etc/session.conf, the other
#   half of 'desktop --autostart' -- has never actually run on a machine: it was
#   only pinned as source text in tests/batch10_check.lua. This script does the
#   opposite. It deploys the project's own tree with tools/deploy.py --with-etc, so
#   /startup.lua on the computer IS the real one (asserted byte for byte below),
#   writes /etc/session.conf the way 'desktop --autostart on' would, and boots.
#
# HOW THE SCREEN IS READ WITHOUT term.getLine
#   term.getLine does not exist on CraftOS-PC 2.8.3 (measured), and a real boot
#   cannot be driven by a rewritten startup.lua. What CAN be used is --script FILE:
#   CraftOS-PC runs that file ONCE, before /startup.lua, in the same Lua state. The
#   observer left by this script does two things and then gets out of the way:
#     * it wraps term.write and term.blit, so every string the boot paints is
#       recorded with its cursor row and column, its foreground and its background.
#       That is how "the panel says Activities at row 1 column 1" and "the dock
#       shows >_ at row 2 column 1" are asserted as CELLS.
#     * it wraps os.pullEvent/os.pullEventRaw, and once the desktop has been seen
#       it queues ONE F10 key event -- the keystroke an operator uses to leave
#       the desktop. A headless machine's stdin is NOT a keyboard (measured: piped
#       characters produce no char events), so an event queued from inside the
#       machine is the only way to type into it.
#   The journal goes to a host directory mounted at /disk3, so this script can read
#   it while the machine is still running and stop as soon as the observer says the
#   expected picture has been painted.
#
# TWO BOOTS, ONE MACHINE (the second is a reboot of the first)
#   1. NO /etc/session.conf: the boot must land on psh -- the banner and the prompt
#      are on the screen, and the desktop was never drawn.
#   2. command=desktop: the boot must draw the desktop first (panel and dock
#      asserted from cells), then the F10 leaves it, and psh follows.
#
# WHAT IS PRE-STAGED, AND WHY
#   A headless boot has no keyboard, so it cannot run 'pkg install gnome'. The
#   package is therefore copied into /usr/pkgs with the bins registry the installer
#   would have written; the INSTALL path is _psh-desktop.sh's subject, and this
#   script is about the boot reading the one key. The setup marker (there is no
#   licence server any more) is written by the same observer, because firstboot
#
# WHY ONE COMPUTER AND NO SERVER
#   Nothing here is fetched: the tree is deployed, the package staged, the key
#   written. Unlike _psh-desktop.sh there is no second computer -- the question is
#   what ONE machine does when it powers on.
#
# USAGE
#   bash tools/rpv-verify/_psh-boot.sh
#
# Environment: PSH (project root), or the repository containing this script.
set -u
PSH="${PSH:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
PY="${PY:-/c/Users/ymd10/.dsh/dsh-runtimes/dsh-primary-runtime/dependencies/python/python.exe}"
EXE="${EXE:-/c/Program Files/CraftOS-PC/CraftOS-PC_console.exe}"
WORK="${WORK:-/c/Users/ymd10/AppData/Local/rpv-craftos/work/psh-boot}"
ID="${ID:-41}"
PKG="${PKG:-gnome}"
# The deployed tree is about 1.3 MB and the staged package sits on top of it; the
# limit is raised so one computer can hold both. This acceptance is not about the
# 1 MB machine (tools/twopart.py is).
LIMIT=8000000
PYW() { cygpath -w "$1"; }

rm -rf "$WORK"; mkdir -p "$WORK"
DATA="$WORK/data"
COMP="$DATA/computer/$ID"
WATCH="$WORK/watch"
RESULT="$COMP/boot-result"
SRC="$PSH/tools/pkgs/$PKG"
mkdir -p "$DATA/config" "$COMP" "$WATCH"
if [ ! -f "$SRC/manifest" ]; then
    echo "error: no package source at $SRC (expected tools/pkgs/$PKG/manifest)" >&2
    exit 1
fi
printf '{ "computerSpaceLimit": %d, "clockSpeed": 20, "logErrors": true }\n' "$LIMIT" \
    > "$DATA/config/global.json"

# ---- 1. the real tree ---------------------------------------------------------
echo "=== the machine: the project's own tree, deployed with --with-etc ==="
"$PY" "$(PYW "$PSH/tools/deploy.py")" --target "$(PYW "$COMP")" --with-etc >/dev/null 2>&1
if [ "$?" -ne 0 ] || [ ! -f "$COMP/startup.lua" ]; then
    echo "RESULT psh-boot=PASS boot=FAIL (deploy.py did not write a startup.lua)"
    exit 1
fi
if cmp -s "$PSH/startup.lua" "$COMP/startup.lua"; then
    echo "  ok   /startup.lua on the machine is the project's own file, byte for byte"
    REAL_STARTUP=1
else
    echo "  FAIL /startup.lua differs from the project's own file"
    REAL_STARTUP=0
fi
printf '  deployed %d B, %d files\n' \
    "$(find "$COMP" -type f -printf '%s\n' | awk '{s+=$1} END {print s+0}')" \
    "$(find "$COMP" -type f | wc -l)"

# The offline machine: no update server on a headless boot. This is the same
# setting an operator with no network uses, not a test hook.
sed -i 's/^offline=.*/offline=true/' "$COMP/etc/network.conf"
printf '  /etc/network.conf offline=true (no update server on a headless boot)\n'
grep -q '^offline=true' "$COMP/etc/network.conf" \
    && echo "  ok   the machine is configured to run without an update server" \
    || { echo "  FAIL /etc/network.conf does not say offline=true"; REAL_STARTUP=0; }

# ---- 2. the package, pre-staged (see the header) ------------------------------
mkdir -p "$COMP/usr/pkgs/$PKG" "$COMP/var/lib/pkg"
cp -a "$SRC/." "$COMP/usr/pkgs/$PKG/"
printf '{ %s = { "desktop" } }\n' "$PKG" > "$COMP/var/lib/pkg/bins"
printf '  staged the %s package in /usr/pkgs (a headless boot cannot run pkg install)\n' "$PKG"

# ---- 3. the observer ----------------------------------------------------------
# Runs before /startup.lua, from --script. It inherits this machine's Lua state and
# leaves wrappers behind, which is exactly what lets a REAL startup.lua be watched.
PRE="$WORK/observer.lua"
cat > "$PRE" <<'LUA'
local phase = ... or "boot"
local mount = "/disk3"
local function mark(s)
    local line = tostring(s)
    local ok = pcall(function()
        local f = fs.open(mount .. "/journal-" .. phase .. ".txt", "a")
        if f then f.writeLine(line); f.flush(); f.close() end
    end)
    if not ok then
        local f = fs.open("/boot-journal-" .. phase .. ".txt", "a")
        if f then f.writeLine(line); f.flush(); f.close() end
    end
end
local t0 = os.epoch("utc")
mark("SPY start phase=" .. tostring(phase))
-- The SETUP marker firstboot would otherwise run for: the observer runs before
-- /startup.lua, which is the only moment it can be written. There is no licence
-- server any more; the marker only says that this machine has been set up.
package.path = "/lib/?.lua;/usr/?.lua;" .. package.path
local ok_marker, marker = pcall(require, "marker")
local stamped = false
if ok_marker and type(marker) == "table" then
    local ok_write = pcall(marker.write, { computerId = tostring(os.getComputerID()) })
    stamped = ok_write and marker.done() and true or false
    mark("SPY setup marker=" .. tostring(stamped))
end
local seen = {}
local nudged = 0
local pulls = 0
local done = false
local function remember(tag, text)
    if seen[tag] then return end
    seen[tag] = true
    mark("SAW " .. tag .. " t=" .. tostring(os.epoch("utc") - t0) .. " " .. tostring(text))
end
local real_write, real_blit = term.write, term.blit
-- The screen as the boot WROTE it, one character at a time: print() and write()
-- emit a sentence in pieces ("psh", " 1.0", " -", ...), so a matcher that only
-- looks at one call sees neither the banner nor the prompt. The tail is what makes
-- "the banner appeared" a fact about the screen rather than about a call.
local tail = ""
local function fed(text)
    tail = (tail .. tostring(text)):sub(-240)
    if not seen["psh-banner"] and tail:find("psh 1.0", 1, true) then
        remember("psh-banner", "text=[psh 1.0]")
    end
    if not seen["prompt"] and tail:find("@cc-", 1, true) and tail:find(":/$ ", 1, true) then
        remember("prompt", "text=[" .. tail:sub(-24) .. "]")
    end
end
local function finish()
    if done then return end
    if not seen["psh-banner"] then return end
    if not seen["prompt"] then return end
    if phase ~= "fresh" and not seen["panel"] then return end
    done = true
    mark("SPY DONE phase=" .. tostring(phase))
end
-- What a blit said, wherever it was seen. Since 1.7.7 the desktop draws on the
-- terminal OBJECT and not through the term API, so a wrapper on term.blit alone
-- no longer sees the desktop paint; the same recorder is installed on the native
-- object as well. Seeing a row twice is harmless: remember() keeps one tag.
local function note_blit(text, fg, bg, x, y)
    local s = tostring(text or "")
    if s:find("Activities", 1, true) then
        remember("panel", "row=" .. tostring(y) .. " col=" .. tostring(x) ..
                 " text=[" .. s .. "] fg=" .. tostring(fg) .. " bg=" .. tostring(bg))
    end
    -- The first row-2 blit of a boot can be the ROM's own clear (three spaces,
    -- black on white) long before the desktop exists, and remember() keeps only
    -- the first tag: wait for the dock's own glyphs instead of claiming the tag
    -- with a blank. >_ is the Terminal icon the dock draws at row 2 column 1.
    if y == 2 and x == 1 and s:sub(1, 2) == ">_" then
        remember("dock", "row=" .. tostring(y) .. " col=" .. tostring(x) ..
                 " text=[" .. s:sub(1, 3) .. "] fg=" .. tostring(fg):sub(1, 3) ..
                 " bg=" .. tostring(bg):sub(1, 3))
    end
end
term.write = function(text, ...)
    local x, y = term.getCursorPos()
    fed(text)
    local r = real_write(text, ...)
    finish()
    return r
end
if real_blit then
    term.blit = function(text, fg, bg)
        local x, y = term.getCursorPos()
        note_blit(text, fg, bg, x, y)
        local r = real_blit(text, fg, bg)
        finish()
        return r
    end
end
-- The terminal object the desktop binds its screen to (term.current()); wrapping
-- it is what keeps this observer honest after that change.
local native = (type(term.native) == "function") and term.native() or nil
if type(native) == "table" and native ~= term then
    local nwrite, nblit, npos = native.write, native.blit, native.getCursorPos
    if type(nwrite) == "function" then
        native.write = function(text, ...)
            fed(text)
            local r = nwrite(text, ...)
            return r
        end
    end
    if type(nblit) == "function" then
        native.blit = function(text, fg, bg)
            local x, y = 1, 1
            if type(npos) == "function" then
                local okp, px, py = pcall(npos, native)
                if okp then x, y = px, py end
            end
            note_blit(text, fg, bg, x, y)
            local r = nblit(text, fg, bg)
            finish()
            return r
        end
    end
end
local real_pull, real_raw = os.pullEvent, os.pullEventRaw
-- One nudge, from inside the machine: once the desktop has painted, queue F10.
-- A desktop with no windows leaves on the first F10 (its back-out ladder).
local function act()
    pulls = pulls + 1
    if not seen["panel"] then return end
    if seen["psh-banner"] then return end
    if nudged >= 1 then return end
    if nudged == 0 and pulls > 0 then
        nudged = 1
        mark("SPY queued f10 t=" .. tostring(os.epoch("utc") - t0))
        os.queueEvent("key", 68)
    end
    finish()
end
os.pullEvent = function(...)
    act()
    local a, b, c, d, e = real_pull(...)
    act()
    return a, b, c, d, e
end
os.pullEventRaw = function(...)
    act()
    local a, b, c, d, e = real_raw(...)
    act()
    return a, b, c, d, e
end
mark("SPY armed")
LUA

boot_phase() {  # phase, seconds-to-wait
    local phase="$1" limit="$2"
    local out="$WORK/stdout-$phase.txt"
    local journal="$WATCH/journal-$phase.txt"
    rm -f "$journal"
    echo "=== boot: $phase ==="
    "$EXE" -d "$(PYW "$DATA")" --headless --id "$ID" \
        --script "$(PYW "$PRE")" --args "$phase" \
        --mount-rw "/disk3=$(PYW "$WATCH")" >"$out" 2>"$WORK/stderr-$phase.txt" &
    local pid=$!
    local i
    for i in $(seq 1 "$((limit * 2))"); do
        [ -f "$journal" ] && grep -q "SPY DONE" "$journal" && break
        sleep 0.5
    done
    sleep 1
    kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
    printf '  journal: %s\n' "$(basename "$journal")"
    sed 's/^/    /' "$journal" 2>/dev/null | head -20
    echo
}

# ---- 4. boot one: the default (no session.conf) ------------------------------
rm -f "$COMP/etc/session.conf"
NO_CONF=0
[ ! -f "$COMP/etc/session.conf" ] && NO_CONF=1
boot_phase fresh 90
J1="$WATCH/journal-fresh.txt"
O1="$WORK/stdout-fresh.txt"

# ---- 5. boot two: the same key 'desktop --autostart on' writes ----------------
mkdir -p "$COMP/etc"
printf 'command=desktop\n' > "$COMP/etc/session.conf"
printf '  /etc/session.conf written: %s\n' "$(cat "$COMP/etc/session.conf")"
boot_phase autostart 90
J2="$WATCH/journal-autostart.txt"
O2="$WORK/stdout-autostart.txt"

# ---- 6. verdict --------------------------------------------------------------
fail=0
ok()  { printf '  ok   %s\n' "$1"; }
bad() { printf '  FAIL %s%s\n' "$1" "${2:+ ($2)}"; fail=$((fail + 1)); }
has() {  # file, literal, label
    if grep -qF "$2" "$1"; then ok "$3"; else bad "$3" "not in $(basename "$1")"; fi
}
hasnt() {
    if grep -qF "$2" "$1"; then bad "$3" "found in $(basename "$1")"; else ok "$3"; fi
}
# The line an event appears on: the boot's ORDER is the claim ("the desktop first,
# then psh"), so the numbers are compared rather than both substrings found.
line_of() { grep -nF "$2" "$1" | head -1 | cut -d: -f1; }
# One field out of a journal mark: "SAW panel row=1 col=1 text=[...]" -> row=1.
mark_field() {  # journal, tag, key -> the key=.. token of the first match
    grep -F "SAW $2 " "$1" 2>/dev/null | head -1 | tr ' ' '\n' | grep -m1 "^$3=" | cut -d= -f2-
}
journal_of() {  # the journal, from the mounted host directory or the computer's disk
    if [ -f "$1" ]; then echo "$1"; else echo "$COMP/boot-journal-$(basename "$1" | sed 's/^journal-//')"; fi
}
J1="$(journal_of "$J1")"; J2="$(journal_of "$J2")"

echo "=== verdict ==="
if [ "$REAL_STARTUP" -eq 1 ]; then
    ok "the machine boots its own /startup.lua (deployed, byte for byte identical)"
else
    bad "the machine boots its own /startup.lua" "a substitute was found"
fi
if [ "$NO_CONF" -eq 1 ]; then
    ok "boot one has no /etc/session.conf, so nothing can name a session command"
else
    bad "boot one has no /etc/session.conf" "the file was there"
fi

# 1. the default boot lands on psh, and never draws the desktop
has "$J1" "SPY setup marker=true" "the observer wrote the setup marker before the gate"
has "$J1" "SAW psh-banner" "the boot reaches psh, which prints its banner"
has "$J1" "SAW prompt" "and psh draws its prompt on the screen"
has "$O1" "psh 1.0 - type 'help' for commands" "the terminal really shows the psh banner"
hasnt "$J1" "SAW panel" "the desktop was never started by this boot"
hasnt "$O1" "Activities" "and no desktop panel was ever painted"
hasnt "$O1" "starting the session command" "the boot read no session command: the machine boots into the shell"

# 2. command=desktop: the desktop comes up first
has "$O2" "starting the session command: desktop" "with command=desktop the boot script reads the key and runs it through psh"
PANEL_ROW="$(mark_field "$J2" panel row)"
PANEL_COL="$(mark_field "$J2" panel col)"
if [ "$PANEL_ROW" = "1" ] && [ "$PANEL_COL" = "1" ]; then
    ok "the desktop panel is painted at row 1 column 1 (Activities)"
else
    bad "the desktop panel is painted at row 1 column 1" "got row=${PANEL_ROW:-none} col=${PANEL_COL:-none}"
fi
has "$J2" "text=[Activities" "the panel's first cells are the word Activities"
has "$J2" "[psh]" "the panel's status area is painted too"
if [ "$(mark_field "$J2" panel fg)" != "" ] && [ "$(mark_field "$J2" panel bg)" != "" ]; then
    ok "the panel's cells carry a foreground AND a background colour"
else
    bad "the panel's cells carry colours" "the journal has no fg/bg"
fi
DOCK_ROW="$(mark_field "$J2" dock row)"
if [ "$DOCK_ROW" = "2" ] && grep -qF "SAW dock" "$J2" && grep -qF "text=[>_ ]" "$J2"; then
    ok "the dock is drawn down the left edge: >_ at row 2 column 1"
else
    bad "the dock is drawn down the left edge" "row=${DOCK_ROW:-none}: $(grep -F 'SAW dock' "$J2" | head -1)"
fi
has "$J2" "SAW dock" "the dock icon cells are on the screen, not only in a buffer"

# 3. leaving the desktop lands on psh
has "$J2" "SPY queued f10" "the observer sent the F10 an operator would press"
has "$O2" "desktop: left the desktop" "the desktop answers the F10 and leaves"
has "$O2" "the session ended; starting psh" "the boot script says the session ended and starts psh"
has "$J2" "SAW psh-banner" "psh then prints its banner"
has "$J2" "SAW prompt" "and its prompt"
has "$O2" "admin@cc-$ID" "the prompt names the account and this computer"
PANEL_LINE="$(line_of "$O2" "Activities")"
BANNER_LINE="$(line_of "$O2" "psh 1.0")"
if [ -n "$PANEL_LINE" ] && [ -n "$BANNER_LINE" ] && [ "$PANEL_LINE" -lt "$BANNER_LINE" ]; then
    ok "the order is the claim: the desktop painted before psh started (line $PANEL_LINE < $BANNER_LINE)"
else
    bad "the desktop painted before psh started" "panel line=${PANEL_LINE:-none} banner line=${BANNER_LINE:-none}"
fi
if grep -qF "SPY DONE" "$J1" && grep -qF "SPY DONE" "$J2"; then
    ok "both boots reached the picture they were supposed to reach"
else
    bad "both boots reached their expected picture" "a boot ran out of time"
fi
if grep -qF "PROBE ERROR" "$O1" "$O2" 2>/dev/null; then
    bad "neither boot raised inside the observer"
else
    ok "neither boot raised inside the observer"
fi

echo
if [ "$fail" -eq 0 ]; then
    echo "RESULT psh-boot=PASS"
    exit 0
fi
echo "RESULT psh-boot=FAIL ($fail check(s) failed)"
exit 1
