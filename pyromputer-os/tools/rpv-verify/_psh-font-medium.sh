#!/usr/bin/env bash
# Font medium acceptance on CraftOS-PC: do the glyphs, which live on a disk of
# their own, actually put PIXELS on a real screen?
#
# WHY THIS EXISTS, AND WHY IT IS NOT "the modules loaded"
#   A bitmap font can be wrong in ways that raise nothing: a shard the index does
#   not name, a matrix that is mostly zeroes, a renderer that packs the six
#   sub-pixels in the wrong bit order. All three produce a screen with no glyphs
#   and a clean error log. So the probe below never asks whether a call returned
#   -- it wraps term.blit, captures the (text, fg, bg) it was given, and looks at
#   the BYTES. term.blit reads one byte per cell, packing six sub-pixel flags as
#   string.char(128 + mask) with mask 0 = blank, so a real glyph must produce
#   bytes ABOVE 128 and an empty square must not. That is the evidence, and it is
#   the only evidence that distinguishes "it drew the character" from "it
#   returned without error".
#
# WHY THE GLYPHS ARE NOT COPIED ONTO THE COMPUTER EITHER
#   The whole point of the font medium is that the computer has no room for the
#   glyphs (about 1 MB against a 1,000,000 B filesystem limit). So the probe first
#   asserts that the computer has NO copy of the shards, and the mount with
#   --mount-rw is the only thing that can supply them. If a stray copy existed,
#   every assertion after it would pass for the wrong reason.
#
# USAGE
#   bash tools/rpv-verify/_psh-font-medium.sh
#
# Environment: PSH (project root), or the repository containing this script.
set -u
PSH="${PSH:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
PY="${PY:-/c/Users/ymd10/.dsh/dsh-runtimes/dsh-primary-runtime/dependencies/python/python.exe}"
EXE="${EXE:-/c/Program Files/CraftOS-PC/CraftOS-PC_console.exe}"
WORK="${WORK:-/c/Users/ymd10/AppData/Local/Temp/psh-font-medium}"
ID="${ID:-31}"
SIZE="${SIZE:-12}"
PYW() { cygpath -w "$1"; }

rm -rf "$WORK"; mkdir -p "$WORK"
DATA="$WORK/data"; COMP="$DATA/computer/$ID"; MEDIUM="$WORK/medium"
GLYPHS="$WORK/fontdata"; INSTALL="$WORK/install"
FONT_JSON="$WORK/fontgen.json"; DISK_JSON="$WORK/fontdisk.json"

# ------------------------------------------------------------------ the glyphs
echo "=== $PY tools/fontgen.py --size $SIZE --out <work>/fontdata ==="
# --quiet with --json: the report is written to a file and read back, so the human
# summary would be the file's first line and the reader would choke on it. (It
# did: the summary below never printed.) The summary is printed from the parsed
# report instead.
"$PY" "$(PYW "$PSH/tools/fontgen.py")" --size "$SIZE" --out "$(PYW "$GLYPHS")" \
    --quiet --json > "$FONT_JSON" 2>"$WORK/fontgen.err"
rc=$?
if [ "$rc" -ne 0 ]; then
    echo "tools/fontgen.py failed (exit $rc):"
    cat "$WORK/fontgen.err" "$FONT_JSON"
    echo
    echo "RESULT psh-font-medium=PASS server=FAIL (no glyphs were generated)"
    exit 1
fi
"$PY" - "$(PYW "$FONT_JSON")" <<'PY'
import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
print("fontgen: %s size %d -> %d glyph(s) in %d shard(s), %d B total"
      % (d["font_name"], d["size"], d["glyphs"], len(d["shards"]), d["bytes"]))
for s in d["shards"]:
    print("  %-18s %8d B  U+%04X..U+%04X" % (s["file"], s["bytes"], s["first"], s["last"]))
print("  %-18s %8d B  %d entries" % (d["index"]["file"], d["index"]["bytes"],
                                     d["index"]["entries"]))
PY

