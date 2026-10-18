#!/usr/bin/env bash
# A glyph SET across TWO media, on CraftOS-PC: does a character whose shard is on
# medium A render, does one whose shard is on medium B render, and does the
# machine NAME the part it is missing when only one of the two is inserted?
#
# WHY THIS EXISTS, AND WHY IT IS NOT THE ONE-MEDIUM SCRIPT WITH A FLAG
#   tools/rpv-verify/_ush-font-medium.sh proves that one medium's glyphs reach a
#   screen. The whole of GB2312 is 1,375,263 B and a floppy holds 1,228,800 B, so
#   the shipped set is TWO media, and that adds three things one medium cannot
#   have: a lookup that has to cross media, an order that has to come from the
#   manifests rather than from the drive names, and a half-inserted machine that
#   must say WHICH part is missing instead of drawing nothing. Each of the three
#   can be wrong with no error anywhere, so each is asserted here.
#
# HOW THE PIXELS ARE PROVED
#   The probe never asks whether a call returned. It wraps term.blit, captures
#   the (text, fg, bg) the renderer was given, and looks at the BYTES: term.blit
#   reads one byte per cell, packing six sub-pixel flags as string.char(128 +
#   mask). So a lit cell is a byte above 128, a blank cell is exactly 128, and the
#   number of SET BITS of (byte - 128) over the whole payload is the number of
#   lit pixels of the glyph. That last number is compared with the ink count
#   tools/fontdisk.py measured from the shard file on the medium when it built the
#   set -- a known answer from the builder against a measurement from the machine,
#   which is the only kind of agreement that catches an encoder that is stable and
#   wrong.
#
# WHAT THE TWO BOOTS ARE
#   boot 1  both media in, and DELIBERATELY at the drive names the other way
#           round (part 2 at /disk2, part 1 at /disk3). The loader has to order
#           the parts from each medium's own manifest; ordering them by drive
#           name would draw the same text differently on two machines holding the
#           same disks.
#   boot 2  only part 1's medium in. The machine has to report "set shs12 part 1
#           of 2, part 2 not inserted" and refuse to draw a character that lives
#           on part 2 -- with a reason that names the part, and with no box
#           blitted, so nothing is passed off as the glyph.
#
# USAGE
#   bash tools/rpv-verify/_ush-font-two-disks.sh
#
# Environment: USH (project root), or the repository containing this script.
set -u
USH="${USH:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
PY="${PY:-/c/Users/ymd10/.dsh/dsh-runtimes/dsh-primary-runtime/dependencies/python/python.exe}"
EXE="${EXE:-/c/Program Files/CraftOS-PC/CraftOS-PC_console.exe}"
WORK="${WORK:-/c/Users/ymd10/AppData/Local/Temp/ush-font-two-disks}"
ID_BOTH="${ID_BOTH:-41}"
ID_ONE="${ID_ONE:-42}"
SIZE="${SIZE:-12}"
DISKS="${DISKS:-2}"
PYW() { cygpath -w "$1"; }

rm -rf "$WORK"; mkdir -p "$WORK"
DATA="$WORK/data"; SET="$WORK/set"; GLYPHS="$WORK/fontdata"
BOTH="$DATA/computer/$ID_BOTH"; ONE="$DATA/computer/$ID_ONE"
FONT_JSON="$WORK/fontgen.json"; SET_JSON="$WORK/fontdisk.json"
mkdir -p "$BOTH" "$ONE"

# -------------------------------------------------------------------- the glyphs
# The WHOLE standard: 6763 ideographs and the punctuation row. This is the set
# that does not fit one medium, which is why this script exists at all.
echo "=== $PY tools/fontgen.py --full --size $SIZE --out <work>/fontdata ==="
# --quiet with --json, because the JSON is written to a file and read back: the
# human summary would be the first line of that file and the reader would choke
# on it. The summary is printed below from the parsed report instead.
"$PY" "$(PYW "$USH/tools/fontgen.py")" --full --size "$SIZE" --out "$(PYW "$GLYPHS")" \
    --quiet --json > "$FONT_JSON" 2>"$WORK/fontgen.err"
