#!/usr/bin/env bash
# GNOME-like desktop acceptance on CraftOS-PC: is the desktop really an EXTRA
# PACKAGE -- installed over the network by the machine's own package manager --
# and does a booted machine draw the chrome that tests/batch10_check.lua asserts
# on?
#
# WHY THE PROBE RENDERS INTO A BUFFER INSTEAD OF LOOKING AT THE SCREEN
#   term.getLine does not exist on CraftOS-PC 2.8.3 (measured), so a real screen
#   cannot be read back. A terminal-only run could show that nothing raised, never
#   that the panel says what it should. So the probe drives the desktop with
#   synthetic mouse events on a buffer screen and prints the CELLS -- character,
#   foreground and background per cell -- and for the part where the desktop hands
#   the terminal to ush it also captures the term screen's own blit payloads.
#
# WHAT THE WHOLE PATH PROVES, IN ORDER
#   1. a repository directory is built from tools/pkgs/gnome, and tools/ is in
#      tools/deploy.py's SKIP_DIRS, so the same tree provably cannot reach a
#      machine by a deploy: the submitted tree is checked for any "gnome" path
#      after the deploy, and deploy.py is asked directly about the package file.
#   2. the machine installs it THE REAL WAY: computer 20 serves the repository
#      with pkgserver.lua (repo_dir=/disk2, the directory that was built), computer
#      31 runs "pkg install gnome" through its own shell, and the probe asserts the
#      package was NOT there before and IS /usr/pkgs/gnome after.
#   3. the installed desktop is launched and driven with synthetic mouse events:
#      the panel's text and the clock's column, the overview listing five apps, a
#      click that opens a window with a title bar and a close control, a drag that
#      is clamped on screen, and a close that removes the window.
#   4. the Terminal runs the project's shell INSIDE its window (1.6.0): a command
#      typed at that window's prompt is executed by a real ush that lives in a ROM
#      window below the desktop, and the evidence is that window's own cells (read
#      back with getLine) plus the panel and the dock still being on the screen.
#      Nothing in this file calls Desktop:handover: the Terminal no longer gives the
#      screen away, and an acceptance that needed the handover API to pass would go
#      green on a Terminal that does give it away.
#   4b. TWO Consoles at once (1.5.0): each builds its own ROM window and is pumped
#      independently, so a command typed into the focused one runs there and the
#      other window's shell never sees it -- the evidence is each ROM window's own
#      cells, read back with getLine, with the panel and dock still on the screen.
#   5. the command is also run through the shell in its headless mode, which is the
#      path an operator has: "desktop --headless --events F --dump F".
#
# WHY TWO COMPUTERS IN ONE EMULATOR AND WHY REDNET
#   Two separate OS processes do not share a modem medium (see _ush-rpv-verify3.sh),
#   so computer 20 spawns 31 with ccemux.openEmu. The transport is rednet, the
#   ROM's own, to keep the repository exchange independent of the rpv stack: this
#   acceptance is about the package, and the rpv path has its own scripts.
#
# USAGE
#   bash tools/rpv-verify/_ush-desktop.sh
#
# Environment: USH (project root), or the repository containing this script.
set -u
USH="${USH:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
PY="${PY:-/c/Users/ymd10/.dsh/dsh-runtimes/dsh-primary-runtime/dependencies/python/python.exe}"
EXE="${EXE:-/c/Program Files/CraftOS-PC/CraftOS-PC_console.exe}"
WORK="${WORK:-/c/Users/ymd10/AppData/Local/rpv-craftos/work/ush-desktop}"
ID="${ID:-31}"
SRV="${SRV:-20}"
PKG="${PKG:-gnome}"
# The full deployed tree is about 1.3 MB, and this run installs a package on top
# of it: the limit is raised so the machine can hold both. The package itself is
# small, and the two-part installation (tools/twopart.py) is what a real 1 MB
# computer uses for the tree -- this acceptance is not about that limit.
LIMIT=8000000
PYW() { cygpath -w "$1"; }

rm -rf "$WORK"; mkdir -p "$WORK"
REPO_DIR="$WORK/repo"
DATA="$WORK/data"
COMP="$DATA/computer/$ID"
SRVCOMP="$DATA/computer/$SRV"
RESULT="$COMP/desktop-result"

SRC="$USH/tools/pkgs/$PKG"
if [ ! -f "$SRC/manifest" ]; then
    echo "error: no package source at $SRC (expected tools/pkgs/$PKG/manifest)" >&2
    exit 1
fi

# ---- 1. build the repository the way pkgserver.lua reads it ------------------
echo "=== the repository: $REPO_DIR/$PKG, built from tools/pkgs/$PKG ==="
mkdir -p "$REPO_DIR/$PKG"
cp -a "$SRC/." "$REPO_DIR/$PKG/"
( cd "$REPO_DIR" && find . -type f -printf '%8s  %P\n' | sort -k2 )
PKG_BYTES=$(find "$REPO_DIR/$PKG" -type f -printf '%s\n' | awk '{s+=$1} END {print s+0}')
PKG_FILES=$(find "$REPO_DIR/$PKG" -type f | wc -l)
printf 'package: %d file(s), %d B\n' "$PKG_FILES" "$PKG_BYTES"
MANIFEST_VERSION=$(sed -n 's/^version=//p' "$REPO_DIR/$PKG/manifest" | head -1)
MANIFEST_BIN=$(sed -n 's/^bin=//p' "$REPO_DIR/$PKG/manifest" | head -1)
printf 'manifest: version=%s bin=%s (pkgserver reads the version from this file,\n' \
    "$MANIFEST_VERSION" "$MANIFEST_BIN"
printf '          and the DIRECTORY name is the package name: %s)\n' "$(basename "$REPO_DIR/$PKG")"
if [ ! -f "$REPO_DIR/$PKG/bin/$MANIFEST_BIN.lua" ]; then
    echo
    echo "RESULT ush-desktop=PASS server=FAIL (the manifest publishes $MANIFEST_BIN and the package has no bin/$MANIFEST_BIN.lua)"
    exit 1
fi
echo

# ---- 2. prove the package SOURCE cannot be deployed --------------------------
echo "=== tools/ is where a host side package source belongs: can a deploy copy it? ==="
"$PY" - "$(PYW "$USH")" <<'PY'
import sys, os, importlib.util
repo = sys.argv[1]
spec = importlib.util.spec_from_file_location("deploy", os.path.join(repo, "tools", "deploy.py"))
deploy = importlib.util.module_from_spec(spec)
spec.loader.exec_module(deploy)
opts = deploy.Options()
for rel, what in (("tools/pkgs/gnome/manifest", "the package source"),
                  ("tools/pkgs/gnome/bin/desktop.lua", "its command"),
                  ("lib/pkg.lua", "a CONTROL: a real module")):
    print("  deploy.wanted(%-34s) = %-5s  %s" % (rel, deploy.wanted(rel, opts), what))
bad = deploy.wanted("tools/pkgs/gnome/manifest", opts) or deploy.wanted("tools/pkgs/gnome/bin/desktop.lua", opts)
if not deploy.wanted("lib/pkg.lua", opts):
    bad = True
print("  deployable=" + ("YES (this is the bug the separate directory avoids)" if bad else "NO"))
PY
echo

# ---- 3. the machine: a deployed tree on both computers ------------------------
mkdir -p "$DATA/config" "$COMP" "$SRVCOMP"
printf '{ "computerSpaceLimit": %d, "clockSpeed": 20, "logErrors": true }\n' "$LIMIT" \
    > "$DATA/config/global.json"
for id in "$SRV" "$ID"; do
    "$PY" "$(PYW "$USH/tools/deploy.py")" --target "$(PYW "$DATA/computer/$id")" --with-etc >/dev/null 2>&1
    rc=$?
    if [ "$rc" -ne 0 ]; then
        echo "RESULT ush-desktop=PASS server=FAIL (deploy.py failed for computer $id)"
        exit 1
    fi
done
TREE_BYTES=$(find "$COMP" -type f -printf '%s\n' | awk '{s+=$1} END {print s+0}')
printf 'deployed: %d B at the root of each computer (limit raised to %d B for the package)\n' \
    "$TREE_BYTES" "$LIMIT"
# The submitted tree must not carry the package: if it did, "installed with pkg"
# would mean nothing, because the machine already had it.
STRAY=$(find "$COMP" -iname '*gnome*' | wc -l)
if [ "$STRAY" -ne 0 ]; then
    echo "  FAIL the deployed tree carries $STRAY path(s) named gnome:"
    find "$COMP" -iname '*gnome*' | sed 's|^|    |'
    echo "RESULT ush-desktop=PASS server=FAIL (the package leaked into the deployed tree)"
    exit 1
fi
printf '  ok   the deployed tree has no path named gnome: the machine can only get it from the repository\n\n'

