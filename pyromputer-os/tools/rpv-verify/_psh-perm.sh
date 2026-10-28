#!/usr/bin/env bash
# Permission acceptance on CraftOS-PC: what an ordinary account may do to the
# machine's own files, what root may do, and what neither of them may do.
#
# WHAT THIS PROVES, AND WHY IT IS NOT THE PC SUITE
#   Three layers can refuse a write, and the suite tests each of them in a Lua
#   state:
#     * the shell's built-ins ask lib/perm.lua (the permission database and the
#       read-only system paths) and lib/protect.lua (the boot files);
#     * lib/osguard.lua wraps the machine's `fs` table at boot, so a program that
#       never goes through the shell is refused as well;
#     * lib/danger.lua refuses a recursive remove of the filesystem root or of a
#       system directory even when root asks for it.
#   The bug this script was written for was invisible in the suite: on a deployed
#   machine with no /etc/perm.db, perm.check answered true for every path. So this
#   runs a real boot, a real psh, real commands typed at its prompt, and it reads
#   the result back from the machine's own filesystem and from logs the machine
#   itself wrote.
#
# HOW THE COMMANDS ARE TYPED
#   --script runs before /startup.lua, in the same Lua state. The observer left by
#   this script wraps term.write (it sees what the machine paints, including the
#   danger blacklist's refusal text) and os.pullEvent/os.pullEventRaw (the shell's
#   line editor calls it once per event, and its one second idle timer guarantees
#   an event even with no input). A headless machine's stdin is NOT a keyboard
#   (measured: piped characters produce no char events), so a char event queued
#   from inside the machine is the only way to type into it. Every typed line
#   leaves a marker file of its own, and the next line is typed only once that
#   marker exists: the machine, not a clock, says when a command has finished, so
#   a command that never ran can never be reported as a refusal.
#
# WHAT IS NOT A JUDGE
#   The simulator's stdout is screen-diff output in which print() and write() land
#   one word at a time, so it is not evidence. Every verdict below comes from the
#   machine's filesystem (the host reads the deployed directory) or from a log the
#   machine wrote: /var/tmp/*.txt for statuses and command output, and the journal
#   on the mounted /disk3 for what the screen said (the observer dumps the screen
#   text it collected, so a refusal's wording is a fact about the machine).
#
# THE SCENARIOS
#   boot one, ordinary account (admin):
#     rm of the shell, rm of /etc/passwd, a redirect into /etc, touch in /usr,
#     mkdir in /etc, a copy of /etc/shadow out, and a write to an ordinary file at
#     the machine root; then a Lua program ON the machine exercises the guarded
#     `fs` table underneath the shell: fs.open("/usr/psh.lua", "a") must answer nil
#     and fs.delete("/etc/passwd") must answer false, while writing an ordinary
#     file must still succeed.
#   boot two, root:
#     touch in /usr and in /etc must work; rm -rf /, rm -rf /usr and sudo rm -rf /
#     must be refused with a reason and status 1 while /usr/psh.lua and /etc/passwd
#     keep their exact size; rm -rf /home/me must still delete an ordinary
#     directory; and the same guarded `fs` must now allow both calls of the probe.
#
# MEASURED PLATFORM FACTS THIS SCRIPT RELIES ON
#   * on CraftOS-PC 2.8.3 fs.delete and fs.makeDir return NOTHING when they work
#     (measured, like fs.makeDir in psh's mktemp note), so "root deleted the file"
#     is proven by the file being gone, not by a true return;
#   * the guard's own refusal IS visible in the return value: fs.delete answers
#     false and fs.open answers nil when the permission model says no;
#   * the ROM gives every program its OWN package table (rom/programs/shell.lua,
#     createShellEnv -> make_package), so lib/osguard.lua's module-local
#     "installed" flag belongs to one program environment even though the fs table
#     it wraps is global. The guard is therefore proven here by what the guarded
#     calls DO; asking osguard.installed() from another program answers false on a
#     machine where the guard is demonstrably installed;
#   * psh's print() writes a message word by word and never writes a newline
#     through term.write, so the screen is collected as one string and each
#     command's messages are copied into the journal when its marker appears.
#
# WART NOTES
#   The verdict is about the security properties, not about how tidy the messages
#   are. Warts this run reproduces are printed as "note" lines instead of being
#   asserted. The four this script was written for are FIXED, and the notes are
#   kept as a regression alarm, because each of them was invisible in the PC
#   suite: touch raised on a guarded path while run() reported no failing status,
#   mkdir answered 0 while creating nothing, cat worded a guarded open as "no such
#   file", and danger.lua reported a plain "rm -rf /usr" as a wildcard. A note
#   printing again means one of them came back.
#   * The second boot used to be a root boot only on paper: a console left as
#     root is handed back to the machine's level 1 account when the shell starts
#     (usr/psh.lua, console.claim), and the "root can create ..." checks passed
#     only because touch never asked the permission database. The run_boot below
#     now gives that account level 0 for the root phase, which is what leaves the
#     console on the account /etc/current_user names.
#
# USAGE
#   bash tools/rpv-verify/_psh-perm.sh
#
# Environment: PSH (project root), or the repository containing this script.
set -u
PSH="${PSH:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
PY="${PY:-/c/Users/ymd10/.dsh/dsh-runtimes/dsh-primary-runtime/dependencies/python/python.exe}"
EXE="${EXE:-/c/Program Files/CraftOS-PC/CraftOS-PC_console.exe}"
WORK="${WORK:-/c/Users/ymd10/AppData/Local/rpv-craftos/work/psh-perm}"
ID="${ID:-44}"
PYW() { cygpath -w "$1"; }
T0=$(date +%s)