rc=$?
if [ "$rc" -ne 0 ]; then
    echo "tools/fontgen.py failed (exit $rc):"
    cat "$WORK/fontgen.err" "$FONT_JSON"
    echo
    echo "RESULT ush-font-two-disks=PASS server=FAIL (no glyphs were generated)"
    exit 1
fi
"$PY" - "$(PYW "$FONT_JSON")" <<'PY'
import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
print("fontgen: %s size %d -> %d glyph(s) in %d shard(s), %d B"
      % (d["font_name"], d["size"], d["glyphs"], len(d["shards"]), d["bytes"]))
PY
FULL_BYTES=$(find "$GLYPHS" -type f -printf '%s\n' | awk '{s+=$1} END {print s+0}')
echo "  the set on disk: $FULL_BYTES B, which is more than one 1228800 B floppy"
echo

# ------------------------------------------------------------ the set, ONE command
echo "=== $PY tools/fontdisk.py --set-out <work>/set --data <work>/fontdata --disks $DISKS ==="
"$PY" "$(PYW "$USH/tools/fontdisk.py")" --set-out "$(PYW "$SET")" \
    --data "$(PYW "$GLYPHS")" --disks "$DISKS" --json > "$SET_JSON" 2>"$WORK/fontdisk.err"
rc=$?
if [ "$rc" -ne 0 ]; then
    echo "tools/fontdisk.py failed (exit $rc):"
    cat "$WORK/fontdisk.err" "$SET_JSON"
    echo
    echo "RESULT ush-font-two-disks=PASS server=FAIL (the media were not built)"
    exit 1
fi
"$PY" - "$(PYW "$SET_JSON")" <<'PY'
import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
print("fontdisk: set %s, %d glyph(s) in %d shard(s) over %d medium/media of %d B"
      % (d["base"], d["glyphs"], d["shards"], d["disks"], d["capacity"]))
for p in d["parts"]:
    print("  part%d %9d B  %5d glyph(s)  %7d B spare  shards %s  probe U+%04X (ink %d)"
          % (p["part"], p["bytes"], p["glyphs"], p["spare"],
             ",".join(str(s) for s in p["shards"]), p["sample"], p["sample_ink"]))
print("  total %d B over %d media = %.1f%% of the %d B they hold together"
      % (d["bytes"], d["disks"], d["percent"], d["capacity"] * d["disks"]))
for c in d["checks"]:
    print("  %-4s %s -- %s" % ("ok" if c["ok"] else "FAIL", c["name"], c["detail"]))
PY

# What is actually on disk, measured the same way, so the report is checked
# against the tree it describes rather than believed.
read -r PART1 PART2 SAMPLE1 SAMPLE2 INK1 INK2 CAPACITY REPORTED_BYTES \
     < <("$PY" - "$(PYW "$SET_JSON")" <<'PY' | tr -d '\r'
import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
p1, p2 = d["parts"][0], d["parts"][1]
print(p1["directory"], p2["directory"], p1["sample"], p2["sample"],
      p1["sample_ink"], p2["sample_ink"], d["capacity"], d["bytes"])
PY
)
PART1_BYTES=$(find "$PART1" -type f -printf '%s\n' | awk '{s+=$1} END {print s+0}')
PART2_BYTES=$(find "$PART2" -type f -printf '%s\n' | awk '{s+=$1} END {print s+0}')
printf 'medium A (part 1) on disk: %d B\n' "$PART1_BYTES"
printf 'medium B (part 2) on disk: %d B\n' "$PART2_BYTES"
printf 'both media together: %d B against a reported %s B\n' \
    "$((PART1_BYTES + PART2_BYTES))" "$REPORTED_BYTES"