# ---- the repository server ----------------------------------------------------
cat > "$SRVCOMP/startup.lua" <<LUA
-- The repository side: the machine that serves $PKG. It is a normal installation
-- that happens to have /etc/pkg.conf pointing repo_dir at a mounted directory.
local out = {}
local function mark(s) out[#out+1] = tostring(s) end
mark("BOOT id=" .. tostring(os.getComputerID()))
if periphemu then pcall(function() return periphemu.create("back", "modem") end) end
if ccemux and ccemux.openEmu then
    ccemux.openEmu($ID)
    mark("spawned $ID")
end
fs.makeDir("/etc")
local c = fs.open("/etc/pkg.conf", "w")
c.writeLine("key=mysecretpassword")
c.writeLine("channel=pkg-repo")
c.writeLine("repo_dir=/disk2")
c.close()
local n = fs.open("/etc/network.conf", "w")
n.writeLine("modem_side=back")
n.writeLine("transport=rednet")
n.writeLine("offline=false")
n.close()
os.sleep(2)
package.path = "/lib/?.lua;/usr/?.lua;" .. package.path
local okc, netcfg = pcall(require, "netcfg")
mark("repo_dir=" .. tostring(okc and netcfg.get("repo_dir")))
mark("serving=" .. table.concat(fs.list("/disk2") or {}, ","))
mark("manifest=" .. tostring(fs.exists("/disk2/$PKG/manifest")))
mark("SERVER starting pkgserver.lua")
local f = fs.open("/server.log", "w")
f.write(table.concat(out, "\n"))
f.close()
shell.run("/pkgserver.lua")
mark("SERVER returned")
LUA

# ---- the client probe --------------------------------------------------------
cat > "$COMP/startup.lua" <<LUA
-- The client side. Everything the verdict reads is written to /desktop-result,
-- and every scenario that has to be looked at cell by cell is written to its own
-- dump file (SIZE / ROW / FG / BG / WINDOW / STATS lines).
local out = {}
-- Every mark is appended to the result file as it happens, so a probe that hangs
-- or aborts still leaves the record of how far it got -- which is exactly the
-- failure mode a booted machine has and a PC side suite does not.
local function mark(s)
    out[#out+1] = tostring(s)
    local f = fs.open("/desktop-result", "a")
    if f then
        f.write(tostring(s) .. "\\n")
        f.close()
    end
end

mark("BOOT id=" .. tostring(os.getComputerID()))
if periphemu then pcall(function() return periphemu.create("back", "modem") end) end
mark("modem on back=" .. tostring(peripheral.getType("back")))
fs.makeDir("/etc")
local c = fs.open("/etc/pkg.conf", "w")
c.writeLine("server_id=$SRV")
c.writeLine("key=mysecretpassword")
c.writeLine("channel=pkg-repo")
-- The emulator serves a 167 KB package as ONE message: the repository side walks
-- every file to build checksums, serializes the file set and encrypts it, and
-- this side decrypts and unserializes it. On a headless emulator that work does
-- not fit the machine default (5 s), and it used to look fine only because the
-- client read the answer to an EARLIER request as its own. Two things have
-- changed since: an answer belongs to its request (the wait must now be long
-- enough for the real answer), and an install fetches the package ONCE instead
-- of twice (lib/pkg.lua hands the preflight's answer to the install pass), which
-- halved the cost. MEASURED on this machine with os.epoch("utc"), three samples:
-- one fetch 9552 / 9625 / 8133 ms, one "list" round trip 7 ms, one whole install
-- 12093 ms. 20 s is twice the slowest single fetch -- a real margin rather than
-- a number that only looked safe while a second download was hiding in it.
c.writeLine("timeout=20")
c.close()
local n = fs.open("/etc/network.conf", "w")
n.writeLine("modem_side=back")
n.writeLine("transport=rednet")
n.writeLine("offline=false")
n.close()
mark("network config written=" .. tostring(fs.exists("/etc/network.conf")))

-- Every write the shell makes is recorded here, with its text: that is how the
-- command section below can say what a command printed.
local seen_output = {}
local function record(...)
    local parts = {}
    for i = 1, select("#", ...) do parts[#parts + 1] = tostring((select(i, ...))) end
    seen_output[#seen_output + 1] = table.concat(parts, " ")
end
local real_write, real_print = write, print
local real_term_write = term.write
write = function(...) record(...) return real_write(...) end
print = function(...) record(...) return real_print(...) end
term.write = function(text) record(text) return real_term_write(text) end
mark("terminal capture installed")

os.sleep(4)
mark("awake")
package.path = "/lib/?.lua;/usr/?.lua;" .. package.path
local okpkg, pkg = pcall(require, "pkg")
mark("require pkg=" .. tostring(okpkg))
local okmounts, mounts = pcall(require, "mounts")

-- The shell of this project, driven through its own test hook (the same hook
-- tools/rpv-verify/_ush-twopart-build.sh uses).
_G.__USH_TEST = true
local okush = pcall(function() shell.run("/usr/ush.lua") end)
mark("ush starts=" .. tostring(okush))
mark("ush hook=" .. type(_G.__ush_test))
if type(_G.__ush_test) == "table" then pcall(_G.__ush_test.init) end

-- THE EVIDENCE THAT IT WAS NOT THERE BEFORE.
mark("before fs.exists /usr/pkgs/$PKG=" .. tostring(fs.exists("/usr/pkgs/$PKG")))
mark("before pkg list=" .. table.concat(okpkg and pkg.list() or {}, ","))
mark("before resolve_command desktop=" .. tostring(okpkg and pkg.resolve_command("desktop")))
-- The repository is mounted on the SERVER's computer; the command-line mount is
-- inherited by a computer spawned from it, so this is reported rather than
-- claimed: what matters is that lib/pkg.lua can only FETCH over the network, and
-- the index answer below is the server's.
mark("repository also visible on this computer=" .. tostring(fs.exists("/disk2/$PKG/manifest")))
local preload = pcall(require, "gnome.desktop")
mark("before the install, require gnome.desktop=" .. tostring(preload))
if okpkg then
    local ready, why = pkg.server_ready()
    mark("update server ready=" .. tostring(ready) .. " why=" .. tostring(why))
    mark("install would go to=" .. tostring(pkg.root()))
end

-- THE INSTALL, THE REAL WAY: the machine's own package command. The machine's
-- first-run setup leaves the console on the operator's account (admin here) and
-- pkg answers it with "must be root" -- so the probe takes the refusal as
-- evidence, then becomes root the way the console does, with su. It cannot type
-- the operator's password (there is no keyboard on a headless boot), and the
-- property under test is the PACKAGE path -- the machine's own pkg command
-- fetching over its own network -- not the machine's password policy, which has
-- its own tests.
local okperm, perm = pcall(require, "perm")
if type(_G.__ush_test) == "table" then
    local function attempt(cmd)
        local at = #seen_output
        local st = _G.__ush_test.run(cmd)
        local said = {}
        for i = at + 1, #seen_output do said[#said + 1] = seen_output[i] end
        mark("attempt [" .. cmd .. "] status=" .. tostring(st) ..
             " said=" .. table.concat(said, " "):sub(1, 160))
        return st
    end
    mark("console account=" .. tostring(okperm and perm.get_current_user()))
    mark("install as the console account=" .. tostring(attempt("pkg install $PKG")))
    mark("console account is a sudoer=" .. tostring(okperm and perm.is_sudoer(perm.get_current_user())))
    mark("whoami through the shell=" .. tostring(attempt("whoami")))
    -- A headless probe cannot type the operator's password, so it primes the very
    -- cache the sudo builtin primes after one successful authentication
    -- (lib/sudocache.lua) and then runs the operator's own command. What is under
    -- test is the package path, not the machine's password policy.
    local okcache, sudocache = pcall(require, "sudocache")
    mark("primed the sudo cache=" ..
         tostring(okcache and type(sudocache) == "table" and sudocache.touch(perm.get_current_user()) or okcache))
    mark("install status=" .. tostring(attempt("sudo pkg install $PKG")))

    -- THE LANDING'S FACT, on the machine. gnome.desktop.landing decides where the
    -- operator is left by asking whether a shell started the desktop, and that
    -- answer comes from __ush_command, which ush sets on the fresh command table.
    -- A command file really does see it -- this is that, measured, rather than a
    -- source pin.
    local mf = fs.open("/usr/cmd/markprobe.lua", "w")
    if mf then
        mf.write("print('SHELLMARK=' .. tostring(__ush_command))" .. string.char(10))
        mf.close()
        local mat = #seen_output
        mark("LANDING command status=" .. tostring(attempt("markprobe")))
        local msaid = {}
        for i = mat + 1, #seen_output do msaid[#msaid + 1] = seen_output[i] end
        mark("LANDING a shell command sees the mark=" .. table.concat(msaid, " "):sub(1, 80))
    end

    -- THE OPTIONAL BOOT SESSION. ush is the default; "desktop --autostart on" makes
    -- the NEXT boot start the desktop instead, by writing the one key the boot
    -- script reads. The switch is root only, so it is tried as the console account
    -- first (the refusal is the evidence), then through the same primed sudo cache
    -- the install used. What is checked here is the FILE, not a reboot: rebooting
    -- in the middle of this probe would end it.
    mark("autostart as the console account=" .. tostring(attempt("desktop --autostart on")))
    mark("autostart on=" .. tostring(attempt("sudo desktop --autostart on")))
    local sessionf = fs.open("/etc/session.conf", "r")
    mark("autostart file=" .. tostring(sessionf ~= nil))
    if sessionf then
        local body = sessionf.readAll()
        sessionf.close()
        -- %c is every control character: the file is one line, and a mark is one line.
        mark("autostart body=" .. tostring(body:gsub("%c", "|")))
    end
    mark("autostart status=" .. tostring(attempt("desktop --autostart status")))
    mark("autostart off=" .. tostring(attempt("sudo desktop --autostart off")))
    mark("autostart gone=" .. tostring(not fs.exists("/etc/session.conf")))
else
    mark("install status=no shell hook")
end

mark("after fs.exists /usr/pkgs/$PKG=" .. tostring(fs.exists("/usr/pkgs/$PKG")))
mark("after manifest=" .. tostring(fs.exists("/usr/pkgs/$PKG/manifest")))
mark("after bin=" .. tostring(fs.exists("/usr/pkgs/$PKG/bin/desktop.lua")))
mark("after pkg list=" .. table.concat(okpkg and pkg.list() or {}, ","))
mark("after resolve_command desktop=" .. tostring(okpkg and pkg.resolve_command("desktop")))
mark("after module dirs=" .. table.concat(okpkg and pkg.module_dirs() or {}, ","))
mark("package.path already had the package lib=" ..
     tostring(package.path:find("/usr/pkgs/$PKG/lib/?.lua", 1, true) ~= nil))

-- The repository index on the real server: the entry's name is the DIRECTORY
-- name in the repository and its version came out of the manifest pkgserver read.
-- The update's own answer is recorded as well: a request that timed out and a
-- repository that lists nothing look the same in the line below, and knowing which
-- happened is the difference between a network fact and a server fact.
if okpkg then
    -- ONE ASK, and the attempt count is asserted below. pkg.update() now pairs
    -- the answer with the request that asked for it: the request carries an id
    -- and the repository echoes it back, so a reply left over from the install's
    -- FETCH is skipped instead of being read as the answer. Before that fix the
    -- leftover fetch reply was accepted as an index and saved as "0 packages"
    -- (measured three times: 'server index shape=a leftover fetch reply
    -- (ok=true)'), and this probe asked up to three times to get past it. Asking
    -- again now would hide a regression rather than report it, so the probe asks
    -- once and the expectation is attempts=1.
    local tries, upd, uinfo, idx = 1, nil, nil, nil
    upd, uinfo = pkg.update()
    idx = pkg.index()
    mark("server index attempts=" .. tostring(tries) .. " update=" .. tostring(upd) ..
         " said=" .. tostring(uinfo))
    -- WHAT KIND of answer came back. A "list" answer is an array of entries, so
    -- an index read correctly is "an index of N"; the shape is still printed
    -- because naming the failure mode is what told this defect apart from a
    -- repository that lists nothing.
    local shape = "nothing"
    if type(idx) == "table" then
        if idx.files ~= nil or idx.checksums ~= nil then
            shape = "a leftover fetch reply (ok=" .. tostring(idx.ok) .. ")"
        elseif #idx > 0 then
            shape = "an index of " .. tostring(#idx)
        else
            shape = "an empty table"
        end
    end
    mark("server index shape=" .. shape)
    local found, count = "none", 0
    for _, e in ipairs(type(idx) == "table" and idx or {}) do
        count = count + 1
        if e.name == "$PKG" then found = e.name .. " " .. tostring(e.version) end
    end
    mark("server index entries=" .. tostring(count))
    mark("server index entry=" .. found)
end

-- The command refreshes the package module paths itself (an install registers
-- the command but does not put the module directory on package.path).
if okmounts and mounts.refresh_module_paths then pcall(mounts.refresh_module_paths) end
mark("package.path has the package lib=" ..
     tostring(package.path:find("/usr/pkgs/$PKG/lib/?.lua", 1, true) ~= nil))
local oklib, desktop = pcall(require, "gnome.desktop")
local okscr, screen = pcall(require, "gnome.screen")
local okapps, apps = pcall(require, "gnome.apps")
mark("load gnome.desktop=" .. tostring(oklib) .. " " .. tostring(not oklib and desktop or ""))
mark("load gnome.screen=" .. tostring(okscr))
mark("load gnome.apps=" .. tostring(okapps))

local function write_file(path, text)
    local f = fs.open(path, "w")
    if not f then return false end
    f.write(text)
    f.close()
    return true
end

-- ===========================================================================
-- the desktop, driven headless on a buffer screen with synthetic mouse events
-- ===========================================================================
if oklib then
    local function scenario(name, opts, events)
        local scr = screen.buffer(opts.w or 51, opts.h or 19)
        local s, d = desktop.run({ screen = scr, clock = opts.clock or "12:34",
                                   events = events, entries = opts.entries,
                                   run_shell = opts.run_shell })
        write_file("/dump-" .. name .. ".txt", desktop.dump(s, d))
        return s, d
    end

    local sa = scenario("a", {}, {})
    mark("A row1=[" .. sa.row(1) .. "]")
    mark("A clock column=" .. tostring(sa.find(1, "12:34")))
    mark("A activities column=" .. tostring(sa.find(1, "Activities")))
    mark("A status column=" .. tostring(sa.find(1, "[ush]")))
    mark("A dock column=" .. tostring(sa.find(2, ">_")))
    mark("A wallpaper row=" .. tostring(sa.find(8, "press o")))

    local sb = scenario("b", {}, { { "mouse_click", 1, 5, 1 } })
    mark("B overview title column=" .. tostring(sb.find(2, "Applications")))
    -- The cards wrap at three columns now, so Calculator is on the second row.
    local names = { { "Terminal", 6 }, { "Files", 6 }, { "Settings", 6 }, { "Calculator", 10 } }
    local at = {}
    for i, pair in ipairs(names) do
        at[i] = pair[1] .. "@" .. tostring(sb.find(pair[2], pair[1]))
    end
    mark("B cards=" .. table.concat(at, " "))

    local sc = scenario("c", {}, { { "mouse_click", 1, 5, 1 }, { "mouse_click", 1, 6, 6 } })
    mark("C title column=" .. tostring(sc.find(3, "Terminal")))
    mark("C close column=" .. tostring(sc.find(3, "[x]")))
    mark("C border left=" .. tostring(sc.char(5, 5)) .. " right=" .. tostring(sc.char(44, 5)))

    scenario("d", {}, { { "mouse_click", 1, 5, 1 }, { "mouse_click", 1, 6, 6 },
                        { "mouse_click", 1, 5, 3 }, { "mouse_drag", 1, 60, 18 } })

    scenario("e", {}, { { "mouse_click", 1, 5, 1 }, { "mouse_click", 1, 6, 6 },
                        { "mouse_click", 1, 43, 3 } })

    local sf = scenario("f", { w = 20, h = 5 }, { { "mouse_click", 1, 5, 1 } })
    mark("F row1=[" .. sf.row(1) .. "]")

    -- An app that raises, and an unknown / malformed event: the desktop has to
    -- still be there and still be drawing.
    local bomb = { { id = "bomb", name = "Bomb", icon = "***",
                     draw = function() error("boom from the acceptance probe") end } }
    local sg = scenario("g", { entries = bomb },
                        { { "mouse_click", 1, 5, 1 }, { "mouse_click", 1, 6, 6 } })
    mark("G error row=" .. tostring(sg.find(4, "app error")))

    local sh = scenario("h", {}, { { "nonsense", 4 }, { "mouse_click", 1, "x", "y" },
                                   { "mouse_scroll", -1, 3, 3 }, { "key", "not a key" },
                                   { "mouse_click", 1, 5, 1 } })
    mark("H overview after the junk=" .. tostring(sh.find(2, "Applications")))

    -- A SCHEDULE, in this driver too: the desktop has to resume the package's own
    -- task once per tick, and the task manager prints the count it was given, so
    -- "the machine multitasked" is a cell on the machine's screen and not a claim
    -- about the PC suite. The fifth card is the Tasks app.
    local st = scenario("t", {}, { { "mouse_click", 1, 5, 1 },
                                   { "mouse_click", 1, 18, 8 },
                                   { "tick" }, { "tick" }, { "tick" } })
    mark("T title row=" .. tostring(st.find(3, "Tasks")))
    mark("T body row=" .. tostring(st.find(4, "windows: 1")))
    mark("T ticks row=" .. tostring(st.find(5, "ticks: 3")))
    mark("T clock row=" .. tostring(st.find(6, "now: 0.15")))

    -- THE SAME APPLICATION TWICE. Opening is not a singleton any more: the
    -- second click on a card is a second window, both are in the dump, and the
    -- dock says the application is running. This is what the machine has to show
    -- for "one application, many windows".
    local sm, dm = scenario("m", {}, { { "mouse_click", 1, 5, 1 },
                                       { "mouse_click", 1, 6, 6 },
                                       { "mouse_click", 1, 5, 1 },
                                       { "mouse_click", 1, 6, 6 } })
    mark("M windows=" .. tostring(#dm.windows))
    mark("M titles=" .. tostring(dm.windows[1] and dm.windows[1].title) .. "," ..
                        tostring(dm.windows[2] and dm.windows[2].title))
    mark("M dock dot=" .. tostring(sm.char(2, 3)))

    -- THE SHELL INSIDE A WINDOW. This one needs a real ROM window, so the PC suite
    -- cannot check it at all: the console app creates one under its own interior,
    -- redirects the shell's term into it and copies its cells out every frame. The
    -- claim is that a command typed into that window really ran while the desktop's
    -- own frame (the panel and the dock) was still on the screen.
    -- ush PUBLISHES ITS TEST HOOK AND RETURNS when _G.__USH_TEST is set -- that is
    -- this project's own hook, and a probe that leaves it on can never see an
    -- interactive shell. The machine's real boot does not set it, so for this one
    -- scenario it is cleared (and put back afterwards): the shell then enters its
    -- session loop, which is the thing the console has to show.
    local saved_hook = _G.__USH_TEST
    _G.__USH_TEST = nil
    local sc2, dsc2 = scenario("c2", {}, { { "mouse_click", 1, 5, 1 },
                                     { "mouse_click", 1, 30, 8 },
                                     { "char", "e" }, { "char", "c" }, { "char", "h" },
                                     { "char", "o" }, { "char", " " }, { "char", "h" },
                                     { "char", "i" }, { "key", 28 } })
    _G.__USH_TEST = saved_hook
    local cw
    for _, w in ipairs(dsc2.windows) do
        if w.id == "console" then cw = w end
    end
    local st = (cw and cw.state) or {}
    mark("C2 exited=" .. tostring(st.exited))
    mark("C2 problem=" .. tostring(st.problem))
    mark("C2 result=" .. tostring(st.result))
    mark("C2 task error=" .. tostring(cw and cw.tasks and cw.tasks[1] and cw.tasks[1].error))
    local echoed = 0
    for y = 4, 11 do
        if tostring(sc2.row(y)):find("hi", 1, true) then echoed = y end
    end
    mark("C2 title row=" .. tostring(sc2.find(3, "Console")))
    mark("C2 the command echoed in the window=" .. tostring(echoed > 0))
    mark("C2 row it echoed on=" .. tostring(echoed))
    mark("C2 the panel is still drawn=" .. tostring(sc2.find(1, "Activities")))
    mark("C2 the dock is still drawn=" .. tostring(sc2.find(2, ">_")))
    -- Close the console again. The dump above is the evidence that the shell WAS
    -- running; leaving it running would hand a redirected terminal to the next
    -- scenario. It is closed the way an operator closes it -- the [x] control --
    -- because a KEY goes to the pumped shell that has the focus, not to the
    -- desktop: the window is behind the pump for mouse events, which is the point.
    dsc2:handle({ "mouse_click", 1, 42, 3 })
    dsc2:handle({ "key", 68 })
    mark("C2 pumps left after closing=" .. tostring(#dsc2.pumps))

    -- TWO SHELLS AT ONCE, ON THE MACHINE. Every Console builds its own ROM window
    -- and is pumped independently (1.5.0), so both prompts are drawn, a command
    -- typed into the focused window runs THERE, and the other shell never sees a
    -- character of it. The evidence is the two ROM windows' own cells, read back
    -- with getLine -- a buffer-only suite cannot reach this at all.
    local saved_hook3 = _G.__USH_TEST
    _G.__USH_TEST = nil
    -- The second console opens with the focus, so the first command is typed
    -- there; console 1 is then raised by its title bar (row 3 -- console 2 starts
    -- at row 4) and the second command is typed into it.
    local c3events = { { "mouse_click", 1, 5, 1 }, { "mouse_click", 1, 30, 8 },
                       { "mouse_click", 1, 5, 1 }, { "mouse_click", 1, 30, 8 } }
    for _, ch in ipairs({ "e", "c", "h", "o", " ", "t", "w", "o" }) do
        c3events[#c3events + 1] = { "char", ch }
    end
    c3events[#c3events + 1] = { "key", 28 }
    c3events[#c3events + 1] = { "mouse_click", 1, 10, 3 }
    for _, ch in ipairs({ "e", "c", "h", "o", " ", "o", "n", "e" }) do
        c3events[#c3events + 1] = { "char", ch }
    end
    c3events[#c3events + 1] = { "key", 28 }
    local sc3, dc3 = scenario("c3", {}, c3events)
    _G.__USH_TEST = saved_hook3
    local cons = {}
    for _, w in ipairs(dc3.windows) do
        if w.id == "console" then cons[#cons + 1] = w end
    end
    -- The windows list is in raise order, so the raised one is last; the consoles
    -- are told apart by their creation serial, which is what their titles are
    -- numbered by.
    table.sort(cons, function(a, b) return (a.serial or 0) < (b.serial or 0) end)
    local function console_text(win)
        local sw = win and win.state and win.state.win
        if not sw or type(sw.getLine) ~= "function" then return "" end
        local parts = {}
        local okh, hh = pcall(sw.getSize)
        if not okh or not tonumber(hh) then hh = 10 end
        for y = 1, math.floor(hh) do
            local ok, text = pcall(sw.getLine, y)
            if ok and type(text) == "string" then parts[#parts + 1] = text end
        end
        return table.concat(parts, "\n")
    end
    local function console_rows(win)
        local text = console_text(win)
        local n = 0
        for line in (text .. "\n"):gmatch("([^\n]*)\n") do
            if line:find("%S") then n = n + 1 end
        end
        return n
    end
    local t1 = console_text(cons[1])
    local t2 = console_text(cons[2])
    mark("C3 windows=" .. tostring(#dc3.windows))
    mark("C3 titles=" .. tostring(cons[1] and cons[1].title) .. "," ..
                        tostring(cons[2] and cons[2].title))
    mark("C3 pumps=" .. tostring(#dc3.pumps))
    mark("C3 each shell drew its own screen=" ..
         tostring(console_rows(cons[1]) >= 2 and console_rows(cons[2]) >= 2))
    mark("C3 win1 has one=" .. tostring(t1:find("one", 1, true) ~= nil))
    mark("C3 win1 has two=" .. tostring(t1:find("two", 1, true) ~= nil))
    mark("C3 win2 has two=" .. tostring(t2:find("two", 1, true) ~= nil))
    mark("C3 win2 has one=" .. tostring(t2:find("one", 1, true) ~= nil))
    mark("C3 the two windows are two ROM windows=" ..
         tostring(cons[2] ~= nil and cons[1].state.win ~= cons[2].state.win))
    mark("C3 the panel is still drawn=" .. tostring(sc3.find(1, "Activities")))
    mark("C3 the dock is still drawn=" .. tostring(sc3.find(2, ">_")))
    -- And closing them drops their pumps: console 1's [x] is at (42,3), console
    -- 2's at (44,4) once the first is gone; the last F10 leaves the desktop.
    dc3:handle({ "mouse_click", 1, 42, 3 })
    dc3:handle({ "mouse_click", 1, 44, 4 })
    dc3:handle({ "key", 68 })
    mark("C3 pumps left after closing=" .. tostring(#dc3.pumps))
    mark("C3 desktop left=" .. tostring(dc3.exit))

    -- =======================================================================
    -- the Terminal runs the shell INSIDE its window (1.6.0)
    -- =======================================================================
    -- The Console scenarios' shape, on the Terminal's own card: a real ush is
    -- started in the Terminal window, 'echo hi' is typed at ITS prompt, and the
    -- evidence is that window's own cells -- read back with getLine -- plus the
    -- panel and the dock still being on the screen. Nothing here calls
    -- Desktop:handover. ush publishes its test hook and returns when
    -- _G.__USH_TEST is set, so it is cleared for this scenario only (the machine's
    -- real boot does not set it) and the shell enters its session loop.
    local saved_hook1 = _G.__USH_TEST
    _G.__USH_TEST = nil
    local c1events = { { "mouse_click", 1, 5, 1 }, { "mouse_click", 1, 6, 6 } }
    for _, ch in ipairs({ "e", "c", "h", "o", " ", "h", "i" }) do
        c1events[#c1events + 1] = { "char", ch }
    end
    c1events[#c1events + 1] = { "key", 28 }
    -- And a `desktop` typed at THIS window's prompt: it must be refused, because a
    -- desktop inside a window of another one is not a state this package can keep
    -- consistent (its frame would be drawn into an invisible window of the outer
    -- desktop and two pumps would fight over one event stream).
    for _, ch in ipairs({ "d", "e", "s", "k", "t", "o", "p" }) do
        c1events[#c1events + 1] = { "char", ch }
    end
    c1events[#c1events + 1] = { "key", 28 }
    local sc1, dc1 = scenario("c1", {}, c1events)
    _G.__USH_TEST = saved_hook1
    local tw
    for _, w in ipairs(dc1.windows) do
        if w.id == "terminal" then tw = w end
    end
    local st = (tw and tw.state) or {}
    local sw = st.win
    local text, rows = "", 0
    if sw and type(sw.getLine) == "function" then
        local okh, hh = pcall(sw.getSize)
        if not okh or not tonumber(hh) then hh = 10 end
        local parts = {}
        for y = 1, math.floor(hh) do
            local ok, line = pcall(sw.getLine, y)
            if ok and type(line) == "string" then
                parts[#parts + 1] = line
                if line:find("%S") then rows = rows + 1 end
            end
        end
        text = table.concat(parts, "\n")
    end
    -- And the desktop's own buffer has to show that text inside the window's body
    -- (rows 4..13 of a window at 5,3 40x12): that copy is what an operator sees.
    local shown = false
    for y = 4, 13 do
        if tostring(sc1.row(y)):find("hi", 1, true) then shown = true end
    end
    -- "hi" alone on a row is the command's OUTPUT: the typed line is "echo hi" and
    -- the prompt prefixes it, so a row of exactly "hi" can only be echo's answer.
    -- Without this, "the window contains hi" would also be satisfied by the
    -- characters typed but never submitted.
    local own_line = false
    for line in (text .. "\n"):gmatch("([^\n]*)\n") do
        if line:match("^hi%s*$") then own_line = true end
    end
    if not own_line then
        mark("C1 window preview=" .. text:gsub("\n", "|"):sub(1, 120))
    end
    mark("C1 title row=" .. tostring(sc1.find(3, "Terminal")))
    mark("C1 a shell is pumped in the window=" .. tostring(#dc1.pumps == 1))
    mark("C1 the pump belongs to the Terminal window=" ..
         tostring(#dc1.pumps == 1 and dc1.pumps[1].window == tw))
    mark("C1 the shell has a window of its own=" .. tostring(sw ~= nil))
    mark("C1 the shell drew its own screen=" .. tostring(rows >= 2))
    mark("C1 the window holds the command's output=" ..
         tostring(text:find("hi", 1, true) ~= nil))
    mark("C1 the output is inside the window=" .. tostring(shown))
    mark("C1 the command's output is a line of its own=" .. tostring(own_line))
    mark("C1 the panel is still drawn=" .. tostring(sc1.find(1, "Activities")))
    mark("C1 the dock is still drawn=" .. tostring(sc1.find(2, ">_")))
    mark("C1 screen handovers=" .. tostring(dc1.stats.handovers))
    mark("C1 a windowed desktop is refused=" ..
         tostring(text:find("cannot start inside a window", 1, true) ~= nil))
    mark("C1 no second desktop appeared=" .. tostring(#dc1.windows == 1))
    mark("C1 the shell pump is still the only one=" .. tostring(#dc1.pumps == 1))
    mark("C1 exited=" .. tostring(st.exited))
    mark("C1 problem=" .. tostring(st.problem))
    mark("C1 task error=" .. tostring(tw and tw.tasks and tw.tasks[1] and tw.tasks[1].error))
    -- Close it the way an operator closes a window that has a pumped shell: its
    -- [x] at (42,3), because a KEY belongs to the shell that has the focus.
    dc1:handle({ "mouse_click", 1, 42, 3 })
    mark("C1 pumps left after closing=" .. tostring(#dc1.pumps))
    mark("C1 the desktop is still running=" .. tostring(not dc1.exit))

    -- C1R: the same shell, on the REAL terminal instead of a buffer. This is the
    -- path a graphical emulator takes, and the one a real bug lived in: while a
    -- pumped shell had redirected the global term to its own window, a desktop
    -- that painted through the term API painted ITS OWN FRAME into that window.
    -- The Terminal then showed a copy of the desktop ("Activities", the dock, the
    -- title bar) and the shell prompt was overwritten, so typing looked dead.
    -- C1 cannot catch it: it renders into a buffer and never touches term.
    do
        local saved_hook_r = _G.__USH_TEST
        _G.__USH_TEST = nil
        local revents = { { "mouse_click", 1, 5, 1 }, { "mouse_click", 1, 6, 6 } }
        for _, ch in ipairs({ "e", "c", "h", "o", " ", "h", "i" }) do
            revents[#revents + 1] = { "char", ch }
        end
        revents[#revents + 1] = { "key", 28 }
        local _, dr = desktop.run({ clock = "12:34", events = revents })
        _G.__USH_TEST = saved_hook_r
        local rw
        for _, w in ipairs(dr.windows) do if w.id == "terminal" then rw = w end end
        local rst = (rw and rw.state) or {}
        local rsw = rst.win
        local rtext = ""
        if rsw and type(rsw.getLine) == "function" then
            local okh, rh = pcall(rsw.getSize)
            local parts = {}
            for y = 1, math.floor((okh and tonumber(rh)) or 10) do
                local ok, line = pcall(rsw.getLine, y)
                if ok then parts[#parts + 1] = tostring(line) end
            end
            rtext = table.concat(parts, "|")
        end
        mark("C1R shell window has the command output=" ..
             tostring(rtext:find("hi", 1, true) ~= nil))
        mark("C1R the desktop did not paint into the shell window=" ..
             tostring(rtext:find("Activities", 1, true) == nil))
        mark("C1R preview=" .. rtext:sub(1, 100))
    end

    -- =======================================================================
    -- the text editor, opened from FILES and saved on the machine
    -- =======================================================================
    -- Files and the editor meet at one call (api.open("editor", {path=...})); this
    -- is the machine evidence for that seam: the file lives in a directory whose
    -- name sorts first, so its row is on screen
    -- (the Files window shows ten rows and does not scroll yet).
    -- The file is written, Files lists it, Enter opens the editor, a character is
    -- typed, F2 saves, and the assertion is the file's own bytes read back with fs.
    do
        pcall(fs.makeDir, "/aaa-note-dir")
        write_file("/aaa-note-dir/note.txt",
                   "hello" .. string.char(10) .. "world" .. string.char(10))
        local _, de0 = scenario("ed0", {}, { { "mouse_click", 1, 5, 1 }, { "mouse_click", 1, 20, 6 } })
        local fw
        for _, w in ipairs(de0.windows) do if w.id == "files" then fw = w end end
        local idx = nil
        local okf, filesmod = pcall(require, "gnome.apps.files")
        if fw and okf then
            for i, row in ipairs(filesmod.rows(fw)) do
                if row.entry and row.entry.name == "aaa-note-dir" then idx = i end
            end
        end
        mark("E the directory is listed=" .. tostring(idx ~= nil))
        if idx then
            local body = desktop.body_rect(fw)
            local _, de = scenario("ed", {}, {
                { "mouse_click", 1, 5, 1 },
                { "mouse_click", 1, 20, 6 },
                -- Double clicks now open: two on the folder enter it, two on
                -- note.txt (the second listed row, after "<..>") open it.
                { "mouse_click", 1, body.x, body.y + idx },
                { "mouse_click", 1, body.x, body.y + idx },
                { "mouse_click", 1, body.x, body.y + 2 },
                { "mouse_click", 1, body.x, body.y + 2 },
                { "char", "!" },
                { "key", 113 },
            })
            local ew
            for _, w in ipairs(de.windows) do if w.id == "editor" then ew = w end end
            mark("E editor opened=" .. tostring(ew ~= nil) ..
                 " path=" .. tostring(ew and ew.state.path))
            local f = fs.open("/aaa-note-dir/note.txt", "r")
            local text = f and f.readAll() or ""
            if f then f.close() end
            mark("E saved=" .. tostring(text:gsub(string.char(10), "|")))
        end
        -- SOFT WRAP, UNDO AND FIND on the machine. Each scenario starts from the
        -- same two-line file; the assertions are the file's bytes and the cells the
        -- buffer drew, not "the window opened".
        local ok_chunk, err_chunk = pcall(function()
        local NL = string.char(10)
        -- The clicks need the Files body and the row aaa-note-dir sits on, and this
        -- chunk runs after the block that computed them for its own scenario: ask a
        -- fresh Files window for them rather than depending on a local that is out
        -- of scope here (that mistake made the first version of this chunk raise).
        local _, dpre = scenario("edpre", {}, { { "mouse_click", 1, 5, 1 }, { "mouse_click", 1, 20, 6 } })
        local fpre
        for _, w in ipairs(dpre.windows) do if w.id == "files" then fpre = w end end
        local body = fpre and desktop.body_rect(fpre) or { x = 6, y = 4, w = 38, h = 10 }
        local idx = nil
        local okf2, filesmod2 = pcall(require, "gnome.apps.files")
        if fpre and okf2 then
            for i, row in ipairs(filesmod2.rows(fpre)) do
                if row.entry and row.entry.name == "aaa-note-dir" then idx = i end
            end
        end
        local function open_note(tag, extra)
            local events = {
                { "mouse_click", 1, 5, 1 },
                { "mouse_click", 1, 20, 6 },
                { "mouse_click", 1, body.x, body.y + idx },
                { "mouse_click", 1, body.x, body.y + idx },
                { "mouse_click", 1, body.x, body.y + 2 },
                { "mouse_click", 1, body.x, body.y + 2 },
            }
            for _, ev in ipairs(extra) do events[#events + 1] = ev end
            return scenario(tag, {}, events)
        end
        local function editor_window(d)
            for _, w in ipairs(d.windows) do
                if w.id == "editor" then return w end
            end
            return nil
        end
        local function read_note()
            local f = fs.open("/aaa-note-dir/note.txt", "r")
            local text = f and f.readAll() or ""
            if f then f.close() end
            return text
        end

        write_file("/aaa-note-dir/note.txt", "hello" .. NL .. "world" .. NL)
        local long_events = {}
        for _ = 1, 60 do long_events[#long_events + 1] = { "char", "z" } end
        long_events[#long_events + 1] = { "key", 113 }      -- F2 save
        local sw, dw = open_note("ed2", long_events)
        local ew2 = editor_window(dw)
        local ebody = ew2 and desktop.body_rect(ew2) or nil
        local wrap_ok = false
        if ebody then
            local r1 = tostring(sw.row(ebody.y + 1) or "")
            local r2 = tostring(sw.row(ebody.y + 2) or "")
            local z1 = select(1, r1:sub(ebody.x, ebody.x + 37):gsub("[^z]", ""))
            local z2 = select(1, r2:sub(ebody.x, ebody.x + 21):gsub("[^z]", ""))
            wrap_ok = #z1 == 38 and #z2 == 22
        end
        mark("E wrap 38+22=" .. tostring(wrap_ok))
        local wrapped = read_note()
        mark("E wrap saved all 60=" ..
             tostring(wrapped:sub(1, 60) == string.rep("z", 60) and #wrapped > 60))

        write_file("/aaa-note-dir/note.txt", "hello" .. NL .. "world" .. NL)
        open_note("ed3", { { "char", "X" }, { "key", 115 }, { "key", 113 } })
        mark("E undo restored the file=" ..
             tostring(read_note() == "hello" .. NL .. "world" .. NL))

        write_file("/aaa-note-dir/note.txt", "hello" .. NL .. "world" .. NL)
        local _, df = open_note("ed4", {
            { "key", 114 },                                  -- F3 opens find
            { "char", "w" }, { "char", "o" }, { "char", "r" },
            { "char", "l" }, { "char", "d" },
            { "key", 28 },                                   -- enter finds
            { "key", 113 },                                  -- F2 saves
        })
        local ew4 = editor_window(df)
        mark("E find row/col=" .. tostring(ew4 and ew4.state.row) .. ":" ..
             tostring(ew4 and ew4.state.col))
        mark("E find left the file alone=" ..
             tostring(read_note() == "hello" .. NL .. "world" .. NL))
        end)
        mark("E chunk ok=" .. tostring(ok_chunk) .. " err=" .. tostring(err_chunk))

        pcall(fs.delete, "/aaa-note-dir/note.txt")
        pcall(fs.delete, "/aaa-note-dir")
    end

    -- =======================================================================
    -- the settings panel and the calculator, ON THE MACHINE (1.7.0)
    -- =======================================================================
    -- Until this block existed, both windows were only ever looked at through
    -- tests/batch10_check.lua's buffer: a cell the PC suite asserted had never
    -- been painted by a machine's own installed package. Nothing here invents a
    -- layout: the cards are the ones the machine's overview draws (card_w=12,
    -- three per row from x=5 y=4, so Settings is at 29..40/4..7 and Calculator at
    -- 5..16/8..11), and the body rows below are the rows settings.layout packs a
    -- 38x10 body into and calc.layout a 4x4 grid into.
    local ss = scenario("s", {}, { { "mouse_click", 1, 5, 1 },
                                   { "mouse_click", 1, 30, 6 } })
    mark("S title row=" .. tostring(ss.find(3, "Settings")))
    mark("S system section row=" .. tostring(ss.find(4, "System")))
    mark("S storage section row=" .. tostring(ss.find(7, "Storage")))
    mark("S about section row=" .. tostring(ss.find(11, "About")))
    mark("S total label row=" .. tostring(ss.find(8, "total")))
    mark("S free label row=" .. tostring(ss.find(8, "free")))
    mark("S free space carries a unit=" ..
         tostring(tostring(ss.row(8)):find("%d[%d%.]*%s*[KMG]?B") ~= nil))
    mark("S storage bar row=" .. tostring(tostring(ss.row(9)):find("[#%-]+") ~= nil))
    mark("S storage percentage row=" .. tostring(tostring(ss.row(9)):find("%%") ~= nil))
    local mfv = nil
    local mff = fs.open("/usr/pkgs/$PKG/manifest", "r")
    if mff then
        mfv = mff.readAll():match("version=([%w%.%-]+)")
        mff.close()
    end
    mark("S installed version=" .. tostring(mfv))
    mark("S package version row=" .. tostring(ss.find(12, tostring(mfv))))
    mark("S action row=" .. tostring(ss.find(13, "log out")))
    mark("S the panel is still drawn=" .. tostring(ss.find(1, "Activities")))
    mark("S the dock is still drawn=" .. tostring(ss.find(2, ">_")))
    -- Closing it is the [x] control at (42,3), the same control C1 closes with.
    local ssx, dsx = scenario("sx", {}, { { "mouse_click", 1, 5, 1 },
                                          { "mouse_click", 1, 30, 6 },
                                          { "mouse_click", 1, 42, 3 } })
    mark("SX windows after closing=" .. tostring(#dsx.windows))
    mark("SX the desktop is still running=" .. tostring(not dsx.exit))
    mark("SX the panel is still drawn=" .. tostring(ssx.find(1, "Activities")))

    -- The default window's body, in screen columns: a window at (5,3) 40 wide has
    -- its borders at 5 and 44, so the body an app writes into is 6..43. The
    -- calculator's display is right aligned in it, and reading the BODY (not the
    -- whole row) is what keeps the dock's own icon out of the answer.
    local function body_row(s, y)
        local text = tostring(s.row(y)):sub(6, 43)
        text = text:gsub("^%s+", "")
        return (text:gsub("%s+$", ""))
    end

    -- The calculator: the keypad is drawn (its labels and its 4x4 grid), a key
    -- clicked with the mouse presses that key, and the keyboard is the same
    -- keypad. 2+3= is 5 with no operator precedence, a digit after = starts a new
    -- number, and 1/0= reports the division instead of answering.
    local sk = scenario("k", {}, { { "mouse_click", 1, 5, 1 },
                                   { "mouse_click", 1, 10, 10 } })
    mark("K title row=" .. tostring(sk.find(3, "Calculator")))
    mark("K first keypad row=" .. tostring(sk.find(6, "7") ~= nil))
    mark("K the 9 key=" .. tostring(sk.find(6, "9") ~= nil))
    mark("K the plus key=" .. tostring(sk.find(12, "+") ~= nil))
    local ska = scenario("ka", {}, { { "mouse_click", 1, 5, 1 },
                                     { "mouse_click", 1, 10, 10 },
                                     { "char", "2" }, { "char", "+" }, { "char", "3" },
                                     { "key", 28 } })
    mark("KA display after 2+3=" .. body_row(ska, 4))
    local skm = scenario("km", {}, { { "mouse_click", 1, 5, 1 },
                                     { "mouse_click", 1, 10, 10 },
                                     { "mouse_click", 1, 7, 6 } })
    mark("KM display after clicking 7=" .. body_row(skm, 4))
    local skd = scenario("kd", {}, { { "mouse_click", 1, 5, 1 },
                                     { "mouse_click", 1, 10, 10 },
                                     { "char", "1" }, { "char", "/" }, { "char", "0" },
                                     { "key", 28 } })
    mark("KD divide by zero display=" .. body_row(skd, 4))
    local skn = scenario("kn", {}, { { "mouse_click", 1, 5, 1 },
                                     { "mouse_click", 1, 10, 10 },
                                     { "char", "2" }, { "char", "+" }, { "char", "3" },
                                     { "key", 28 }, { "char", "4" } })
    mark("KN display after = then 4=" .. body_row(skn, 4))
    mark("KN the panel is still drawn=" .. tostring(skn.find(1, "Activities")))
end

-- ===========================================================================
-- the command an operator runs, through the shell
-- ===========================================================================
if type(_G.__ush_test) == "table" then
    -- What does a COMMAND chunk see? The desktop command is loaded by the shell
    -- like any other external command, and this machine's command environment is
    -- not the one the probe itself runs in -- that difference is the whole reason
    -- for the fallback loader in bin/desktop.lua.
    mark("PROBE in this probe's own chunk: require=" .. type(require) ..
         " package=" .. type(package) .. " loadfile=" .. type(loadfile) ..
         " fs=" .. type(fs) .. " shell=" .. type(shell))
    local body = [[
local t = {}
t[#t+1] = "require=" .. type(require)
t[#t+1] = "package=" .. type(package)
t[#t+1] = "loadfile=" .. type(loadfile)
t[#t+1] = "setfenv=" .. type(setfenv)
t[#t+1] = "fs=" .. type(fs)
t[#t+1] = "term=" .. type(term)
t[#t+1] = "shell=" .. type(shell)
t[#t+1] = "os=" .. type(os)
t[#t+1] = "colors=" .. type(colors)
t[#t+1] = "args=" .. type((...))
local o = fs.open("/env-probe.txt", "w")
o.write(table.concat(t, " "))
o.close()
return 0
]]
    local ef = fs.open("/env-probe.lua", "w")
    ef.write(body)
    ef.close()
    if okperm and perm.set_mode then pcall(perm.set_mode, "/env-probe.lua", "rwxr-xr-x") end
    local est = _G.__ush_test.run("/env-probe.lua")
    local eg = fs.open("/env-probe.txt", "r")
    mark("PROBE a command chunk ran=" .. tostring(est) ..
         " env: " .. (eg and eg.readAll() or "(no file)"))
    if eg then eg.close() end
    -- The base installation's own external commands need require() too: if this
    -- fails, the gap is not the desktop package's.
    local wat = #seen_output
    local wst = _G.__ush_test.run("w")
    local wsaid = {}
    for i = wat + 1, #seen_output do wsaid[#wsaid + 1] = seen_output[i] end
    mark("PROBE base external command w status=" .. tostring(wst) ..
         " said=" .. table.concat(wsaid, " "):sub(1, 140))

    local function shell_line(label, cmd)
        local at = #seen_output
        local st = _G.__ush_test.run(cmd)
        local said = {}
        for i = at + 1, #seen_output do said[#said + 1] = seen_output[i] end
        mark("COMMAND " .. label .. " status=" .. tostring(st))
        mark("COMMAND " .. label .. " said=" .. table.concat(said, " "):sub(1, 180))
        return st
    end
    if okpkg then
        mark("COMMAND resolve_command again=" .. tostring(pkg.resolve_command("desktop")) ..
             " list=" .. table.concat(pkg.list() or {}, ","))
    end
    mark("COMMAND package.path=" .. package.path:sub(1, 200))
    mark("COMMAND gnome.desktop already loaded=" ..
         tostring(package.loaded["gnome.desktop"] ~= nil))
    local okreq, errreq = pcall(require, "gnome.desktop")
    mark("COMMAND require again=" .. tostring(okreq) .. " " ..
         tostring(errreq):gsub("\n", " / "):sub(1, 200))
    local f = fs.open("/ev.txt", "w")
    f.write("mouse_click 1 5 1\\nmouse_click 1 6 6\\n")
    f.close()
    shell_line("desktop --headless",
               "desktop --headless --events /ev.txt --dump /dump-command.txt --clock 12:34")
    local f2 = fs.open("/dump-command.txt", "r")
    if f2 then
        local text = f2.readAll()
        f2.close()
        mark("COMMAND dump has the panel=" .. tostring(text:find("Activities", 1, true) ~= nil))
        mark("COMMAND dump has the window=" .. tostring(text:find("WINDOW 1 id=terminal", 1, true) ~= nil))
        mark("COMMAND dump has the counters=" .. tostring(text:find("STATS events=2 clicks=2", 1, true) ~= nil))
    else
        mark("COMMAND dump has the panel=false (no dump file)")
    end
    -- A missing events file is a message and a status, not a traceback.
    shell_line("missing events file", "desktop --headless --events /no-such-file.txt")
    shell_line("unknown option", "desktop --frobnicate")
end

write = real_write
print = real_print
term.write = real_term_write

mark("PROBE END")
LUA

rm -f "$RESULT" "$SRVCOMP/server.log"
for id in a b c d e f g h t c1 c2 c3 m; do rm -f "$COMP/dump-$id.txt"; done
rm -f "$COMP/dump-command.txt"

# ---- boot it ----------------------------------------------------------------
"$EXE" -d "$(PYW "$DATA")" --headless --id "$SRV" \
    --mount-rw "/disk2=$(PYW "$REPO_DIR")" >"$WORK/emu.out.txt" 2>"$WORK/emu.err.txt" &
pid=$!
# The probe appends its marks as it goes, so the wait is for its LAST line: a
# result file that exists but never ends is a probe that hung, and the partial
# record below is then the evidence of where.
for _ in $(seq 1 240); do
    [ -f "$RESULT" ] && grep -q "PROBE END" "$RESULT" && break
    sleep 0.5
done
sleep 1
kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null

echo "=== the repository server (computer $SRV) ==="
if [ -f "$SRVCOMP/server.log" ]; then cat "$SRVCOMP/server.log"; else echo "(no log)"; fi
echo
echo "=== the machine (computer $ID): install, then the desktop ==="
if [ ! -f "$RESULT" ]; then
    echo "RESULT ush-desktop=PASS server=FAIL (the computer did not reach a result)"
    tail -5 "$WORK/emu.err.txt" 2>/dev/null
    exit 1
fi
cat "$RESULT"
echo

# ---- verdict ----------------------------------------------------------------
RESULT_TEXT="$(cat "$RESULT")"
fail=0
expect() {
    if printf '%s' "$RESULT_TEXT" | grep -qF "$1"; then
        printf '  ok   %s\n' "$2"
    else
        printf '  FAIL %s\n' "$2"
        fail=$((fail + 1))
    fi
}
value() {
    printf '%s\n' "$RESULT_TEXT" | sed -n "s/^$1=//p" | head -1
}
# A value that has to be EXACTLY right. A substring expect() cannot do this:
# "status=1" is also a substring of "status=127", and that is how a command the
# shell could not find looked like a command that answered "no such file".
exact() {
    local got
    got="$(value "$1")"
    if [ "$got" = "$2" ]; then
        printf '  ok   %s\n' "$3"
    else
        printf '  FAIL %s (got %s, wanted %s)\n' "$3" "${got:-nothing}" "$2"
        fail=$((fail + 1))
    fi
}
# A substring in ONE dump file: the dumps are where the cells are, and a marker in
# the result file cannot stand in for them.
dump_expect() {
    if grep -qF "$2" "$1"; then
        printf '  ok   %s\n' "$3"
    else
        printf '  FAIL %s (not in %s)\n' "$3" "$(basename "$1")"
        fail=$((fail + 1))
    fi
}
# The column a label starts at in a dump row. A substring expect() cannot do this:
# "Activities" anywhere in the row would pass even if the panel were centred wrong.
col() {
    awk -v row="$2" -v text="$3" '
        $1 == "ROW" && $2 == row {
            rest = substr($0, length("ROW " row " ") + 1)
            print index(rest, text)
            found = 1
        }
        END { if (!found) print 0 }
    ' "$1"
}
# The background blit letter of one cell in a dump. The wallpaper is a sweep of
# six redefined slots, so its top row and its bottom row cannot carry the same
# letter; one swatch is enough to tell a gradient from a flat background.
bgletter() {
    awk -v row="$2" -v at="$3" '
        $1 == "BG" && $2 == row { print substr($3, at, 1); found = 1 }
        END { if (!found) print "?" }
    ' "$1"
}
dumpfile() { echo "$COMP/dump-$1.txt"; }

echo "=== verdict ==="

# 1. the package source cannot be deployed. The boot has installed the package by
# now, so this counts what is named gnome OUTSIDE the package install root -- the
# strict form of the same question ran before the boot, over the submitted tree.
STRAY=$(find "$COMP" -iname '*gnome*' -not -path "*/usr/pkgs/*" | wc -l)
if [ "$STRAY" -eq 0 ]; then
    printf '  ok   nothing named %s is in the deployed tree outside the install root\n' "$PKG"
else
    printf '  FAIL the machine has %d path(s) named %s outside /usr/pkgs\n' "$STRAY" "$PKG"
    find "$COMP" -iname '*gnome*' -not -path "*/usr/pkgs/*" | sed 's/^/        /'
    fail=$((fail + 1))
fi

# 2. installed the real way
expect "before fs.exists /usr/pkgs/$PKG=false" "the package was NOT on the machine before"
expect "before resolve_command desktop=nil" "and its command resolved nowhere"
expect "before the install, require gnome.desktop=false" "and its module could not be loaded before either"
expect "ush starts=true" "the machine's own shell starts"
exact "install as the console account" "1" "the machine refuses a package install from the ordinary console account"
expect "console account is a sudoer=true" "and that account is the one sudo lets through"
expect "primed the sudo cache=true" "the probe authenticates for sudo the way an operator does once (a headless boot has no keyboard)"
exact "install status" "0" "the operator's own 'sudo pkg install' command installs the package"
expect "after fs.exists /usr/pkgs/$PKG=true" "the package is on the machine afterwards"
expect "after manifest=true" "with its manifest"
expect "after bin=true" "and the command the manifest publishes"
expect "after pkg list=$PKG" "the package manager lists it"
expect "after resolve_command desktop=/usr/pkgs/$PKG/bin/desktop.lua" "and resolves the command to the installed file"
expect "server index attempts=1 update=true" "the index is read on the FIRST ask: the answer is paired with its request"
expect "server index shape=an index of" "and what came back has the index shape, not the fetch reply's"
expect "server index entry=$PKG $MANIFEST_VERSION" "the server's index reports the directory name and the manifest version"
expect "load gnome.desktop=true" "the installed desktop module loads"
expect "package.path has the package lib=true" "the package's lib directory is on package.path"

# 3. the chrome, cell by cell
A="$(dumpfile a)"; B="$(dumpfile b)"; C="$(dumpfile c)"; D="$(dumpfile d)"
E="$(dumpfile e)"; F="$(dumpfile f)"; G="$(dumpfile g)"; H="$(dumpfile h)"
T="$(dumpfile t)"
C2="$(dumpfile c2)"
if [ "$(col "$A" 1 Activities)" = "1" ]; then
    printf '  ok   the panel says Activities at column 1\n'
else
    printf '  FAIL the panel says Activities at column %s\n' "$(col "$A" 1 Activities)"
    fail=$((fail + 1))
fi
if [ "$(col "$A" 1 12:34)" = "24" ]; then
    printf '  ok   the clock is centred at column 24 of 51\n'
else
    printf '  FAIL the clock starts at column %s (wanted 24)\n' "$(col "$A" 1 12:34)"
    fail=$((fail + 1))
fi
if [ "$(col "$A" 1 '[ush]')" = "47" ]; then
    printf '  ok   the status area ends at the right edge (column 47)\n'
else
    printf '  FAIL the status area starts at column %s (wanted 47)\n' "$(col "$A" 1 '[ush]')"
    fail=$((fail + 1))
fi
if [ "$(col "$A" 2 '>_')" = "1" ]; then
    printf '  ok   the dock is down the left edge (row 2, column 1)\n'
else
    printf '  FAIL the dock starts at column %s (wanted 1)\n' "$(col "$A" 2 '>_')"
    fail=$((fail + 1))
fi
if [ "$(col "$A" 8 'press o')" = "16" ]; then
    printf '  ok   the wallpaper names the overview shortcut and no product name\n'
else
    printf '  FAIL the wallpaper hint starts at column %s (wanted 16)\n' "$(col "$A" 8 'press o')"
    fail=$((fail + 1))
fi
# The six redefined colour slots must reach the screen. A wallpaper whose top and
# bottom rows are the same background slot is one flat colour again, which is the
# bug this acceptance would otherwise not see (the PC suite asserts the palette, not
# the machine's screen).
A_TOP="$(bgletter "$A" 2 5)"
A_BOTTOM="$(bgletter "$A" 18 5)"
if [ -n "$A_TOP" ] && [ "$A_TOP" != "?" ] && [ "$A_TOP" != "$A_BOTTOM" ]; then
    printf '  ok   the wallpaper sweeps: top=%s bottom=%s\n' "$A_TOP" "$A_BOTTOM"
else
    printf '  FAIL the wallpaper is one colour (%s vs %s)\n' "$A_TOP" "$A_BOTTOM"
    fail=$((fail + 1))
fi
# A row must be ONE background slot: the 4x2 cell dither of 1.7.5 is still a
# visible pattern on a 51x19 screen, so the sweep lives in the palette instead.
if [ "$(bgletter "$A" 10 5)" = "$(bgletter "$A" 10 20)" ] && \
   [ "$(bgletter "$A" 10 5)" = "$(bgletter "$A" 10 51)" ]; then
    printf '  ok   a wallpaper row is one slot (%s), not a pattern\n' "$(bgletter "$A" 10 5)"
else
    printf '  FAIL row 10 is checkered (%s..%s..%s)\n' \
        "$(bgletter "$A" 10 5)" "$(bgletter "$A" 10 20)" "$(bgletter "$A" 10 51)"
    fail=$((fail + 1))
fi

expect "A clock column=24" "the buffer answers the same column the dump shows"
grep -qF "BG 1 f" "$A" && printf '  ok   the dump carries the background letters per cell\n' \
    || { printf '  FAIL the dump has no background letters\n'; fail=$((fail + 1)); }
grep -qF "FG 1 " "$A" && printf '  ok   and the foreground letters\n' \
    || { printf '  FAIL the dump has no foreground letters\n'; fail=$((fail + 1)); }

for name in Terminal Files Settings Calculator; do
    if grep -qF "$name" "$B"; then
        printf '  ok   the overview lists %s\n' "$name"
    else
        printf '  FAIL the overview does not list %s\n' "$name"
        fail=$((fail + 1))
    fi
done
expect "B overview title column=5" "the overview is titled inside the workspace"
expect "B cards=Terminal@7 Files@20 Settings@31 Calculator@6" "every card is laid out where the tests say"

expect "T title row=7" "the overview's fifth card opens the task manager"
expect "T body row=6" "and the task manager draws its own window on the machine"
# 2b. one application, two windows: the machine must show both.
expect "M windows=2" "a second click on a card opens a second window, not a raise"
expect "M titles=Terminal,Terminal 2" "and the two copies are told apart by their titles"
expect "M dock dot=*" "while the dock says the application is running"
expect "T ticks row=17" "the desktop resumed the package's task once per tick"
expect "T clock row=6" "and its clock moved exactly three ticks"
dump_expect "$T" "TASKS 1 started=1" "the dump reports the one task the package started"
grep -qF "CLOCK now=0.150" "$T" \
    && printf '  ok   and the machine clock is the sum of its tick events\n' \
    || { printf '  FAIL the machine clock is not three steps:\n'; grep -F "CLOCK" "$T" | sed 's/^/        /'; fail=$((fail + 1)); }

# 2c. the optional boot session: ush is the default, root can put the desktop first,
# and the switch is the one key the boot script reads.
expect "autostart as the console account=1" "an ordinary account cannot change what this machine boots into"
expect "autostart on=0" "root can make the desktop the session the machine starts with"
expect "autostart file=true" "and it writes the session file the boot script reads"
expect "autostart body=command=desktop|" "with the command line the boot runs through ush"
expect "autostart status=0" "the command reports what the next boot will start"
expect "autostart off=0" "root can put ush back"
expect "autostart gone=true" "and the file is gone, so the default boot is ush again"
expect "C2 title row=7" "the console opens the project's shell in a window"
expect "C2 the command echoed in the window=true" "and a command typed into that window really ran"
expect "C2 the panel is still drawn=1" "while the desktop's own panel is still on the screen"
expect "C2 the dock is still drawn=1" "and so is the dock: the shell did not take the screen"
grep -qF "PUMP 1 active=true" "$C2" \
    && printf '  ok   and the dump shows the shell waiting inside the pump\n' \
    || { printf '  FAIL no pump is active while the console shell runs:\n'; grep -F "PUMP" "$C2" | sed 's/^/        /'; fail=$((fail + 1)); }
expect "C2 pumps left after closing=0" "closing the console window drops its own pump"

# 2d. TWO CONSOLES AT ONCE (1.5.0). The pump is a registry, not one slot, so two
# windows can each run a shell: both drew their own prompt, and what was typed into
# one shell is in that shell's ROM window and nowhere else.
C3="$(dumpfile c3)"
expect "C3 windows=2" "the Console can be open twice on the machine"
expect "C3 titles=Console,Console 2" "and the two copies are numbered by creation"
expect "C3 pumps=2" "two shells are being pumped at the same time"
dump_expect "$C3" "PUMPS 2 active=2" "the dump's registry says there are two pumps"
dump_expect "$C3" "PUMP 1 active=true task=Console window=console" "the first pump is the first console's"
dump_expect "$C3" "PUMP 2 active=true task=Console 2 window=console" "and the second is the other console's"
expect "C3 each shell drew its own screen=true" "each shell drew its own prompt into its own window"
expect "C3 win1 has one=true" "the command typed into console 1 ran in console 1"
expect "C3 win1 has two=false" "and console 1 never saw what was typed into console 2"
expect "C3 win2 has two=true" "the command typed into console 2 ran in console 2"
expect "C3 win2 has one=false" "and console 2 never saw console 1's command"
expect "C3 the two windows are two ROM windows=true" "the two consoles own two different ROM windows"
expect "C3 the panel is still drawn=1" "while both shells run, the panel is still the screen's row 1"
expect "C3 the dock is still drawn=1" "and the dock is still down the left edge"
expect "C3 pumps left after closing=0" "closing both consoles drops both pumps"
expect "C3 desktop left=true" "and the last F10 leaves the desktop"

expect "C title column=7" "a click that opens an app draws a title bar with its name"
expect "C close column=42" "and a close control at the right end of it"
expect "C border left=| right=|" "and the window's side borders"
grep -qF "WINDOW 1 id=terminal title=Terminal x=5 y=3 w=40 h=12" "$C" \
    && printf '  ok   the window geometry is the one the tests assert\n' \
    || { printf '  FAIL the window geometry is not the expected one:\n'; grep -F "WINDOW 1" "$C" | sed 's/^/        /'; fail=$((fail + 1)); }

grep -qF "WINDOW 1 id=terminal title=Terminal x=12 y=8" "$D" \
    && printf '  ok   dragging past the corner clamps the window on screen (12,8)\n' \
    || { printf '  FAIL the dragged window is not clamped as expected:\n'; grep -F "WINDOW 1" "$D" | sed 's/^/        /'; fail=$((fail + 1)); }
dump_expect "$D" "EXIT false reason=nil" "the drag did not end the desktop"

if grep -qF "WINDOWS 0" "$E"; then
    printf '  ok   the close control removed the window\n'
else
    printf '  FAIL the window is still there after the close control:\n'
    grep -F "WINDOW" "$E" | sed 's/^/        /'
    fail=$((fail + 1))
fi
# The dash still names the application, so "no Terminal anywhere" would be the
# wrong question: the title bar ROW is what has to be empty.
if [ "$(col "$E" 3 Terminal)" = "0" ]; then
    printf '  ok   and its title bar is gone from the screen\n'
else
    printf '  FAIL the closed window still has a title bar on row 3\n'
    fail=$((fail + 1))
fi

if grep -qF "SIZE 20 5" "$F" && [ "$(awk '$1=="ROW" && $2==1 { print length($0) - 6 }' "$F")" = "20" ]; then
    printf '  ok   a 20x5 screen renders without a raise (row 1 is 20 cells)\n'
else
    printf '  FAIL the 20x5 screen did not render as expected:\n'
    head -3 "$F" | sed 's/^/        /'
    fail=$((fail + 1))
fi
expect "F row1=[Activit12:34   [ush]]" "and the panel truncates where the clock and status need the cells"

exact "G error row" "6" "an app that raises is reported in its own window, on the row it occupies"
dump_expect "$G" "app error" "and the dump shows the failure in that window"
grep -qF "app_errors=1" "$G" && printf '  ok   and counted once\n' \
    || { printf '  FAIL the app error was not counted\n'; fail=$((fail + 1)); }
grep -qF "boom from the acceptance probe" "$G" && printf '  ok   the window names the failure\n' \
    || { printf '  FAIL the window does not name the failure\n'; fail=$((fail + 1)); }

expect "H overview after the junk=5" "unknown and malformed events do not stop the loop"
grep -qF "unknown=1 malformed=1" "$H" && printf '  ok   the junk was counted (one unknown, one malformed)\n' \
    || { printf '  FAIL the counters are not what the junk should produce:\n'; grep -F "STATS" "$H" | sed 's/^/        /'; fail=$((fail + 1)); }
grep -qF "EXIT false" "$H" && printf '  ok   and the desktop is still running\n' \
    || { printf '  FAIL the desktop exited on the junk\n'; fail=$((fail + 1)); }

# 4. the Terminal runs the shell INSIDE its window (1.6.0). The evidence is that
# window's own cells read back with getLine, plus the panel and the dock still being
# on the display -- and no handover at all: an acceptance that needed
# Desktop:handover to pass would go green on a Terminal that still gives the screen
# away, which is the regression this section exists for.
C1="$(dumpfile c1)"
expect "C1 title row=7" "the Terminal still opens a window called Terminal"
expect "C1 a shell is pumped in the window=true" "and starts the project's shell in it"
expect "C1 the pump belongs to the Terminal window=true" "the pumped program is that window's, not another window's"
expect "C1 the shell has a window of its own=true" "the shell writes into a ROM window under the desktop"
expect "C1 the shell drew its own screen=true" "and has drawn its prompt and its echo there"
expect "C1 the window holds the command's output=true" "so 'echo hi' typed at the prompt ran in that shell"
expect "C1 the output is inside the window=true" "and the frame copies it into the Terminal window's body"
expect "C1 the command's output is a line of its own=true" "the command really ran: its answer is a row that is just 'hi'"
expect "C1 the panel is still drawn=1" "while the shell runs, the panel is still the screen's row 1"
expect "C1 the dock is still drawn=1" "and the dock is still down the left edge"
exact "C1 screen handovers" "0" "the Terminal never hands the screen over"
dump_expect "$C1" "PUMP 1 active=true task=Terminal window=terminal" \
    "the dump reports the Terminal's own pump"
expect "C1 pumps left after closing=0" "closing the Terminal window drops its pump"
expect "C1 the desktop is still running=true" "and the desktop itself never went anywhere"
# 4a2. a `desktop` typed into the Terminal window is refused: one desktop at a time.
expect "C1 a windowed desktop is refused=true" "a desktop typed in a window is refused, with the reason"
expect "C1 no second desktop appeared=true" "and no nested desktop window appeared"
expect "C1 the shell pump is still the only one=true" "and the window keeps its one shell"
# 4b2. the same run on the REAL terminal: the desktop must not paint its own frame
# into the pumped shell window (it did on the machine, and the Terminal showed a
# copy of the desktop).
expect "C1R shell window has the command output=true" "on the real terminal, the shell window holds the command output"
expect "C1R the desktop did not paint into the shell window=true" "and the desktop did not paint itself into that window"
# 4b3. the text editor, opened from Files and saved on the machine.
expect "E the directory is listed=true" "Files lists the file the editor will open"
expect "E editor opened=true path=/aaa-note-dir/note.txt" "Enter on a file opens the editor on that path"
expect "E saved=!hello|world|" "a typed character reaches the file through F2 save"
expect "E wrap 38+22=true" "a long line is drawn as two display rows (38 + 22)"
expect "E wrap saved all 60=true" "and the file holds all 60 characters: wrapping inserts nothing"
expect "E undo restored the file=true" "F4 undoes the typed character before F2 saves"
expect "E find row/col=2:1" "F3 + a query + Enter puts the cursor on the match"
expect "E find left the file alone=true" "and finding does not change the document"

# 4c. the settings panel and the calculator, opened ON THE MACHINE. Before this
# block the two windows had only ever been asserted through the PC suite's buffer;
# these checks say a machine's own installed package painted the same panel and
# pressed the same keys.
expect "S title row=7" "the Settings card opens a window called Settings"
expect "S system section row=6" "the panel's first section is System, on the body's first row"
expect "S storage section row=6" "a Storage section follows it"
expect "S total label row=8" "Storage names the disk's total"
expect "S free label row=25" "and the free space beside it"
expect "S free space carries a unit=true" "the free space carries its own unit, not a raw byte count"
expect "S storage bar row=true" "a bar is drawn for the used part"
expect "S storage percentage row=true" "with the percentage the bar is counted from"
expect "S package version row=17" "the About section names the installed package's version"
expect "S action row=25" "and the actions are on the panel's last row"
expect "S the panel is still drawn=1" "the desktop's panel is still row 1 with Settings open"
expect "S the dock is still drawn=1" "and the dock is still down the left edge"
expect "SX windows after closing=0" "the Settings window closes with its [x] control"
expect "SX the desktop is still running=true" "the desktop is still running after that"
expect "SX the panel is still drawn=1" "with the panel still drawn"
expect "K title row=7" "the Calculator card opens a window called Calculator"
expect "K first keypad row=true" "the keypad's first row of keys is drawn"
expect "K the 9 key=true" "including the 9 key"
expect "K the plus key=true" "and the plus key on the last keypad row"
expect "KA display after 2+3=5" "typing 2+3= on the machine's calculator answers 5 (left to right, no precedence)"
expect "KM display after clicking 7=7" "clicking the 7 key presses it: 7 reaches the display"
expect "KD divide by zero display=error: divide by zero" "1/0= reports the division instead of answering it"
expect "KN display after = then 4=4" "a digit typed after = starts a new number rather than appending"
expect "KN the panel is still drawn=1" "the desktop is still whole with a calculator open"

# 5. the command an operator runs. The first two lines are the environmental fact
# the acceptance found: a command chunk the shell loads only sees require, package
# and shell because the shell now hands it its own environment (the ROM keeps them
# out of _G), and the project's own external commands need it too.
expect "PROBE a command chunk ran=0 env: require=function" "a command chunk gets the ROM's require (the environment the shell hands it)"
expect "PROBE base external command w status=0" "the base's own external command w runs, so the fix is not only this package's"
expect "LANDING a shell command sees the mark=SHELLMARK=true" "a command the shell ran sees __ush_command, the fact the desktop lands by"
exact "COMMAND desktop --headless status" "0" "the shell can run 'desktop --headless --events FILE --dump FILE'"
expect "COMMAND dump has the panel=true" "and the dump it writes has the panel"
expect "COMMAND dump has the window=true" "and the window the events opened"
expect "COMMAND dump has the counters=true" "and the counters"
exact "COMMAND missing events file status" "1" "a missing events file is a status and a message"
exact "COMMAND unknown option status" "1" "an unknown option is refused"

if printf '%s' "$RESULT_TEXT" | grep -q "PROBE ERROR"; then
    printf '  FAIL the probe itself raised\n'
    fail=$((fail + 1))
else
    printf '  ok   the probe ran to the end\n'
fi

echo
if [ "$fail" -eq 0 ]; then
    echo "RESULT ush-desktop=PASS server=PASS"
    exit 0
fi
echo "RESULT ush-desktop=PASS server=FAIL ($fail check(s) failed)"
exit 1
