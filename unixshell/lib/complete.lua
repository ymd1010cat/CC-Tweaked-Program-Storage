-- complete.lua - Tab completion for the ush line editor
-- Command words are completed against the shell built-ins, the current aliases
-- and the PATH directories; a word that starts with a dash is completed
-- against the options the command in front of it takes, the manual page of the
-- command being the source, so an unknown command yields nothing instead of an
-- error; "sudo" hands the completion over to the command it wraps, completes
-- its own options and suggests an account after -u; every other word is
-- completed against the file system, with directories completed with a
-- trailing slash. A single candidate is inserted directly, several candidates
-- extend the word to their longest common prefix and are returned for display.

local cwd = require("cwd")
local pathlib = require("path")

-- lib/man.lua is NOT required at load time, on purpose.
--
-- The manual pages are 76 KB of documentation -- by far the largest library after
-- the shell itself -- and they are only needed to complete the OPTIONS of a
-- command. A top-level require here put them in the base half of a two-part
-- install, which means they sat on the machine's own disk: measured, they were
-- 76,549 B of an 808,370 B part 1, on a 1 MB computer. Because the base/modules
-- split follows the load-time closure, one `local man = require("man")` here was
-- enough to drag the whole table onto the disk.
--
-- Loading them on first use moves them to the medium (the system module store),
-- where documentation belongs. The failure is handled rather than propagated: a
-- machine with no medium must still complete file names, and a completion that
-- threw would break the line editor -- the one thing that has to keep working.
local function man_pages()
    local ok, mod = pcall(require, "man")
    if ok and type(mod) == "table" and type(mod.pages) == "table" then
        return mod.pages
    end
    return nil
end

local complete = {}

local function join(dir, name)
    if dir == "" then return name end
    if dir:sub(-1) == "/" then return dir .. name end
    return dir .. "/" .. name
end

local function path_entries(dir)
    local ok, entries = pcall(fs.list, dir)
    if not ok or type(entries) ~= "table" then return {} end
    table.sort(entries)
    return entries
end