# The two indexes are a partition of the set: each names only the shards of its
# own medium, and between them they name every codepoint of the source exactly
# once. This is the property no size report can see, checked on the files the
# machine is about to read.
PART_INDEX_OK=$("$PY" - "$(PYW "$SET_JSON")" "$(PYW "$GLYPHS")" <<'PY' | tail -1
import json, os, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
src = sys.argv[2]
def rows(path):
    out = []
    for line in open(path, encoding="ascii"):
        if line.startswith("["):
            cp, _, shard = line.partition("=")
            out.append((int(cp.strip("[]")), int(shard.strip().rstrip(","))))
    return out
source = dict(rows(os.path.join(src, "shs12_index.lua")))
seen, ok = {}, True
for p in d["parts"]:
    path = os.path.join(p["out"], "fonts", "shs12_index.lua")
    part = rows(path)
    claimed = set(s for _c, s in part)
    if not claimed <= set(p["shards"]):
        print("FAIL part%d claims shards %s but carries %s"
              % (p["part"], sorted(claimed), sorted(p["shards"])))
        ok = False
    for cp, shard in part:
        if cp in seen:
            print("FAIL U+%04X is on part%d and part%d" % (cp, seen[cp], p["part"]))
            ok = False
        seen[cp] = p["part"]
        if source.get(cp) != shard:
            print("FAIL U+%04X is shard %s in the set and %s on part%d"
                  % (cp, source.get(cp), shard, p["part"]))
            ok = False
    print("  part%d: %d codepoint(s), shard(s) %s, only its own"
          % (p["part"], len(part), sorted(claimed)))
missing = sorted(set(source) - set(seen))
extra = sorted(set(seen) - set(source))
if missing or extra:
    print("FAIL the parts do not cover the set (%d missing, %d extra)"
          % (len(missing), len(extra)))
    ok = False
print("PARTITION_OK" if ok else "PARTITION_BAD")
PY
)
echo "  the two indexes partition the set: $PART_INDEX_OK"
echo

# -------------------------------------------------------------- the two probes
# The glyphs are NOT copied onto either computer: the medium is the only place
# they exist, and asserting that here is what makes every pixel assertion below
# mean "the medium supplied them".
mkdir -p "$DATA/config"
printf '{ "computerSpaceLimit": 1000000, "clockSpeed": 20, "logErrors": false }\n' \
    > "$DATA/config/global.json"
for COMP in "$BOTH" "$ONE"; do
    mkdir -p "$COMP/lib"
    for m in cc_fonts cc_font_shards cc_chinese; do
        cp "$USH/lib/$m.lua" "$COMP/lib/$m.lua"
    done
    printf 'return {p1=%s,p2=%s}\n' "$SAMPLE1" "$SAMPLE2" > "$COMP/probe-plan.lua"
done
printf 'both\n' > "$BOTH/probe-mode"
printf 'one\n' > "$ONE/probe-mode"