# ------------------------------------------------------------------ the medium
echo
echo "=== $PY tools/fontdisk.py --out <work>/medium --data <work>/fontdata ==="
"$PY" "$(PYW "$PSH/tools/fontdisk.py")" --out "$(PYW "$MEDIUM")" \
    --data "$(PYW "$GLYPHS")" --json > "$DISK_JSON" 2>"$WORK/fontdisk.err"
rc=$?
if [ "$rc" -ne 0 ]; then
    echo "tools/fontdisk.py failed (exit $rc):"
    cat "$WORK/fontdisk.err" "$DISK_JSON"
    echo
    echo "RESULT psh-font-medium=PASS server=FAIL (the medium was not built)"
    exit 1
fi
"$PY" - "$(PYW "$DISK_JSON")" <<'PY'
import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
print("fontdisk: ok=%s" % d["ok"])
print("  %s at the root, %s %s" % (d["marker"], d["store_marker"] or "(no store marker)", ""))
print("  %d glyph(s) in fonts/, %d B = %.1f%% of a %d B floppy (%d B spare)"
      % (d["glyphs"], d["bytes"], d["percent"], d["floppy"], d["spare"]))
for c in d["checks"]:
    print("  %-4s %s -- %s" % ("ok" if c["ok"] else "FAIL", c["name"], c["detail"]))
PY

# What is actually on disk, measured the same way, so the report is checked
# against the tree it describes rather than believed.
MEDIUM_BYTES=$(find "$MEDIUM" -type f -printf '%s\n' | awk '{s+=$1} END {print s+0}')
MEDIUM_FILES=$(find "$MEDIUM" -type f | wc -l)
FLOPPY=1228800
read -r REPORTED_BYTES GLYPHS < <("$PY" - "$(PYW "$DISK_JSON")" <<'PY' | tr -d '\r'
import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
print(d["bytes"], d["glyphs"])
PY
)
printf 'medium on disk: %d B in %d file(s) of a %d B floppy (%d B spare)\n' \
    "$MEDIUM_BYTES" "$MEDIUM_FILES" "$FLOPPY" "$((FLOPPY - MEDIUM_BYTES))"
echo

# ---- the computer gets the runtime; the medium gets the glyphs ---------------
mkdir -p "$DATA/config" "$COMP"
printf '{ "computerSpaceLimit": 1000000, "clockSpeed": 20, "logErrors": false }\n' \
    > "$DATA/config/global.json"
# Only the three modules the probe requires. The point is the GLYPHS, and a full
# install would make the failure modes of the boot path part of this test.
mkdir -p "$COMP/lib"
for m in cc_fonts cc_font_shards cc_chinese; do
    cp "$PSH/lib/$m.lua" "$COMP/lib/$m.lua"
done

