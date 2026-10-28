-- dc.cjk_shards — 从 pyromputer-os/lib/cc_font_shards.lua 复制（作者同意跨项目复用）
-- 只改模块名与 require 目标。
-- cjk_shards.lua - read glyph shards from the font media, on demand
--
-- THE FILE SHAPE IS THE INTERFACE
-- Three kinds of file, all plain Lua data evaluated with the ROM's own
-- loadstring() on the machine:
--
--     <base>_index.lua      { [codepoint] = shard_id }
--     <base>_shard<N>.lua   { [codepoint] = matrix }
--     <base>.set.lua        which PART of a multi-medium set this medium is
--
-- where a matrix is a list of strings of "0" and "1", one string per pixel row.
-- A Lua table constructor is the only container a CraftOS machine can read with
-- no parser and no dependency, which is why the data is Lua source rather than
-- a packed binary: textutils.unserialize() would also work but it loads the
-- whole file into a string and parses it again, and loadstring() is the same
-- path the ROM's own shell uses for every command it runs. The manifest is
-- OPTIONAL -- a medium without one is a set of one part, which is what it is.
--
-- WHY SHARDS AT ALL
-- One file with the whole set in it would be read to its end to draw one
-- character: about 1 MB of string built and parsed, of which the caller wanted
-- two strings. The index makes a lookup cost a table read and one shard open;
-- the shard is the unit that is cached and the unit that can be dropped.
--
-- WHY LOOKUPS CROSS MORE THAN ONE MEDIUM
-- The whole of GB2312 at size 12 is 1,375,263 B and a CraftOS floppy holds
-- 1,228,800 B, so the standard is 146,463 B too big for one medium and is built
-- as two (the operator's instruction: "the Chinese shards do not fit on one
-- drive, so use two"). Each medium carries the shards that fit on it and an
-- index naming ONLY those shards, and a lookup therefore walks the parts: a
-- codepoint is found on whichever medium's index names it. Shard ids are global
-- to the set (part 1 holds 0..6, part 2 holds 7..13), so the cache is keyed by
-- medium AND shard id and two parts can never return each other's glyphs.
--
-- WHY A MISSING PART IS A REASON AND NOT A BLANK
-- With one of two media out, a character that lives on the other is a KNOWN
-- absence: the manifest of the medium that IS inserted carries the whole plan,
-- so the lookup can answer "U+7480 is in shs12 part 2 of 2 (shards 7-13), which
-- is not inserted" instead of "not in this set". Those are different problems
-- with different fixes -- insert the second medium versus that character is not
-- in this font -- so they must not be the same answer, and neither may be a
-- blank cell.
--
-- WHY NOTHING HERE THROWS FROM INSIDE A DRAW
-- get() is called once per character of a line. An error raised here surfaces in
-- the middle of a render, when half a line has already been blitted, which is
-- the worst place to leave a screen. So a shard that is missing or that does not
-- compile is REMEMBERED as a failure and reported as nil, and why() says what
-- happened; init() is the one function that returns a reason rather than raising,
-- and its caller (lib/cjk.lua) turns that into a message.
local shards = {}

local state = {
    key = nil,         -- what the caller last asked for, for the idempotence test
    base = nil,        -- the base of the first layer, for source()/stats().base
    layers = {},       -- ordered: { base, index, source, part, shards }
    set = nil,         -- the picture: { name, parts, present, missing, broken }
    loaded = {},       -- "<base>|<shard>" -> table of glyphs
    failed = {},       -- "<base>|<shard>" -> why it will not be loaded again
    source = nil,      -- where the first index came from, for a message
    error = nil,       -- why the last init() left this empty
}

-- The stem of a base path ("/disk2/fonts/shs12" -> "shs12"), which is the name of
-- the set. Kept here rather than required from lib/cjk_fonts.lua because this
-- module works with no finder at all (a program that ships its own font).
local function stem_of(path)
    return tostring(path):match("([^/]+)$") or tostring(path)
end

-- CraftOS 1.8 spells it loadstring, Lua 5.2 and later spell it load. Both are
-- tried because this module is also loaded by the PC side test runner, which
-- uses lupa over LuaJIT (loadstring) while a host lua may be 5.4 (load).
local function compile(src, name)
    local loader = loadstring or load
    return loader(src, name)
end

local function read_file(path)
    if not fs.exists(path) then return nil, "no such file: " .. path end
    local handle = fs.open(path, "r")
    if not handle then return nil, "cannot open " .. path end
    local text = handle.readAll()
    handle.close()
    if type(text) ~= "string" or text == "" then
        return nil, "empty file: " .. path
    end
    return text
end

-- Evaluate one of the data files. Returns the table, or nil plus the reason.
--
-- The chunk's own error is kept verbatim: "unexpected symbol near ..." with the
-- file's name in it is what tells an operator that a shard was truncated in
-- transit, and rewording it here would lose that.
local function evaluate(path)
    local text, why = read_file(path)
    if not text then return nil, why end
    local chunk, err = compile(text, "@" .. path)
    if not chunk then return nil, "does not compile: " .. tostring(err) end
    local ok, value = pcall(chunk)
    if not ok then return nil, "raised when loaded: " .. tostring(value) end
    if type(value) ~= "table" then
        return nil, "did not evaluate to a table (" .. type(value) .. ")"
    end
    return value
end

-- Read one medium's index. Returns the table and the path it came from.
--
-- THE INDEX DECLARES ITS OWN GEOMETRY, and that declaration is read here. The
-- generator writes a header line
--     -- matrix: 16 rows of 16 chars of "0"/"1" -> 8 x 6 cells
-- because how many pixels a glyph is drawn with -- and therefore how many
-- character cells it occupies -- is a property of the SET, not of the machine
-- reading it. Deriving it from the file name instead is wrong twice over: the
-- test fixture's set is called shs4 and holds 4x4-pixel matrices, and a real
-- machine carrying a size 16 set while the renderer still assumed 12 packed 16
-- rows of pixels into 6x4 cells and drew a band of noise. Measured on the GUI:
-- the glyph came out as garbage while every "something was drawn" assertion
-- passed, because drawing DID happen -- at the wrong geometry.
--
-- An index with no such line is an older file: no geometry is recorded and the
-- caller keeps whatever size it was configured with.
local function load_index(base)
    local path = base .. "_index.lua"
    local text, read_why = read_file(path)
    if not text then return nil, nil, path .. ": " .. tostring(read_why) end
    local index, why = evaluate(path)
    if not index then return nil, nil, path .. ": " .. tostring(why) end
    local rows = tonumber(text:match("matrix:%s*(%d+)%s+rows"))
    local cols = tonumber(text:match("rows%s+of%s+(%d+)%s+chars"))
    if rows and cols then
        index.__rows, index.__cols = rows, cols
    end
    return index, path
end

local function set_of(list)
    if type(list) ~= "table" then return nil end
    local out = {}
    for _, id in ipairs(list) do out[tonumber(id) or id] = true end
    return out
end

local function make_layer(base, index, source, part, shard_list)
    return { base = base, index = index, source = source,
             part = part or 1, shards = set_of(shard_list) }
end

-- A shard, loaded once and kept. Returns the glyph table, or nil plus why.
--
-- The key is the medium AND the shard id: with a set split over two media the
-- shard ids are global, but a caller that mixed two sets (or rebuilt one
-- halfway) must still not be handed one medium's shard for another's.
local function load_shard(layer, shard_id)
    local key = layer.base .. "|" .. tostring(shard_id)
    if state.loaded[key] then return state.loaded[key] end
    if state.failed[key] then return nil, state.failed[key] end
    local path = layer.base .. "_shard" .. tostring(shard_id) .. ".lua"
    local glyphs, why = evaluate(path)
    if not glyphs then
        -- Remembered, so that a line of 40 characters in a shard that is not on
        -- the medium reads the missing file once instead of 40 times.
        state.failed[key] = path .. ": " .. tostring(why)
        return nil, state.failed[key]
    end
    state.loaded[key] = glyphs
    return glyphs
end

-- The sentence for one absent (or unreadable) part. This is the text the whole
-- two-medium design exists to be able to say, so it is built in one place and
-- names the part, how many parts there are, the shards and the codepoint range.
local function part_reason(gap, set, code)
    local where = ""
    if type(gap.shards) == "table" and #gap.shards > 0 then
        where = "shards " .. tostring(gap.shards[1]) .. "-" ..
                tostring(gap.shards[#gap.shards])
    end
    if gap.first and gap.last then
        local range = string.format("U+%04X..U+%04X", gap.first, gap.last)
        where = (where ~= "" and (where .. ", ") or "") .. range
    end
    local how
    if gap.why then
        how = "is inserted but could not be read: " .. tostring(gap.why)
    else
        how = "is not inserted: insert the medium that carries it"
    end
    return "U+" .. string.format("%04X", tonumber(code) or 0) .. " is in " ..
        tostring(set.name) .. " part " .. tostring(gap.part) .. " of " ..
        tostring(set.parts) .. (where ~= "" and (" (" .. where .. ")") or "") ..
        ", which " .. how
end

-- "1", "1 and 2", "1, 2 and 3".
local function join_numbers(list)
    local out = {}
    for i, n in ipairs(list) do out[i] = tostring(n) end
    if #out <= 1 then return out[1] or "" end
    return table.concat(out, ", ", 1, #out - 1) .. " and " .. out[#out]
end

-- The one line an operator reads: "set shs12 part 1 of 2, part 2 not inserted".
local function status_line()
    local set = state.set
    if not set then
        if state.base then
            return "set " .. stem_of(state.base) .. " part 1 of 1"
        end
        return "no font set loaded" .. (state.error and (": " .. tostring(state.error)) or "")
    end
    local present = {}
    for _, entry in ipairs(set.present or {}) do present[#present + 1] = entry.part end
    local absent, broken = {}, {}
    for _, entry in ipairs(set.missing or {}) do absent[#absent + 1] = entry.part end
    for _, entry in ipairs(set.broken or {}) do broken[#broken + 1] = entry.part end
    local where
    if #present == 1 then
        where = "part " .. tostring(present[1]) .. " of " .. tostring(set.parts)
    else
        where = "parts " .. join_numbers(present) .. " of " .. tostring(set.parts)
    end
    local tail = {}
    if #absent > 0 then
        tail[#tail + 1] = (#absent == 1 and "part " or "parts ") ..
            join_numbers(absent) .. " not inserted"
    end
    if #broken > 0 then
        tail[#tail + 1] = (#broken == 1 and "part " or "parts ") ..
            join_numbers(broken) .. " could not be read"
    end
    if #tail == 0 then tail[1] = "all parts inserted" end
    return "set " .. tostring(set.name) .. " " .. where .. ", " .. table.concat(tail, ", ")
end

-- Is the loaded set incomplete? Then the picture itself expires on clear(),
-- because the medium the operator inserts next has to be looked for again.
local function incomplete()
    local set = state.set
    if not set then return false end
    return #(set.missing or {}) > 0 or #(set.broken or {}) > 0
end

-- Should clear() also forget WHICH media carry the set? Yes whenever the set
-- spans more than one medium -- and that includes the case where nothing is
-- missing yet: a machine that was holding both parts and loses one would
-- otherwise keep drawing from the picture taken before the disk came out, and
-- the failure would be "the shard file is not there" instead of "part 2 of 2 is
-- not inserted". Which media are in the machine is exactly what a disk event
-- changes, so the resolution is re-asked; a one-medium set keeps its index.
local function spans_media()
    local set = state.set
    if not set then return false end
    return (set.parts or 1) > 1 or incomplete()
end

-- THE PICTURE, if the media can be asked. lib/cjk_fonts.lua owns the question
-- "which media carry this set"; this module asks it through a pcall so that a
-- program shipping its own single font directory -- or a machine where
-- cjk_fonts.lua is not loadable -- still works with one base and no finder.
local function set_view(base)
    local ok, fonts = pcall(dc_require, "dc.cjk_fonts")
    if not (ok and type(fonts) == "table" and fonts.parts and fonts.stem_of) then
        return nil
    end
    local ok_parts, picture = pcall(fonts.parts, fonts.stem_of(base))
    if ok_parts and type(picture) == "table" and type(picture.present) == "table" and
       #picture.present > 0 then
        return picture
    end
    return nil
end

-- Load every present part of a picture, and record which parts are not here.
local function init_set(picture, key)
    local layers, present, missing, broken, first_why = {}, {}, {}, {}, nil
    for _, entry in ipairs(picture.present or {}) do
        local index, path, why = load_index(entry.base)
        if index then
            layers[#layers + 1] = make_layer(entry.base, index, path, entry.part,
                                             entry.shards)
            present[#present + 1] = { part = entry.part, base = entry.base,
                                      medium = entry.medium }
        else
            -- A part that is HERE but whose index will not load is reported like
            -- one that is not inserted, because no glyph can be drawn from it
            -- either way -- and its codepoint range is still known, because the
            -- plan is on the medium that is here.
            first_why = first_why or why
            broken[#broken + 1] = { part = entry.part, shards = entry.shards,
                                    first = entry.first, last = entry.last,
                                    why = why }
        end
    end
    if #layers == 0 then
        state.key, state.base, state.layers = nil, nil, {}
        state.set, state.source = nil, nil
        state.error = first_why or "no glyph index could be read"
        return false, state.error
    end
    for _, entry in ipairs(picture.missing or {}) do
        missing[#missing + 1] = { part = entry.part, shards = entry.shards,
                                  first = entry.first, last = entry.last }
    end
    state.key = key
    state.layers = layers
    state.base = layers[1].base
    state.source = layers[1].source
    state.set = { name = picture.name, parts = picture.parts, present = present,
                  missing = missing, broken = broken, foreign = picture.foreign }
    state.loaded, state.failed = {}, {}
    state.error = nil
    return true
end

-- Initialize with the base path, without the _index.lua or _shardN.lua suffix.
-- A TABLE is a picture from cjk_fonts.parts(), i.e. the whole set across media.
--
-- IDEMPOTENT ON PURPOSE: a caller that draws in a loop resolves the font every
-- time, and re-reading and re-parsing the index on every call would turn a cheap
-- lookup into the most expensive thing on the line. Calling init() again with
-- the same base is therefore free; a DIFFERENT base is a new font set and drops
-- the cache, because a shard of one size is not a shard of another. The one
-- exception is an INCOMPLETE set: that one is re-resolved when clear() has been
-- called, so that a medium inserted after the machine complained is found.
function shards.init(base)
    if type(base) == "table" then
        local key = base.name or (base.bases and base.bases[1]) or "set"
        if state.key == key and state.error == nil and not incomplete() then
            return true
        end
        return init_set(base, key)
    end
    if type(base) ~= "string" or base == "" then
        return false, "no base path"
    end
    if state.key == base and state.error == nil and not incomplete() then
        return true
    end

    local picture = set_view(base)
    if picture then
        return init_set(picture, base)
    end

    -- One medium, no marker or no finder: exactly the single-base behaviour this
    -- module had before a set could span two media.
    local index, path, why = load_index(base)
    if not index then
        state.key, state.base, state.layers, state.source = nil, nil, {}, nil
        state.set, state.loaded, state.failed = nil, {}, {}
        state.error = why
        return false, state.error
    end
    state.key = base
    state.layers = { make_layer(base, index, path, 1) }
    state.base = base
    state.source = path
    state.set = nil
    state.loaded, state.failed = {}, {}
    state.error = nil
    return true
end

-- The index of the first loaded layer, or nil.
--
-- It carries the geometry the generator declared (__rows/__cols, set by
-- load_index), which is what lib/cjk.lua needs in order to pack a glyph
-- into the right number of cells. Reading the size from the set's NAME instead
-- would be a guess: the test fixture's set is called shs4 and holds 4x4-pixel
-- matrices, and a real size 16 set drawn at 12 is a band of noise.
function shards.index()
    local layer = state.layers[1]
    return layer and layer.index or nil
end

-- The matrix for a codepoint: a list of "0"/"1" rows, or nil plus why.
--
-- A codepoint the set does not have is NOT an error: it is the normal case for
-- text with a character outside the set, and the caller decides what to draw
-- instead (lib/cjk.lua draws FALLBACK). The distinctions that matter are
-- three: "this font has no such glyph" (nil, "not in this set"), "the glyph is
-- in this set but on a medium that is not inserted" (nil, naming the part), and
-- "the shard holding it could not be read" (nil, with a real reason), because
-- only the first one is not an operator's problem.
function shards.get(code)
    if #state.layers == 0 then
        return nil, "shards: no index loaded" ..
                    (state.error and (" (" .. state.error .. ")") or "")
    end
    code = tonumber(code)
    if not code then return nil, "shards: not a codepoint: " .. tostring(code) end
    for _, layer in ipairs(state.layers) do
        local shard_id = layer.index[code]
        if shard_id ~= nil then
            local glyphs, why = load_shard(layer, shard_id)
            if not glyphs then return nil, why end
            local matrix = glyphs[code]
            if matrix == nil then
                -- The index and the shard disagree: the medium was rebuilt
                -- halfway, or the two files came from different runs. Worth a
                -- real message, because nothing else on the machine can detect
                -- it.
                return nil, layer.base .. "_shard" .. tostring(shard_id) ..
                       ".lua does not contain U+" .. string.format("%04X", code)
            end
            return matrix
        end
    end
    local gap = shards.absent(code)
    if gap then return nil, gap.why end
    return nil, "not in this set"
end

-- The part a codepoint lives on when that part is not available: nil when the
-- codepoint is simply not in the set, or a table describing the part that has to
-- be inserted. This is the question "is this a blank font or an unplugged disk",
-- asked separately from get() so that a caller can render one and report the
-- other.
function shards.absent(code)
    local set = state.set
    if not set then return nil end
    code = tonumber(code)
    if not code then return nil end
    local groups = {}
    for _, entry in ipairs(set.missing or {}) do groups[#groups + 1] = entry end
    for _, entry in ipairs(set.broken or {}) do groups[#groups + 1] = entry end
    for _, gap in ipairs(groups) do
        local first, last = tonumber(gap.first), tonumber(gap.last)
        if first and last and code >= first and code <= last then
            return { part = gap.part, parts = set.parts, name = set.name,
                     shards = gap.shards, first = first, last = last,
                     why = part_reason(gap, set, code) }
        end
    end
    return nil
end

-- Is this codepoint in the set as loaded? Cheap: the indexes only, and FALSE for
-- a codepoint that is in the set but on a medium that is not inserted -- because
-- the question is "can this be drawn now".
function shards.has(code)
    code = tonumber(code)
    if code == nil then return false end
    for _, layer in ipairs(state.layers) do
        if layer.index[code] ~= nil then return true end
    end
    return false
end

-- How many codepoints the loaded parts claim to have, how many shards are
-- cached, and -- the part that matters with two media -- which parts of the set
-- are here and which are not. `status` is the sentence for an operator:
-- "set shs12 part 1 of 2, part 2 not inserted".
function shards.stats()
    local count, cached = 0, 0
    for _, layer in ipairs(state.layers) do
        for _ in pairs(layer.index) do count = count + 1 end
    end
    for _ in pairs(state.loaded) do cached = cached + 1 end
    local set = state.set
    local present, missing, broken = {}, {}, {}
    for _, entry in ipairs(set and set.present or {}) do
        present[#present + 1] = entry.part
    end
    for _, entry in ipairs(set and set.missing or {}) do
        missing[#missing + 1] = entry.part
    end
    for _, entry in ipairs(set and set.broken or {}) do
        broken[#broken + 1] = entry.part
    end
    if not set and state.base then present[1] = 1 end
    return {
        base = state.base,
        glyphs = count,
        cached = cached,
        error = state.error,
        set = set and set.name or (state.base and stem_of(state.base) or nil),
        parts = set and set.parts or 1,
        present = present,
        missing = missing,
        broken = broken,
        layers = #state.layers,
        foreign = set and set.foreign or nil,
        status = status_line(),
    }
end

-- The status sentence on its own, for a caller that only wants to print it.
function shards.status()
    return status_line()
end

-- Where the indexes in use came from, in the order the parts are read. One path
-- for a one-medium set, two for a set that spans two media, and the order is the
-- parts' own order rather than the order the drives were mounted in.
function shards.sources()
    local out = {}
    for _, layer in ipairs(state.layers) do out[#out + 1] = layer.source end
    return out
end

-- Drop every cached shard, keeping the indexes.
--
-- THE FAILURES ARE DROPPED TOO, and that is the point of the function rather than
-- an oversight. A remembered failure is a statement about the MEDIUM as it was
-- when the file could not be read -- and the medium is removable, so that
-- statement expires the moment the operator inserts it again. Keeping it would
-- mean a machine that saw the disk out once could never see the glyphs again
-- without a reboot: re-init()ing with the same base reloads the index and leaves
-- the failure table alone, so a reinserted medium would answer "not there" for
-- every shard it had once been missing. clear() is the call a disk event handler
-- makes, and after it the next lookup tries the medium again.
--
-- With a PART missing, or with a set that spans more than one medium, the whole
-- resolution expires as well, because "part 2 is not inserted" is a statement
-- about which media are in the machine -- and that is exactly what a disk event
-- changes. So the next init() re-scans the media instead of answering from the
-- picture taken before the medium was put in or taken out.
function shards.clear()
    state.loaded = {}
    state.failed = {}
    if spans_media() then
        state.key = nil
    end
end

-- Load one shard before it is needed, for a caller that knows what it is about
-- to draw. Returns the glyph table, or nil plus why.
function shards.preload(shard_id)
    shard_id = tonumber(shard_id)
    if not shard_id then return nil, "shards: not a shard id" end
    for _, layer in ipairs(state.layers) do
        if layer.shards and layer.shards[shard_id] then
            return load_shard(layer, shard_id)
        end
    end
    -- No manifest to ask: the index is what says which medium names this shard.
    for _, layer in ipairs(state.layers) do
        for _, id in pairs(layer.index) do
            if id == shard_id then return load_shard(layer, shard_id) end
        end
    end
    if #state.layers == 0 then
        return nil, "shards: no font base set (call init() first)"
    end
    return nil, "no medium of " .. tostring(state.set and state.set.name or state.base) ..
                " names shard " .. tostring(shard_id)
end

-- Where the index in use came from, for a diagnostic.
function shards.source()
    return state.source
end

return shards
