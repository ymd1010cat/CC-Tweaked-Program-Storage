#!/usr/bin/env bash
# Two-part BUILD acceptance on CraftOS-PC: does the installation that
# tools/twopart.py produces in ONE command boot, with part 2 on the medium as a
# system module store?
#
# WHY THIS EXISTS, AND HOW IT DIFFERS FROM _ush-twopart.sh
#   _ush-twopart.sh assembles the two halves by hand and proves the DESIGN: the
#   medium's package layout, the marker, and mounting being the only thing that
#   puts a module's directory on package.path. This script proves the TOOL: it
#   runs tools/twopart.py once, copies the half it produced onto the computer and
#   the other onto the medium, and booting that is the test. A tool can be wrong
#   in ways a hand built directory cannot be -- the package the regrouping put a
#   module in, the marker it wrote, the config switch it edited -- and none of
#   those show up in a check that reads the tree instead of booting it.
#
# WHAT IT ASSERTS, AND WHAT IT DELIBERATELY DOES NOT DO ITSELF
#   The boot script below NEVER edits package.path to add a package lib
#   directory. Mounting the medium is the only action that wires the module half
#   in (lib/mounts.lua refresh_module_paths, called from mounts.mount and from
#   startup.lua). The probe first asserts that the computer has NO copy of the
#   module it is about to require -- fs.exists on /lib and /usr -- so a passing
#   require("xfer") cannot have come from anywhere but the medium.
#
#   CraftOS-PC 2.8.3 cannot insert a floppy image (see _ush-disk-probe.ps1), so
#   the removable medium here is part2/ mounted with --mount-rw at a path
#   lib/disk.lua treats as a drive. That is a real filesystem, so everything the
#   split rests on -- the marker on the medium, packages read from the medium,
#   modules requirable from the medium -- is exercised for real. What cannot be
#   exercised is the insert/eject event path, which is why the probe takes the
#   mount table entry away to ask what the machine says about a missing medium.
#
# USAGE
#   bash tools/rpv-verify/_ush-twopart-build.sh
#
# Environment: USH (project root), or the repository containing this script.
set -u
USH="${USH:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
PY="${PY:-/c/Users/ymd10/.dsh/dsh-runtimes/dsh-primary-runtime/dependencies/python/python.exe}"
EXE="${EXE:-/c/Program Files/CraftOS-PC/CraftOS-PC_console.exe}"
WORK="${WORK:-/c/Users/ymd10/AppData/Local/Temp/ush-twopart-build}"
ID="${ID:-31}"
LIMIT=1000000

rm -rf "$WORK"; mkdir -p "$WORK"
OUT="$WORK/install"; DATA="$WORK/data"; COMP="$DATA/computer/$ID"
JSON="$WORK/twopart.json"

# ---- the installation, in one command ---------------------------------------
echo "=== $PY tools/twopart.py --out $OUT --json ==="
"$PY" "$USH/tools/twopart.py" --out "$(cygpath -w "$OUT")" --json > "$JSON"
rc=$?
if [ "$rc" -ne 0 ]; then
    echo "tools/twopart.py failed (exit $rc):"
    cat "$JSON"
    echo
    echo "RESULT ush-twopart-build=PASS server=FAIL (the installation was not built)"
    exit 1
fi

# The tool's own report, printed before anything is booted. The verdict below
# compares these numbers with what is on disk: a report that does not match the
# tree it describes is the kind of wrong this script exists to catch.
"$PY" - "$(cygpath -w "$JSON")" <<'PY'
import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
p1, p2 = d["part1"], d["part2"]
print("twopart: ok=%s" % d["ok"])
print("  part 1  %8d B in %d file(s)  (%s%% of %d B, %d B spare)"
      % (p1["bytes"], p1["files"], p1["pct"], p1["limit"], p1["spare"]))
print("  part 2  %8d B in %d file(s)  (%d package(s), marker %s, sys_required %s)"
      % (p2["bytes"], p2["files"], len(p2["packages"]), p2["marker"],
         p2["sys_required"]))
