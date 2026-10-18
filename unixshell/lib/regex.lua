-- regex.lua - the small regular expression engine shared by grep, sed and awk.
--
-- Two syntaxes are understood, which is all the text tools need:
--   basic    (BRE, the grep default and the sed pattern syntax)
--            .  *  ^  $  [...]  \( \)  \|  \+  \?
--   extended (ERE, "grep -E" and the awk pattern syntax)
--            .  *  +  ?  ^  $  [...]  ( )  |
--
-- Matching is a plain backtracking walk over the bytes of the subject, which
-- is enough for the line oriented texts a CraftOS shell handles. Capturing
-- groups are numbered from 1; a group that took no part in the match is
-- reported as nil.

local regex = {}

local INF = math.huge

-- ------------------------------------------------------------- byte classes
local function b_alpha(b)
    return (b >= 65 and b <= 90) or (b >= 97 and b <= 122)
end
local function b_digit(b) return b >= 48 and b <= 57 end
local function b_alnum(b) return b_alpha(b) or b_digit(b) end
local function b_space(b) return b == 32 or (b >= 9 and b <= 13) end
local function b_upper(b) return b >= 65 and b <= 90 end
local function b_lower(b) return b >= 97 and b <= 122 end
local function b_xdigit(b)
    return b_digit(b) or (b >= 65 and b <= 70) or (b >= 97 and b <= 102)
end
local function b_punct(b)
    return (b >= 33 and b <= 47) or (b >= 58 and b <= 64) or
           (b >= 91 and b <= 96) or (b >= 123 and b <= 126)
end
local function b_cntrl(b) return b < 32 or b == 127 end
local function b_print(b) return b >= 32 and b <= 126 end
local function b_graph(b) return b >= 33 and b <= 126 end
local function b_blank(b) return b == 32 or b == 9 end
local function b_word(b) return b_alnum(b) or b == 95 end

local CLASS_TEST = {
    alpha = b_alpha, digit = b_digit, alnum = b_alnum, space = b_space,
    upper = b_upper, lower = b_lower, xdigit = b_xdigit, punct = b_punct,
    cntrl = b_cntrl, print = b_print, graph = b_graph, blank = b_blank,
    word = b_word,
}

-- Backslash escapes that stand for a whole class inside a bracket set.
local CLASS_ESCAPE = {
    d = "digit", D = "!digit",
    w = "word", W = "!word",
    s = "space", S = "!space",
}

local CHAR_ESCAPE = { n = "\n", t = "\t", r = "\r" }

-- A set carries a 0..255 truth table, so a membership test is one lookup.
local function build_set(items, neg)
    local map = {}
    for b = 0, 255 do
        local hit = false
        for i = 1, #items do
            local it = items[i]
            if it.kind == "char" then
                if b == it.lo then hit = true end
            elseif it.kind == "range" then
                if b >= it.lo and b <= it.hi then hit = true end
            else
                local name = it.name
                local flip = false
                if name:sub(1, 1) == "!" then
                    flip = true
                    name = name:sub(2)
                end
                local test = CLASS_TEST[name]
                if test then
                    local ok = test(b)
                    if flip then ok = not ok end
                    if ok then hit = true end
                end
            end
            if hit then break end
        end
        if neg then hit = not hit end
        map[b] = hit
    end
    return { map = map }
end