rm -rf "$WORK"; mkdir -p "$WORK"
DATA="$WORK/data"
COMP="$DATA/computer/$ID"
OBS="$WORK/observer.lua"
WATCH="$WORK/watch"
fail=0
ok()  { printf '  ok   %s\n' "$1"; }
bad() { printf '  FAIL %s%s\n' "$1" "${2:+ ($2)}"; fail=$((fail + 1)); }

mkdir -p "$DATA/config" "$WATCH" "$COMP"
# The deployed tree is about 1.4 MB; the limit is raised so the machine can hold
# the logs and markers the commands write. The 1 MB machine is not the subject
# here (tools/twopart.py is).
printf '{ "computerSpaceLimit": 4000000, "clockSpeed": 20, "logErrors": true }\n' \
    > "$DATA/config/global.json"

# ---- the machine -------------------------------------------------------------
echo "=== the machine: the project's own tree ==="
"$PY" "$(PYW "$PSH/tools/deploy.py")" --target "$(PYW "$COMP")" --with-etc --quiet || {
    echo "deploy failed" >&2; exit 1; }
printf '  deployed %s B, %s files\n' \
    "$(find "$COMP" -type f -printf '%s\n' | awk '{s+=$1} END {print s+0}')" \
    "$(find "$COMP" -type f | wc -l)"

# ---- the fixtures the machine is expected to write into ----------------------
mkdir -p "$COMP/var/tmp" "$COMP/home/me"
printf 'doomed\n' > "$COMP/home/me/doomed.txt"
printf 'before\n' > "$COMP/ownfile.txt"
printf '  staged /var/tmp, /home/me and /ownfile.txt for the machine to write into\n'

# ---- the probe that runs ON the machine, not from the host -------------------
# lib/osguard.lua wraps the machine's `fs` table, so the only honest way to test
# it is a program that calls fs directly, after the shell has started. It records
# what the guarded calls answered, in a file the host reads afterwards.
cat > "$COMP/var/tmp/osguard.lua" <<'LUA'
-- Exercises the machine's guarded fs table from inside the machine.
local args = ...
local who = (args and args[1]) or "unknown"
local logpath = "/var/tmp/osguard-" .. who .. ".txt"
local out = fs.open(logpath, "w")
local function line(s)
    if out then out.writeLine(tostring(s)) end
end
line("who=" .. who)
line("who_seen=" .. tostring((type(args) == "table") and args[1] or "none"))
-- The write the permission model forbids for an ordinary account.
local h = fs.open("/usr/psh.lua", "a")
line("open_usr_psh=" .. ((h and "handle") or "nil"))
if h then h.close() end
-- What fs.delete answers, and whether the file really went away. On this ROM a
-- successful delete returns nothing, so the file's presence is the evidence.
local kept = nil
if who == "root" then
    local r = fs.open("/etc/passwd", "r")
    if r then kept = r.readAll(); r.close() end