print("  packages: %s" % ", ".join(p["name"] for p in p2["packages"]))
for c in d["checks"]:
    print("  %-4s %s -- %s" % ("ok" if c["ok"] else "FAIL", c["name"], c["detail"]))
PY

MEDIA="$OUT/part2"
# tr -d '\r': this python writes CRLF to a pipe on Windows, and a value read
# back with a CR in it is not a number to printf and not a substring expect()
# can find.
read -r P1JSON P2JSON NPKG < <("$PY" - "$(cygpath -w "$JSON")" <<'PY' | tr -d '\r'
import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
print(d["part1"]["bytes"], d["part2"]["bytes"], len(d["part2"]["packages"]))
PY
)

# What is actually on disk, measured the same way for both halves.
P1=$(find "$OUT/part1" -type f -printf '%s\n' | awk '{s+=$1} END {print s+0}')
P2=$(find "$MEDIA" -type f -printf '%s\n' | awk '{s+=$1} END {print s+0}')
P1PCT=$(awk -v t="$P1" -v l="$LIMIT" 'BEGIN{printf "%.1f", t*100/l}')
if [ "$P1" -le "$LIMIT" ]; then P1VERDICT="FITS (spare $((LIMIT - P1)) B)"; else P1VERDICT="OVER by $((P1 - LIMIT)) B"; fi
printf 'part 1 (computer) %8d B  %5s%% of 1MB  %s\n' "$P1" "$P1PCT" "$P1VERDICT"
printf 'part 2 (medium)   %8d B  %d package(s)  marker %s\n' "$P2" "$NPKG" "$(head -c 30 "$MEDIA/.pkgsys" 2>/dev/null)"
echo

# ---- part 1 -> the computer, part 2 -> the medium ---------------------------
mkdir -p "$DATA/config" "$COMP"
printf '{ "computerSpaceLimit": %d, "clockSpeed": 20, "logErrors": false }\n' "$LIMIT" \
    > "$DATA/config/global.json"
# The CONTENTS of part1/ go to the computer's filesystem root, which is what the
# README tells an operator to do. part2/ is mounted where it stands: the medium
# is not copied, it IS the directory the build produced.
cp -a "$OUT/part1/." "$COMP/"