-- Reads a bracket expression; "i" points at the opening "[".
local function parse_class(pat, i)
    local n = #pat
    i = i + 1
    local neg = false
    if pat:sub(i, i) == "^" then
        neg = true
        i = i + 1
    end
    local items = {}
    local first = true
    while i <= n do
        local c = pat:sub(i, i)
        if c == "]" and not first then
            return build_set(items, neg), i + 1
        end
        first = false
        if c == "[" and pat:sub(i + 1, i + 1) == ":" then
            local close = pat:find(":]", i + 2, true)
            if close then
                items[#items + 1] = { kind = "class",
                                      name = pat:sub(i + 2, close - 1) }
                i = close + 2
            else
                items[#items + 1] = { kind = "char", lo = 91 }
                i = i + 1
            end
        elseif c == "\\" and i < n then
            local d = pat:sub(i + 1, i + 1)
            local esc = CLASS_ESCAPE[d]
            if esc then
                items[#items + 1] = { kind = "class", name = esc }
            else
                local lit = CHAR_ESCAPE[d] or d
                items[#items + 1] = { kind = "char", lo = lit:byte() }
            end
            i = i + 2
        else
            local next_c = pat:sub(i + 1, i + 1)
            if next_c == "-" and i + 2 <= n and pat:sub(i + 2, i + 2) ~= "]" then
                items[#items + 1] = { kind = "range", lo = c:byte(),
                                      hi = pat:sub(i + 2, i + 2):byte() }
                i = i + 3
            else
                items[#items + 1] = { kind = "char", lo = c:byte() }
                i = i + 1
            end
        end
    end
    -- Unterminated set: everything up to the end of the pattern is the set.
    return build_set(items, neg), n + 1
end

-- ------------------------------------------------------------- the pattern
-- A parsed pattern is a list of nodes:
--   char  { c }                     one byte
--   any   {}                        "."
--   class { set }                   a bracket expression
--   bol   {}                        "^"
--   eol   {}                        "$"
--   group { index, nodes }          a capturing group
--   alt   { branches }              "|" alternatives
--   star  { child, min, max }       a quantified node
local function as_nodes(grp)
    if #grp.branches == 1 then return grp.branches[1] end
    return { { k = "alt", branches = grp.branches } }
end

local function parse(pat, ere)
    local root = { branches = { {} } }
    local cur = root
    local stack = {}
    local ngroups = 0
    local n = #pat
    local i = 1

    local function push(node)
        local b = cur.branches[#cur.branches]
        b[#b + 1] = node
    end

    -- Turns the node that was pushed last into a repetition. A quantifier with
    -- nothing to repeat is kept as a literal character.
    local function quantify(min, max, literal)
        local b = cur.branches[#cur.branches]
        local node = b[#b]
        if node == nil or node.k == "bol" or node.k == "eol" then
            b[#b + 1] = { k = "char", c = literal }
            return
        end
        b[#b] = { k = "star", child = node, min = min, max = max }
    end

    -- Opening a group only switches the current branch container: the group is
    -- appended to its parent when it is closed, so the parent never holds the
    -- half built node.
    local function open_group()
        ngroups = ngroups + 1
        local grp = { branches = { {} }, index = ngroups }
        stack[#stack + 1] = cur
        cur = grp
    end

    local function close_group()
        if #stack == 0 then
            -- An unbalanced ")" is a literal, the way most implementations do.
            push({ k = "char", c = ")" })
            return
        end
        local grp = cur
        cur = table.remove(stack)
        push({ k = "group", index = grp.index, nodes = as_nodes(grp) })
    end

    while i <= n do
        local c = pat:sub(i, i)
        if c == "\\" and i < n then
            local d = pat:sub(i + 1, i + 1)
            if not ere and d == "(" then
                open_group()
            elseif not ere and d == ")" then
                close_group()
            elseif not ere and d == "|" then
                cur.branches[#cur.branches + 1] = {}
            elseif not ere and d == "+" then
                quantify(1, INF, "+")
            elseif not ere and d == "?" then
                quantify(0, 1, "?")
            else
                push({ k = "char", c = CHAR_ESCAPE[d] or d })
            end
            i = i + 2
        elseif c == "." then
            push({ k = "any" })
            i = i + 1
        elseif c == "*" then
            quantify(0, INF, "*")
            i = i + 1
        elseif ere and c == "+" then
            quantify(1, INF, "+")
            i = i + 1
        elseif ere and c == "?" then
            quantify(0, 1, "?")
            i = i + 1
        elseif ere and c == "(" then
            open_group()
            i = i + 1
        elseif ere and c == ")" then
            close_group()
            i = i + 1
        elseif ere and c == "|" then
            cur.branches[#cur.branches + 1] = {}
            i = i + 1
        elseif c == "^" then
            push({ k = "bol" })
            i = i + 1
        elseif c == "$" then
            push({ k = "eol" })
            i = i + 1
        elseif c == "[" then
            local set, next_i = parse_class(pat, i)
            push({ k = "class", set = set })
            i = next_i
        else
            push({ k = "char", c = c })
            i = i + 1
        end
    end

    while #stack > 0 do close_group() end
    return as_nodes(root), ngroups
end

-- ------------------------------------------------------------- the matcher
-- Match positions are byte offsets: a node returns the offset just past the
-- text it consumed, so an empty match keeps the offset unchanged.
local match_here, node_match

local function copy_caps(caps, ncap)
    local out = {}
    for i = 1, ncap do out[i] = caps[i] end
    return out
end

node_match = function(node, text, pos, caps, ncap)
    local k = node.k
    if k == "char" then
        if text:sub(pos, pos) == node.c then return pos + 1, caps end
    elseif k == "any" then
        if pos <= #text then return pos + 1, caps end
    elseif k == "class" then
        local b = text:byte(pos)
        if b and node.set.map[b] then return pos + 1, caps end
    elseif k == "bol" then
        if pos == 1 then return pos, caps end
    elseif k == "eol" then
        if pos > #text then return pos, caps end
    elseif k == "group" then
        local inner = {}
        for i = 1, ncap do inner[i] = false end
        local e, c = match_here(node.nodes, 1, text, pos, inner, ncap)
        if e then
            local out = copy_caps(caps, ncap)
            out[node.index] = { pos, e }
            return e, out
        end
    elseif k == "alt" then
        for i = 1, #node.branches do
            local e, c = match_here(node.branches[i], 1, text, pos, caps, ncap)
            if e then return e, c end
        end
    end
    return nil
end

-- A repetition is greedy: every reachable offset is collected first, then the
-- longest one that lets the rest of the pattern match is taken.
match_here = function(nodes, ni, text, pos, caps, ncap)
    if ni > #nodes then return pos, caps end
    local node = nodes[ni]
    if node.k == "star" then
        local min = node.min or 0
        local max = node.max or INF
        local positions = { pos }
        local capsets = { caps }
        local p, c = pos, caps
        while #positions - 1 < max do
            local q, c2 = node_match(node.child, text, p, c, ncap)
            if not q or q == p then break end
            p, c = q, c2
            positions[#positions + 1] = p
            capsets[#capsets + 1] = c
        end
        for k = #positions, min + 1, -1 do
            local r, rc = match_here(nodes, ni + 1, text, positions[k],
                                     capsets[k], ncap)
            if r then return r, rc end
        end
        return nil
    end
    local p2, c2 = node_match(node, text, pos, caps, ncap)
    if not p2 then return nil end
    return match_here(nodes, ni + 1, text, p2, c2, ncap)
end

local function captures_as_strings(text, caps, ncap)
    local out = {}
    for i = 1, ncap do
        local c = caps[i]
        if c then out[i] = text:sub(c[1], c[2] - 1) else out[i] = false end
    end
    return out
end

-- compile(pattern, syntax) -> matcher
-- syntax is "basic" (default) or "extended".
-- matcher:find(text, init) -> start, stop, captures
-- start is the 1 based offset of the match, stop the offset just past it, so
-- text:sub(start, stop - 1) is the matched text. Captures is a list of strings,
-- false for a group that did not take part.
function regex.compile(pattern, syntax)
    local ere = (syntax == "extended")
    local nodes, ngroups = parse(pattern, ere)
    local matcher = {
        pattern = pattern,
        syntax = syntax or "basic",
        groups = ngroups,
    }
    function matcher:find(text, init)
        if type(text) ~= "string" then return nil end
        local last = #text + 1
        local start = init or 1
        if start < 1 then start = 1 end
        while start <= last do
            local caps = {}
            for i = 1, ngroups do caps[i] = false end
            local stop, found = match_here(nodes, 1, text, start, caps, ngroups)
            if stop then
                return start, stop, captures_as_strings(text, found, ngroups)
            end
            start = start + 1
        end
        return nil
    end
    return matcher
end

-- Escapes the characters that would otherwise be read as pattern syntax, so a
-- literal text can be handed to the engine ("grep -F").
function regex.escape(text)
    return (tostring(text):gsub("([%^%$%.%*%+%?%(%)%[%]%%\\|%-])", "\\%1"))
end

return regex
