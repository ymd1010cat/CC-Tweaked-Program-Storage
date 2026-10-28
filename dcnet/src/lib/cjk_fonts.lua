-- dc.cjk_fonts — 从 pyromputer-os/lib/cc_fonts.lua 复制（作者同意跨项目复用）
-- 只改模块名；字体介质的标记文件仍是 cc_fonts.marker（与 Pyromputer OS 字体盘兼容）。
-- cjk_fonts.lua - find the media that carry the glyphs, and the set they make
--
-- WHY THE GLYPHS ARE NOT ON THE COMPUTER, AND WHY FINDING THEM IS A MODULE
-- A CJK bitmap set at size 12 is about 1 MB of data. A CraftOS computer's own
-- filesystem is capped at 1,000,000 B by computer_space_limit, and the shell plus
-- the modules it boots with already use about 73% of that, so the glyphs cannot
-- live on the computer at all: they live on a medium of their own. That medium
-- is not a drive letter, because a drive letter is a property of the bay and not
-- of the data -- a medium moved to another bay, or inserted after a reboot, must
-- still be found. So it is found by its MARKER, exactly as the package stores
-- are: a file named cc_fonts.marker in the root of the medium.
--
-- This is a THIRD marker, and the three mean three different things:
--   .pkgsys        the system module store: the shell's own modules
--   .pkgstore      an ordinary package store: extra packages
--   cc_fonts.marker this medium carries font glyphs (and is usually also a
--                  package store, because the package that uses the glyphs is
--                  installed with "requires_disk=cc_fonts.marker")
-- None of them is a drive number, and the search below is what turns "some
-- mounted medium has the marker" into a path the renderer can open.
--
-- WHY TWO MEDIA AND NOT ONE
-- The whole of GB2312 at size 12 measures 1,375,263 B (measured, see
-- tools/fontgen.py) and a CraftOS floppy holds 1,228,800 B, so the standard is
-- 146,463 B too big for the medium it would have to live on. The operator's
-- instruction was "the Chinese shards do not fit on one drive, so use two", and
-- that is what this module now describes: a SET of glyphs may span several
-- media, each carrying the shards that fit on it and an index naming ONLY those
-- shards. Nothing here duplicates an index: two media of one set have two
-- different indexes, one per part.
--
-- WHY A REASON AND NOT A BOOLEAN
-- The renderer has to be able to say why it is not drawing. "There is no medium
-- inserted" and "there is a medium but it is not a font medium" and "the font
-- medium is here but its index file is missing" are three different operational
-- situations with three different fixes, and a single false tells the operator
-- none of them. resolve() therefore returns a reason string in every failure
-- case, and the two callers (cjk.lua and a test) both report it. A fourth
-- situation joins them with a two-medium set: the medium IS inserted and the
-- glyph IS in the set, but on the part that is not -- parts() names that part,
-- because "part 2 of 2 is not inserted" is actionable and a blank box is not.
--
-- WHAT IS SEARCHED, AND WHY BOTH A MOUNT TABLE AND A DRIVE LIST
-- The mount table is the project's own view of the filesystems (lib/mounts.lua):
-- an entry there has been mounted by the shell or by the automount, and its
-- source is the real directory. But a font can also be read with no mount at all
-- -- the drive is simply there -- and the shell is not always running: a program
-- that draws a menu may start before anything has mounted anything. So both are
-- searched, and the drive list is the same one lib/disk.lua watches.
local cjk_fonts = {}

-- The marker that makes a medium a font medium. It is deliberately NOT one of
-- lib/pkg.lua's two store markers: a medium can be a font medium and an ordinary
-- package store at once, and neither claim implies the other.
cjk_fonts.MARKER = "cc_fonts.marker"

-- The directory the shards live in, inside the font medium. A subdirectory
-- rather than the root: the root already carries the marker and may carry a
-- package store's own layout (usr/pkgs), and the glyph files are data the
-- runtime asks for by name, not packages.
cjk_fonts.DIR = "fonts"

