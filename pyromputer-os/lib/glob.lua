-- glob.lua - POSIX-style pathname expansion for psh
-- Shell patterns (*, ?, [abc]) are translated into Lua patterns and expanded
-- against the CraftOS file system. Directory lookups always go through
-- lib/cwd.lua, so relative patterns are anchored at the current directory
-- while the returned names keep exactly the prefix the user typed.

local cwd = require("cwd")

local glob = {}

local LUA_MAGIC = "[%^%$%(%)%%%.%[%]%*%+%-%?]"

local function esc(c)
    if c:match(LUA_MAGIC) then return "%" .. c end
    return c
end

-- Escape a literal run of text so that it matches itself as a glob pattern.
-- Used for quoted or backslash-escaped words, which never act as wildcards.
function glob.literal(text)
    return (text:gsub("([%*%?%[%]\\])", "\\%1"))
end

-- Translate the bracket expression starting at pat[i] ("[") into a Lua set.
-- Returns class, next_index or nil, next_index when the class is unterminated.
-- A "]" that stands right behind the "[" (or behind its "[!" or "[^") is a
-- member of the set and not its end, the way POSIX reads it: "[]]" is the set
-- that holds the bracket itself, "[!]]" is the set of everything but it. A set
-- that holds no member at all is not a set, so "[]" and "[!]" are read as the
-- unterminated "[" and reach the caller as the plain text they are.
local function class(pat, i)
    local j = i + 1
    local negate = false
    local c = pat:sub(j, j)
    if c == "!" or c == "^" then
        negate = true
        j = j + 1
    end
    local body = {}
    if pat:sub(j, j) == "]" then
        body[#body + 1] = esc("]")
        j = j + 1
    end
    while j <= #pat do
        c = pat:sub(j, j)
        if c == "]" then
            if #body == 0 then return nil, i + 1 end
            return "[" .. (negate and "^" or "") .. table.concat(body) .. "]", j + 1
        elseif c == "\\" and j < #pat then
            body[#body + 1] = esc(pat:sub(j + 1, j + 1))
            j = j + 2
        elseif c == "%" then
            body[#body + 1] = "%%"
            j = j + 1
        else
            body[#body + 1] = c
            j = j + 1
        end
    end
    return nil, i + 1
end

-- Compile a shell pattern into an anchored Lua pattern. "cross" tells whether
-- a wildcard may also match a path separator: filename expansion never crosses
-- one, while the pattern removal of the parameter expansion ("${path##*/}")
-- works on the whole value and has to.
local function build(pat, cross)
    local out = {}
    local i = 1
    while i <= #pat do
        local c = pat:sub(i, i)
        if c == "*" then
            out[#out + 1] = cross and ".*" or "[^/]*"
            i = i + 1
        elseif c == "?" then
            out[#out + 1] = cross and "." or "[^/]"
            i = i + 1
        elseif c == "[" then
            local cls, nxt = class(pat, i)
            if cls then out[#out + 1] = cls else out[#out + 1] = "%[" end
            i = nxt
        elseif c == "\\" and i < #pat then
            out[#out + 1] = esc(pat:sub(i + 1, i + 1))
            i = i + 2
        else
            out[#out + 1] = esc(c)
            i = i + 1
        end
    end
    return "^" .. table.concat(out) .. "$"
end

function glob.compile(pat)
    return build(pat, false)
end

-- The same, for the value of a variable rather than a path name. A value has
-- no directories, so "*" and "?" cross a separator here: "${p##*/}" is the
-- basename idiom of a POSIX shell and "${p%/*}" its dirname counterpart.
function glob.compile_value(pat)
    return build(pat, true)
end

-- True when the pattern holds an unescaped wildcard character.
function glob.has_magic(pat)
    local i = 1
    while i <= #pat do
        local c = pat:sub(i, i)
        if c == "\\" then
            i = i + 2
        elseif c == "*" or c == "?" or c == "[" then
            return true
        else
            i = i + 1
        end
    end
    return false
end

function glob.match(name, pat)
    return type(name) == "string" and name:match(glob.compile(pat)) ~= nil
end

-- Match a whole value against a pattern, used by the parameter expansion
-- operators "#", "##", "%" and "%%".
function glob.match_value(name, pat)
    return type(name) == "string" and name:match(glob.compile_value(pat)) ~= nil
end

local function join(prefix, name)
    if prefix == "" then return name end
    if prefix == "/" then return "/" .. name end
    return prefix .. "/" .. name
end

local function split_pattern(pat)
    local trailing = #pat > 1 and pat:sub(-1) == "/"
    local body = trailing and pat:sub(1, #pat - 1) or pat
    local leading = body:sub(1, 1) == "/" and "/" or ""
    local segs = {}
    for seg in body:gmatch("[^/]+") do segs[#segs + 1] = seg end
    return leading, segs, trailing
end

-- Expand one pattern into a sorted list of existing paths. Returns an empty
-- table when nothing matched, which the caller turns into the literal word
-- (the POSIX behaviour when a pattern does not match anything).
function glob.expand(pat)
    local leading, segs, trailing = split_pattern(pat)
    if #segs == 0 then return {} end

    local results = { leading }
    for idx, seg in ipairs(segs) do
        local last = idx == #segs
        local matcher = glob.has_magic(seg) and glob.compile(seg) or nil
        local hidden_ok = seg:sub(1, 1) == "."
        local out = {}

        for _, base in ipairs(results) do
            if matcher then
                local dir = base == "" and cwd.get() or cwd.resolve(base)
                local ok, entries = pcall(fs.list, dir)
                if ok and type(entries) == "table" then
                    table.sort(entries)
                    for _, name in ipairs(entries) do
                        if (hidden_ok or name:sub(1, 1) ~= ".") and name:match(matcher) then
                            local full = join(base, name)
                            local is_dir = fs.isDir(cwd.resolve(full))
                            if last then
                                if not trailing then
                                    out[#out + 1] = full
                                elseif is_dir then
                                    out[#out + 1] = full .. "/"
                                end
                            elseif is_dir then
                                out[#out + 1] = full
                            end
                        end
                    end
                end
            else
                local name = seg:gsub("\\(.)", "%1")
                local full = join(base, name)
                local abs = cwd.resolve(full)
                if fs.exists(abs) then
                    local is_dir = fs.isDir(abs)
                    if last then
                        if not trailing then
                            out[#out + 1] = full
                        elseif is_dir then
                            out[#out + 1] = full .. "/"
                        end
                    elseif is_dir then
                        out[#out + 1] = full
                    end
                end
            end
        end

        results = out
        if #results == 0 then break end
    end

    table.sort(results)
    return results
end

return glob