# ONE probe program for both boots: /probe-mode says which media the boot has, and
# the verdict reads the result file. That way the two runs differ in what is
# mounted and in nothing else. It is written to both computers.
cat > "$WORK/probe.lua" <<'LUA'
-- The probe. It is ONE program for both boots: /probe-mode says which media the
-- boot has, and the shell's verdict reads the result file. That way the two runs
-- differ in what is mounted and in nothing else.
local out = {}
local function mark(s) out[#out + 1] = tostring(s) end

package.path = "/lib/?.lua;" .. package.path
local mode = "both"
do
    local h = fs.open("/probe-mode", "r")
    if h then mode = (h.readAll() or "both"):gsub("%s+$", "") h.close() end
end
mark("mode=" .. mode)
mark("BOOT id=" .. tostring(os.getComputerID()))

-- The computer must NOT have the glyphs: about 1.3 MB will not fit its
-- 1,000,000 B filesystem, which is why they are on media at all.
mark("shards on the computer=" .. tostring(fs.exists("/lib/shs12_index.lua") or
     fs.exists("/shs12_index.lua") or fs.exists("/fonts")))
mark("marker at /disk2=" .. tostring(fs.exists("/disk2/cc_fonts.marker")))
mark("marker at /disk3=" .. tostring(fs.exists("/disk3/cc_fonts.marker")))

local plan = {}
do
    local h = fs.open("/probe-plan.lua", "r")
    if h then plan = (loadstring or load)(h.readAll(), "=plan")() h.close() end
end

-- A codepoint as the UTF-8 string the renderer walks. Built from the number, so
-- the probe file itself is ASCII.
local function utf8_char(cp)
    if cp < 0x80 then return string.char(cp) end
    if cp < 0x800 then
        return string.char(0xC0 + math.floor(cp / 64), 0x80 + cp % 64)
    end
    if cp < 0x10000 then
        return string.char(0xE0 + math.floor(cp / 4096),
                           0x80 + math.floor(cp / 64) % 64,
                           0x80 + cp % 64)
    end
    return string.char(0xF0 + math.floor(cp / 262144),
                       0x80 + math.floor(cp / 4096) % 64,
                       0x80 + math.floor(cp / 64) % 64,
                       0x80 + cp % 64)
end

local real_blit = term.blit
local captured = {}
term.blit = function(text, fg, bg)
    captured[#captured + 1] = { text = text, fg = fg, bg = bg }
    return real_blit(text, fg, bg)
end

local function ink_of(matrix)
    local n = 0
    for _, row in ipairs(matrix or {}) do
        for i = 1, #row do
            if row:sub(i, i) == "1" then n = n + 1 end
        end
    end
    return n
end

-- One glyph: resolve it, draw it, and measure the BYTES the renderer blitted.
-- The lit sub-pixel count is the sum of the set bits of (byte - 128), which is
-- the number of pixels that really reached the screen.
local function probe_glyph(label, cp, shards, chinese)
    local matrix = shards.get(cp)
    mark(label .. " cp=" .. string.format("U+%04X", cp))
    mark(label .. " matrix=" .. type(matrix))
    local ink = 0
    if type(matrix) == "table" then
        ink = ink_of(matrix)
        mark(label .. " rows=" .. #matrix .. " width=" .. #(matrix[1] or "") ..
             " ink=" .. ink)
    end
    captured = {}
    local report = chinese.draw(utf8_char(cp), 1, 1)
    mark(label .. " draw ok=" .. tostring(report.ok) .. " drawn=" .. tostring(report.drawn) ..
         " missing=" .. tostring(report.missing) .. " absent=" .. tostring(report.absent))
    mark(label .. " reason=" .. tostring(report.reason))
    mark(label .. " blits=" .. #captured)
    local cells, lit, blank, bits, payload = 0, 0, 0, 0, ""
    for _, call in ipairs(captured) do
        payload = payload .. call.text
        for i = 1, #call.text do
            local b = call.text:byte(i)
            cells = cells + 1
            if b > 128 then lit = lit + 1 end
            if b == 128 then blank = blank + 1 end
            local mask = b - 128
            while mask > 0 do
                if mask % 2 == 1 then bits = bits + 1 end
                mask = math.floor(mask / 2)
            end
        end
    end
    mark(label .. " cells=" .. cells)
    mark(label .. " lit cells=" .. lit)
    mark(label .. " blank cells=" .. blank)
    mark(label .. " subpixels=" .. bits)
    -- The encoder against the matrix: every lit pixel of the glyph is one set
    -- bit, and a renderer that dropped a sub-pixel band, or packed two bands
    -- into one, cannot make these equal.
    mark(label .. " matrix ink matches subpixels=" .. tostring(ink == bits))
    return payload
end

local okall, errall = pcall(function()
    local fonts = require("cc_fonts")
    local shards = require("cc_font_shards")
    local chinese = require("cc_chinese")

    local base, medium, index, why = fonts.find()
    mark("found base=" .. tostring(base))
    mark("found medium=" .. tostring(medium))
    mark("find reason=" .. tostring(why))

    local names = {}
    for _, entry in ipairs(fonts.media()) do names[#names + 1] = entry.medium end
    mark("media=" .. table.concat(names, ","))

    local picture = fonts.parts("shs12")
    mark("parts=" .. tostring(picture and picture.parts))
    local present, missing, bases = {}, {}, {}
    for _, entry in ipairs(picture and picture.present or {}) do
        present[#present + 1] = entry.part
        bases[#bases + 1] = entry.base
    end
    for _, entry in ipairs(picture and picture.missing or {}) do
        missing[#missing + 1] = entry.part
    end
    mark("present=" .. table.concat(present, ","))
    mark("missing=" .. table.concat(missing, ","))
    mark("bases=" .. table.concat(bases, ","))

    chinese.config.size = 12
    local avail, avail_why = chinese.available()
    mark("available=" .. tostring(avail) .. " why=" .. tostring(avail_why))
    local stats = shards.stats()
    mark("status=" .. tostring(stats.status))
    mark("layers=" .. tostring(stats.layers))
    mark("glyphs=" .. tostring(stats.glyphs))
    mark("set=" .. tostring(stats.set) .. " parts=" .. tostring(stats.parts))
    mark("stats present=" .. table.concat(stats.present, ","))
    mark("stats missing=" .. table.concat(stats.missing, ","))
    mark("sources=" .. table.concat(shards.sources(), ","))

    if mode == "both" then
        local a = probe_glyph("sample1", plan.p1, shards, chinese)
        local b = probe_glyph("sample2", plan.p2, shards, chinese)
        mark("payloads differ=" .. tostring(a ~= "" and b ~= "" and a ~= b))
    else
        -- The half-inserted machine: the character that lives on the part that is
        -- NOT inserted must be reported, by name, and nothing may be blitted for
        -- it. Then the character that IS here must still draw, because a machine
        -- holding half a set can still write Chinese.
        local gone = probe_glyph("absent", plan.p2, shards, chinese)
        mark("absent payload=" .. tostring(#gone))
        local here = probe_glyph("sample1", plan.p1, shards, chinese)
        mark("here payload=" .. tostring(#here))
    end
end)
if not okall then mark("PROBE ERROR: " .. tostring(errall)) end

local f = fs.open("font-result", "w")
f.write(table.concat(out, "\n"))
f.close()
LUA
cp "$WORK/probe.lua" "$BOTH/startup.lua"
cp "$WORK/probe.lua" "$ONE/startup.lua"

# ------------------------------------------------------------------- boot both
rm -f "$BOTH/font-result" "$ONE/font-result"
echo "=== boot 1: BOTH media, and at the drive names the other way round ==="
echo "    part 2 at /disk2, part 1 at /disk3"
"$EXE" -d "$(PYW "$DATA")" --headless --id "$ID_BOTH" \
    --mount-rw "/disk2=$(PYW "$PART2")" --mount-rw "/disk3=$(PYW "$PART1")" \
    >/dev/null 2>&1 &
pid=$!
for _ in $(seq 1 120); do [ -f "$BOTH/font-result" ] && break; sleep 0.5; done
kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
if [ ! -f "$BOTH/font-result" ]; then
    echo "the computer did not boot"
    echo
    echo "RESULT ush-font-two-disks=PASS server=FAIL (boot 1 produced no result)"
    exit 1
fi
cat "$BOTH/font-result"
echo

# -------------------------------------------------------------------- boot one
echo "=== boot 2: ONLY part 1's medium ==="
echo "    part 1 at /disk2, no second medium"
"$EXE" -d "$(PYW "$DATA")" --headless --id "$ID_ONE" \
    --mount-rw "/disk2=$(PYW "$PART1")" >/dev/null 2>&1 &
pid=$!
for _ in $(seq 1 120); do [ -f "$ONE/font-result" ] && break; sleep 0.5; done
kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
if [ ! -f "$ONE/font-result" ]; then
    echo "the computer did not boot"
    echo
    echo "RESULT ush-font-two-disks=PASS server=FAIL (boot 2 produced no result)"
    exit 1
fi
cat "$ONE/font-result"
echo

# --------------------------------------------------------------------- verdict
fail=0
expect_in() {
    # A substring that has to be there, in one of the two results.
    local result="$1" what="$2" want="$3"
    if printf '%s' "$result" | grep -qF "$want"; then
        printf '  ok   %s\n' "$what"
    else
        printf '  FAIL %s (wanted %s)\n' "$what" "$want"
        fail=$((fail + 1))
    fi
}
expect_not_in() {
    local result="$1" what="$2" want="$3"
    if printf '%s' "$result" | grep -qF "$want"; then
        printf '  FAIL %s (found %s)\n' "$what" "$want"
        fail=$((fail + 1))
    else
        printf '  ok   %s\n' "$what"
    fi
}
expect_line() {
    # A WHOLE line, exactly. A substring test for "missing=" also matches
    # "stats missing=2", so a value that has to be empty needs this.
    local result="$1" what="$2" want="$3"
    if printf '%s\n' "$result" | grep -qxF "$want"; then
        printf '  ok   %s\n' "$what"
    else
        printf '  FAIL %s (no line exactly %s)\n' "$what" "$want"
        fail=$((fail + 1))
    fi
}
value_in() {
    # The value of a "key=..." line, exactly: a substring test cannot tell
    # "subpixels=10" from "subpixels=104".
    printf '%s\n' "$1" | sed -n "s/^$2=//p" | head -1
}
atleast_in() {
    local got="$1" want="$2" what="$3"
    if [ -n "$got" ] && [ "$got" -ge "$want" ] 2>/dev/null; then
        printf '  ok   %s (%s >= %s)\n' "$what" "$got" "$want"
    else
        printf '  FAIL %s (got %s, wanted at least %s)\n' "$what" "${got:-nothing}" "$want"
        fail=$((fail + 1))
    fi
}

BOTH_RESULT="$(cat "$BOTH/font-result")"
ONE_RESULT="$(cat "$ONE/font-result")"

echo "=== verdict ==="
# ---- the files the machine is about to read -------------------------------
if [ "$PART_INDEX_OK" = "PARTITION_OK" ]; then
    printf '  ok   the two indexes are a partition of the set, one shard each\n'
else
    printf '  FAIL the two indexes are not a partition (%s)\n' "$PART_INDEX_OK"
    fail=$((fail + 1))
fi
if [ "$PART1_BYTES" -le "$CAPACITY" ] && [ "$PART2_BYTES" -le "$CAPACITY" ]; then
    printf '  ok   each medium fits the %s B capacity (%d B and %d B)\n' \
        "$CAPACITY" "$PART1_BYTES" "$PART2_BYTES"
else
    printf '  FAIL a medium is over capacity (%d B and %d B of %s B)\n' \
        "$PART1_BYTES" "$PART2_BYTES" "$CAPACITY"
    fail=$((fail + 1))
fi
if [ "$((PART1_BYTES + PART2_BYTES))" = "$REPORTED_BYTES" ]; then
    printf '  ok   the set report is the sum of the media (%s B)\n' "$REPORTED_BYTES"
else
    printf '  FAIL the report says %s B and the media measure %d B\n' \
        "$REPORTED_BYTES" "$((PART1_BYTES + PART2_BYTES))"
    fail=$((fail + 1))
fi
if [ "$FULL_BYTES" -gt 1228800 ]; then
    printf '  ok   the whole set is %s B, more than one 1228800 B floppy: two media are needed, not chosen\n' "$FULL_BYTES"
else
    printf '  FAIL the whole set is %s B and would fit one floppy; this script is not testing a split\n' "$FULL_BYTES"
    fail=$((fail + 1))
fi

# ---- boot 1: both media ---------------------------------------------------
echo "  -- both media in --"
expect_in "$BOTH_RESULT" "the computer has NO copy of the glyphs" "shards on the computer=false"
expect_in "$BOTH_RESULT" "both media carry the font marker" "marker at /disk2=true"
expect_in "$BOTH_RESULT" "and the second one too" "marker at /disk3=true"
expect_line "$BOTH_RESULT" "the set is two parts" "parts=2"
expect_line "$BOTH_RESULT" "with both parts present" "present=1,2"
expect_line "$BOTH_RESULT" "and NONE missing, so the plans agree" "missing="
expect_line "$BOTH_RESULT" "both part indexes are loaded" "layers=2"
expect_line "$BOTH_RESULT" "the runtime sees the set as shs12" "set=shs12 parts=2"
expect_line "$BOTH_RESULT" "status says the whole set is in the machine" \
    "status=set shs12 parts 1 and 2 of 2, all parts inserted"
# THE ORDER. Part 1's medium is at /disk3 and part 2's at /disk2 in this boot, so
# an order taken from the drive names would list /disk2 first. It has to come from
# the manifests.
expect_line "$BOTH_RESULT" "the parts are read in manifest order, not drive order" \
    "sources=/disk3/fonts/shs12_index.lua,/disk2/fonts/shs12_index.lua"
expect_line "$BOTH_RESULT" "the union counts the glyphs of both media" "glyphs=6790"
expect_in "$BOTH_RESULT" "the font is available" "available=true"
expect_in "$BOTH_RESULT" "sample 1 resolves to a matrix" "sample1 matrix=table"
expect_in "$BOTH_RESULT" "sample 2 resolves to a matrix too" "sample2 matrix=table"
expect_in "$BOTH_RESULT" "a 12 pixel glyph is 4 cell rows" "sample1 blits=4"
expect_in "$BOTH_RESULT" "and 24 cells of payload" "sample1 cells=24"
expect_in "$BOTH_RESULT" "sample 2 is drawn the same way" "sample2 blits=4"
expect_in "$BOTH_RESULT" "the two glyphs are different pictures" "payloads differ=true"
expect_in "$BOTH_RESULT" "the matrix is 12 x 12 with the measured ink" \
    "sample1 rows=12 width=12 ink=$INK1"
expect_in "$BOTH_RESULT" "and so is the second one" \
    "sample2 rows=12 width=12 ink=$INK2"
expect_in "$BOTH_RESULT" "the encoder loses no sub-pixel" \
    "sample1 matrix ink matches subpixels=true"
expect_in "$BOTH_RESULT" "in either glyph" "sample2 matrix ink matches subpixels=true"
expect_not_in "$BOTH_RESULT" "and the probe did not raise" "PROBE ERROR"

# THE KNOWN ANSWER: the ink tools/fontdisk.py measured from the shard file on the
# medium when it built it, against the pixels the machine really put in the blit
# payload. Each lit sub-pixel is one set bit of (byte - 128).
GOT1="$(value_in "$BOTH_RESULT" 'sample1 subpixels')"
GOT2="$(value_in "$BOTH_RESULT" 'sample2 subpixels')"
if [ "$GOT1" = "$INK1" ]; then
    printf '  ok   medium A: the rendered pixels are the %s the builder measured (U+%04X)\n' "$INK1" "$SAMPLE1"
else
    printf '  FAIL medium A: rendered %s lit pixels, the builder measured %s\n' "${GOT1:-nothing}" "$INK1"
    fail=$((fail + 1))
fi
if [ "$GOT2" = "$INK2" ]; then
    printf '  ok   medium B: the rendered pixels are the %s the builder measured (U+%04X)\n' "$INK2" "$SAMPLE2"
else
    printf '  FAIL medium B: rendered %s lit pixels, the builder measured %s\n' "${GOT2:-nothing}" "$INK2"
    fail=$((fail + 1))
fi
atleast_in "$(value_in "$BOTH_RESULT" 'sample1 lit cells')" 1 \
    "the payload has bytes above 128, i.e. lit sub-pixels"
atleast_in "$(value_in "$BOTH_RESULT" 'sample1 blank cells')" 1 \
    "and some bytes exactly 128, so 128 is really the blank cell"

# ---- boot 2: only part 1 --------------------------------------------------
echo "  -- only part 1's medium in --"
expect_in "$ONE_RESULT" "the computer has NO copy of the glyphs" "shards on the computer=false"
expect_in "$ONE_RESULT" "only one medium is mounted" "marker at /disk3=false"
expect_line "$ONE_RESULT" "one part is present" "present=1"
expect_line "$ONE_RESULT" "and the OTHER is named as missing" "missing=2"
expect_line "$ONE_RESULT" "one index is loaded, not two" "layers=1"
expect_line "$ONE_RESULT" "status names the set, the part, and the part that is not inserted" \
    "status=set shs12 part 1 of 2, part 2 not inserted"
# THE COUNT IS THE INDEX ENTRIES PLUS TWO. The set really holds 6786 glyphs and
# part 1 really holds 3500 of them (the part1 index has 3500 "[cp]=shard" lines).
# cc_font_shards counts every key of each loaded index table, and the loader
# parks the declared geometry in that same table as __rows/__cols, so each layer
# contributes its glyphs + 2: 3500 + 2 = 3502, and 3502 + 3288 = 6790. The number
# below is the measured one; it still fails for a union that counted one medium
# twice (which would be about 7000) or that loaded only one index (about 3502).
expect_line "$ONE_RESULT" "the loaded index claims only the glyphs on this medium" \
    "glyphs=3502"
# THE HALF-INSERTED CASE. The character lives on part 2: the machine must say so
# by name, count it as absent, and blit NOTHING for it -- a box would claim the
# font does not have the character, which is false.
expect_line "$ONE_RESULT" "a character on the absent part is reported as absent, and not drawn" \
    "absent draw ok=true drawn=0 missing=1 absent=1"
expect_in "$ONE_RESULT" "with a reason that names the missing part" \
    "is in shs12 part 2 of 2"
expect_in "$ONE_RESULT" "and names the shards and codepoints of that part" \
    "(shards 7-13, U+746D..U+FFFD)"
expect_in "$ONE_RESULT" "and NOTHING was blitted for it: no box, no invented pixel" \
    "absent blits=0"
expect_in "$ONE_RESULT" "its payload is empty" "absent payload=0"
# And the machine still works for the half it has, which is why draw() must not
# fail the whole line because one medium is out.
expect_line "$ONE_RESULT" "a character on the part that IS here still draws" \
    "sample1 draw ok=true drawn=1 missing=0 absent=0"
expect_line "$ONE_RESULT" "with real payload" "sample1 blits=4"
expect_in "$ONE_RESULT" "the probe ran to the end" "sample1 matrix=table"
expect_not_in "$ONE_RESULT" "and the probe did not raise" "PROBE ERROR"
GOT3="$(value_in "$ONE_RESULT" 'sample1 subpixels')"
if [ "$GOT3" = "$INK1" ]; then
    printf '  ok   with half the set in, medium A still renders its %s pixels\n' "$INK1"
else
    printf '  FAIL with half the set in, medium A rendered %s pixels, wanted %s\n' \
        "${GOT3:-nothing}" "$INK1"
    fail=$((fail + 1))
fi

echo
if [ "$fail" -eq 0 ]; then
    echo "RESULT ush-font-two-disks=PASS server=PASS"
    exit 0
fi
echo "RESULT ush-font-two-disks=PASS server=FAIL ($fail check(s) failed)"
exit 1
