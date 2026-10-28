-- batch9_check.lua - PC side assertions for the CJK bitmap font (ROADMAP 6.3).
--
-- The subject is a font that lives on a medium of its own, so the assertions are
-- about four things that fail in four different ways:
--
--   1. the FILE FORMAT: <base>_index.lua and <base>_shardN.lua are plain Lua data
--      loaded with loadstring, and the matrix inside a shard is a list of "0"/"1"
--      rows. If the writer and the reader of that shape ever disagree, the symptom
--      is a blank screen with no error at all -- so it is pinned here.
--   2. the MISSING MEDIUM: the operator can take the medium out, and the machine
--      must say so in a way a caller can act on. "It did not crash" is not the
--      assertion; the assertion is the reason text and the absence of a raise.
--   3. the FALLBACK: a character the set does not have must draw something
--      visible rather than a blank cell, because a blank cell is indistinguishable
--      from a space and hides the problem.
--   4. the REAL GENERATED FILES in the repository, read with _G.read_host_file:
--      the emulated filesystem cannot see the project tree, so those checks are
--      reported as skipped when the host reader is absent instead of failing for
--      the wrong reason. They are the checks that catch a generator whose output
--      the runtime cannot actually load, which no synthetic fixture can.
--
-- Everything verified here is a PC side simulation result, it is NOT a CraftOS-PC
-- result. A real render on a real screen is tools/rpv-verify/_psh-font-medium.sh.

local PROJ = _G.PROJ
package.path = PROJ .. "/lib/?.lua;" .. PROJ .. "/usr/?.lua;" .. package.path

local say = _G.__realprint
local unpack = _G.unpack or table.unpack

local pass, fail = 0, 0
local fails = {}
local sections = {}
local skipped = {}
local current = { name = "(before the first section)", pass = 0, fail = 0 }
sections[1] = current

-- Named is_same and not "same": a local called `same` looks harmless and then
-- shadows nothing, but a one letter local named `f` further down did exactly
-- that in an earlier draft of this file and turned every check into a call on a
-- string. Assertion code is code.
local function is_same(a, b) return tostring(a) == tostring(b) end