end
local answer = fs.delete("/etc/passwd")
line("delete_passwd=" .. tostring(answer))
line("passwd_after=" .. tostring(fs.exists("/etc/passwd")))
if kept ~= nil and not fs.exists("/etc/passwd") then
    local w = fs.open("/etc/passwd", "w")
    local restored = false
    if w then w.write(kept); w.close(); restored = true end
    line("restored=" .. tostring(restored))
    line("passwd_bytes=" .. tostring(#kept))
end
-- An ordinary path must still be writable through the same guarded table.
local own = fs.open("/ownfile-probe.txt", "w")
line("write_own=" .. ((own and "handle") or "nil"))
if own then own.write("probe-" .. who .. "\n"); own.close() end
line("done=" .. who)
if out then out.close() end
return 0
LUA

# ---- the observer ------------------------------------------------------------
# It runs from --script, BEFORE /startup.lua, and leaves wrappers behind.
cat > "$OBS" <<'LUA'
local phase = ... or "admin"
local mount = "/disk3"
local JOURNAL = mount .. "/journal-" .. phase .. ".txt"
local FALLBACK = "/var/tmp/journal-" .. phase .. ".txt"
-- One journal line, on the mounted host directory when it is there, on the
-- machine's own disk otherwise. A line that cannot be written is not allowed to
-- take the observation down with it.
local function mark(s)
    local line = tostring(s)
    local wrote = false
    pcall(function()
        local f = fs.open(JOURNAL, "a")
        if f then f.writeLine(line); f.flush(); f.close(); wrote = true end
    end)
    if not wrote then
        pcall(function()
            local f = fs.open(FALLBACK, "a")
            if f then f.writeLine(line); f.flush(); f.close() end
        end)
    end
end
mark("SPY start phase=" .. tostring(phase))
package.path = "/lib/?.lua;/usr/?.lua;" .. package.path
-- The setup marker firstboot would otherwise run for: the observer runs before
-- /startup.lua, which is the only moment it can be written. A machine without it
-- boots into the setup program instead of the shell and no command is ever typed.
do
    local okm, marker = pcall(require, "marker")
    if okm and type(marker) == "table" then
        pcall(marker.write, { computerId = tostring(os.getComputerID()) })
        mark("SPY setup marker=" .. tostring(marker.done() and true or false))
    else
        mark("SPY setup marker=unavailable")
    end
end
local function size_of(p)
    local ok, s = pcall(function() return fs.getSize(p) end)
    if ok and s then return tostring(s) end
    return "?"
end
local sizes0 = { usr = size_of("/usr/psh.lua"), passwd = size_of("/etc/passwd") }
mark("SPY sizes0 usr=" .. sizes0.usr .. " passwd=" .. sizes0.passwd)
local function sizes1()
    local usr, passwd = size_of("/usr/psh.lua"), size_of("/etc/passwd")
    mark("SPY sizes1 usr=" .. usr .. " passwd=" .. passwd ..
         " same=" .. tostring(usr == sizes0.usr and passwd == sizes0.passwd))
end

-- What the machine painted, as one growing string: print() emits a sentence in
-- words, so a per-call matcher would see neither a message nor the prompt. The
-- text is kept whole (this ROM does not write newlines through term.write) and
-- every interesting message is copied into the journal AT THE MOMENT IT APPEARS,
-- with its surroundings -- the screen is mostly echoes of the typed commands, so
-- a dump taken at the end holds only the last few lines. That copy is what makes
-- "the refusal said why" a fact about the machine rather than about the
-- simulator's stdout.
local screen = ""
local carry = ""
local total = 0
local said = {}   -- label -> absolute offset of the occurrence last logged
local WATCHED = {
    { label = "refusal", text = "refusing" },
    { label = "denied", text = "permission denied" },
    { label = "bootfile", text = "boot file is protected" },
    { label = "runtime", text = "attempt to index" },
    { label = "catshadow", text = "cat: /etc/shadow" },
}
local function fold(s) return (s:gsub("[\r\n]+", "|")) end
local function feed(text)
    local s = tostring(text or "")
    screen = (screen .. s):sub(-4000)
    local window = carry .. s
    local base = total - #carry + 1
    for _, w in ipairs(WATCHED) do
        -- The LAST match in the window, not the first: a new refusal can arrive
        -- while an older one is still inside the carry, and the older one must not
        -- hide it.
        local at, i = nil, 1
        while true do
            local a = window:find(w.text, i, true)
            if not a then break end
            at = a
            i = a + 1
        end
        if at then
            -- The absolute offset is what makes one message be logged once: the
            -- window slides, so a position inside it does not identify anything.
            local abs_pos = base + at - 1
            if abs_pos > (said[w.label] or 0) then
                said[w.label] = abs_pos
                local from = math.max(1, at - 100)
                local to = math.min(#window, at + #w.text + 40)
                mark("HIT " .. w.label .. " [" .. fold(window:sub(from, to)) .. "]")
            end
        end
    end
    total = total + #s
    carry = (carry .. s):sub(-140)
end
local real_write = term.write
term.write = function(text, ...)
    local r = real_write(text, ...)
    feed(text)
    return r
end
local function dump_screen()
    mark("SCREEN [" .. fold(screen) .. "]")
end

local cmds
if phase == "admin" then
    cmds = {
        { tag = "rm-shell", cmd = "rm -f /usr/psh.lua > /var/tmp/rm-shell.txt 2>&1 ; echo status=$? > /var/tmp/m1.txt", marker = "/var/tmp/m1.txt" },
        { tag = "rm-passwd", cmd = "rm -f /etc/passwd > /var/tmp/rm-passwd.txt 2>&1 ; echo status=$? > /var/tmp/m1b.txt", marker = "/var/tmp/m1b.txt" },
        { tag = "redirect-etc", cmd = "echo X > /etc/permtest.txt ; echo status=$? > /var/tmp/m2.txt", marker = "/var/tmp/m2.txt" },
        -- The marker is written BEFORE the command: a built-in that raises takes
        -- the rest of its own line with it (measured: touch on a guarded path
        -- raises, usr/psh.lua:4225), so the marker of a crashing line has to be
        -- in front of it or the observation would wait for it forever.
        { tag = "touch-usr", cmd = "echo ran > /var/tmp/m3.txt ; touch /usr/permtest.txt", marker = "/var/tmp/m3.txt" },
        { tag = "touch-status", cmd = "echo status=$? > /var/tmp/m3b.txt", marker = "/var/tmp/m3b.txt" },
        { tag = "cat-shadow", cmd = "cat /etc/shadow > /var/tmp/leak.txt ; echo status=$? > /var/tmp/m4.txt", marker = "/var/tmp/m4.txt" },
        { tag = "mkdir-etc", cmd = "mkdir /etc/permtest.dir ; echo status=$? > /var/tmp/m5.txt", marker = "/var/tmp/m5.txt" },
        { tag = "write-own", cmd = "echo own > /ownfile.txt ; echo status=$? > /var/tmp/m6.txt", marker = "/var/tmp/m6.txt" },
        { tag = "osguard", cmd = "/var/tmp/osguard.lua admin", marker = "/var/tmp/osguard-admin.txt" },
    }
else
    cmds = {
        { tag = "touch-usr", cmd = "touch /usr/rootfile.txt ; echo status=$? > /var/tmp/r0.txt", marker = "/var/tmp/r0.txt" },
        { tag = "touch-etc", cmd = "touch /etc/rootfile.txt ; echo status=$? > /var/tmp/r0b.txt", marker = "/var/tmp/r0b.txt" },
        { tag = "rm-root", cmd = "rm -rf / ; echo status=$? > /var/tmp/r1.txt", marker = "/var/tmp/r1.txt" },
        { tag = "rm-usr", cmd = "rm -rf /usr ; echo status=$? > /var/tmp/r2.txt", marker = "/var/tmp/r2.txt" },
        { tag = "sudo-rm-root", cmd = "sudo rm -rf / ; echo status=$? > /var/tmp/r3.txt", marker = "/var/tmp/r3.txt" },
        { tag = "rm-home", cmd = "rm -rf /home/me ; echo status=$? > /var/tmp/r4.txt", marker = "/var/tmp/r4.txt", sizes = true },
        { tag = "osguard", cmd = "/var/tmp/osguard.lua root", marker = "/var/tmp/osguard-root.txt" },
    }
end
local idx, injected = 1, false
local pulls, prompt_seen, done = 0, false, false
local deadline = os.epoch("utc") + 120000
local function step()
    pulls = pulls + 1
    if done then return end
    -- The prompt of an ordinary account ends with "$", the superuser's with "#"
    -- (lib/theme.lua): the root boot has to be recognised too, or nothing is
    -- ever typed on it.
    if not prompt_seen and screen:find("@cc-", 1, true) and
       (screen:find(":/$ ", 1, true) or screen:find(":/# ", 1, true)) then
        prompt_seen = true
        mark("SAW prompt pulls=" .. pulls)
    end
    if os.epoch("utc") > deadline then
        mark("SPY TIMEOUT pulls=" .. pulls .. " next=" .. tostring(idx) ..
             " injected=" .. tostring(injected) .. " prompt=" .. tostring(prompt_seen))
        dump_screen()
        done = true
        os.shutdown()
        return
    end
    if not prompt_seen then
        if pulls % 60 == 0 then
            mark("SPY wait-prompt pulls=" .. pulls .. " screen=[" ..
                 screen:sub(-80):gsub("[\r\n]+", "|") .. "]")
        end
        return
    end
    if idx > #cmds then
        if fs.exists(cmds[#cmds].marker) then
            mark("SPY DONE phase=" .. tostring(phase) .. " commands=" .. #cmds ..
                 " pulls=" .. pulls)
            dump_screen()
            done = true
            os.shutdown()
        end
        return
    end
    local c = cmds[idx]
    if injected then
        if fs.exists(c.marker) then
            mark("SAW marker " .. idx .. " " .. c.tag)
            -- What the screen held when the command finished: the messages of a
            -- command ("refusing ...") are complete by then, while a HIT taken
            -- when the first word appeared would be cut off after it.
            mark("SEEN " .. c.tag .. " [" .. fold(screen:sub(-600)) .. "]")
            if c.sizes then sizes1() end
            injected = false
            idx = idx + 1
            step()
        end
    else
        mark("SPY inject " .. idx .. " " .. c.tag)
        for ch in c.cmd:gmatch(".") do os.queueEvent("char", ch) end
        os.queueEvent("key", 28)
        injected = true
    end
end
local real_pull, real_raw = os.pullEvent, os.pullEventRaw
os.pullEvent = function(...)
    step()
    local a, b, c, d, e = real_pull(...)
    step()
    return a, b, c, d, e
end
os.pullEventRaw = function(...)
    step()
    local a, b, c, d, e = real_raw(...)
    step()
    return a, b, c, d, e
end
mark("SPY armed")
LUA

# ---- one boot ----------------------------------------------------------------
journal_path() {  # phase -> the journal the machine wrote (mounted first)
    if [ -f "$WATCH/journal-$1.txt" ]; then
        printf '%s' "$WATCH/journal-$1.txt"
    else
        printf '%s' "$COMP/var/tmp/journal-$1.txt"
    fi
}

run_boot() {  # phase, seconds
    local who="$1" limit="${2:-90}"
    local journal="$WATCH/journal-$who.txt"
    local out="$WORK/stdout-$who.txt"
    local attempt i pid started
    printf '%s\n' "$who" > "$COMP/etc/current_user"
    # A console that was left as root is handed back to the machine's level 1
    # account when the shell starts (usr/psh.lua, console.claim), so the file
    # above is NOT enough to get a root session: on this boot the console came
    # up as admin. The "root can create ..." checks only passed because touch
    # did not ask the permission database and the guarded fs had cached root at
    # boot; the fix made touch ask, and they failed. What the claim looks for is
    # a NON root account of level 1, so giving admin level 0 leaves the console
    # as the account the file names.
    if [ "$who" = "root" ] && [ -f "$COMP/etc/passwd" ]; then
        sed -i 's/^admin:1:/admin:0:/' "$COMP/etc/passwd"
    fi
    rm -f "$journal" "$COMP/var/tmp/journal-$who.txt"
    for attempt in 1 2; do
        echo "=== boot: $who (attempt $attempt) ==="
        "$EXE" -d "$(PYW "$DATA")" --headless --id "$ID" \
            --script "$(PYW "$OBS")" --args "$who" \
            --mount-rw "/disk3=$(PYW "$WATCH")" > "$out" 2>&1 &
        pid=$!
        started=0
        for i in $(seq 1 40); do
            if [ -f "$(journal_path "$who")" ]; then started=1; break; fi
            sleep 0.5
        done
        if [ "$started" -eq 1 ]; then break; fi
        # Two CraftOS-PC processes do not share a data directory: a launch that
        # comes too soon after the previous one exits without running --script at
        # all (measured). Say so, and try once more after the machine is gone.
        printf '  the machine did not start (no journal); retrying after it exits\n'
        kill "$pid" 2>/dev/null
        wait "$pid" 2>/dev/null
        sleep 3
    done
    if [ "$started" -ne 1 ]; then
        printf '  FAIL the machine never started\n'
        fail=$((fail + 1))
        return
    fi
    for i in $(seq 1 "$((limit * 2))"); do
        grep -qE "SPY (DONE|TIMEOUT)" "$(journal_path "$who")" 2>/dev/null && break
        sleep 0.5
    done
    sleep 1
    kill "$pid" 2>/dev/null
    wait "$pid" 2>/dev/null
    sleep 2
    journal="$(journal_path "$who")"
    printf '  journal %s: %s inject lines, %s markers\n' "$(basename "$journal")" \
        "$(grep -c "SPY inject" "$journal" 2>/dev/null || true)" \
        "$(grep -c "SAW marker" "$journal" 2>/dev/null || true)"
}

# ---- small readers over the machine's own files ------------------------------
field() {  # file, key -> value of "key=..." on the first line that has it
    local f="$1" k="$2"
    [ -f "$f" ] || { printf 'absent'; return; }
    local v
    v="$(sed -n "s/^$k=//p" "$f" | head -1)"
    printf '%s' "${v:-absent}"
}
status_of() { field "$1" status; }
counted() {  # label-suffix file... -> how many of the files exist
    local n=0 f
    for f in "$@"; do [ -e "$f" ] && n=$((n + 1)); done
    printf '%s' "$n"
}
missing_of() {  # file... -> the basenames that are absent
    local out="" f
    for f in "$@"; do [ -e "$f" ] || out="$out $(basename "$f")"; done
    printf '%s' "$out"
}
has() {  # file, literal, label
    local f="$1" lit="$2" label="$3"
    if [ -f "$f" ] && grep -qF "$lit" "$f"; then ok "$label"
    else bad "$label" "$(basename "$f") does not contain [$lit]"; fi
}
has_re() {  # file, extended regex, label
    local f="$1" re="$2" label="$3"
    if [ -f "$f" ] && grep -qE "$re" "$f"; then ok "$label"
    else bad "$label" "$(basename "$f") does not match /$re/"; fi
}
note() { printf '  note %s\n' "$1"; }
# A journal lines that starts with "SCREEN [" holds the screen text the machine
# collected, newlines folded to "|", so one grep sees a whole message.
screen_tail() {  # journal -> the screen text, newlines folded
    sed -n 's/^SCREEN \[\(.*\)\]$/\1/p' "$1" 2>/dev/null | tail -1
}

T="$COMP/var/tmp"
MARKERS_ADMIN="$T/m1.txt $T/m1b.txt $T/m2.txt $T/m3.txt $T/m3b.txt $T/m4.txt $T/m5.txt $T/m6.txt $T/osguard-admin.txt"

# =============================================================================
echo
echo "=== boot one: an ordinary account (admin) ==="
# =============================================================================
run_boot admin 90
JA="$(journal_path admin)"

# shellcheck disable=SC2086
n="$(counted $MARKERS_ADMIN)"
# shellcheck disable=SC2086
if [ "$n" -eq 9 ]; then
    ok "the machine ran all 9 typed commands (each left a marker)"
else
    # shellcheck disable=SC2086
    bad "the machine ran all 9 typed commands" \
        "only $n/9 markers exist:$(missing_of $MARKERS_ADMIN)"
fi

[ -f "$COMP/usr/psh.lua" ] && ok "the shell itself is still there after rm /usr/psh.lua" \
    || bad "the shell itself is still there after rm /usr/psh.lua"
[ -f "$COMP/etc/passwd" ] && ok "/etc/passwd survived an ordinary account's rm" \
    || bad "/etc/passwd survived an ordinary account's rm"
has "$T/rm-shell.txt" "boot file is protected" \
    "removing the shell is refused with the boot-file reason (the machine's own file)"
has "$T/rm-passwd.txt" "/etc/passwd: permission denied" \
    "removing /etc/passwd is refused with 'permission denied' (the machine's own file)"
[ "$(status_of "$T/m1.txt")" = "1" ] && ok "rm of the shell reports status 1" \
    || bad "rm of the shell reports status 1" "status=$(status_of "$T/m1.txt")"
[ "$(status_of "$T/m1b.txt")" = "1" ] && ok "rm of /etc/passwd reports status 1" \
    || bad "rm of /etc/passwd reports status 1" "status=$(status_of "$T/m1b.txt")"

[ -e "$COMP/etc/permtest.txt" ] && bad "a redirect cannot create a file in /etc" \
    || ok "a redirect cannot create a file in /etc"
[ "$(status_of "$T/m2.txt")" = "1" ] && ok "the refused redirect reports status 1" \
    || bad "the refused redirect reports status 1" "status=$(status_of "$T/m2.txt")"
has "$JA" "/etc/permtest.txt: permission denied" \
    "and the machine's screen log says '/etc/permtest.txt: permission denied'"

[ -e "$COMP/usr/permtest.txt" ] && bad "touch cannot create a file in /usr" \
    || ok "touch cannot create a file in /usr"
# NOT ASSERTED AS A FAILURE, AND WHY: the security property above holds, but the
# machinery underneath is rough, and this script reports it rather than hiding it.
# touch does `local f = fs.open(p, "w"); f.close()` -- a guarded open answers nil,
# so the built-in raises and the line dies with it (usr/psh.lua:4225), and because
# run()'s error branch (usr/psh.lua, "else write_stdout(...)") never sets
# SHELL.status, "$?" after such a line is still the PREVIOUS status. The shell
# reports the error text but not a failing status.
if grep -qF "attempt to index" "$JA" 2>/dev/null; then
    note "touch on a guarded path raises inside the built-in (attempt to index local 'f')"
    note "and psh's run() does not set a failing status for it: \$? was $(status_of "$T/m3b.txt")"
fi

[ -e "$COMP/etc/permtest.dir" ] && bad "mkdir cannot create a directory in /etc" \
    || ok "mkdir cannot create a directory in /etc"
# Same kind of wart, reported: mkdir ignores the false that fs.makeDir answered and
# its status stays 0, so only the directory's absence is evidence.
[ "$(status_of "$T/m5.txt")" = "0" ] \
    && note "mkdir reports status 0 although the guarded makeDir created nothing"

# /etc/shadow is not readable for an ordinary account: the guarded open answers nil,
# so the copy holds nothing. (fs.open's nil is also why cat words it "no such file"
# rather than "permission denied" -- reported below, not asserted away.)
if grep -q "root:" "$T/leak.txt" 2>/dev/null; then
    bad "the password file could not be copied out" \
        "a shadow line landed in /var/tmp/leak.txt"
else
    ok "the password file could not be copied out"
fi
[ "$(status_of "$T/m4.txt")" = "1" ] && ok "cat /etc/shadow reports status 1" \
    || bad "cat /etc/shadow reports status 1" "status=$(status_of "$T/m4.txt")"
# The message of a refused `cat` goes through the command's own redirection, so the
# place it was written is leak.txt, not the screen -- which is exactly the file this
# check reads.
has "$T/leak.txt" "cat: /etc/shadow" \
    "and the machine's own file names the refused file"
grep -qF "no such file" "$T/leak.txt" 2>/dev/null \
    && note "cat words the guarded open as 'no such file' rather than 'permission denied'"

if [ "$(cat "$COMP/ownfile.txt" 2>/dev/null)" = "own" ]; then
    ok "but an ordinary file at the machine root is still writable"
else
    bad "but an ordinary file at the machine root is still writable" \
        "content=[$(cat "$COMP/ownfile.txt" 2>/dev/null)]"
fi

echo "--- lib/osguard.lua, underneath the shell (a program on the machine)"
P="$T/osguard-admin.txt"
[ "$(field "$P" who_seen)" = "admin" ] \
    && ok "the probe ran on the machine as admin" \
    || bad "the probe ran on the machine as admin" "who_seen=$(field "$P" who_seen)"
[ "$(field "$P" open_usr_psh)" = "nil" ] \
    && ok "fs.open('/usr/psh.lua','a') is refused for an ordinary account (nil)" \
    || bad "fs.open('/usr/psh.lua','a') is refused for an ordinary account (nil)" \
           "answered $(field "$P" open_usr_psh)"
if [ "$(field "$P" delete_passwd)" = "false" ] && [ -f "$COMP/etc/passwd" ]; then
    ok "fs.delete('/etc/passwd') is refused for an ordinary account (false), file kept"
else
    bad "fs.delete('/etc/passwd') is refused for an ordinary account (false), file kept" \
        "answered $(field "$P" delete_passwd), passwd present=$([ -f "$COMP/etc/passwd" ] && echo yes || echo no)"
fi
if [ "$(field "$P" write_own)" = "handle" ] \
   && [ "$(cat "$COMP/ownfile-probe.txt" 2>/dev/null)" = "probe-admin" ]; then
    ok "the same guarded fs still writes an ordinary file (probe-admin)"
else
    bad "the same guarded fs still writes an ordinary file (probe-admin)" \
        "write_own=$(field "$P" write_own) content=[$(cat "$COMP/ownfile-probe.txt" 2>/dev/null)]"
fi

# =============================================================================
echo
echo "=== boot two: root ==="
# =============================================================================
PRE_PSH="$(wc -c < "$COMP/usr/psh.lua")"
PRE_PASSWD="$(wc -c < "$COMP/etc/passwd" 2>/dev/null || echo missing)"
run_boot root 90
JR="$(journal_path root)"
MARKERS_ROOT="$T/r0.txt $T/r0b.txt $T/r1.txt $T/r2.txt $T/r3.txt $T/r4.txt $T/osguard-root.txt"
# shellcheck disable=SC2086
n="$(counted $MARKERS_ROOT)"
# shellcheck disable=SC2086
if [ "$n" -eq 7 ]; then
    ok "the machine ran all 7 typed commands (each left a marker)"
else
    # shellcheck disable=SC2086
    bad "the machine ran all 7 typed commands" \
        "only $n/7 markers exist:$(missing_of $MARKERS_ROOT)"
fi

[ -f "$COMP/usr/rootfile.txt" ] && ok "root can create /usr/rootfile.txt" \
    || bad "root can create /usr/rootfile.txt"
[ -f "$COMP/etc/rootfile.txt" ] && ok "root can create /etc/rootfile.txt" \
    || bad "root can create /etc/rootfile.txt"

echo "--- the destructive-command blacklist"
[ "$(status_of "$T/r1.txt")" = "1" ] && ok "rm -rf / is refused (status 1)" \
    || bad "rm -rf / is refused (status 1)" "status=$(status_of "$T/r1.txt")"
has "$JR" "refusing 'rm -r' on the filesystem root" \
    "and it says why: 'refusing rm -r on the filesystem root'"
[ "$(status_of "$T/r2.txt")" = "1" ] && ok "rm -rf /usr is refused (status 1)" \
    || bad "rm -rf /usr is refused (status 1)" "status=$(status_of "$T/r2.txt")"
# The wording is asserted loosely ON PURPOSE: both branches of lib/danger.lua name
# the directory, and which one answers is a detail of that module (measured: a plain
# "rm -rf /usr" is reported through the wildcard branch, see the note below).
has_re "$JR" "refusing 'rm -r' (with a wildcard over|on the system directory) '/usr'" \
    "and it says why, naming /usr"
grep -qF "wildcard over '/usr'" "$JR" 2>/dev/null \
    && note "danger.lua reports a plain 'rm -rf /usr' as a wildcard: lib/danger.lua's wildcard_target() returns a system directory before is_system() can name it"
[ "$(status_of "$T/r3.txt")" = "1" ] && ok "sudo rm -rf / is looked through and refused (status 1)" \
    || bad "sudo rm -rf / is looked through and refused (status 1)" \
           "status=$(status_of "$T/r3.txt")"

s0="$(grep -F 'SPY sizes0 ' "$JR" 2>/dev/null | head -1)"
s1="$(grep -F 'SPY sizes1 ' "$JR" 2>/dev/null | head -1)"
if printf '%s' "$s1" | grep -q "same=true"; then
    ok "the blacklist left the shell and /etc/passwd untouched (sizes measured on the machine)"
else
    bad "the blacklist left the shell and /etc/passwd untouched (sizes measured on the machine)" \
        "before [${s0:-none}] after [${s1:-none}]"
fi
[ -f "$COMP/usr/psh.lua" ] && [ "$(wc -c < "$COMP/usr/psh.lua")" = "$PRE_PSH" ] \
    && ok "/usr/psh.lua is still there, at the same size ($PRE_PSH B)" \
    || bad "/usr/psh.lua is still there, at the same size ($PRE_PSH B)" \
           "size=$([ -f "$COMP/usr/psh.lua" ] && wc -c < "$COMP/usr/psh.lua" || echo missing)"
[ -f "$COMP/etc/passwd" ] && [ "$(wc -c < "$COMP/etc/passwd")" = "$PRE_PASSWD" ] \
    && ok "/etc/passwd is still there, at the same size ($PRE_PASSWD B)" \
    || bad "/etc/passwd is still there, at the same size ($PRE_PASSWD B)" \
           "size=$([ -f "$COMP/etc/passwd" ] && wc -c < "$COMP/etc/passwd" || echo missing)"
if [ ! -e "$COMP/home/me" ] && [ "$(status_of "$T/r4.txt")" = "0" ]; then
    ok "rm -rf /home/me still deletes an ordinary directory (status 0)"
else
    bad "rm -rf /home/me still deletes an ordinary directory (status 0)" \
        "status=$(status_of "$T/r4.txt") directory_left=$([ -e "$COMP/home/me" ] && echo yes || echo no)"
fi

echo "--- lib/osguard.lua, underneath the shell (root)"
PR="$T/osguard-root.txt"
[ "$(field "$PR" open_usr_psh)" = "handle" ] \
    && ok "fs.open('/usr/psh.lua','a') succeeds for root (a handle)" \
    || bad "fs.open('/usr/psh.lua','a') succeeds for root (a handle)" \
           "answered $(field "$PR" open_usr_psh)"
if [ "$(field "$PR" passwd_after)" = "false" ]; then
    ok "fs.delete('/etc/passwd') really deleted it for root (the file is gone)"
else
    bad "fs.delete('/etc/passwd') really deleted it for root (the file is gone)" \
        "passwd_after=$(field "$PR" passwd_after) answered $(field "$PR" delete_passwd)"
fi
[ "$(field "$PR" restored)" = "true" ] && [ -f "$COMP/etc/passwd" ] \
    && ok "and root could write /etc/passwd back (the probe restored it)" \
    || bad "and root could write /etc/passwd back (the probe restored it)" \
           "restored=$(field "$PR" restored)"
[ "$(cat "$COMP/ownfile-probe.txt" 2>/dev/null)" = "probe-root" ] \
    && ok "an ordinary file is writable through the guarded fs as root too" \
    || bad "an ordinary file is writable through the guarded fs as root too" \
           "content=[$(cat "$COMP/ownfile-probe.txt" 2>/dev/null)]"

# =============================================================================
echo
echo "=== verdict ==="
if [ "$fail" -eq 0 ]; then
    printf '  elapsed: %ss\n' "$(($(date +%s) - T0))"
    echo "RESULT psh-perm=PASS"
    exit 0
fi
for f in "$(journal_path admin)" "$(journal_path root)"; do
    echo "--- $(basename "$f") (last lines)"
    tail -6 "$f" 2>/dev/null | sed 's/^/    /'
    echo "--- $(basename "$f") screen text"
    screen_tail "$f" | fold -w 150 | tail -8 | sed 's/^/    /'
done
echo "  journals kept in $WATCH and $COMP/var/tmp"
echo "RESULT psh-perm=FAIL ($fail check(s) failed)"
exit 1
