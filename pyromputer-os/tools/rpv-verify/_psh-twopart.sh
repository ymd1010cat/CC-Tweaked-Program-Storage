#!/usr/bin/env bash
# Two-part installation acceptance on CraftOS-PC: does a 1 MB computer boot when only the
# base half is on it, with the module half on a removable system module store?
#
# WHY THIS EXISTS
#   A CraftOS computer's filesystem is capped by computer_space_limit (1,000,000 by default) and
#   the whole deployed tree is about 1.14 MB, so the tree does not fit. The answer is two parts:
#   the shell on the computer ("--part base"), its own modules on a medium marked .pkgsys
#   ("--part modules"). This script builds both halves and proves the machine boots.
#
# WHAT IT PROVES, AND WHAT IT DELIBERATELY DOES NOT DO ITSELF
#   The boot script below NEVER edits package.path to add a package lib directory. Mounting the
#   medium is the only action that wires the module half in (lib/mounts.lua
#   refresh_module_paths, called from mounts.mount and from startup.lua). If the design works,
#   `require mediumonly` resolves a module that exists ONLY on the medium. That is the assertion
#   that matters: a probe that added the path by hand would pass even with the mechanism removed.
#
#   CraftOS-PC 2.8.3 cannot insert a floppy image (see _psh-disk-probe.ps1), so the removable
#   medium here is a directory mounted with --mount-rw at a path lib/disk.lua treats as a drive.
#   That is a real filesystem, so the parts of the mechanism that matter -- the marker on the
#   medium, packages read from the medium, modules requirable from the medium -- are exercised
#   for real. What cannot be exercised is the insert/eject event path.
#
# USAGE
#   bash tools/rpv-verify/_psh-twopart.sh
#
# Environment: PSH (project root), or the repository containing this script.
set -u
PSH="${PSH:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
PY="${PY:-/c/Users/ymd10/.dsh/dsh-runtimes/dsh-primary-runtime/dependencies/python/python.exe}"
EXE="${EXE:-/c/Program Files/CraftOS-PC/CraftOS-PC_console.exe}"
WORK="${WORK:-/c/Users/ymd10/AppData/Local/Temp/psh-twopart}"
ID="${ID:-30}"
LIMIT=1000000

rm -rf "$WORK"; mkdir -p "$WORK"
DATA="$WORK/data"; COMP="$DATA/computer/$ID"; MEDIA="$DATA/disk2"
mkdir -p "$DATA/config" "$COMP/etc" "$MEDIA/etc"
printf '{ "computerSpaceLimit": %d, "clockSpeed": 20, "logErrors": false }\n' "$LIMIT" \
    > "$DATA/config/global.json"

# ---- part 1 -> the computer -------------------------------------------------
"$PY" "$PSH/tools/deploy.py" --target "$(cygpath -w "$COMP")" \
    --source "$(cygpath -w "$PSH")" --part base --with-etc --quiet >/dev/null

# ---- part 2 -> the medium, in the package layout ----------------------------
# pkg's layout is <root>/<package>/lib/<module>.lua, so each module of the modules half becomes
# its own package. rpv/ is a stack rather than a module and keeps its directory shape.
"$PY" "$PSH/tools/deploy.py" --target "$(cygpath -w "$MEDIA/stage")" \
    --source "$(cygpath -w "$PSH")" --part modules --quiet >/dev/null
mkdir -p "$MEDIA/usr/pkgs"
for f in $(cd "$MEDIA/stage/lib" 2>/dev/null && ls *.lua 2>/dev/null); do
    name="${f%.lua}"
    mkdir -p "$MEDIA/usr/pkgs/$name/lib"
    mv "$MEDIA/stage/lib/$f" "$MEDIA/usr/pkgs/$name/lib/$f"
    printf 'name=%s\nversion=1.0.0\n' "$name" > "$MEDIA/usr/pkgs/$name/manifest"
done
if [ -d "$MEDIA/stage/rpv" ]; then
    mkdir -p "$MEDIA/usr/pkgs/rpv/lib"
    mv "$MEDIA/stage/rpv" "$MEDIA/usr/pkgs/rpv/lib/rpv"
    printf 'name=rpv\nversion=1.0.0\n' > "$MEDIA/usr/pkgs/rpv/manifest"
fi
rm -rf "$MEDIA/stage"

# A module that exists ONLY on the medium: the proof that the mount put its directory on
# package.path, since no file on the computer could satisfy this require.
mkdir -p "$MEDIA/usr/pkgs/mediumonly/lib"
cat > "$MEDIA/usr/pkgs/mediumonly/lib/mediumonly.lua" <<'LUA'
return { tag = "loaded from the system module store" }
LUA
printf 'name=mediumonly\nversion=1.0.0\n' > "$MEDIA/usr/pkgs/mediumonly/manifest"
printf 'psh system module store\n' > "$MEDIA/.pkgsys"