-- The manifest a medium carries beside its index, naming the SET the glyphs
-- belong to and WHICH PART of it this medium is: <base>.set.lua, e.g.
-- fonts/shs12.set.lua with
--
--     return {name="shs12",parts=2,part=1,glyphs=3500,shards={0,1,2,3,4,5,6},
--             plan={{part=1,...},{part=2,shards={7,...,13},first=...,last=...}}}
--
-- WHY A PART AND NOT JUST "A FONT MEDIUM"
-- Two media that each carry "some glyphs" are not a set: a lookup has to know
-- which medium holds which shard, and a machine that is holding only one of them
-- has to be able to say WHICH ONE IS MISSING. `shards` answers the first -- it
-- lists the shard ids this medium's index names, so a per-disk index can be
-- checked against the files beside it -- and `plan` answers the second: every
-- part of the set with the codepoint range it covers, so a machine holding only
-- part 1 can still say "U+7480 is in part 2 of 2" instead of drawing nothing and
-- saying nothing. Both are small: two lines per part.
--
-- The file is plain Lua data like the index and the shards, read with the ROM's
-- own loadstring, so it costs no parser. It is OPTIONAL: a medium built before
-- this existed, or handwritten, is still a font medium, and it then behaves as
-- a set of one part -- which is exactly what it is.
cjk_fonts.MANIFEST_SUFFIX = ".set.lua"

-- The drives to look at when the mount table has nothing, in the order
-- lib/disk.lua names them. "/rom" is included last and is not a font medium in
-- practice -- it is the read only ROM and cannot be written -- but it is a
-- mounted filesystem, so leaving it out would make "no medium" and "only the ROM
-- is there" the same answer.
cjk_fonts.DRIVES = { "/disk", "/disk0", "/disk1", "/disk2", "/disk3", "/rom" }

-- Overridable so that a test can hand the finder an environment without a
-- machine, and so that a future caller can pin a program's font to one medium.
-- pkg.roots() is deliberately NOT used here: lib/pkg.lua is itself on the medium
-- on a two-part install, so a finder that required it could never find the very
-- medium pkg.lua is on.
cjk_fonts.CANDIDATES = nil

local function exists(path)
    return fs.exists(path)
end

-- Is `path` a mounted filesystem rather than a plain directory? fs.getCapacity is
-- what tells them apart, the same test lib/disk.lua uses. It is wrapped because
-- it is not available on every host, and a missing capacity must not be read as
-- "no medium".
local function is_medium(path)
    if not (exists(path) and fs.isDir(path)) then return false end
    local ok, cap = pcall(fs.getCapacity, path)
    if ok and cap == nil then return false end
    return true
end

