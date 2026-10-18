-- sed.lua - the sed subset used by the shell.
--
-- Supported: the substitution "s/pat/repl/[gp]", the "d" and "p" commands,
-- the -n (quiet) flag and line addresses (n, n,m, /re/, $). The replacement
-- text understands "&" and the back references \1..\9.
--
-- A program is compiled once and can then be applied to any number of texts;
-- the state a range address needs is kept per run, not inside the program.

local regex = require("regex")

local sed = {}

local function skip_blanks(s, i, n)
    while i <= n do
        local c = s:sub(i, i)
        if c == " " or c == "\t" then i = i + 1 else break end
    end
    return i
end

-- Reads "re<delim>" starting at the delimiter; the pattern is kept in BRE
-- syntax, exactly like the pattern of a substitution. An escaped delimiter is
-- kept escaped, the engine reads it as the literal character.
local function read_pattern(s, i, n, delim)
    delim = delim or "/"
    local buf = {}
    local j = i + 1
    while j <= n do
        local c = s:sub(j, j)
        if c == "\\" and j < n then
            buf[#buf + 1] = c
            buf[#buf + 1] = s:sub(j + 1, j + 1)
            j = j + 2
        elseif c == delim then
            return table.concat(buf), j + 1
        else
            buf[#buf + 1] = c
            j = j + 1
        end
    end
    return table.concat(buf), j
end

local function read_address(s, i, n)
    local c = s:sub(i, i)
    if c == "" then return nil, i end
    if c:match("%d") then
        local num = s:match("^(%d+)", i)
        return { t = "line", n = tonumber(num) }, i + #num
    end
    if c == "$" then return { t = "last" }, i + 1 end
    if c == "/" then
        local pattern, j = read_pattern(s, i, n)
        return { t = "re", re = regex.compile(pattern, "basic") }, j
    end
    return nil, i
end

-- The replacement text is compiled into a template: pieces of literal text,
-- the whole match ("&") and the back references.
local function read_replacement(s, i, n, delim)
    local parts = {}
    local buf = {}
    local function flush()
        if #buf > 0 then
            parts[#parts + 1] = { text = table.concat(buf) }
            buf = {}
        end
    end
    while i <= n do
        local c = s:sub(i, i)
        if c == delim then
            flush()
            return parts, i + 1
        elseif c == "\\" and i < n then
            local d = s:sub(i + 1, i + 1)
            if d:match("%d") then
                flush()
                parts[#parts + 1] = { group = tonumber(d) }
            else
                flush()
                parts[#parts + 1] = { text = (d == "n" and "\n") or
                                             (d == "t" and "\t") or d }
            end
            i = i + 2
        elseif c == "&" then
            flush()
            parts[#parts + 1] = { whole = true }
            i = i + 1
        else
            buf[#buf + 1] = c
            i = i + 1
        end
    end
    flush()
    return parts, i
end

local function compile_script(script)
    script = tostring(script or "")
    local n = #script
    local i = 1
    local cmds = {}
    while i <= n do
        local c = script:sub(i, i)
        if c == ";" or c == "\n" or c == " " or c == "\t" then
            i = i + 1
        else
            local addr
            addr, i = read_address(script, i, n)
            if addr then
                local j = skip_blanks(script, i, n)
                if script:sub(j, j) == "," then
                    j = skip_blanks(script, j + 1, n)
                    local second
                    second, j = read_address(script, j, n)
                    if not second then return nil, "bad address range" end
                    addr = { t = "range", a = addr, b = second }
                    i = j
                end
            end
            i = skip_blanks(script, i, n)
            c = script:sub(i, i)
            local cmd
            if c == "" then
                break
            elseif c == "s" then
                local delim = script:sub(i + 1, i + 1)
                if delim == "" or delim == " " then
                    return nil, "unterminated s command"
                end
                local pattern, after_pattern = read_pattern(script, i + 1, n,
                                                             delim)
                local repl, after_repl = read_replacement(script, after_pattern,
                                                          n, delim)
                local flags = { global = false, print = false, icase = false }
                local k = after_repl
                while k <= n do
                    local f = script:sub(k, k)
                    if f == "g" then
                        flags.global = true
                        k = k + 1
                    elseif f == "p" then
                        flags.print = true
                        k = k + 1
                    elseif f == "i" then
                        flags.icase = true
                        k = k + 1
                    else
                        break
                    end
                end
                cmd = { op = "s", repl = repl, flags = flags,
                        re = regex.compile(pattern, "basic") }
                i = k
            elseif c == "d" then
                cmd = { op = "d" }
                i = i + 1
            elseif c == "p" then
                cmd = { op = "p" }
                i = i + 1
            elseif c == "{" or c == "}" or c == "!" then
                i = i + 1
            else
                return nil, "unknown command: " .. c
            end
            if cmd then
                cmd.addr = addr
                cmds[#cmds + 1] = cmd
            end
        end
    end
    if #cmds == 0 then return nil, "no commands" end
    return { cmds = cmds }
end

local function render(parts, line, start, stop, caps)
    local out = {}
    for i = 1, #parts do
        local p = parts[i]
        if p.text then
            out[#out + 1] = p.text
        elseif p.whole then
            out[#out + 1] = line:sub(start, stop - 1)
        else
            out[#out + 1] = caps[p.group] or ""
        end
    end
    return table.concat(out)
end

local function substitute(cmd, line)
    local re = cmd.re
    local subject = line
    if cmd.flags.icase then subject = line:lower() end
    local out = {}
    local pos = 1
    local init = 1
    local count = 0
    local limit = #subject + 1
    while init <= limit do
        local start, stop, caps = re:find(subject, init)
        if not start then break end
        out[#out + 1] = line:sub(pos, start - 1)
        out[#out + 1] = render(cmd.repl, line, start, stop, caps)
        -- stop is the offset just past the match, which is exactly where the
        -- untouched remainder of the line starts again.
        pos = stop
        count = count + 1
        if not cmd.flags.global then break end
        -- An empty match must not stall the scan.
        if stop > start then init = stop else init = start + 1 end
    end
    if count == 0 then return line, 0 end
    out[#out + 1] = line:sub(pos)
    return table.concat(out), count
end

-- sed.run(program, lines, quiet) -> output lines
-- "lines" is the input split on "\n"; the result is the list of lines sed
-- would write, so the caller decides how they reach the console or a file.
function sed.run(program, lines, quiet)
    local out = {}
    local last = #lines
    local ranges = {}

    local function address_hit(index, addr, ln, line)
        local t = addr.t
        if t == "line" then return ln == addr.n end
        if t == "last" then return ln == last end
        if t == "re" then return addr.re:find(line, 1) ~= nil end

        local inside = ranges[index] ~= nil
        if not inside then
            local a = addr.a
            local start
            if a.t == "line" then
                start = (ln == a.n)
            elseif a.t == "last" then
                start = (ln == last)
            else
                start = a.re:find(line, 1) ~= nil
            end
            if not start then return false end
        end

        -- The closing address is looked for from the following line on, so a
        -- range like /a/,/a/ still covers one line.
        local b = addr.b
        local finish
        if b.t == "line" then
            finish = (ln >= b.n)
        elseif b.t == "last" then
            finish = (ln >= last)
        elseif inside then
            finish = b.re:find(line, 1) ~= nil
        else
            finish = false
        end
        if finish then
            ranges[index] = nil
        else
            ranges[index] = true
        end
        return true
    end

    for ln = 1, last do
        local work = lines[ln]
        local deleted = false
        for ci = 1, #program.cmds do
            local cmd = program.cmds[ci]
            local selected = true
            if cmd.addr then
                selected = address_hit(ci, cmd.addr, ln, work)
            end
            if selected then
                if cmd.op == "s" then
                    local replaced, count = substitute(cmd, work)
                    work = replaced
                    if cmd.flags.print and count > 0 then
                        out[#out + 1] = work
                    end
                elseif cmd.op == "d" then
                    deleted = true
                    break
                elseif cmd.op == "p" then
                    out[#out + 1] = work
                end
            end
        end
        if not deleted and not quiet then out[#out + 1] = work end
    end
    return out
end

sed.compile = compile_script
sed.run = sed.run

return sed