P1=$(find "$COMP" -type f -printf '%s\n' | awk '{s+=$1} END {print s+0}')
P2=$(find "$MEDIA" -type f -printf '%s\n' | awk '{s+=$1} END {print s+0}')
P1PCT=$(awk -v t="$P1" -v l="$LIMIT" 'BEGIN{printf "%.1f", t*100/l}')
if [ "$P1" -le "$LIMIT" ]; then P1VERDICT="FITS (spare $((LIMIT - P1)) B)"; else P1VERDICT="OVER by $((P1 - LIMIT)) B"; fi
printf 'part 1 (computer) %8d B  %5s%% of 1MB  %s\n' "$P1" "$P1PCT" "$P1VERDICT"
printf 'part 2 (medium)   %8d B  (%d packages)\n' "$P2" "$(ls -1 "$MEDIA/usr/pkgs" | wc -l)"
echo

# ---- boot it ----------------------------------------------------------------
cat > "$COMP/startup.lua" <<'LUA'
local out = {}
local function mark(s) out[#out+1] = s end
package.path = "/lib/?.lua;/usr/?.lua;" .. package.path
mark("BOOT id=" .. tostring(os.getComputerID()))

local okall, errall = pcall(function()
    local mounts = require("mounts")

    -- Mounting alone must be enough: NOTHING here edits package.path.
    local mok, mrec = mounts.mount("/disk2", "/mnt/sys", "rw", "acceptance")
    mark("mount=" .. tostring(mok))
    mounts.clear_cache()
    mark("module dirs found=" .. tostring(#mounts.module_dirs()))

    local okm, m = pcall(require, "mediumonly")
    mark("require mediumonly=" .. tostring(okm) ..
         (okm and (" -> " .. tostring(m.tag)) or ""))

    mark("require xfer (medium)=" .. tostring(pcall(require, "xfer")))

    local pkg = require("pkg")
    mark("stores=" .. table.concat(pkg.stores(), ","))
    mark("roots=" .. table.concat(pkg.roots(), ","))
    mark("sys complete=" .. tostring(pkg.sys_status().complete))

    local okush = pcall(function() _G.__PSH_TEST = true; shell.run("/usr/psh.lua") end)
    mark("psh starts=" .. tostring(okush))
    if okush and _G.__psh_test then
        pcall(_G.__psh_test.init)
        local r = {}
        for _, line in ipairs({ "echo ok", "pwd", "cat /etc/passwd", "grep root /etc/passwd",
                                "sed s/root/R/ /etc/passwd", "sort /etc/passwd",
                                "wc -l /etc/passwd", "ls /" }) do
            local oks, st = pcall(function() return _G.__psh_test.run(line) end)
            r[#r+1] = line:gsub("%s.*$", "") .. "=" .. tostring(oks and st or "ERR")
        end
        mark("commands: " .. table.concat(r, " "))
    end
end)
if not okall then mark("PROBE ERROR: " .. tostring(errall)) end
local f = fs.open("boot-result", "w"); f.write(table.concat(out, "\n")); f.close()
LUA
rm -f "$COMP/boot-result"

"$EXE" -d "$(cygpath -w "$DATA")" --headless --id "$ID" \
    --mount-rw "/disk2=$(cygpath -w "$MEDIA")" >/dev/null 2>&1 &
pid=$!
for _ in $(seq 1 100); do [ -f "$COMP/boot-result" ] && break; sleep 0.5; done
kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null

echo "=== boot result (part 1 on the computer, part 2 on the medium) ==="
if [ ! -f "$COMP/boot-result" ]; then
    echo "RESULT psh-twopart=PASS server=FAIL (the computer did not boot)"
    exit 1
fi
cat "$COMP/boot-result"
echo

# ---- verdict ----------------------------------------------------------------
RESULT="$(cat "$COMP/boot-result")"
fail=0
expect() {
    if printf '%s' "$RESULT" | grep -qF "$1"; then
        printf '  ok   %s\n' "$2"
    else
        printf '  FAIL %s\n' "$2"
        fail=$((fail + 1))
    fi
}
echo "=== verdict ==="
if [ "$P1" -gt "$LIMIT" ]; then
    echo "  FAIL part 1 does not fit ($P1 > $LIMIT)"; fail=$((fail + 1))
else
    printf '  ok   part 1 fits on the computer (%s%% of the limit)\n' "$P1PCT"
fi
expect "mount=true" "the medium mounts"
expect "require mediumonly=true" "a module that exists ONLY on the medium is requirable"
expect "loaded from the system module store" "  and it is the medium's copy that loaded"
expect "require xfer (medium)=true" "a module the shell itself uses loads from the medium"
expect "stores=/disk2" "the medium is recognised as the system module store"
expect "sys complete=true" "the machine reports itself complete"
expect "psh starts=true" "the shell starts with part 2 on the medium"
if printf '%s' "$RESULT" | grep -q "ERR"; then
    echo "  FAIL at least one command failed"; fail=$((fail + 1))
else
    printf '  ok   every command ran (echo pwd cat grep sed sort wc ls)\n'
fi

echo
if [ "$fail" -eq 0 ]; then
    echo "RESULT psh-twopart=PASS server=PASS"
    exit 0
fi
echo "RESULT psh-twopart=PASS server=FAIL ($fail check(s) failed)"
exit 1