-- Is `path` at or below `root`? Compared as path components, not as text: a
-- string prefix would say that /disk2 holds /disk22.
local function within(path, root)
    if type(path) ~= "string" or type(root) ~= "string" then return false end
    if path == root then return true end
    return path:sub(1, #root + 1) == root .. "/"
end

-- Every directory that might be a medium, in the order they are worth trying.
-- The mount table comes first because a mounted medium is one the operator (or
-- the automount) has already decided is a filesystem rather than a directory.
local function candidates()
    if cjk_fonts.CANDIDATES then return cjk_fonts.CANDIDATES end
    local out, seen = {}, {}
    local function add(path)
        if type(path) ~= "string" or path == "" then return end
        if seen[path] then return end
        seen[path] = true
        out[#out + 1] = path
    end
    -- The mount table is read through pcall because this module is reachable
    -- from a boot path where lib/mounts.lua may not be loadable yet; a font
    -- search has no business turning that into an error inside a draw loop.
    local ok, mounts = pcall(dc_require, "dc.mounts")
    if ok and type(mounts) == "table" and mounts.list then
        local ok_list, list = pcall(mounts.list)
        if ok_list then
            for _, entry in ipairs(list or {}) do add(entry.source) end
        end
    end
    for _, drive in ipairs(cjk_fonts.DRIVES) do add(drive) end
    return out
end

-- Look for every glyph layer under `medium`, returning the base paths to hand to
-- cjk_shards.init (e.g. "/disk2/fonts/shs12"), or nil.
--
-- A medium is not required to have its shards in one place: a size 8 set and a
-- size 12 set may sit in the same fonts/ directory, and the index is what names
-- a set. So the directory is scanned for *_index.lua and every one found is
-- returned -- and when several are present the choice is decided by the caller's
-- preference list (lib/cjk.lua checks the size it is configured for
-- first), which is why this returns a LIST of bases rather than one.
local function bases_under(medium)
    local dir = medium .. "/" .. cjk_fonts.DIR
    if not (exists(dir) and fs.isDir(dir)) then return nil end
    local out = {}
    for _, name in ipairs(fs.list(dir) or {}) do
        local stem = name:match("^(.*)_index%.lua$")
        if stem then out[#out + 1] = dir .. "/" .. stem end
    end
    table.sort(out)
    return out
end

-- The stem of a base path ("/disk2/fonts/shs12" -> "shs12"), which is the NAME OF
-- THE SET: the index, the shards and the manifest of one set all share it, and
-- two media are parts of one set exactly when they carry the same stem.
local function stem_of(path)
    return tostring(path):match("([^/]+)$") or tostring(path)
end
cjk_fonts.stem_of = stem_of

-- The manifest beside an index, or nil (plus the path it would have been at).
--
-- A manifest that will not load counts as absent, and that is on purpose: the
-- index and the shards are what a lookup needs, and a medium whose manifest is
-- corrupt still carries working glyphs. The path is returned either way so that
-- a caller who WANTS to complain about a corrupt manifest can name the file.
function cjk_fonts.manifest(base)
    local path = base .. cjk_fonts.MANIFEST_SUFFIX
    if not exists(path) then return nil, path end
    local handle = fs.open(path, "r")
    if not handle then return nil, path end
    local text = handle.readAll()
    handle.close()
    if type(text) ~= "string" or text == "" then return nil, path end
    local loader = loadstring or load
    local chunk = loader(text, "@" .. path)
    if not chunk then return nil, path end
    local ok, value = pcall(chunk)
    if ok and type(value) == "table" then return value, path end
    return nil, path
end

-- Every marked medium that carries at least one glyph set, in a DETERMINISTIC
-- order: by the medium's own path.
--
-- WHY SORT AND NOT THE ORDER THEY WERE MOUNTED IN. candidates() answers in the
-- order the media are worth TRYING (the mount table first, then the drive list),
-- and that order depends on what the operator or the automount happened to do
-- first. A union built in that order would answer differently on two machines
-- holding the same disks, so this list is sorted and is the same everywhere. The
-- order a glyph SET is read in does not come from here anyway -- each part's
-- manifest says which part it is, which is the order that has to be stable.
function cjk_fonts.media()
    local out = {}
    for _, medium in ipairs(candidates()) do
        if is_medium(medium) and exists(medium .. "/" .. cjk_fonts.MARKER) then
            local bases = bases_under(medium)
            if bases and #bases > 0 then
                out[#out + 1] = { medium = medium, bases = bases }
            end
        end
    end
    table.sort(out, function(a, b) return a.medium < b.medium end)
    return out
end

-- Every glyph set base on every marked medium, in media() order then in the
-- order of the bases within a medium. The flat form of media(), for a caller
-- that only wants the list of sets the machine can see.
function cjk_fonts.bases()
    local out = {}
    for _, entry in ipairs(cjk_fonts.media()) do
        for _, base in ipairs(entry.bases) do out[#out + 1] = base end
    end
    return out
end

-- A plan flattened into one string, to answer "do two media describe the same
-- split of the same set?". Two runs that wrote different partitions of one set
-- and then got mixed on one desk are the failure this catches, and nothing else
-- on the machine can see it.
local function plan_key(plan)
    local out = {}
    for _, entry in ipairs(plan or {}) do
        local ids = {}
        for _, id in ipairs(entry.shards or {}) do ids[#ids + 1] = tostring(id) end
        out[#out + 1] = tostring(entry.part) .. ":" .. table.concat(ids, ",")
    end
    return table.concat(out, ";")
end

-- THE WHOLE PICTURE of a glyph set: every medium that carries it, ordered by the
-- PART each one says it is, plus the parts that are NOT inserted.
--
-- Returns: picture (nil when no marked medium carries the set), reason.
--
-- The picture is what a caller needs to resolve a codepoint across media:
--   name     the set ("shs12")
--   parts    how many media the whole set needs, taken from the manifests and
--            NOT from how many are inserted: a machine holding part 2 of 3 has
--            to be able to say "3"
--   bases    the present parts' base paths, in part order
--   present  {part=, base=, medium=, shards=} per inserted part
--   missing  {part=, shards=, first=, last=} per absent part, from the plan
--   foreign  a complaint about a file that claims to be part of this set and is
--            not (a manifest naming another set, or another split); nil when the
--            media agree, which is the normal case
function cjk_fonts.parts(stem)
    stem = tostring(stem or "")
    if stem == "" then return nil, "no set name" end
    local present, plan, foreign = {}, nil, nil
    for _, entry in ipairs(cjk_fonts.media()) do
        for _, base in ipairs(entry.bases) do
            if stem_of(base) == stem then
                local man, man_path = cjk_fonts.manifest(base)
                local item = { part = 1, parts = 1, base = base, medium = entry.medium }
                local usable = true
                if man then
                    if type(man.name) == "string" and man.name ~= stem then
                        -- A file called <stem>_index.lua whose manifest names a
                        -- different set is not a part of this set, and it is not
                        -- silently dropped either: a mixed pair of media is a
                        -- thing the operator has to be told about.
                        usable = false
                        foreign = (foreign and (foreign .. "; ") or "") ..
                            man_path .. " names the set " .. tostring(man.name)
                    else
                        item.part = tonumber(man.part) or 1
                        item.parts = tonumber(man.parts) or 1
                        if type(man.shards) == "table" then item.shards = man.shards end
                        if type(man.plan) == "table" and #man.plan > 0 then
                            local key = plan_key(man.plan)
                            if plan and key ~= "" and plan_key(plan) ~= key then
                                foreign = (foreign and (foreign .. "; ") or "") ..
                                    man_path .. " describes a different split of " .. stem
                            end
                            plan = plan or man.plan
                        end
                    end
                end
                if usable then present[#present + 1] = item end
            end
        end
    end

    if #present == 0 then
        return nil, "no marked medium carries the glyph set " .. stem ..
            " (looked at " .. table.concat(candidates(), ", ") .. " for " ..
            cjk_fonts.DIR .. "/" .. stem .. "_index.lua)"
    end

    table.sort(present, function(a, b)
        if a.part ~= b.part then return a.part < b.part end
        return a.base < b.base
    end)

    local count = 1
    for _, item in ipairs(present) do
        if item.parts > count then count = item.parts end
    end
    if plan and #plan > count then count = #plan end

    local here = {}
    for _, item in ipairs(present) do here[item.part] = item end
    local missing = {}
    for p = 1, count do
        if not here[p] then
            local gap = { part = p }
            for _, planned in ipairs(plan or {}) do
                if tonumber(planned.part) == p then
                    gap.shards = planned.shards
                    gap.first = tonumber(planned.first)
                    gap.last = tonumber(planned.last)
                    gap.glyphs = tonumber(planned.glyphs)
                end
            end
            missing[#missing + 1] = gap
        end
    end

    local bases = {}
    for _, item in ipairs(present) do bases[#bases + 1] = item.base end
    return {
        name = stem,
        parts = count,
        bases = bases,
        present = present,
        missing = missing,
        foreign = foreign,
    }
end

-- The medium that carries the marker and has at least one glyph set, plus every
-- candidate that looked like a medium and did not, as a reason.
--
-- Returns: base (nil when none), medium (nil when none), index_path (nil when
-- the medium was found without a set), reason (nil on success).
function cjk_fonts.find()
    local saw_medium, saw_marker, saw_dir = false, nil, nil
    for _, medium in ipairs(candidates()) do
        if is_medium(medium) then
            saw_medium = true
            if exists(medium .. "/" .. cjk_fonts.MARKER) then
                local bases = bases_under(medium)
                if bases and #bases > 0 then
                    local base = bases[1]
                    return base, medium, base .. "_index.lua", nil
                end
                if not saw_dir then saw_dir = medium end
                saw_marker = saw_marker or medium
            end
        end
    end

    -- The failures are ordered by how close the machine was to working, because
    -- that is the order an operator can act on them.
    if saw_marker then
        return nil, saw_marker, nil,
            "the font medium " .. saw_marker .. " carries " .. cjk_fonts.MARKER ..
            " but has no glyph set in " .. saw_marker .. "/" .. cjk_fonts.DIR ..
            "/*_index.lua (was the medium built with tools/fontdisk.py?)"
    end
    if saw_medium then
        return nil, nil, nil,
            "no mounted medium carries " .. cjk_fonts.MARKER .. ": insert the font " ..
            "medium, or build one with tools/fontdisk.py"
    end
    return nil, nil, nil,
        "no medium is inserted (looked at " .. table.concat(candidates(), ", ") ..
        " for " .. cjk_fonts.MARKER .. "; build a font medium with " ..
        "tools/fontdisk.py)"
end

-- One glyph set by name, for a caller that knows where its font is. The base is
-- mounted through lib/mounts.lua so a logical path ("/mnt/floppy/fonts/shs12")
-- works as well as the physical one ("/disk2/fonts/shs12").
local function mountable(path)
    local ok, mounts = pcall(dc_require, "dc.mounts")
    if ok and type(mounts) == "table" and mounts.map then
        local ok_map, mapped = pcall(mounts.map, path)
        if ok_map and type(mapped) == "string" then return mapped end
    end
    return path
end

function cjk_fonts.resolve(base)
    if base then
        local path = mountable(base)
        local index = path .. "_index.lua"
        if not exists(index) then
            return nil, nil, nil, "no glyph index at " .. index
        end
        return path, nil, index, nil
    end
    return cjk_fonts.find()
end

-- The reason a font could not be resolved, in one line, for a caller that only
-- has bool to work with. Kept here so the wording exists in one place.
function cjk_fonts.why(reason)
    return "cjk_fonts: " .. tostring(reason)
end

return cjk_fonts
