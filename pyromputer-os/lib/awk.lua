-- awk.lua - the awk subset used by the shell.
--
-- Supported: the fields $0..$N, the variables NF and NR, print and printf,
-- -F for the field separator, a pattern before a block, BEGIN and END blocks,
-- assignments to variables and to fields (with $0 rebuilt from the parts), the
-- operators + - * / % , ! && || < <= > >= == != ~ !~ and string concatenation.
-- The pattern syntax of ~ and of a regular expression field separator is the
-- extended one (ERE).

local regex = require("regex")

local awk = {}

-- Sentinels raised while walking a rule list; the runner catches them.
local EXIT = {}
local NEXT = {}

-- ------------------------------------------------------------------ scanner
local TWO_CHAR_OPS = {
    ["=="] = true, ["!="] = true, ["<="] = true, [">="] = true,
    ["&&"] = true, ["||"] = true, ["!~"] = true, ["+="] = true,
    ["-="] = true, ["*="] = true, ["/="] = true, ["%="] = true,
}

local function tokenize(src)
    local toks = {}
    local i, n = 1, #src
    local function add(t, v) toks[#toks + 1] = { t = t, v = v } end
    while i <= n do
        local c = src:sub(i, i)
        local two = src:sub(i, i + 1)
        if c == "\n" then
            add("sep", "\n")
            i = i + 1
        elseif c == " " or c == "\t" or c == "\r" then
            i = i + 1
        elseif two == "\\\n" then
            i = i + 2
        elseif c == "#" then
            while i <= n and src:sub(i, i) ~= "\n" do i = i + 1 end
        elseif TWO_CHAR_OPS[two] then
            add("op", two)
            i = i + 2
        elseif c == '"' then
            local buf = {}
            local j = i + 1
            while j <= n do
                local d = src:sub(j, j)
                if d == "\\" and j < n then
                    local e = src:sub(j + 1, j + 1)
                    buf[#buf + 1] = (e == "n" and "\n") or (e == "t" and "\t")
                                     or (e == "r" and "\r") or e
                    j = j + 2
                elseif d == '"' then
                    j = j + 1
                    break
                else
                    buf[#buf + 1] = d
                    j = j + 1
                end
            end
            add("str", table.concat(buf))
            i = j
        elseif c:match("%d") or
               (c == "." and src:sub(i + 1, i + 1):match("%d")) then
            local num = src:match("^%d+%.?%d*", i) or src:match("^%.%d+", i)
            local exp = src:match("^[eE][%+%-]?%d+", i + #num)
            if exp then num = num .. exp end
            add("num", tonumber(num))
            i = i + #num + (exp and #exp or 0)
        elseif c:match("[%a_]") then
            local id = src:match("^[%w_]+", i)
            add("id", id)
            i = i + #id
        else
            add("op", c)
            i = i + 1
        end
    end
    add("eof", "")
    return toks
end

-- ------------------------------------------------------------------- parser
local Parser = {}
Parser.__index = Parser

local function fail(msg) error(msg, 0) end

local function describe(tok)
    if tok.t == "eof" then return "end of program" end
    if tok.t == "sep" then return "a newline" end
    if tok.t == "str" then return "a string" end
    return "\"" .. tostring(tok.v) .. "\""
end

function Parser:peek(k)
    local idx = self.pos + (k or 0)
    return self.toks[idx] or { t = "eof", v = "" }
end

function Parser:at_op(v, k)
    local tok = self:peek(k)
    return tok.t == "op" and tok.v == v
end

function Parser:accept_op(v)
    if self:at_op(v) then
        self.pos = self.pos + 1
        return true
    end
    return false
end

function Parser:skip_seps()
    while true do
        local tok = self:peek()
        if tok.t == "sep" then
            self.pos = self.pos + 1
        elseif tok.t == "op" and tok.v == ";" then
            self.pos = self.pos + 1
        else
            break
        end
    end
end

function Parser:skip_newlines()
    while self:peek().t == "sep" do self.pos = self.pos + 1 end
end

function Parser:at_stmt_end()
    local tok = self:peek()
    if tok.t == "sep" or tok.t == "eof" then return true end
    if tok.t == "op" and (tok.v == ";" or tok.v == "}") then return true end
    return false
end

function Parser:primary()
    local tok = self:peek()
    if tok.t == "num" then
        self.pos = self.pos + 1
        return { k = "num", v = tok.v }
    end
    if tok.t == "str" then
        self.pos = self.pos + 1
        return { k = "str", v = tok.v }
    end
    if tok.t == "id" then
        self.pos = self.pos + 1
        return { k = "var", name = tok.v }
    end
    if self:accept_op("$") then
        if self:accept_op("(") then
            local e = self:expr()
            if not self:accept_op(")") then fail("missing )") end
            return { k = "field", expr = e }
        end
        return { k = "field", expr = self:primary() }
    end
    if self:accept_op("(") then
        local e = self:expr()
        if not self:accept_op(")") then fail("missing )") end
        return e
    end
    fail("unexpected " .. describe(tok))
end

function Parser:unary()
    if self:accept_op("-") then
        return { k = "un", op = "-", e = self:unary() }
    end
    if self:accept_op("!") then
        return { k = "un", op = "!", e = self:unary() }
    end
    if self:accept_op("+") then
        return self:unary()
    end
    return self:primary()
end

function Parser:mul()
    local left = self:unary()
    while self:at_op("*") or self:at_op("/") or self:at_op("%") do
        local op = self:peek().v
        self.pos = self.pos + 1
        left = { k = "bin", op = op, a = left, b = self:unary() }
    end
    return left
end

function Parser:add()
    local left = self:mul()
    while self:at_op("+") or self:at_op("-") do
        local op = self:peek().v
        self.pos = self.pos + 1
        left = { k = "bin", op = op, a = left, b = self:mul() }
    end
    return left
end

local function starts_term(tok)
    if tok.t == "num" or tok.t == "str" or tok.t == "id" then return true end
    if tok.t == "op" then
        return tok.v == "$" or tok.v == "(" or tok.v == "-" or tok.v == "!"
    end
    return false
end

-- Juxtaposition is concatenation, as in "print \"a\" $1".
function Parser:concat()
    local left = self:add()
    while starts_term(self:peek()) do
        left = { k = "bin", op = ".", a = left, b = self:add() }
    end
    return left
end

local COMPARE_OPS = { ["<"] = true, ["<="] = true, [">"] = true,
                      [">="] = true, ["=="] = true, ["!="] = true,
                      ["~"] = true, ["!~"] = true }

function Parser:compare()
    local left = self:concat()
    local tok = self:peek()
    if tok.t == "op" and COMPARE_OPS[tok.v] then
        self.pos = self.pos + 1
        return { k = "bin", op = tok.v, a = left, b = self:concat() }
    end
    return left
end

function Parser:and_expr()
    local left = self:compare()
    while self:accept_op("&&") do
        left = { k = "bin", op = "&&", a = left, b = self:compare() }
    end
    return left
end

function Parser:or_expr()
    local left = self:and_expr()
    while self:accept_op("||") do
        left = { k = "bin", op = "||", a = left, b = self:and_expr() }
    end
    return left
end

function Parser:expr() return self:or_expr() end

function Parser:expr_list()
    local list = { self:expr() }
    while self:accept_op(",") do
        self:skip_newlines()
        list[#list + 1] = self:expr()
    end
    return list
end

function Parser:stmt()
    local tok = self:peek()
    if tok.t == "id" and tok.v == "print" then
        self.pos = self.pos + 1
        if self:at_stmt_end() or self:at_op("}") then
            return { k = "print", args = {} }
        end
        return { k = "print", args = self:expr_list() }
    end
    if tok.t == "id" and tok.v == "printf" then
        self.pos = self.pos + 1
        return { k = "printf", args = self:expr_list() }
    end
    if tok.t == "id" and tok.v == "exit" then
        self.pos = self.pos + 1
        return { k = "exit" }
    end
    if tok.t == "id" and tok.v == "next" then
        self.pos = self.pos + 1
        return { k = "next" }
    end
    if tok.t == "id" and self:at_op("=", 1) and not COMPARE_OPS[self:peek(1).v] then
        self.pos = self.pos + 2
        return { k = "assign", name = tok.v, expr = self:expr() }
    end
    if tok.t == "op" and tok.v == "$" then
        local index = self:peek(1)
        if index.t == "num" and self:at_op("=", 2) then
            self.pos = self.pos + 3
            return { k = "fassign", index = index.v, expr = self:expr() }
        end
    end
    return { k = "expr", expr = self:expr() }
end

function Parser:block()
    if not self:accept_op("{") then
        return { self:stmt() }
    end
    local stmts = {}
    while true do
        self:skip_seps()
        if self:accept_op("}") then break end
        if self:peek().t == "eof" then fail("missing }") end
        stmts[#stmts + 1] = self:stmt()
        if not self:at_stmt_end() then
            fail("unexpected " .. describe(self:peek()) ..
                 " after the statement")
        end
    end
    return stmts
end

local function compile_program(src)
    local p = setmetatable({ toks = tokenize(src), pos = 1 }, Parser)
    local program = { begin_blocks = {}, rules = {}, end_blocks = {} }
    while true do
        p:skip_seps()
        local tok = p:peek()
        if tok.t == "eof" then break end
        if tok.t == "op" and tok.v == "{" then
            program.rules[#program.rules + 1] = { action = p:block() }
        elseif tok.t == "id" and (tok.v == "BEGIN" or tok.v == "END") then
            p.pos = p.pos + 1
            p:skip_newlines()
            local block = p:block()
            if tok.v == "BEGIN" then
                program.begin_blocks[#program.begin_blocks + 1] = block
            else
                program.end_blocks[#program.end_blocks + 1] = block
            end
        else
            local pattern = p:expr()
            local save = p.pos
            p:skip_seps()
            if p:at_op("{") then
                program.rules[#program.rules + 1] = { pattern = pattern,
                                                      action = p:block() }
            else
                p.pos = save
                program.rules[#program.rules + 1] = { pattern = pattern }
            end
        end
    end
    if #program.rules == 0 and #program.begin_blocks == 0 and
       #program.end_blocks == 0 then
        fail("empty program")
    end
    return program
end

-- ------------------------------------------------------------------ runtime
local function to_num(v)
    if type(v) == "number" then return v end
    if type(v) == "string" then return tonumber(v) end
    return nil
end

local function to_str(v)
    if type(v) == "number" then
        if v == math.floor(v) and math.abs(v) < 1e15 then
            return string.format("%d", v)
        end
        return (string.format("%.6g", v))
    end
    if v == nil then return "" end
    return tostring(v)
end

local function truthy(v)
    if type(v) == "number" then return v ~= 0 end
    if type(v) == "string" then return v ~= "" and v ~= "0" end
    return false
end

local function compare(a, b)
    local na, nb = to_num(a), to_num(b)
    if na and nb then
        if na < nb then return -1 end
        if na > nb then return 1 end
        return 0
    end
    local sa, sb = to_str(a), to_str(b)
    if sa < sb then return -1 end
    if sa > sb then return 1 end
    return 0
end

-- Compiled regular expressions are shared between the records of a run, so a
-- constant pattern or field separator is only parsed once.
local regex_cache = {}

-- Splits a record the way awk does: " " is the special "runs of blanks" mode,
-- a one character separator is literal and anything longer is a regular
-- expression.
local function split_fields(record, fs)
    local fields = {}
    if fs == " " then
        for word in record:gmatch("%S+") do fields[#fields + 1] = word end
        return fields
    end
    if fs == "" then
        for i = 1, #record do fields[i] = record:sub(i, i) end
        return fields
    end
    if #fs == 1 then
        local pos = 1
        while true do
            local stop = record:find(fs, pos, true)
            if not stop then
                fields[#fields + 1] = record:sub(pos)
                break
            end
            fields[#fields + 1] = record:sub(pos, stop - 1)
            pos = stop + 1
        end
        return fields
    end
    local cached = rawget(regex_cache, fs)
    if not cached then
        cached = regex.compile(fs, "extended")
        rawset(regex_cache, fs, cached)
    end
    local pos, init = 1, 1
    while init <= #record + 1 do
        local start, stop = cached:find(record, init)
        if not start then break end
        if stop == start then
            init = start + 1
        else
            fields[#fields + 1] = record:sub(pos, start - 1)
            pos = stop
            init = stop
        end
    end
    fields[#fields + 1] = record:sub(pos)
    return fields
end

local function rebuild_record(ctx)
    ctx.record = table.concat(ctx.fields, to_str(ctx.vars.OFS))
end

local function eval(node, ctx)
    local k = node.k
    if k == "num" or k == "str" then return node.v end
    if k == "var" then
        local name = node.name
        if name == "NR" then return ctx.nr end
        if name == "NF" then return #ctx.fields end
        local v = ctx.vars[name]
        if v == nil then return "" end
        return v
    end
    if k == "field" then
        local index = to_num(eval(node.expr, ctx)) or 0
        if index <= 0 then return ctx.record end
        return ctx.fields[index] or ""
    end
    if k == "un" then
        local v = eval(node.e, ctx)
        if node.op == "!" then
            if truthy(v) then return 0 end
            return 1
        end
        return -(to_num(v) or 0)
    end
    if k == "bin" then
        local op = node.op
        if op == "&&" then
            if not truthy(eval(node.a, ctx)) then return 0 end
            if truthy(eval(node.b, ctx)) then return 1 end
            return 0
        end
        if op == "||" then
            if truthy(eval(node.a, ctx)) then return 1 end
            if truthy(eval(node.b, ctx)) then return 1 end
            return 0
        end
        local a = eval(node.a, ctx)
        local b = eval(node.b, ctx)
        if op == "." then return to_str(a) .. to_str(b) end
        if op == "~" or op == "!~" then
            local pattern = to_str(b)
            local matcher = rawget(regex_cache, pattern)
            if not matcher then
                matcher = regex.compile(pattern, "extended")
                rawset(regex_cache, pattern, matcher)
            end
            local hit = matcher:find(to_str(a), 1) ~= nil
            if op == "!~" then
                if hit then return 0 end
                return 1
            end
            if hit then return 1 end
            return 0
        end
        if op == "==" or op == "!=" or op == "<" or op == "<=" or op == ">" or
           op == ">=" then
            local c = compare(a, b)
            local ok
            if op == "==" then ok = (c == 0)
            elseif op == "!=" then ok = (c ~= 0)
            elseif op == "<" then ok = (c < 0)
            elseif op == "<=" then ok = (c <= 0)
            elseif op == ">" then ok = (c > 0)
            else ok = (c >= 0) end
            if ok then return 1 end
            return 0
        end
        local na, nb = to_num(a) or 0, to_num(b) or 0
        if op == "+" then return na + nb end
        if op == "-" then return na - nb end
        if op == "*" then return na * nb end
        if op == "/" then
            if nb == 0 then error("division by zero", 0) end
            return na / nb
        end
        if op == "%" then
            if nb == 0 then error("division by zero", 0) end
            return na % nb
        end
        return 0
    end
    return ""
end

local function format_printf(fmt, values)
    local out = {}
    local index = 1
    local i, n = 1, #fmt
    while i <= n do
        local c = fmt:sub(i, i)
        if c ~= "%" then
            out[#out + 1] = c
            i = i + 1
        else
            local spec = fmt:match("^%%[%-%+ #0]*%d*%.?%d*[diouxXeEfgGsc%%]", i)
            if not spec then
                out[#out + 1] = c
                i = i + 1
            else
                local conv = spec:sub(-1)
                local value = values[index]
                if conv == "%" then
                    out[#out + 1] = "%"
                elseif conv == "s" then
                    out[#out + 1] = string.format(spec, to_str(value))
                    index = index + 1
                elseif conv == "c" then
                    if type(value) == "number" then
                        out[#out + 1] = string.char(value % 256)
                    else
                        out[#out + 1] = to_str(value):sub(1, 1)
                    end
                    index = index + 1
                elseif conv == "d" or conv == "i" then
                    local pattern = spec:gsub("i$", "d")
                    out[#out + 1] = string.format(pattern,
                                                  math.floor(to_num(value) or 0))
                    index = index + 1
                elseif conv == "u" then
                    local pattern = spec:gsub("u$", "d")
                    out[#out + 1] = string.format(pattern,
                                                  math.floor(to_num(value) or 0))
                    index = index + 1
                elseif conv == "x" or conv == "X" or conv == "o" then
                    out[#out + 1] = string.format(spec,
                                                  math.floor(to_num(value) or 0))
                    index = index + 1
                else
                    out[#out + 1] = string.format(spec, to_num(value) or 0)
                    index = index + 1
                end
                i = i + #spec
            end
        end
    end
    return table.concat(out)
end

-- Output is collected as one byte stream: "print" appends ORS while "printf"
-- adds nothing, so a printf without a newline keeps the cursor on the same
-- line and the next statement continues there. Complete lines are moved into
-- "out" as they are closed, the trailing partial line is flushed at the end.
local function emit_text(out, text)
    local pending = (out.buf or "") .. text
    local pos = 1
    while true do
        local stop = pending:find("\n", pos, true)
        if not stop then break end
        out[#out + 1] = pending:sub(pos, stop - 1)
        pos = stop + 1
    end
    out.buf = pending:sub(pos)
end

local function flush_text(out)
    if out.buf and out.buf ~= "" then
        out[#out + 1] = out.buf
    end
    out.buf = nil
end

local exec_stmt, exec_block

exec_stmt = function(stmt, ctx, out)
    local k = stmt.k
    if k == "print" then
        local args = stmt.args
        local ors = to_str(ctx.vars.ORS)
        if #args == 0 then
            emit_text(out, ctx.record .. ors)
            return
        end
        local parts = {}
        for i = 1, #args do parts[#parts + 1] = to_str(eval(args[i], ctx)) end
        emit_text(out, table.concat(parts, to_str(ctx.vars.OFS)) .. ors)
    elseif k == "printf" then
        local args = stmt.args
        if #args == 0 then return end
        local fmt = to_str(eval(args[1], ctx))
        local values = {}
        for i = 2, #args do values[#values + 1] = eval(args[i], ctx) end
        emit_text(out, format_printf(fmt, values))
    elseif k == "assign" then
        ctx.vars[stmt.name] = eval(stmt.expr, ctx)
    elseif k == "fassign" then
        ctx.fields[stmt.index] = to_str(eval(stmt.expr, ctx))
        rebuild_record(ctx)
    elseif k == "exit" then
        error(EXIT, 0)
    elseif k == "next" then
        error(NEXT, 0)
    elseif k == "expr" then
        eval(stmt.expr, ctx)
    end
end

exec_block = function(block, ctx, out)
    for i = 1, #block do exec_stmt(block[i], ctx, out) end
end

-- compile(source) -> program | nil, message
function awk.compile(source)
    local ok, result = pcall(compile_program, source)
    if not ok then
        return nil, tostring(result)
    end
    return result
end

-- run(program, text, options) -> lines, error message
-- options.fs is the initial FS, options.vars holds the -v assignments.
function awk.run(program, text, options)
    options = options or {}
    local ctx = {
        vars = {},
        fields = {},
        record = "",
        nr = 0,
    }
    ctx.vars.FS = options.fs or " "
    ctx.vars.OFS = " "
    ctx.vars.ORS = "\n"
    ctx.vars.OFMT = "%.6g"
    if options.vars then
        for name, value in pairs(options.vars) do
            ctx.vars[name] = value
        end
    end

    local out = {}
    local stopped = false

    local function run_block(block)
        local ok, err = pcall(exec_block, block, ctx, out)
        if ok then return true end
        if err == EXIT then
            stopped = true
            return false
        end
        if err == NEXT then return false end
        error(err, 0)
    end

    for i = 1, #program.begin_blocks do
        run_block(program.begin_blocks[i])
    end

    if not stopped and text and text ~= "" then
        local pos = 1
        local n = #text
        while pos <= n do
            local stop = text:find("\n", pos, true)
            local line
            if stop then
                line = text:sub(pos, stop - 1)
                pos = stop + 1
            else
                line = text:sub(pos)
                pos = n + 1
            end
            ctx.nr = ctx.nr + 1
            ctx.record = line
            ctx.fields = split_fields(line, to_str(ctx.vars.FS))
            for i = 1, #program.rules do
                local rule = program.rules[i]
                local selected = true
                if rule.pattern then
                    selected = truthy(eval(rule.pattern, ctx))
                end
                if selected then
                    if rule.action then
                        if not run_block(rule.action) then break end
                    else
                        emit_text(out, ctx.record .. to_str(ctx.vars.ORS))
                    end
                end
            end
            if stopped then break end
        end
    end

    for i = 1, #program.end_blocks do
        run_block(program.end_blocks[i])
    end

    -- A trailing printf without a newline still counts as one output line.
    flush_text(out)
    return out
end

return awk