# ---- boot it ----------------------------------------------------------------
cat > "$COMP/startup.lua" <<'LUA'
local out = {}
local function mark(s) out[#out+1] = s end

-- The shell's own directory layout, which the real startup.lua also needs. This
-- is NOT what wires the medium in: nothing below adds a package lib directory.
package.path = "/lib/?.lua;/usr/?.lua;" .. package.path
mark("BOOT id=" .. tostring(os.getComputerID()))

-- The module the require below asks for exists ONLY on the medium. Asserting
-- that here is what makes a passing require mean "the medium supplied it".
mark("xfer on the computer=" .. tostring(fs.exists("/lib/xfer.lua") or fs.exists("/usr/xfer.lua")))
mark("pkg on the computer=" .. tostring(fs.exists("/lib/pkg.lua") or fs.exists("/usr/pkg.lua")))
mark("marker on the medium=" .. tostring(fs.exists("/disk2/.pkgsys")))

local okall, errall = pcall(function()
    local mounts = require("mounts")

    -- Mounting alone must be enough: nothing here edits package.path.
    local mok = mounts.mount("/disk2", "/mnt/sys", "rw", "acceptance")
    mark("mount=" .. tostring(mok))
    mounts.clear_cache()

    local dirs, on_medium = mounts.module_dirs(), 0
    for _, d in ipairs(dirs) do
        if d:sub(1, 6) == "/disk2" then on_medium = on_medium + 1 end
    end
    mark("module dirs=" .. tostring(#dirs))
    mark("medium module dirs=" .. tostring(on_medium))

    -- xfer also requires "checksum", which the build put in a DIFFERENT package
    -- of the same medium: one require proves the whole package set is on the
    -- path, not just one directory of it.
    local okx, x = pcall(require, "xfer")
    mark("require xfer=" .. tostring(okx) .. (okx and (" type=" .. type(x)) or (" " .. tostring(x))))
    mark("require pkg=" .. tostring(pcall(require, "pkg")))

    local pkg = require("pkg")
    mark("stores=" .. table.concat(pkg.stores(), ","))
    mark("roots=" .. table.concat(pkg.roots(), ","))
    mark("sys complete=" .. tostring(pkg.sys_status().complete))

    local okush = pcall(function() _G.__USH_TEST = true; shell.run("/usr/ush.lua") end)
    mark("ush starts=" .. tostring(okush))
    -- The hook is armed by __USH_TEST and PUBLISHES its entry points as
    -- __ush_test (see the bottom of usr/ush.lua). Indexing the flag instead is a
    -- mistake that looks like a working probe: a boolean is truthy in Lua.
    if okush and type(_G.__ush_test) == "table" then
        pcall(_G.__ush_test.init)
        local r = {}
        for _, line in ipairs({ "echo ok", "pwd", "cat /etc/passwd", "grep root /etc/passwd",
                                "sed s/root/R/ /etc/passwd", "sort /etc/passwd",
                                "wc -l /etc/passwd", "ls /", "pkg store" }) do
            local oks, st = pcall(function() return _G.__ush_test.run(line) end)
            r[#r+1] = line:gsub("%s.*$", "") .. "=" .. tostring(oks and st or "ERR")
        end
        mark("commands: " .. table.concat(r, " "))
    end

    -- The other half of what the build promises: with the medium gone the
    -- machine says it is incomplete instead of running on quietly. The emulator
    -- cannot eject a medium, so the mount entry is removed, which is what
    -- ejection means to lib/pkg.lua.
    mounts.umount("/mnt/sys")
    mounts.clear_cache()
    mark("unmounted complete=" .. tostring(pkg.sys_status().complete))
    mark("unmounted warning=" .. tostring(pkg.completeness_warning() ~= nil))
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

echo "=== boot result (part 1 on the computer, part 2 mounted as the medium) ==="
if [ ! -f "$COMP/boot-result" ]; then
    echo "RESULT ush-twopart-build=PASS server=FAIL (the computer did not boot)"
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
    printf '  ok   part 1 fits on the computer (%s%% of the limit, %d B spare)\n' \
        "$P1PCT" "$((LIMIT - P1))"
fi
expect "xfer on the computer=false" "the module is NOT on the computer (only the medium can supply it)"
expect "pkg on the computer=false" "nor is the package manager"
expect "marker on the medium=true" "the medium carries the .pkgsys marker"
expect "mount=true" "the medium mounts"
expect "medium module dirs=$NPKG" "every package of part 2 is a module directory ($NPKG)"
expect "require xfer=true type=table" "a module that exists ONLY on the medium is requirable"
expect "require pkg=true" "the package manager loads from the medium"
expect "stores=/disk2" "the medium is recognised as the system module store"
expect "sys complete=true" "the machine reports itself complete with the medium in"
expect "ush starts=true" "the shell starts with part 2 on the medium"
expect "unmounted complete=false" "and incomplete once the medium is gone"
expect "unmounted warning=true" "which is the warning the build's sys_required asks for"
if printf '%s' "$RESULT" | grep -q "ERR"; then
    echo "  FAIL at least one command failed"; fail=$((fail + 1))
else
    printf '  ok   every command ran (echo pwd cat grep sed sort wc ls pkg)\n'
fi
# The tool's report has to describe the tree it just wrote.
if [ "$P1" = "$P1JSON" ] && [ "$P2" = "$P2JSON" ]; then
    printf '  ok   the report matches the tree (part 1 %d B, part 2 %d B)\n' "$P1" "$P2"
else
    printf '  FAIL the report does not match the tree (reported %s/%s, measured %s/%s)\n' \
        "$P1JSON" "$P2JSON" "$P1" "$P2"
    fail=$((fail + 1))
fi

echo
if [ "$fail" -eq 0 ]; then
    echo "RESULT ush-twopart-build=PASS server=PASS"
    exit 0
fi
echo "RESULT ush-twopart-build=PASS server=FAIL ($fail check(s) failed)"
exit 1