cat > "$COMP/startup.lua" <<'LUA'
local out = {}
local function mark(s) out[#out+1] = tostring(s) end

-- The shell's own directory layout. This is NOT what finds the glyphs: nothing
-- below adds a fonts/ directory to any path, and the shards are on the medium.
package.path = "/lib/?.lua;" .. package.path
mark("BOOT id=" .. tostring(os.getComputerID()))

-- The computer must NOT have the glyphs. Asserting it here is what makes every
-- pixel assertion below mean "the medium supplied them".
mark("shards on the computer=" .. tostring(fs.exists("/lib/shs12_index.lua") or
     fs.exists("/shs12_index.lua") or fs.exists("/fonts")))
mark("medium marker=" .. tostring(fs.exists("/disk2/cc_fonts.marker")))
mark("medium store marker=" .. tostring(fs.exists("/disk2/.pkgstore")))
mark("medium capacity=" .. tostring(fs.getCapacity("/disk2")))

-- Capture every term.blit the renderer makes. The REAL blit is kept and called,
-- so the screen state is the real one; the wrapper only records the arguments.
local real_blit = term.blit
local captured = {}
term.blit = function(text, fg, bg)
    captured[#captured + 1] = { text = text, fg = fg, bg = bg }
    return real_blit(text, fg, bg)
end

local okall, errall = pcall(function()
    local fonts = require("cc_fonts")
    local shards = require("cc_font_shards")
    local chinese = require("cc_chinese")

    -- 1. The medium is found by its marker, with no drive letter anywhere.
    local base, medium, index, why = fonts.find()
    mark("found base=" .. tostring(base))
    mark("found medium=" .. tostring(medium))
    mark("found index=" .. tostring(index))
    mark("find reason=" .. tostring(why))

    -- 2. A codepoint must resolve, and to a matrix of the declared shape.
    shards.init(base)
    local matrix = shards.get(0x4E2D)
    mark("U+4E2D matrix=" .. type(matrix))
    if type(matrix) == "table" then
        mark("U+4E2D rows=" .. #matrix .. " width=" .. #(matrix[1] or ""))
        local ink = 0
        for _, row in ipairs(matrix) do
            for i = 1, #row do
                if row:sub(i, i) == "1" then ink = ink + 1 end
            end
        end
        mark("U+4E2D ink=" .. ink)
    end

    -- 3. THE PIXELS. A string of three characters, drawn at a known place.
    captured = {}
    chinese.config.size = 12
    local report = chinese.draw("\228\184\173\230\150\135\229\155\189", 1, 1)
    mark("draw ok=" .. tostring(report.ok) .. " drawn=" .. tostring(report.drawn) ..
         " missing=" .. tostring(report.missing) ..
         " error=" .. tostring(report.error))
    mark("blit calls=" .. #captured)

    -- One blit per cell row of each glyph: 12 pixels is 4 cell rows, so three
    -- characters make twelve calls of six cells each.
    local cells_total, above, blank_bytes = 0, 0, 0
    for _, call in ipairs(captured) do
        cells_total = cells_total + #call.text
        for i = 1, #call.text do
            local b = call.text:byte(i)
            if b > 128 then above = above + 1 end
            if b == 128 then blank_bytes = blank_bytes + 1 end
        end
    end
    mark("cells blitted=" .. cells_total)
    mark("lit cells (byte > 128)=" .. above)
    mark("blank cells (byte == 128)=" .. blank_bytes)

    -- The character in the MIDDLE of the string must be the one with the most
    -- ink here, but the point is that EVERY glyph produced some lit cell.
    local per_glyph = {}
    for g = 0, 2 do
        local lit = 0
        for row = 1, 4 do
            local call = captured[g * 4 + row]
            if call then
                for i = 1, #call.text do
                    if call.text:byte(i) > 128 then lit = lit + 1 end
                end
            end
        end
        per_glyph[#per_glyph + 1] = lit
    end
    mark("lit cells per glyph=" .. table.concat(per_glyph, ","))

    -- The colour arguments have to be blit characters, one per cell.
    local first = captured[1]
    mark("first fg=" .. tostring(first and first.fg) ..
         " bg=" .. tostring(first and first.bg))
    mark("toBlit(white)=" .. tostring(colors.toBlit(colors.white)) ..
         " toBlit(black)=" .. tostring(colors.toBlit(colors.black)))

    local okall_flag = true
    -- 4. THE MISSING MEDIUM. Two ways for the glyphs to be gone, because they
    --    are two different situations with two different fixes, and the machine
    --    has to name which one it is in.
    --    (a) nothing carries the marker. The medium IS still mounted at /disk2 --
    --        it has to be, or nothing above could have drawn -- so the way to ask
    --        "and if the operator pulls it out?" is to take the drives away from
    --        the finder. That is the one place a probe may look behind the API,
    --        and it is exactly the state an ejection leaves: no drive, no marker.
    local keep = chinese.config.base
    chinese.config.base = nil
    local real_candidates = fonts.CANDIDATES
    fonts.CANDIDATES = { "/disk9" }             -- a drive with nothing in it
    captured = {}
    local missing = chinese.draw("\228\184\173", 1, 1)
    mark("missing ok=" .. tostring(missing.ok))
    mark("missing drawn=" .. tostring(missing.drawn))
    mark("missing blits=" .. #captured)
    mark("missing reason=" .. tostring(missing.reason))

    --    render() is the loud variant, for a caller that wants a font or wants to
    --    know rather than a screen it cannot read.
    local raised, message = pcall(chinese.render)
    mark("render raised=" .. tostring(not raised))
    mark("render message=" .. tostring(message))
    fonts.CANDIDATES = real_candidates

    --    (b) a set that was pinned by name and is not there: the caller asked for
    --        a specific file, and the message has to name the file.
    chinese.config.base = "/disk9/fonts/shs12"
    shards.init("/disk9/fonts/shs12")
    captured = {}
    local pinned = chinese.draw("\228\184\173", 1, 1)
    mark("pinned ok=" .. tostring(pinned.ok))
    mark("pinned blits=" .. #captured)
    mark("pinned reason=" .. tostring(pinned.reason))
    chinese.config.base = keep
    if not okall_flag then mark("PROBE ERROR: unreachable") end
end)
if not okall then mark("PROBE ERROR: " .. tostring(errall)) end

local f = fs.open("font-result", "w"); f.write(table.concat(out, "\n")); f.close()
LUA
rm -f "$COMP/font-result"

# ---- boot it ----------------------------------------------------------------
"$EXE" -d "$(PYW "$DATA")" --headless --id "$ID" \
    --mount-rw "/disk2=$(PYW "$MEDIUM")" >/dev/null 2>&1 &
pid=$!
for _ in $(seq 1 120); do [ -f "$COMP/font-result" ] && break; sleep 0.5; done
kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null

echo "=== boot result (the runtime on the computer, the glyphs on the medium) ==="
if [ ! -f "$COMP/font-result" ]; then
    echo "RESULT psh-font-medium=PASS server=FAIL (the computer did not boot)"
    exit 1
fi
cat "$COMP/font-result"
echo

# ---- verdict ----------------------------------------------------------------
RESULT="$(cat "$COMP/font-result")"
fail=0
expect() {
    if printf '%s' "$RESULT" | grep -qF "$1"; then
        printf '  ok   %s\n' "$2"
    else
        printf '  FAIL %s\n' "$2"
        fail=$((fail + 1))
    fi
}
# A value that has to be EXACTLY right, read back out of the result file. A
# substring expect() cannot do this: "lit cells=12" also matches "lit cells=120".
value() {
    printf '%s\n' "$RESULT" | sed -n "s/^$1=//p" | head -1
}
atleast() {
    local got="$1" want="$2" what="$3"
    if [ -n "$got" ] && [ "$got" -ge "$want" ] 2>/dev/null; then
        printf '  ok   %s (%s >= %s)\n' "$what" "$got" "$want"
    else
        printf '  FAIL %s (got %s, wanted at least %s)\n' "$what" "${got:-nothing}" "$want"
        fail=$((fail + 1))
    fi
}

echo "=== verdict ==="
expect "shards on the computer=false" "the computer has NO copy of the glyphs"
expect "medium marker=true" "the medium carries cc_fonts.marker at its root"
expect "medium store marker=true" "and .pkgstore, so a package install can find it"
expect "found base=/disk2/fonts/shs12" "the medium is found BY ITS MARKER, no drive letter anywhere"
expect "U+4E2D matrix=table" "a real codepoint resolves to a glyph matrix"
expect "U+4E2D rows=12 width=12" "and the matrix is the declared 12 x 12"
atleast "$(value 'U+4E2D ink')" 12 "the glyph has real ink, not zeroes"
expect "draw ok=true" "cc_chinese.draw() succeeds on a CJK string"
expect "draw ok=true drawn=3 missing=0" "all three characters were drawn from the set"
expect "blit calls=12" "a 12 pixel glyph is 4 cell rows, so 3 glyphs make 12 blits"
expect "cells blitted=72" "each row blits 6 cells, so 72 cells of pixels"
atleast "$(value 'lit cells (byte > 128)')" 24 "the payload contains bytes ABOVE 128, i.e. lit sub-pixels"
atleast "$(value 'blank cells (byte == 128)')" 1 "and some blank cells, so 128 is really the blank byte"

# Every glyph, not just the first: a shard that resolved but drew nothing would
# show up as a zero here while the row above still passed.
per_glyph="$(value 'lit cells per glyph')"
glyph_fail=0
IFS=',' read -ra GLYPHS_ARR <<< "$per_glyph"
if [ "${#GLYPHS_ARR[@]}" -ne 3 ]; then
    echo "  FAIL each of the three glyphs drew something (got '${per_glyph:-nothing}')"
    glyph_fail=1
else
    for lit in "${GLYPHS_ARR[@]}"; do
        [ "${lit:-0}" -ge 1 ] 2>/dev/null || glyph_fail=1
    done
    if [ "$glyph_fail" -eq 0 ]; then
        printf '  ok   each of the three glyphs drew lit pixels (%s)\n' "$per_glyph"
    else
        echo "  FAIL each of the three glyphs drew something (got '$per_glyph')"
    fi
fi
[ "$glyph_fail" -eq 0 ] || fail=$((fail + 1))

expect "toBlit(white)=0 toBlit(black)=f" "term.blit and colors.toBlit are the ROM's own"

# The missing-medium path, which is the behaviour a caller depends on when the
# operator pulls the disk out. Two situations, two messages.
expect "missing ok=false" "with no medium inserted, draw() reports failure instead of raising"
expect "missing drawn=0" "and draws nothing, so no blank screen was passed off as a glyph"
expect "missing blits=0" "and made no blit call at all"
if printf '%s' "$(value 'missing reason')" | grep -q "cc_fonts.marker"; then
    echo "  ok   the reason names the marker the operator has to supply"
else
    echo "  FAIL the reason names the marker (got '$(value 'missing reason')')"
    fail=$((fail + 1))
fi
# A set pinned by name and absent is the other situation, and it has to name the
# FILE: "insert the font medium" would be wrong advice when the medium is in and
# the set is not on it.
expect "pinned ok=false" "a glyph set pinned by name and absent also reports rather than raises"
expect "pinned blits=0" "and blits nothing"
if printf '%s' "$(value 'pinned reason')" | grep -q "shs12_index.lua"; then
    echo "  ok   and its reason names the index file that is missing"
else
    echo "  FAIL the pinned reason names the file (got '$(value 'pinned reason')')"
    fail=$((fail + 1))
fi
expect "render raised=true" "render() is the loud variant and raises for a caller that wants a font"
if printf '%s' "$(value 'render message')" | grep -q "^cc_fonts: "; then
    echo "  ok   and its message is prefixed with the module that refused"
else
    echo "  FAIL render()'s message names the module (got '$(value 'render message')')"
    fail=$((fail + 1))
fi

if printf '%s' "$RESULT" | grep -q "PROBE ERROR"; then
    echo "  FAIL the probe itself raised"
    fail=$((fail + 1))
else
    printf '  ok   the probe ran to the end\n'
fi
# The medium's report has to describe the tree it wrote.
if [ "$MEDIUM_BYTES" = "$REPORTED_BYTES" ] && [ "$MEDIUM_BYTES" -le "$FLOPPY" ]; then
    printf '  ok   the size report matches the tree and fits the floppy (%d B)\n' "$MEDIUM_BYTES"
else
    printf '  FAIL the report does not match the tree (reported %s, measured %s, floppy %d)\n' \
        "$REPORTED_BYTES" "$MEDIUM_BYTES" "$FLOPPY"
    fail=$((fail + 1))
fi

echo
if [ "$fail" -eq 0 ]; then
    echo "RESULT psh-font-medium=PASS server=PASS"
    exit 0
fi
echo "RESULT psh-font-medium=PASS server=FAIL ($fail check(s) failed)"
exit 1