local function starts_with(text, prefix)
    if prefix == "" then return true end
    return text:sub(1, #prefix) == prefix
end

-- Characters that end a word. Used to find where the word after the cursor
-- stops, so completion can replace the whole word.
local WORD_BREAK = {
    [" "] = true, ["\t"] = true, [";"] = true, ["|"] = true, ["&"] = true,
    ["<"] = true, [">"] = true, ["("] = true, [")"] = true,
    ["{"] = true, ["}"] = true,
}

-- Split the text before the cursor into (head, word).
local function split_word(line, cursor)
    local head = line:sub(1, math.max(cursor - 1, 0))
    local start = 1
    for i = #head, 1, -1 do
        local c = head:sub(i, i)
        if c == " " or c == "\t" or c == ";" or c == "|" or c == "&" or
           c == "<" or c == ">" or c == "(" or c == ")" or c == "{" or c == "}" then
            start = i + 1
            break
        end
    end
    return head:sub(1, start - 1), head:sub(start)
end

-- A word is a command word when the text before it is empty or ends with a
-- command separator (";" "|" "&" "(" "{").
local function command_position(before)
    local trimmed = before:gsub("%s+$", "")
    if trimmed == "" then return true end
    local last = trimmed:sub(-1)
    return last == ";" or last == "|" or last == "&" or last == "(" or last == "{"
end

function complete.commands(prefix, ctx)
    local out = {}
    local seen = {}

    local function add(name)
        if type(name) == "string" and name ~= "" and not seen[name] and
           starts_with(name, prefix) then
            seen[name] = true
            out[#out + 1] = name
        end
    end

    if ctx and ctx.builtins then
        for _, name in ipairs(ctx.builtins) do add(name) end
    end
    if ctx and ctx.aliases then
        for _, name in ipairs(ctx.aliases) do add(name) end
    end

    for _, dir in ipairs(pathlib.dirs()) do
        for _, entry in ipairs(path_entries(dir)) do
            local name = entry
            if entry:sub(-4) == ".lua" then name = entry:sub(1, #entry - 4) end
            if fs.exists(join(dir, name .. ".lua")) then add(name) end
        end
    end

    table.sort(out)
    return out
end

function complete.files(prefix)
    local dirpart, base = prefix:match("^(.*/)([^/]*)$")
    if not dirpart then
        dirpart, base = "", prefix
    end
    local list_dir = dirpart == "" and cwd.get() or cwd.resolve(dirpart)
    local hidden_ok = base:sub(1, 1) == "."

    local out = {}
    for _, name in ipairs(path_entries(list_dir)) do
        if starts_with(name, base) and (hidden_ok or name:sub(1, 1) ~= ".") then
            local full = dirpart .. name
            if fs.isDir(cwd.resolve(full)) then full = full .. "/" end
            out[#out + 1] = full
        end
    end
    return out
end

-- Pull every option word out of one line of a manual page: a dash, an optional
-- second dash and the name of the option. The dash has to open a word (start
-- of the line, bracket, brace, parenthesis, pipe, comma or blank), so a word
-- like "read-only" in a description is not mistaken for "-read". A single dash
-- only counts when one letter follows it, so a synopsis that writes the flags
-- of a command in one go ("grep [-ivnclqrE]") does not turn into an option
-- nobody could type.
local function scan_options(text, add)
    if type(text) ~= "string" then return end
    local i = 1
    while true do
        local s, e = text:find("%-%-?[%w][%w%-]*", i)
        if not s then return end
        local prev = s > 1 and text:sub(s - 1, s - 1) or ""
        if prev == "" or prev == "[" or prev == "{" or prev == "(" or
           prev == "|" or prev == "," or prev == " " or prev == "\t" then
            local opt = text:sub(s, e)
            if opt:sub(1, 2) == "--" or #opt == 2 then add(opt) end
        end
        i = e + 1
    end
end

-- The options a command takes: the bracketed words of its synopsis plus the
-- entries of its OPTIONS list. A command without a page, a name that is not a
-- string and a page without options all give an empty list.
function complete.options(name, prefix)
    prefix = prefix or ""
    local out, seen = {}, {}
    local function add(opt)
        if starts_with(opt, prefix) and not seen[opt] then
            seen[opt] = true
            out[#out + 1] = opt
        end
    end
    local pages = man_pages()
    local page = type(name) == "string" and pages and pages[name] or nil
    if page then
        for _, line in ipairs(page.syn or {}) do scan_options(line, add) end
        for _, entry in ipairs(page.opts or {}) do
            scan_options(entry[1], add)
        end
    end
    table.sort(out)
    return out
end

-- The account names "sudo -u" can complete to. The list arrives in the shell
-- context (the shell knows /etc/passwd), so this module stays away from the
-- accounts and a missing list simply completes nothing.
function complete.users(prefix, ctx)
    prefix = prefix or ""
    local out = {}
    for _, name in ipairs((ctx and ctx.users) or {}) do
        if starts_with(name, prefix) then out[#out + 1] = name end
    end
    table.sort(out)
    return out
end

-- Split a line into words with the same word breaks the editor uses.
local function words_of(text)
    local words, cur = {}, {}
    for i = 1, #text do
        local c = text:sub(i, i)
        if WORD_BREAK[c] then
            if #cur > 0 then
                words[#words + 1] = table.concat(cur)
                cur = {}
            end
        else
            cur[#cur + 1] = c
        end
    end
    if #cur > 0 then words[#words + 1] = table.concat(cur) end
    return words
end

-- What "sudo" is waiting for after its own name: "user" right after -u,
-- "command" while the command it wraps is being typed, "args" once that
-- command is known (the index of the word is handed back with it) and
-- "option" while sudo reads its own options.
local function sudo_scan(words, count)
    local want_user = false
    local i = 2
    while i <= count do
        local w = words[i]
        if want_user then
            want_user = false
        elseif w == "--" then
            if i < count then return "args", i + 1 end
            return "command", nil
        elseif w == "-u" then
            want_user = true
        elseif w:sub(1, 1) ~= "-" then
            return "args", i
        end
        i = i + 1
    end
    if want_user then return "user", nil end
    return "option", nil
end

-- The candidates of one word. "before" is the text in front of the word, so
-- the word being completed is not part of it.
local function candidates_for(before, word, ctx)
    local words = words_of(before)

    if command_position(before) then
        if word:find("/", 1, true) then return complete.files(word) end
        return complete.commands(word, ctx)
    end

    if words[1] == "sudo" then
        local kind, index = sudo_scan(words, #words)
        local owner = index and words[index] or "sudo"
        if kind == "user" then return complete.users(word, ctx) end
        if kind == "command" or
           (kind == "option" and word:sub(1, 1) ~= "-") then
            if word:find("/", 1, true) then return complete.files(word) end
            return complete.commands(word, ctx)
        end
        if word:sub(1, 1) == "-" then return complete.options(owner, word) end
        return complete.files(word)
    end

    if word:sub(1, 1) == "-" then
        return complete.options(words[1], word)
    end
    return complete.files(word)
end

-- Returns new_line, new_cursor, candidates.
function complete.complete(line, cursor, ctx)
    local before, word = split_word(line, cursor)
    local candidates = candidates_for(before, word, ctx)

    -- The word may continue past the cursor; those extra characters belong to
    -- the word and must be replaced too, otherwise completing "ec|ho" would
    -- leave a stray "ho" behind.
    local rest = line:sub(cursor)
    local skip = 0
    while skip < #rest and not WORD_BREAK[rest:sub(skip + 1, skip + 1)] do
        skip = skip + 1
    end
    local tail = rest:sub(skip + 1)

    if #candidates == 0 then
        return line, cursor, candidates
    end

    if #candidates == 1 then
        local replacement = candidates[1]
        local suffix = replacement:sub(-1) == "/" and "" or " "
        local new_line = before .. replacement .. suffix .. tail
        return new_line, #before + #replacement + #suffix + 1, candidates
    end

    local common = candidates[1]
    for i = 2, #candidates do
        local other = candidates[i]
        local j = 1
        while j <= #common and common:sub(j, j) == other:sub(j, j) do j = j + 1 end
        common = common:sub(1, j - 1)
    end

    local new_line, new_cursor = line, cursor
    if #common > #word then
        new_line = before .. common .. tail
        new_cursor = #before + #common + 1
    end
    return new_line, new_cursor, candidates
end

return complete