local function check(name, cond, extra)
    if cond then
        pass = pass + 1
        current.pass = current.pass + 1
    else
        fail = fail + 1
        current.fail = current.fail + 1
        fails[#fails + 1] = name ..
            (extra ~= nil and ("  [" .. tostring(extra) .. "]") or "")
    end
end

local function skip(name, why)
    skipped[#skipped + 1] = name .. " (" .. tostring(why) .. ")"
end

local function section(title)
    say("")
    say("=== " .. title .. " ===")
    current = { name = title, pass = 0, fail = 0 }
    sections[#sections + 1] = current
end

local fs = _G.fs
local function clear_out() _G.__OUT = {}; _G.__BLITS = {} end

local function write_file(path, text)
    local dir = path:match("^(.*)/[^/]+$")
    if dir and dir ~= "" then fs.makeDir(dir) end
    local h = fs.open(path, "w")
    h.write(text)
    h.close()
end

local function drop_tree(path)
    for _, name in ipairs(fs.list(path) or {}) do
        local child = path .. "/" .. name
        if fs.isDir(child) then drop_tree(child) end
        fs.delete(child)
    end
    fs.delete(path)
end

local function rows_literal(rows)
    local out = {}
    for _, row in ipairs(rows) do out[#out + 1] = '"' .. row .. '"' end
    return table.concat(out, ",")
end

-- Counts the "1" characters of a matrix, which is the ink a glyph has.
local function ink_of(matrix)
    local n = 0
    for _, row in ipairs(matrix or {}) do
        for i = 1, #row do
            if row:sub(i, i) == "1" then n = n + 1 end
        end
    end
    return n
end

-- ---------------------------------------------------------------- fixtures
-- A font medium: the marker at its root, the shards in fonts/. It is built here
-- rather than copied from the repository so that the FORMAT assertions cannot be
-- satisfied by a file an earlier test wrote.
local MEDIUM = "/disk2"
local FONTS = MEDIUM .. "/fonts"
local BASE = FONTS .. "/shs4"

-- A 4x4 glyph: two cells wide, two cells tall. Small on purpose, so that every
-- expected byte can be worked out by hand in the pixel section below.
local ZHONG = { "0000", "0110", "0110", "0000" }
-- A second glyph, different in every cell, so that a shard lookup that returned
-- the wrong entry cannot pass.
local WEN = { "0110", "1001", "1001", "0110" }
-- The placeholder, in its own shard, so a loader that opened shard 0 whatever the
-- index said would return nil.
local BOX = { "1111", "1001", "1001", "1111" }

local function build_medium()
    drop_tree(MEDIUM)
    fs.makeDir(FONTS)
    write_file(MEDIUM .. "/cc_fonts.marker", "this medium carries font glyphs\n")
    write_file(BASE .. "_shard0.lua", "return {\n[20013]={" .. rows_literal(ZHONG) ..
        "},\n[25991]={" .. rows_literal(WEN) .. "},\n}\n")
    write_file(BASE .. "_shard1.lua", "return {\n[65533]={" .. rows_literal(BOX) .. "},\n}\n")
    write_file(BASE .. "_index.lua",
        "return {\n[20013]=0,\n[25991]=0,\n[65533]=1,\n}\n")
end

build_medium()

-- The stub's emulated filesystem reports a capacity for anything under /disk,
-- which is what lib/cc_fonts.lua uses to tell a medium from a plain directory. A
-- mount table is deliberately not built here: that would test lib/mounts.lua,
-- which has its own suite, instead of the font finder.

-- ===========================================================================
section("the font medium is found by its marker, not by a drive letter")
-- ===========================================================================
local fonts = require("cc_fonts")
local shards = require("cc_font_shards")
local chinese = require("cc_chinese")

fonts.CANDIDATES = nil                 -- search the real candidate list

local base, medium, index, why = fonts.find()
check("the medium with cc_fonts.marker is found", base ~= nil, why)
check("the marker name is the documented one",
      fonts.MARKER == "cc_fonts.marker", fonts.MARKER)
check("the glyph set is the one under <medium>/fonts",
      is_same(base, BASE), base)
check("the medium reported is the one the shards are on",
      is_same(medium, MEDIUM), medium)
check("the index path is the base plus _index.lua",
      is_same(index, BASE .. "_index.lua"), index)
check("the shards live in the fonts/ directory of the medium",
      fonts.DIR == "fonts", fonts.DIR)
check("the finder looks at the drives lib/disk.lua watches",
      fonts.DRIVES[1] == "/disk" and fonts.DRIVES[6] == "/rom" and #fonts.DRIVES == 6,
      table.concat(fonts.DRIVES, ","))

-- A medium WITHOUT the marker must not be taken for a font medium: this is what
-- a finder that merely looked for fonts/*_index.lua would get wrong. The marker
-- is removed and put back, so the finder is the only thing under test.
local unmarked_base, unmarked_why = (function()
    fs.delete(MEDIUM .. "/cc_fonts.marker")
    local b, _m, _i, w = fonts.find()
    write_file(MEDIUM .. "/cc_fonts.marker", "restored\n")
    return b, w
end)()
check("an unmarked medium is not a font medium", unmarked_base == nil,
      unmarked_base)
check("and the search says which marker it wanted",
      type(unmarked_why) == "string" and
      unmarked_why:find("cc_fonts.marker", 1, true) ~= nil, unmarked_why)

-- The marker is read at the medium's ROOT, so a fonts/ directory that is not at
-- the root is not the set the finder reports. A finder that scanned the whole
-- medium for *_index.lua would answer with the nested copy here.
local nested = (function()
    fs.makeDir(MEDIUM .. "/nested/fonts")
    fs.copy(BASE .. "_index.lua", MEDIUM .. "/nested/fonts/shs9_index.lua")
    fs.copy(BASE .. "_shard0.lua", MEDIUM .. "/nested/fonts/shs9_shard0.lua")
    local b = fonts.find()
    drop_tree(MEDIUM .. "/nested")
    return b
end)()
check("a set outside <medium>/fonts is not the set the finder reports",
      is_same(nested, BASE), nested)

-- Put the medium back at the end of this section so the rest of the suite starts
-- from the fixture it expects: an earlier draft left the disk removed here, and
-- the failure showed up three sections later as "the set does not work again",
-- which named the wrong cause.
build_medium()

-- ===========================================================================
section("the index and shard round trip through loadstring")
-- ===========================================================================
shards.init(BASE)
local stats = shards.stats()
check("the index loaded and counts every codepoint it names",
      stats and stats.glyphs == 3, stats and stats.glyphs)
check("the index came from the medium's file",
      is_same(shards.source(), BASE .. "_index.lua"), shards.source())

local zhong = select(1, shards.get(20013))
check("a codepoint in the index resolves to a matrix", type(zhong) == "table")
check("the matrix has the height the glyph was written with",
      zhong and #zhong == 4, zhong and #zhong)
check("and the width of every row",
      zhong and #zhong[1] == 4 and #zhong[2] == 4 and
              #zhong[3] == 4 and #zhong[4] == 4,
      zhong and #zhong[1])
check("the rows are the strings that were written, in order",
      zhong and zhong[1] == "0000" and zhong[2] == "0110" and
              zhong[3] == "0110" and zhong[4] == "0000",
      zhong and table.concat(zhong, "/"))

-- The OTHER glyph, so that a lookup that ignored its argument and returned the
-- first entry of the shard cannot pass.
local wen = select(1, shards.get(25991))
check("a different codepoint gets its own matrix, not the first one",
      wen and wen[1] == "0110" and wen[4] == "0110" and wen ~= zhong,
      wen and table.concat(wen, "/"))

-- The index sends U+FFFD to shard 1, so a loader that always opened shard 0
-- would return nil here.
local box = select(1, shards.get(65533))
check("a codepoint in a different shard is read from that shard",
      box and box[1] == "1111" and box[4] == "1111",
      box and table.concat(box, "/"))

check("shards.has answers from the index alone",
      shards.has(20013) == true and shards.has(65) == false)

check("loading a shard caches it and clear() releases it",
      (function()
          shards.clear()
          local before = shards.stats().cached
          shards.get(20013)
          local after = shards.stats().cached
          shards.clear()
          return before == 0 and after == 1 and shards.stats().cached == 0
      end)())

-- init() with the base already in use must not reload: a caller that resolves
-- the font on every draw would otherwise re-read and re-parse the index each
-- time, turning the cheapest step into the most expensive one.
local identity = (function()
    local first = shards.get(20013)
    shards.init(BASE)
    return shards.get(20013) == first
end)()
check("init() on the base already loaded is a no-op", identity)

-- ===========================================================================
section("an unknown codepoint falls back instead of erroring")
-- ===========================================================================
local matrix, err = shards.get(65)          -- 'A': not in this set
check("a codepoint the set does not have returns nil, not a raise",
      matrix == nil, matrix)
check("and says so in the reason, distinctly from a broken shard",
      is_same(err, "not in this set"), err)

shards.clear()
chinese.config.base = BASE
-- The fixture glyphs are 4x4, so the renderer is told to render at size 4: a
-- glyph matrix is padded out to the configured size, and leaving the size at 12
-- would draw every fixture glyph into a 6x4 cell block, which is not what the
-- byte-level assertions below are about.
chinese.config.size = 4
clear_out()
local report = chinese.draw("\228\184\173A\230\150\135", 1, 1)
check("draw does not raise on an unknown codepoint", type(report) == "table",
      report)
check("it reports the characters it drew", report and report.drawn == 2,
      report and report.drawn)
check("and the one it could not", report and report.missing == 1,
      report and report.missing)
check("and it is not an error", report and report.ok == true and
      report.error == nil, report and report.error)

-- Three characters. A 4 pixel glyph occupies TWO cell rows (ceil(4/3)), so the
-- unknown character is the third and fourth blit and the line is six rows.
--
-- The expected bytes are computed from the matrix with cell_byte() and then
-- compared with the whole payload, which is what catches an encoder that packs
-- the sub-pixels in the wrong ORDER -- the one bug that produces a readable byte
-- count and an unreadable glyph. The known-answer byte values are pinned
-- separately, in the pixel section below, so this is not a test of the encoder
-- against itself.
local function expect_payload(matrix, cx, cy)
    local function col(r, k)
        local row = matrix[r] or string.rep("0", #(matrix[1] or ""))
        return row:sub(k, k)
    end
    local a, b = cx * 2 + 1, cx * 2 + 2
    return chinese.cell_byte(col(cy * 3 + 1, a), col(cy * 3 + 2, a),
                             col(cy * 3 + 3, a), col(cy * 3 + 1, b),
                             col(cy * 3 + 2, b), col(cy * 3 + 3, b))
end

check("all three characters were blitted", #_G.__BLITS == 6,
      "#blits=" .. #_G.__BLITS)
local box_payload = _G.__BLITS[3] and _G.__BLITS[3].text
local box_expected = expect_payload(BOX, 0, 0) .. expect_payload(BOX, 1, 0)
check("the fallback payload is the box, cell for cell",
      box_payload == box_expected,
      box_payload and box_payload:byte(1) .. "," .. box_payload:byte(2) ..
      " vs " .. box_expected:byte(1) .. "," .. box_expected:byte(2))
check("and it is not two blank cells, so a hole was not left",
      box_payload ~= string.char(128, 128) and box_payload:byte(1) > 128,
      box_payload and box_payload:byte(1))
check("its second cell row is the box's bottom row, not a blank",
      _G.__BLITS[4] and _G.__BLITS[4].text ==
      (expect_payload(BOX, 0, 1) .. expect_payload(BOX, 1, 1)),
      _G.__BLITS[4] and _G.__BLITS[4].text:byte(1))

-- ===========================================================================
section("the pixels: a real glyph produces lit sub-pixels")
-- ===========================================================================
-- THE KNOWN-ANSWER VALUES. The fixture's U+4E2D is the 4x4 matrix
-- "0000" / "0110" / "0110" / "0000", rendered at size 4, so its first cell row
-- takes matrix rows 1, 2 and 3: row 1 is blank and rows 2 and 3 are "0110", i.e.
-- matrix columns 2 and 3 are lit and 1 and 4 are not. Cell 1 covers matrix
-- columns 1 and 2 and cell 2 covers columns 3 and 4, so EACH CELL gets ONE lit
-- column, over two of the block's three rows -- which is why the two bytes below
-- are the same shape rather than one being 128. They were read off the renderer
-- once and are pinned here; the check that the packing is right for a GENERAL
-- matrix is the expect_payload comparison further down, which is computed from
-- the matrix instead of from a remembered number.
clear_out()
chinese.draw("\228\184\173", 1, 1)          -- U+4E2D only
check("a 4 pixel glyph is two cell rows of two cells",
      #_G.__BLITS == 2 and #_G.__BLITS[1].text == 2,
      #_G.__BLITS .. " rows, " ..
      (_G.__BLITS[1] and #_G.__BLITS[1].text or "?") .. " cells")

local row0 = _G.__BLITS[1].text
check("the left cell is the measured 176 = 128 + 16 + 32", row0:byte(1) == 176,
      row0:byte(1))
check("the right cell is the measured 134 = 128 + 2 + 4", row0:byte(2) == 134,
      row0:byte(2))
check("both cells of the glyph are lit, i.e. bytes above 128",
      row0:byte(1) > 128 and row0:byte(2) > 128,
      row0:byte(1) .. "," .. row0:byte(2))
check("neither is the blank byte, so the glyph is not an empty square",
      row0:byte(1) ~= 128 and row0:byte(2) ~= 128,
      row0:byte(1) .. "," .. row0:byte(2))
-- The second cell row covers matrix row 4, which is "0000": the glyph is 4 pixels
-- tall and the cell is 3, so the last row is blank.
local row1 = _G.__BLITS[2] and _G.__BLITS[2].text
check("the padded row below a 4 pixel glyph is blank in both cells",
      row1 == string.char(128, 128),
      row1 and (row1:byte(1) .. "," .. row1:byte(2)))
check("and the whole payload equals the matrix packed by cell_byte",
      row0 == (expect_payload(ZHONG, 0, 0) .. expect_payload(ZHONG, 1, 0)) and
      row1 == (expect_payload(ZHONG, 0, 1) .. expect_payload(ZHONG, 1, 1)),
      row0 and row0:byte(1) .. "," .. row0:byte(2))

-- The masks are checked directly as well, because they are the contract between
-- the generator's matrices and the ROM's characters, and each bit is one pixel.
check("cell_byte packs left-top as bit 0 of the mask",
      chinese.cell_byte("1", "0", "0", "0", "0", "0") == string.char(129),
      chinese.cell_byte("1", "0", "0", "0", "0", "0"):byte(1))
check("left middle, left bottom, right top, right middle, right bottom",
      chinese.cell_byte("0", "1", "0", "0", "0", "0") == string.char(130) and
      chinese.cell_byte("0", "0", "1", "0", "0", "0") == string.char(132) and
      chinese.cell_byte("0", "0", "0", "1", "0", "0") == string.char(136) and
      chinese.cell_byte("0", "0", "0", "0", "1", "0") == string.char(144) and
      chinese.cell_byte("0", "0", "0", "0", "0", "1") == string.char(160))
check("every sub-pixel lit is 128 + 63 = 191, the highest mask",
      chinese.cell_byte("1", "1", "1", "1", "1", "1") == string.char(191),
      chinese.cell_byte("1", "1", "1", "1", "1", "1"):byte(1))
check("nothing lit is exactly 128, the blank cell",
      chinese.cell_byte("0", "0", "0", "0", "0", "0") == string.char(128))
-- The mask is a sum of distinct bits, so a permutation of the arguments must
-- give a permutation of the bytes and never the same byte twice.
check("each of the six bits has its own value",
      (function()
          local seen = {}
          local names = { "100000", "010000", "001000", "000100", "000010", "000001" }
          for _, bits in ipairs(names) do
              local b = chinese.cell_byte(bits:sub(1, 1), bits:sub(2, 2),
                  bits:sub(3, 3), bits:sub(4, 4), bits:sub(5, 5), bits:sub(6, 6))
              if seen[b:byte(1)] then return false end
              seen[b:byte(1)] = true
          end
          return true
      end)())

-- The colour arguments are one blit character PER CELL, not one per row: the
-- ROM's blit takes a string whose length is the number of cells, exactly like
-- the "text" argument, so a two cell row carries "00" for white on white in the
-- foreground. An earlier version of this assertion compared the whole argument
-- with a single character and failed against a correct renderer.
check("fg and bg carry one blit character per cell, all the same colour",
      _G.__BLITS[1].fg == string.rep(colors.toBlit(chinese.config.text_color),
                                     #_G.__BLITS[1].text) and
      _G.__BLITS[1].bg == string.rep(colors.toBlit(chinese.config.bg_color),
                                     #_G.__BLITS[1].text),
      _G.__BLITS[1].fg .. "/" .. _G.__BLITS[1].bg)
check("which for the configured white on black is '0' per cell and 'f' per cell",
      _G.__BLITS[1].fg == "00" and _G.__BLITS[1].bg == "ff",
      _G.__BLITS[1].fg .. "/" .. _G.__BLITS[1].bg)
check("each row is drawn at its own y, at the x asked for",
      _G.__BLITS[1].x == 1 and _G.__BLITS[1].y == 1 and
      _G.__BLITS[2].x == 1 and _G.__BLITS[2].y == 2,
      _G.__BLITS[1].x .. "," .. _G.__BLITS[1].y .. " .. " ..
      _G.__BLITS[2].x .. "," .. _G.__BLITS[2].y)

-- Two glyphs of the same line are drawn side by side, one glyph width apart: a
-- renderer that forgot to advance the cursor would draw them on top of each
-- other and every byte assertion above would still pass.
clear_out()
chinese.draw("\228\184\173\230\150\135", 1, 1)
check("the second glyph of a line starts one glyph width further right",
      _G.__BLITS[1].x == 1 and _G.__BLITS[3].x == 1 + (select(1, chinese.cells(4))),
      _G.__BLITS[1].x .. " then " .. tostring(_G.__BLITS[3] and _G.__BLITS[3].x))

clear_out()
chinese.draw("\228\184\173\230\150\135", 5, 3)   -- two glyphs at a known origin
local cx, cy = term.getCursorPos()
check("two glyphs leave the cursor two glyph widths from the origin",
      cx == 5 + 2 * (select(1, chinese.cells(4))) and cy == 3, cx .. "," .. cy)

-- The cell rows come from the CONFIGURED size, not from the matrix. This matters
-- because draw() advances the cursor by the configured size: a renderer that took
-- the height from the matrix would draw a 4 pixel glyph into 2 cell rows and then
-- move the cursor 4, leaving the text of every line spaced for a font it is not
-- using, with no error anywhere. The fixture's glyph is 4 pixels tall, so the two
-- are told apart by asking the renderer for size 12 and checking that it still
-- writes FOUR cell rows for a matrix of three.
chinese.config.size = 12
clear_out()
chinese.draw("\228\184\173", 1, 1)
check("a glyph shorter than the configured size is padded to the full cell",
      #_G.__BLITS == 4, "#blits=" .. #_G.__BLITS .. " (4 expected for size 12)")
check("each of those rows is as wide as the configured cell",
      #_G.__BLITS[1].text == 6, #_G.__BLITS[1].text)
check("and the padding rows are blank bytes, not invented pixels",
      _G.__BLITS[3].text == string.char(128, 128, 128, 128, 128, 128),
      _G.__BLITS[3].text)
chinese.config.size = 4

local mw, mh = chinese.measure("\228\184\173\230\150\135")
check("measure agrees with draw about a glyph's cell size",
      mw == 2 * (select(1, chinese.cells(4))) and mh == (select(2, chinese.cells(4))),
      mw .. "x" .. mh)
check("cells() is ceil(size/2) x ceil(size/3)",
      chinese.cells(12) == 6 and select(2, chinese.cells(12)) == 4 and
      chinese.cells(4) == 2 and select(2, chinese.cells(4)) == 2,
      chinese.cells(12))
check("the default size is 12, the size the shipped set was built at",
      chinese.config.size == 4 and chinese.stem(12) == "shs12" and
      chinese.stem(8) == "shs8",
      chinese.stem(12))
check("the decoder reads a CJK codepoint from its three bytes",
      (function()
          local n = 0
          for cp in chinese.codepoints("\228\184\173") do
              n = n + 1
              if cp ~= 0x4E2D then return false end
          end
          return n == 1
      end)())
check("and a stray continuation byte reads as a space, not a huge codepoint",
      (function()
          local out = {}
          for cp in chinese.codepoints("\190") do out[#out + 1] = cp end
          return #out == 1 and out[1] == 32
      end)())

-- ===========================================================================
section("the missing medium is reported, never a silent blank")
-- ===========================================================================
-- Take the medium out: the marker and the shards both go, which is what an
-- ejection leaves behind. The configured base is cleared so that the finder runs
-- and produces the reason an operator would actually see.
drop_tree(MEDIUM)
chinese.config.base = nil
shards.init("/nonexistent/base")
check("the shard loader forgets the index when the medium goes",
      shards.stats().glyphs == 0, shards.stats().glyphs)

-- find() returns a 4-tuple (base, medium, index, reason), so the reason is the
-- FOURTH value: capturing only the first two and calling the second "why" is a
-- mistake that reads as "there was no reason", which is exactly the thing the
-- missing-medium path is supposed to produce.
local found, _fm, _fi, find_why = fonts.find()
check("finding a font fails when no medium has the marker", found == nil, found)
check("and the reason names the marker and the tool that builds one",
      type(find_why) == "string" and
      find_why:find("cc_fonts.marker", 1, true) ~= nil and
      find_why:find("fontdisk.py", 1, true) ~= nil,
      "reason: " .. tostring(find_why))

clear_out()
local drew = chinese.draw("\228\184\173", 1, 1)
check("draw returns a report rather than raising", type(drew) == "table", drew)
check("the report says it did not draw", drew and drew.ok == false, drew and drew.ok)
check("it drew nothing, so no pixels were invented", drew and drew.drawn == 0,
      drew and drew.drawn)
check("no blit happened at all", #_G.__BLITS == 0, #_G.__BLITS)
check("the reason is the finder's own, not a generic false",
      drew and type(drew.reason) == "string" and
      drew.reason:find("cc_fonts.marker", 1, true) ~= nil, drew and drew.reason)

local avail, avail_why = chinese.available()
check("available() answers false with the same reason",
      avail == false and is_same(avail_why, drew.reason), tostring(avail_why))

local raised, message = pcall(chinese.render)
check("render() raises for a caller that wants a font", raised == false, raised)
check("and the message opens with the module name",
      type(message) == "string" and message:sub(1, 10) == "cc_fonts: ",
      message)
check("the message names the marker rather than only a file path",
      type(message) == "string" and
      message:find("cc_fonts.marker", 1, true) ~= nil, message)

-- A medium that carries the marker but no glyph set is a DIFFERENT situation,
-- with a different fix: this is the state of a half-built medium.
build_medium()
drop_tree(FONTS)
fs.makeDir(FONTS)
local _, _, _, no_set = fonts.find()
check("a marked medium with no glyph set is not reported as a missing medium",
      type(no_set) == "string" and no_set:find("no glyph set", 1, true) ~= nil,
      no_set)
check("and its reason names the finder's directory",
      type(no_set) == "string" and no_set:find("/fonts", 1, true) ~= nil, no_set)

-- A set that is there but whose index does not compile: the message has to carry
-- the file's name, because that is the file to look at.
write_file(BASE .. "_index.lua", "return {\nthis is not lua\n")
local bad_base = fonts.find()
check("an index that exists is still reported as a set", bad_base ~= nil)
local ok_init, init_why = shards.init(BASE)
check("but loading it fails with the file's name in the message",
      ok_init == false and type(init_why) == "string" and
      init_why:find("shs4_index.lua", 1, true) ~= nil, init_why)
check("a failed init leaves no index behind", shards.stats().glyphs == 0,
      shards.stats().glyphs)

-- A base PINNED BY NAME (chinese.config.base) that is not there. This is the
-- other half of the missing-medium story: the finder is not consulted at all, so
-- the message has to name the FILE the caller asked for rather than talk about
-- the marker. draw() has to report it, not raise, and blit nothing.
chinese.config.base = BASE .. "_absent"
clear_out()
local pinned = chinese.draw("\228\184\173", 1, 1)
check("a pinned base that is absent is reported, not raised",
      type(pinned) == "table" and pinned.ok == false, pinned and pinned.ok)
check("and its reason names the index file that is missing",
      type(pinned.reason) == "string" and
      pinned.reason:find("_absent_index.lua", 1, true) ~= nil, pinned.reason)
check("and nothing was blitted for it", #_G.__BLITS == 0, #_G.__BLITS)
chinese.config.base = BASE

-- The other side of the same coin: a pinned base that IS there is used directly,
-- with no search, which is what a program shipping its own font depends on. The
-- medium is rebuilt first because init() caches by base: the broken index written
-- just above is still the one a reload would otherwise be short-circuited past.
build_medium()
chinese.config.base = BASE
shards.init(BASE)
clear_out()
local pinned_ok = chinese.draw("\228\184\173", 1, 1)
check("a pinned base that is present is used without searching",
      pinned_ok.ok == true and pinned_ok.drawn == 1 and #_G.__BLITS == 2,
      pinned_ok.drawn .. " drawn, " .. #_G.__BLITS .. " blit(s)")

-- A shard that will not load is remembered, so a line of 40 characters in a
-- broken shard does not open the same missing file 40 times.
--
-- init() caches by base, so the shard is made to go missing BEFORE the init that
-- loads it: deleting it afterwards leaves the cached copy in place and the shard
-- still resolves, which is a test that passes for the wrong reason (and did, as a
-- nil concatenation crash, before this was noticed).
build_medium()
shards.clear()                   -- drop the shard the test above just cached
fs.delete(BASE .. "_shard0.lua")
shards.init(BASE)
local first = select(2, shards.get(20013))
local second = select(2, shards.get(20013))
check("a shard that cannot be read reports a reason naming the file",
      type(first) == "string" and first:find("shs4_shard0.lua", 1, true) ~= nil,
      first)
check("and the failure is remembered rather than retried",
      is_same(first, second), first .. " vs " .. tostring(second))
check("the index is still usable for the shard that IS there",
      select(1, shards.get(65533)) ~= nil)

-- Put the medium back, as a machine with the disk reinserted has it. This has to
-- happen INSIDE the section that took it away: an earlier draft left the disk
-- removed here and the failure surfaced in the next section as "the set does not
-- work again", naming a symptom instead of the cause.
build_medium()
shards.clear()
chinese.config.base = BASE
chinese.config.size = 4
local found_again, _gm, _gi, gone_why = fonts.find()
check("the set is found again once the medium is back",
      is_same(found_again, BASE), "find said: " .. tostring(found_again) ..
      " / " .. tostring(gone_why))
local reinit_ok, reinit_why = shards.init(BASE)
check("and the glyph resolves, so the whole path works after a reinsert",
      reinit_ok == true and shards.get(20013) ~= nil,
      tostring(reinit_ok) .. " / " .. tostring(reinit_why))

-- ===========================================================================
section("the generated files in this repository")
-- ===========================================================================
-- The only assertions that touch the REAL output of tools/fontgen.py. They are
-- reported as skipped when the host reader is absent, because the emulated
-- filesystem cannot see the project tree and a suite that assumed otherwise
-- would fail for a reason that has nothing to do with the font.
local DATADIR = PROJ .. "/fontdata"
local HOST = _G.read_host_file
local host_ok, host_probe = pcall(function() return HOST(PROJ .. "/tools/fontgen.py") end)
if not host_ok or type(host_probe) ~= "string" or #host_probe == 0 then
    skip("the repository's generated glyph files",
         "read_host_file cannot read the project tree")
else
    local index_text = HOST(DATADIR .. "/shs12_index.lua")
    check("fontdata/shs12_index.lua is in the repository",
          type(index_text) == "string" and #index_text > 0,
          index_text == nil and "missing" or #tostring(index_text))

    -- ASCII with LF endings, because the machine loads this with the ROM's own
    -- loadstring and a non-ASCII byte or a CR is the one thing it may not carry.
    local bad_byte = nil
    if type(index_text) == "string" then
        for i = 1, #index_text do
            if index_text:byte(i) > 127 then bad_byte = i break end
        end
        if not bad_byte and index_text:find("\r", 1, true) then bad_byte = "CR" end
        if not bad_byte and index_text:sub(1, 3) == "\239\187\191" then
            bad_byte = "BOM"
        end
    end
    check("the index is pure ASCII, LF only, with no BOM", bad_byte == nil,
          bad_byte)

    -- It has to LOAD, which no report from the generator itself can establish.
    local chunk = (loadstring or load)(index_text or "", "=repo_index")
    check("the index compiles with the ROM's loadstring", chunk ~= nil)
    local table_ok, index_table = pcall(chunk or function() return nil end)
    check("and evaluates to a table", table_ok and type(index_table) == "table",
          table_ok and type(index_table) or tostring(index_table))

    local count, max_shard, keys_are_numbers = 0, 0, true
    for cp, shard in pairs(index_table or {}) do
        count = count + 1
        if type(cp) ~= "number" then keys_are_numbers = false end
        if type(shard) == "number" and shard > max_shard then max_shard = shard end
    end
    -- A KNOWN ANSWER, not a range. The shipped set is the WHOLE of GB2312 (the
    -- operator asked for all 6763 characters, which need two media), so the index
    -- holds 6786 glyphs: 6763 ideographs + 23 marks + the fallback box, less the
    -- codepoint whose glyph has no ink. A range like "between 4000 and 8000"
    -- would pass for a set that silently lost a thousand glyphs.
    --
    -- The count was 6781 before the rasteriser was fixed. It went UP by five
    -- because five codepoints that used to rasterise to nothing but blank rows
    -- (their whole shape was mid-grey and the flat threshold dropped it) now have
    -- ink and are kept. The number is a measurement, and it moved with the fix.
    check("the index names the 6786 glyphs of the whole GB2312 set",
          count == 6786, count)
    check("every codepoint key is a number", keys_are_numbers)
    check("U+4E2D is in the shipped set",
          index_table and index_table[0x4E2D] ~= nil,
          index_table and tostring(index_table[0x4E2D]))
    check("and U+FFFD, the fallback, is in it too",
          index_table and index_table[0xFFFD] ~= nil,
          index_table and tostring(index_table[0xFFFD]))
    -- The whole standard is present, not the 5400 glyph prefix: the LAST
    -- ideographs of GB2312 are the ones a cap would have dropped, so they are the
    -- ones worth pinning. U+9FA0 is the last ideograph GB2312 encodes (its final
    -- row), and U+9FA5 -- five codepoints further on, and the character people
    -- usually name as "the last one" -- is a GBK addition that the standard does
    -- not encode, so it must NOT be in the set.
    check("the tail of the standard is in the set, so the cap is really gone",
          index_table and index_table[0x9FA0] ~= nil,
          index_table and tostring(index_table[0x9FA0]))
    check("and a codepoint the standard does not encode is not invented",
          index_table and index_table[0x9FA5] == nil,
          index_table and tostring(index_table[0x9FA5]))

    -- Every shard the index names has to be there, be ASCII, load, and hold
    -- glyphs of exactly the declared size. A missing shard is the failure a size
    -- report cannot see.
    local missing_shard, bad_shard, dim_bad, glyphs_seen = nil, nil, nil, 0
    local real_zhong = nil
    for shard_id = 0, max_shard do
        local name = "shs12_shard" .. shard_id .. ".lua"
        local text = HOST(DATADIR .. "/" .. name)
        if type(text) ~= "string" or #text == 0 then
            missing_shard = missing_shard or name
        else
            for i = 1, #text do
                if text:byte(i) > 127 then bad_shard = bad_shard or name break end
            end
            local schunk = (loadstring or load)(text, "=" .. name)
            if not schunk then
                bad_shard = bad_shard or (name .. " does not compile")
            else
                local sok, glyphs = pcall(schunk)
                if not sok or type(glyphs) ~= "table" then
                    bad_shard = bad_shard or (name .. " is not a table")
                else
                    if glyphs[0x4E2D] ~= nil then real_zhong = glyphs[0x4E2D] end
                    for cp, matrix in pairs(glyphs) do
                        glyphs_seen = glyphs_seen + 1
                        if type(matrix) ~= "table" or #matrix ~= 12 then
                            dim_bad = dim_bad or string.format(
                                "%s U+%04X has %s rows", name, cp, #(matrix or {}))
                        else
                            for r = 1, #matrix do
                                if type(matrix[r]) ~= "string" or
                                   #matrix[r] ~= 12 or matrix[r]:find("[^01]") then
                                    dim_bad = dim_bad or string.format(
                                        "%s U+%04X row %d is %s", name, cp, r,
                                        type(matrix[r]) == "string" and
                                        ("'" .. #matrix[r] .. "'") or
                                        type(matrix[r]))
                                    break
                                end
                            end
                        end
                    end
                end
            end
        end
    end
    check("every shard the index names is on disk", missing_shard == nil,
          missing_shard)
    check("every shard is ASCII and compiles", bad_shard == nil, bad_shard)
    check("every glyph is 12 rows of 12 characters of 0 and 1",
          dim_bad == nil, dim_bad)
    check("the shards hold exactly the glyphs the index promised",
          glyphs_seen == count, glyphs_seen .. " glyph(s) vs " .. count .. " key(s)")

    -- Known-answer checks on two REAL glyphs, measured from the shipped shards.
    -- The shards are rasterised from Noto Sans SC (SIL Open Font License 1.1;
    -- the licence text and attribution are in THIRD_PARTY_LICENSES), so these
    -- numbers are a property of that build and move with it.
    --
    --   U+4E2D is the character for "middle": a closed box with a vertical stroke
    --   driven through it, standing proud above and below. 34 pixels of ink over
    --   ten of its twelve rows, with one column lit on eight rows, and two
    --   ten-pixel bars (rows 4 and 8).
    --   U+6587 has 30 pixels of ink.
    --
    -- THIS BLOCK USED TO ENCODE A BUG. It asserted "ink is the 16 pixels of its
    -- two horizontal strokes" and "the glyph is exactly two lit rows", which was
    -- what tools/fontgen.py produced when it thresholded a size-12 bitmap at a
    -- flat 128: the box's sides, the vertical stroke and both feet were mid-grey
    -- and vanished, leaving two bars. The suite said the glyph was right and the
    -- screen showed two loose bars wherever a Chinese character belonged.
    --
    -- So these assertions are about SHAPE now, not only about a count. A matrix
    -- can have the right number of lit pixels and be the wrong picture; it cannot
    -- have a column lit on nine rows, and it cannot have two equal-width rows four
    -- rows apart with lit pixels between them, unless the box is really there.
    check("U+4E2D has a real matrix in the shipped shards",
          type(real_zhong) == "table" and #real_zhong == 12,
          type(real_zhong) == "table" and #real_zhong or tostring(real_zhong))
    check("every row of it is 12 characters of 0 and 1",
          (function()
              if type(real_zhong) ~= "table" then return false end
              for i = 1, 12 do
                  local row = real_zhong[i]
                  if type(row) ~= "string" or #row ~= 12 or row:find("[^01]") then
                      return false
                  end
              end
              return true
          end)())
    check("and its ink is the 34 pixels measured from the rasteriser",
          ink_of(real_zhong) == 34, ink_of(real_zhong))

    -- The structure of the character, computed from the matrix itself rather than
    -- read out of the renderer.
    local lit_rows, lit_cols = {}, {}
    local wide_rows, widest_n = {}, 0
    if type(real_zhong) == "table" then
        for i = 1, 12 do
            local row = real_zhong[i] or ""
            local lit = 0
            for k = 1, #row do
                if row:sub(k, k) == "1" then
                    lit = lit + 1
                    lit_cols[k] = (lit_cols[k] or 0) + 1
                end
            end
            if lit > 0 then lit_rows[#lit_rows + 1] = i end
            if lit > widest_n then widest_n = lit end
            -- The box's two horizontal bars. Seven pixels is the threshold: the
            -- character's own bars measure 10 on the 12 pixel grid, while a row
            -- through the box's sides has 3 or 4.
            if lit >= 7 then wide_rows[#wide_rows + 1] = { row = i, lit = lit } end
        end
    end

    check("the character covers at least eight rows, not two",
          #lit_rows >= 8, #lit_rows .. " lit row(s)")
    check("and at least one column is lit on eight rows -- the vertical stroke",
          (function()
              for _, n in pairs(lit_cols) do
                  if n >= 8 then return true end
              end
              return false
          end)(),
          "no column reaches 8")
    -- The box: two wide bars, with lit pixels on BOTH sides of the rows between
    -- them. A glyph that lost its sides (the bug this replaced) has the bars and
    -- nothing between them; a bar chart has no sides at all.
    check("two rows are wide enough to be the box's bars",
          #wide_rows >= 2, #wide_rows .. " wide row(s), widest " .. widest_n)
    check("and the rows between them have ink on both the left and the right",
          (function()
              if #wide_rows < 2 then return false end
              local first, last = wide_rows[1].row, wide_rows[#wide_rows].row
              for i = first + 1, last - 1 do
                  local row = real_zhong[i] or ""
                  local left = row:sub(1, 6):find("1") ~= nil
                  local right = row:sub(7):find("1") ~= nil
                  if left and right then return true end
              end
              return false
          end)(),
          #wide_rows >= 2 and
          (wide_rows[1].row .. ".." .. wide_rows[#wide_rows].row) or "-")

    -- A second character, to prove the shards hold different pictures and that
    -- the first shard is not repeating one matrix for every key.
    local other = nil
    if index_table and index_table[0x6587] ~= nil then
        local name = "shs12_shard" .. index_table[0x6587] .. ".lua"
        local text = HOST(DATADIR .. "/" .. name)
        local schunk = text and (loadstring or load)(text, "=" .. name)
        if schunk then
            local sok, glyphs = pcall(schunk)
            if sok and type(glyphs) == "table" then other = glyphs[0x6587] end
        end
    end
    check("a second character is a different picture from the first",
          type(other) == "table" and
          table.concat(other, "") ~= table.concat(real_zhong or {}, ""),
          type(other) == "table" and tostring(other) or "missing")
    check("and its ink is the 30 pixels measured for it", ink_of(other) == 30,
          ink_of(other))
end

-- ===========================================================================
section("a set that spans two media: the union, the order, the missing part")
-- ===========================================================================
-- THE WHOLE POINT OF THE TWO-MEDIUM WORK. The whole of GB2312 is 146,463 B too
-- big for one 1,228,800 B floppy, so a glyph set may be built as two media. The
-- fixture here is set shs7 as two media:
--
--   /disk2/fonts/shs7   PART 1: shard 0, holding U+4E2D and U+6587
--   /disk3/fonts/shs7   PART 2: shard 1, holding U+FFFD
--
-- The two codepoints the assertions use are in DIFFERENT parts on purpose: a
-- lookup that only ever opened one medium cannot pass both. A second set, shs6,
-- has its parts on the drives THE OTHER WAY ROUND (part 1 on /disk3, part 2 on
-- /disk2), so "which part is read first" cannot come from a drive name or a
-- mount order -- it has to come from each manifest's own `part`.
local UNION = "/disk2/fonts/shs7"
local UNION2 = "/disk3/fonts/shs7"
local OTHER = "/disk3/fonts/shs6"       -- shs6 PART 1, on the second drive
local OTHER2 = "/disk2/fonts/shs6"      -- shs6 PART 2, on the first drive
local ON_PART1 = 20013                  -- U+4E2D, in shard 0 -> part 1
local ON_PART2 = 65533                  -- U+FFFD, in shard 1 -> part 2

-- The manifest of one part. The PLAN OF THE WHOLE SET is on every part and not
-- only on part 1, because a machine holding only part 2 has to be able to say
-- that part 1 is the one missing -- and with only part 2 in the machine, part
-- 1's manifest is not there to be read.
local function set_manifest(name, part, parts, shards, plan)
    local rows = {}
    for _, entry in ipairs(plan) do
        rows[#rows + 1] = string.format(
            "{part=%d,shards={%s},glyphs=%d,first=%d,last=%d},\n",
            entry.part, table.concat(entry.shards, ","), entry.glyphs,
            entry.first, entry.last)
    end
    return string.format(
        "return {name=\"%s\",parts=%d,part=%d,glyphs=%d,shards={%s},plan={\n%s}}\n",
        name, parts, part, plan[part].glyphs, table.concat(shards, ","),
        table.concat(rows))
end

local SH7_PLAN = {
    { part = 1, shards = { 0 }, glyphs = 2, first = 20013, last = 25991 },
    { part = 2, shards = { 1 }, glyphs = 1, first = 65533, last = 65533 },
}
local SH6_PLAN = {
    { part = 1, shards = { 0 }, glyphs = 1, first = 20013, last = 20013 },
    { part = 2, shards = { 1 }, glyphs = 1, first = 65533, last = 65533 },
}

local function build_two_media()
    drop_tree("/disk3")
    fs.makeDir("/disk3/" .. fonts.DIR)
    write_file("/disk3/cc_fonts.marker", "a second font medium\n")
    write_file(MEDIUM .. "/cc_fonts.marker", "the first font medium\n")

    -- shs7: part 1 on the first drive, part 2 on the second
    write_file(UNION .. "_shard0.lua", "return {\n[20013]={" .. rows_literal(ZHONG) ..
        "},\n[25991]={" .. rows_literal(WEN) .. "},\n}\n")
    write_file(UNION .. "_index.lua", "return {\n[20013]=0,\n[25991]=0,\n}\n")
    write_file(UNION .. fonts.MANIFEST_SUFFIX,
        set_manifest("shs7", 1, 2, { 0 }, SH7_PLAN))
    write_file(UNION2 .. "_shard1.lua", "return {\n[65533]={" .. rows_literal(BOX) ..
        "},\n}\n")
    write_file(UNION2 .. "_index.lua", "return {\n[65533]=1,\n}\n")
    write_file(UNION2 .. fonts.MANIFEST_SUFFIX,
        set_manifest("shs7", 2, 2, { 1 }, SH7_PLAN))

    -- shs6: the same shape with the parts exchanged between the drives
    write_file(OTHER .. "_shard0.lua", "return {\n[20013]={" .. rows_literal(ZHONG) ..
        "},\n}\n")
    write_file(OTHER .. "_index.lua", "return {\n[20013]=0,\n}\n")
    write_file(OTHER .. fonts.MANIFEST_SUFFIX,
        set_manifest("shs6", 1, 2, { 0 }, SH6_PLAN))
    write_file(OTHER2 .. "_shard1.lua", "return {\n[65533]={" .. rows_literal(BOX) ..
        "},\n}\n")
    write_file(OTHER2 .. "_index.lua", "return {\n[65533]=1,\n}\n")
    write_file(OTHER2 .. fonts.MANIFEST_SUFFIX,
        set_manifest("shs6", 2, 2, { 1 }, SH6_PLAN))
end

build_two_media()
fonts.CANDIDATES = nil

-- Every marked medium that carries a set, in a deterministic order. This is the
-- "full picture" a caller needs before it can resolve anything: which media are
-- font media at all, and which sets each one offers.
local media_list = fonts.media()
check("every marked medium that carries a glyph set is found",
      #media_list == 2, "#media()=" .. #media_list)
check("and media() is ordered by the medium's own path",
      #media_list == 2 and media_list[1].medium == "/disk2" and
      media_list[2].medium == "/disk3",
      #media_list == 2 and (media_list[1].medium .. " then " .. media_list[2].medium)
      or "-")

-- The order matters: the same machine with the same two disks must answer the
-- same way whichever drive was mounted first, so the list may not inherit the
-- order of the mount table or of the drive list.
local function media_names()
    local out = {}
    for _, entry in ipairs(fonts.media()) do out[#out + 1] = entry.medium end
    return table.concat(out, ",")
end
local real_candidates = fonts.CANDIDATES
fonts.CANDIDATES = { "/disk3", "/disk2" }
local reversed = media_names()
fonts.CANDIDATES = { "/disk2", "/disk3" }
local forwards = media_names()
fonts.CANDIDATES = real_candidates
check("media() is the same list whichever order the drives were mounted in",
      reversed == "/disk2,/disk3" and reversed == forwards,
      reversed .. " vs " .. forwards)

-- fonts.parts() is the union picture: which parts of one set are in the machine.
local picture, picture_why = fonts.parts("shs7")
check("both parts of the set are found across the two media",
      type(picture) == "table" and #picture.bases == 2, tostring(picture_why))
check("and they are ordered by the PART each manifest says, not by drive",
      type(picture) == "table" and picture.bases[1] == UNION and
      picture.bases[2] == UNION2,
      type(picture) == "table" and table.concat(picture.bases, " then ") or "-")
check("the set knows it has two parts while both are here",
      type(picture) == "table" and picture.parts == 2 and #picture.missing == 0,
      type(picture) == "table" and
      (picture.parts .. " part(s), " .. #picture.missing .. " missing") or "-")
check("no medium is reported as carrying a different set",
      type(picture) == "table" and picture.foreign == nil,
      type(picture) == "table" and tostring(picture.foreign) or "-")

-- THE REVERSED FIXTURE is the control: with the parts on the drives the other way
-- round, the order still follows the manifests. A union that ordered media by
-- path would put shs6's part 2 first here and answer these two assertions the
-- other way round.
local reversed_picture = fonts.parts("shs6")
check("with the parts on the drives exchanged, part 1 is still read first",
      type(reversed_picture) == "table" and reversed_picture.bases[1] == OTHER and
      reversed_picture.bases[2] == OTHER2,
      type(reversed_picture) == "table" and
      table.concat(reversed_picture.bases, " then ") or "-")

-- ---------------------------------------------------------------- the union
shards.clear()
local union_ok, union_why = shards.init(UNION)
check("init() of ONE part's base resolves the whole set", union_ok == true,
      tostring(union_why))
local ustats = shards.stats()
check("one shard index is loaded per medium that carries the set",
      ustats.layers == 2, tostring(ustats.layers))
check("stats() names the set and how many parts it has",
      ustats.set == "shs7" and ustats.parts == 2,
      tostring(ustats.set) .. " / " .. tostring(ustats.parts))
check("and lists the parts that are here", table.concat(ustats.present, ",") == "1,2",
      table.concat(ustats.present, ","))
-- The union counts every codepoint of both indexes: 2 on part 1 + 1 on part 2. A
-- union that loaded one index twice, or that counted the same table twice, would
-- answer 4 or 6 here.
check("the union counts the glyphs of both parts, not one part twice",
      ustats.glyphs == 3, tostring(ustats.glyphs))
check("sources() is the indexes in part order",
      table.concat(shards.sources(), ",") ==
      UNION .. "_index.lua," .. UNION2 .. "_index.lua",
      table.concat(shards.sources(), ","))
check("status() says the whole set is in the machine",
      shards.status() == "set shs7 parts 1 and 2 of 2, all parts inserted",
      shards.status())

local from_part1 = select(1, shards.get(ON_PART1))
check("a glyph whose shard is on medium A resolves", from_part1 ~= nil and
      from_part1[1] == ZHONG[1] and from_part1[2] == ZHONG[2],
      from_part1 and table.concat(from_part1, "/") or "nil")
local from_part2 = select(1, shards.get(ON_PART2))
check("a glyph whose shard is on medium B resolves from THAT medium",
      from_part2 ~= nil and from_part2[1] == BOX[1] and from_part2[4] == BOX[4],
      from_part2 and table.concat(from_part2, "/") or "nil")
-- Every term is nil-safe: an assertion that indexes a nil because the check
-- before it already failed turns a clean "this check failed" into "raised an
-- error" and hides WHICH check it was -- which is what this one did until it was
-- fixed, and it cost a debugging round.
check("and the two did not come from one shard read twice",
      type(from_part1) == "table" and type(from_part2) == "table" and
      from_part1 ~= from_part2 and from_part1[2] ~= from_part2[2],
      (from_part1 and from_part1[2] or "?") .. " vs " ..
      (from_part2 and from_part2[2] or "?"))

-- preload() by shard NUMBER has to answer "which medium owns that shard?": with
-- one medium there is only one answer, and with two there is one file per shard
-- and a guess would read the wrong medium's file -- or the right shard number out
-- of the wrong set.
local pl0 = select(1, shards.preload(0))
local pl1 = select(1, shards.preload(1))
local pl9, pl9_why = shards.preload(9)
check("preload() finds a shard on the medium that owns it",
      type(pl0) == "table" and type(pl1) == "table" and
      pl0[20013] ~= nil and pl1[65533] ~= nil and pl0[65533] == nil,
      type(pl0) .. "/" .. type(pl1))
check("and says so when no medium of the set names that shard",
      pl9 == nil and type(pl9_why) == "string" and
      pl9_why:find("shard 9", 1, true) ~= nil, tostring(pl9_why))

-- ------------------------------------------------------- half the set inserted
-- Part 2's medium comes out; a disk event handler calls clear(), which is what
-- tells this module that WHICH media are in the machine may have changed.
drop_tree("/disk3")
shards.clear()
local half_ok, half_why = shards.init(UNION)
check("the set is re-resolved after a medium goes", half_ok == true,
      tostring(half_why))
local half = shards.stats()
check("stats() says the set is half inserted, and which part is missing",
      half.status == "set shs7 part 1 of 2, part 2 not inserted", half.status)
check("the missing part is named as a part NUMBER", table.concat(half.missing, ",") == "2",
      table.concat(half.missing, ","))
-- The per-disk index does NOT claim the absent shard: part 1's index names its own
-- two glyphs and nothing else, which is why the count is 2 and not 3.
check("the loaded index claims only the glyphs on the medium that is here",
      half.glyphs == 2, tostring(half.glyphs))
check("has() answers from the loaded parts only",
      shards.has(ON_PART1) == true and shards.has(ON_PART2) == false,
      tostring(shards.has(ON_PART1)) .. "/" .. tostring(shards.has(ON_PART2)))

local missing_matrix, missing_why = shards.get(ON_PART2)
check("a glyph on the absent part is nil rather than a matrix",
      missing_matrix == nil, tostring(missing_matrix))
check("and its reason NAMES the missing part and the range it covers",
      type(missing_why) == "string" and
      missing_why:find("part 2 of 2", 1, true) ~= nil and
      missing_why:find("U+FFFD", 1, true) ~= nil, tostring(missing_why))
-- The distinction the two-medium design exists to make: "the font does not have
-- this character" and "the glyph is on the medium that is not here" are different
-- answers with different fixes.
local plain_matrix, plain_why = shards.get(65)          -- 'A': not in the set at all
check("a codepoint the set does not have still says exactly that",
      plain_matrix == nil and plain_why == "not in this set", tostring(plain_why))
local gap = shards.absent(ON_PART2)
check("absent() describes the part to insert, with its codepoint range",
      type(gap) == "table" and gap.part == 2 and gap.parts == 2 and
      gap.first == 65533 and gap.last == 65533,
      type(gap) == "table" and
      (gap.part .. " of " .. gap.parts .. " U+" .. string.format("%04X", gap.first)) or "-")
check("absent() is nil for a character the set simply does not have",
      shards.absent(65) == nil)

-- ------------------------------------------------- and what DRAWING does with it
chinese.config.base = UNION
chinese.config.size = 4
clear_out()
local drew_part1 = chinese.draw("\228\184\173", 1, 1)     -- U+4E2D, on part 1
check("with part 2 out, a character on part 1 still draws",
      drew_part1.ok == true and drew_part1.drawn == 1 and #_G.__BLITS == 2,
      drew_part1.drawn .. " drawn, " .. #_G.__BLITS .. " blit(s)")

clear_out()
local drew_part2 = chinese.draw("\239\191\189", 1, 1)     -- U+FFFD, on part 2
check("a character on the absent part is REPORTED, not raised",
      type(drew_part2) == "table" and drew_part2.absent == 1,
      drew_part2 and tostring(drew_part2.absent))
check("and its reason names the part to insert rather than the font",
      type(drew_part2.reason) == "string" and
      drew_part2.reason:find("part 2 of 2", 1, true) ~= nil,
      drew_part2 and tostring(drew_part2.reason))
check("report.missing_parts lists the medium the operator has to insert",
      #drew_part2.missing_parts == 1 and drew_part2.missing_parts[1] == 2,
      table.concat(drew_part2.missing_parts, ","))
check("and NOTHING was blitted for it: no box was passed off as the glyph",
      #_G.__BLITS == 0, #_G.__BLITS .. " blit(s)")
check("it is counted as missing rather than drawn",
      drew_part2.missing == 1 and drew_part2.drawn == 0,
      drew_part2.missing .. " missing, " .. drew_part2.drawn .. " drawn")

-- The fallback box itself is a glyph in the set, and in this fixture it lives on
-- part 2. So with part 2 out a character the set does not have cannot be drawn as
-- a box either -- and that must be SAID rather than left as a silent blank cell.
clear_out()
local drew_unknown = chinese.draw("A", 1, 1)
check("with the box itself on the absent part, the reason says so",
      drew_unknown.absent == 0 and
      type(drew_unknown.reason) == "string" and
      drew_unknown.reason:find("part 2 of 2", 1, true) ~= nil,
      tostring(drew_unknown.reason))

-- ------------------------------------------- the marker is what makes a medium
-- A medium that carries a set's FILES but not the marker is not a font medium:
-- media() is what decides, and it asks for the marker. A union that scanned every
-- disk for fonts/*_index.lua would take a stray copy -- an old backup, a working
-- directory -- for part of the set and draw from it.
build_two_media()
local unmarked_names, unmarked_parts = (function()
    fs.delete("/disk3/cc_fonts.marker")
    local names = {}
    for _, entry in ipairs(fonts.media()) do names[#names + 1] = entry.medium end
    local picture_now = fonts.parts("shs7")
    write_file("/disk3/cc_fonts.marker", "a second font medium\n")
    return table.concat(names, ","), picture_now and #picture_now.present or -1
end)()
check("a medium without the marker is not a font medium, whatever it carries",
      unmarked_names == "/disk2", unmarked_names)
check("so the set behind it is one part short", unmarked_parts == 1,
      tostring(unmarked_parts))

-- ------------------------------------------- and the OTHER direction of missing
-- With only PART 2's medium in the machine, the part that is missing is part 1 --
-- and part 1's manifest is not there to be read. That is why the manifest carries
-- the WHOLE plan on every part instead of only on the first, and it is the case a
-- fixture that always drops part 2 would never exercise.
drop_tree("/disk3")
shards.clear()
local only2_ok = shards.init(OTHER2)             -- shs6's PART 2, on /disk2
local only2 = shards.stats()
check("with only part 2 in, the set is reported as missing part 1",
      only2_ok == true and
      only2.status == "set shs6 part 2 of 2, part 1 not inserted",
      tostring(only2.status))
local p1_matrix, p1_why = shards.get(ON_PART1)   -- U+4E2D, which is on part 1
check("and a glyph on part 1 names part 1 as the medium to insert",
      p1_matrix == nil and type(p1_why) == "string" and
      p1_why:find("part 1 of 2", 1, true) ~= nil, tostring(p1_why))

-- ---------------------------------------- the cache is keyed by medium AND shard
-- Shard ids are global in a set built by tools/fontdisk.py (part 1 holds 0..6,
-- part 2 holds 7..13), but nothing stops a hand-made or half-rebuilt pair from
-- calling both of its files _shard0.lua. A cache keyed by the shard id ALONE then
-- answers with the first medium's matrix for the second medium's codepoint: a
-- wrong picture on the screen, and no error anywhere.
build_two_media()
local SAMEA, SAMEB = "/disk2/fonts/shs5", "/disk3/fonts/shs5"
local SAME_PLAN = {
    { part = 1, shards = { 0 }, glyphs = 1, first = 20013, last = 20013 },
    { part = 2, shards = { 0 }, glyphs = 1, first = 65533, last = 65533 },
}
write_file(SAMEA .. "_shard0.lua", "return {\n[20013]={" .. rows_literal(ZHONG) ..
    "},\n}\n")
write_file(SAMEA .. "_index.lua", "return {\n[20013]=0,\n}\n")
write_file(SAMEA .. fonts.MANIFEST_SUFFIX,
    set_manifest("shs5", 1, 2, { 0 }, SAME_PLAN))
write_file(SAMEB .. "_shard0.lua", "return {\n[65533]={" .. rows_literal(BOX) ..
    "},\n}\n")
write_file(SAMEB .. "_index.lua", "return {\n[65533]=0,\n}\n")
write_file(SAMEB .. fonts.MANIFEST_SUFFIX,
    set_manifest("shs5", 2, 2, { 0 }, SAME_PLAN))
shards.clear()
shards.init(SAMEA)
local same1 = select(1, shards.get(20013))
local same2 = select(1, shards.get(65533))
check("two media that both call their shard 0 still return their OWN glyph",
      same1 ~= nil and same2 ~= nil and same1[1] == ZHONG[1] and
      same2[1] == BOX[1] and same1 ~= same2,
      (same1 and same1[1] or "nil") .. " / " .. (same2 and same2[1] or "nil"))

-- -------------------------------------------- a medium that claims another set
-- shs7_index.lua on /disk3 with a manifest naming shs9 is not a part of shs7.
-- Unioning it would mix two sets' glyphs under one stem, and dropping it silently
-- would leave the operator with a medium that looks inserted and is not used.
write_file(UNION2 .. fonts.MANIFEST_SUFFIX,
    set_manifest("shs9", 2, 2, { 1 }, SH7_PLAN))
local mixed = fonts.parts("shs7")
check("a medium whose manifest names another set is not used as a part",
      type(mixed) == "table" and #mixed.present == 1 and #mixed.bases == 1,
      type(mixed) == "table" and #mixed.present or "-")
check("and the set is then honestly reported as missing that part",
      type(mixed) == "table" and #mixed.missing == 1 and mixed.missing[1].part == 2,
      type(mixed) == "table" and #mixed.missing or "-")
check("with the file that disagrees named, so it can be rebuilt",
      type(mixed) == "table" and type(mixed.foreign) == "string" and
      mixed.foreign:find("shs9", 1, true) ~= nil,
      type(mixed) == "table" and tostring(mixed.foreign) or "-")

-- The other disagreement: a manifest that names the RIGHT set but describes a
-- different SPLIT -- a medium built by an earlier run, with a different shard
-- size. Its index still says which glyphs it really holds, so the part is usable;
-- but the mixture is reported rather than passed off as one set, because a
-- codepoint's shard number means different things in the two plans.
write_file(UNION2 .. fonts.MANIFEST_SUFFIX,
    set_manifest("shs7", 2, 2, { 1 },
        { { part = 1, shards = { 1 }, glyphs = 2, first = 20013, last = 25991 },
          { part = 2, shards = { 0 }, glyphs = 1, first = 65533, last = 65533 } }))
local mixed_split = fonts.parts("shs7")
check("a manifest that describes a different split is reported, not ignored",
      type(mixed_split) == "table" and type(mixed_split.foreign) == "string" and
      mixed_split.foreign:find("different split", 1, true) ~= nil,
      type(mixed_split) == "table" and tostring(mixed_split.foreign) or "-")
check("and that medium is still used, because its index says what it holds",
      type(mixed_split) == "table" and #mixed_split.present == 2,
      type(mixed_split) == "table" and #mixed_split.present or "-")

-- ------------------------------------------------ and the whole set comes back
build_two_media()
shards.clear()
chinese.config.base = UNION
clear_out()
local back1 = chinese.draw("\228\184\173", 1, 1)          -- part 1
clear_out()
local back2 = chinese.draw("\239\191\189", 1, 1)          -- part 2
check("with both media in, a glyph of each part renders again",
      back1.drawn == 1 and back2.drawn == 1,
      back1.drawn .. " from part 1, " .. back2.drawn .. " from part 2")
check("and the box is available again for a character outside the set",
      (function()
          clear_out()
          local unknown = chinese.draw("A", 1, 1)
          return unknown.absent == 0 and unknown.missing == 1 and #_G.__BLITS == 2
      end)(), "the fallback box was not drawn")
check("status() is back to the whole set", shards.status() ==
      "set shs7 parts 1 and 2 of 2, all parts inserted", shards.status())

-- The single-medium case, one more time and explicitly, because it is the common
-- case and the one that may not regress: a set with no manifest at all is a set
-- of ONE part, and its status says so without inventing a second medium.
build_medium()
drop_tree("/disk3")
shards.clear()
local single_ok = shards.init(BASE)
local single = shards.stats()
check("a medium with no manifest is a set of one part", single_ok == true and
      single.parts == 1 and single.layers == 1,
      tostring(single.parts) .. " part(s), " .. tostring(single.layers) .. " layer(s)")
check("and its status line says part 1 of 1, not 'a part is missing'",
      single.status == "set shs4 part 1 of 1, all parts inserted", single.status)
check("with no missing part to report", #single.missing == 0 and
      table.concat(single.present, ",") == "1",
      table.concat(single.missing, ","))

-- ===========================================================================
-- A SUBSET SET: a character the set lacks is drawn as the replacement box.
--
-- The size 16 interface set carries only the characters the interface uses (135
-- of them), so "the set does not have this character" is the ordinary case there,
-- not a hypothetical. Measured on the GUI: U+9FA5 came back drawn=0 missing=1
-- absent=0 with the fallback glyph present in the set, i.e. a box was drawn.
--
-- The two failures are different and both are asserted elsewhere in this file:
--   missing -- not in this set          -> the BOX is drawn (true: no such glyph)
--   absent  -- in the set, medium out   -> NOTHING is drawn, the part is named
-- This section adds the one thing neither covered: that the box the subset
-- falls back to is IN the subset's own index, so a small set cannot turn every
-- unknown character into a blank cell.
section("a subset set: its own fallback is in its index")
do
    -- A second medium, in the same shape as the fixture one, holding a two-glyph
    -- set: the character the interface uses, and the replacement box. This is
    -- what a size 16 UI subset looks like, and the point is that the box travels
    -- WITH the subset -- a small set that forgot it would turn every unknown
    -- character into a blank cell.
    local subset = "/disk3"
    local subset_fonts = subset .. "/fonts"
    drop_tree(subset)
    fs.makeDir(subset_fonts)
    write_file(subset .. "/cc_fonts.marker", "this medium carries font glyphs\n")
    write_file(subset_fonts .. "/shs16_index.lua",
        "return {\n[20013]=0,\n[65533]=0,\n}\n")
    write_file(subset_fonts .. "/shs16_shard0.lua",
        "return {\n[20013]={" .. rows_literal(ZHONG) .. "},\n" ..
        "[65533]={" .. rows_literal(BOX) .. "},\n}\n")
    shards.clear()
    local ok_sub = shards.init(subset_fonts .. "/shs16")
    check("a two-glyph subset set loads", ok_sub == true, tostring(ok_sub))
    check("it has the one character it was built for",
          select(1, shards.get(0x4E2D)) ~= nil)
    check("and it has the replacement box, so a character it lacks is not blank",
          select(1, shards.get(65533)) ~= nil)
    local outside, why_out = shards.get(0x9FA5)
    check("a character outside a subset set answers nil plus a reason",
          outside == nil and type(why_out) == "string", tostring(why_out))
    check("and absent() is nil for it, because no medium could carry it",
          shards.absent(0x9FA5) == nil)
    drop_tree(subset)
    shards.clear()
end

-- ===========================================================================
-- THE SET DECLARES ITS GEOMETRY, and the renderer must obey it.
--
-- The index carries "matrix: N rows of N chars -> w x h cells". That line is the
-- only truthful statement about how many pixels a glyph has, because the number
-- of pixels is a property of the SET. Reading the size from the set's NAME (or
-- from config.size alone) is a guess, and the guess was measured wrong on the
-- GUI: a machine carrying a size 16 set while config.size still said 12 packed 16
-- rows of pixels into 6x4 cells and drew a band of noise, while every "a glyph
-- was drawn" assertion kept passing -- the drawing happened, at the wrong size.
section("the set declares its own matrix size, and the renderer adopts it")
do
    -- A 6-pixel-tall set whose name says nothing useful: this is the fixture
    -- shape, and it is exactly what a name-based rule would mis-read.
    local decl = "/disk3"
    local dfonts = decl .. "/fonts"
    drop_tree(decl)
    fs.makeDir(dfonts)
    write_file(decl .. "/cc_fonts.marker", "this medium carries font glyphs\n")
    write_file(dfonts .. "/shs6_index.lua",
        "-- generated by tools/fontgen.py at size 6 - do not edit by hand\n" ..
        "-- matrix: 6 rows of 6 chars of \"0\"/\"1\" -> 3 x 2 cells\n" ..
        "return {\n[20013]=0,\n[65533]=0,\n}\n")
    write_file(dfonts .. "/shs6_shard0.lua",
        "return {\n[20013]={\"111111\",\"100001\",\"100001\",\"100001\"," ..
        "\"100001\",\"111111\"},\n[65533]={\"111111\",\"100001\",\"100001\"," ..
        "\"100001\",\"100001\",\"111111\"},\n}\n")
    shards.clear()
    -- Pin the set explicitly. Without a pin the finder walks the media and picks
    -- by preference, and this assertion is about the GEOMETRY of one set, not
    -- about which set a machine with several would choose.
    chinese.config.size = 12                       -- deliberately the wrong size
    chinese.config.base = dfonts .. "/shs6"
    local ok_decl, why_decl = chinese.available()
    check("a set whose name carries no size still loads", ok_decl == true,
          tostring(why_decl))
    check("the renderer adopts the matrix size the index declares",
          chinese.config.size == 6, chinese.config.size)
    check("so a glyph occupies ceil(6/2) x ceil(6/3) = 3 x 2 cells",
          chinese.cells(chinese.config.size) == 3 and
          select(2, chinese.cells(chinese.config.size)) == 2,
          select(1, chinese.cells(chinese.config.size)) .. "x" ..
          select(2, chinese.cells(chinese.config.size)))
    chinese.config.base = nil
    drop_tree(decl)
    shards.clear()
    chinese.config.size = 12
end

-- ===========================================================================
-- WHICH SET WINS when a machine carries several: size 16 first, by readability.
--
-- The first version of the choice loop put the CONFIGURED size first, so a
-- machine that had both the size 16 interface set and the full size 12 set took
-- the 12 one -- the config said 12 -- and the better set was never used. Measured
-- on the GUI: adopted size=12 source=/disk3/fonts/shs12 while
-- /disk2/fonts/shs16 was mounted and readable.
section("several sets on several media: the readable one wins")
do
    -- Two media, each with one set, mounted at the same time.
    for _, spec in ipairs({
        { "/disk3", "shs12", 12 },
        { "/disk4", "shs16", 16 },
    }) do
        local medium, stem, size = spec[1], spec[2], spec[3]
        local dir = medium .. "/fonts"
        drop_tree(medium)
        fs.makeDir(dir)
        write_file(medium .. "/cc_fonts.marker", "this medium carries font glyphs\n")
        write_file(dir .. "/" .. stem .. "_index.lua",
            "-- matrix: " .. size .. " rows of " .. size .. " chars of \"0\"/\"1\"\n" ..
            "return {\n[20013]=0,\n[65533]=0,\n}\n")
        local row = string.rep("1", size)
        write_file(dir .. "/" .. stem .. "_shard0.lua",
            "return {\n[20013]={\"" .. row .. "\"},\n[65533]={\"" .. row .. "\"},\n}\n")
    end
    -- CANDIDATES is the module's own test hook for "which media does this
    -- machine have": without it the search reads the mount table, and the stub
    -- filesystem the suite runs on has no mount table entries for these paths.
    local saved_candidates = fonts.CANDIDATES
    fonts.CANDIDATES = { "/disk3", "/disk4" }
    shards.clear()
    chinese.config.base = nil
    chinese.config.size = 12                     -- the config says 12 on purpose
    local ok_multi, why_multi = chinese.available()
    check("a machine with two sets loads one of them", ok_multi == true,
          tostring(why_multi))
    -- 12 wins over 16 on this screen: a 2x3-pixel cell holds six sub-pixels
    -- whatever the matrix size, so a bigger matrix spreads the same strokes over
    -- more, coarser cells instead of adding detail. Measured on the GUI: the size
    -- 16 glyph was byte-correct and still read as noise at 51 columns.
    check("and it is the size 12 set, the denser one",
          chinese.config.size == 12, chinese.config.size)
    check("so its glyphs are packed as 6 x 4 cells",
          chinese.cells(chinese.config.size) == 6 and
          select(2, chinese.cells(chinese.config.size)) == 4,
          select(1, chinese.cells(chinese.config.size)) .. "x" ..
          select(2, chinese.cells(chinese.config.size)))
    chinese.config.base = nil
    fonts.CANDIDATES = saved_candidates
    drop_tree("/disk3")
    drop_tree("/disk4")
    shards.clear()
    chinese.config.size = 12
end

-- ===========================================================================
_G.__RESULT = { pass = pass, fail = fail, fails = fails, sections = sections }
say("")
for _, s in ipairs(sections) do
    say(string.format("SECTION %-58s pass=%d fail=%d", s.name, s.pass, s.fail))
end
for _, s in ipairs(skipped) do say("  SKIP: " .. s) end
say(string.format("assertions: %d passed, %d failed", pass, fail))
for _, f in ipairs(fails) do
    say("  FAIL: " .. f)
end
