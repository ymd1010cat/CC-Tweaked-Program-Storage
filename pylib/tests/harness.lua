-- harness.lua - assertion helper for the pylib offline suite.
--
-- Pure ASCII. Nothing here talks to the outside world except /logs/suite.log:
-- CraftOS-PC buffers redirected stdout, so every result line is appended to
-- that file as well (run-tests.ps1 reads it to decide PASS/FAIL).
--
-- Counter and naming conventions match the itn-pass suite (PYLIB_PASS /
-- PYLIB_FAIL / TEST_FAIL) so the two runners stay comparable.

local H = {}
H.pass = 0
H.fail = 0
H.groups = 0
H.current = "?"
H.log = nil
H.py = nil

local function emit(line)
    if H.log then
        H.log.write(line .. "\n")
        H.log.flush()
    end
    -- term.write instead of print: the suite swaps _G.print to capture the
    -- interpreter's output, and BIOS print() goes through global write().
    term.write(line .. "\n")
end
H.emit = emit

-- Informational line (kept in the log, not counted as an assertion).
function H.note(line)
    emit("NOTE " .. tostring(line))
end

function H.openLog(path)
    if not fs.exists("/logs") then fs.makeDir("/logs") end
    H.log = fs.open(path, "w")
    if not H.log then error("cannot open log: " .. path) end
end

function H.group(name)
    H.current = name
    H.groups = H.groups + 1
    emit("GROUP " .. name)
end

function H.ok(cond, name, detail)
    if cond then
        H.pass = H.pass + 1
    else
        H.fail = H.fail + 1
        -- one failure must stay on one line: the runner greps whole lines
        local text = tostring(detail or ""):gsub("[\r\n]+", " | ")
        emit("TEST_FAIL " .. H.current .. " :: " .. name ..
             " :: " .. text)
    end
    return cond
end

function H.eq(got, want, name)
    local same = (got == want)
    return H.ok(same, name, "want=" .. tostring(want) ..
        " got=" .. tostring(got))
end

function H.contains(hay, needle, name)
    local found = type(hay) == "string" and hay:find(needle, 1, true) ~= nil
    return H.ok(found, name, "missing <" .. tostring(needle) .. "> in <" ..
        tostring(hay) .. ">")
end

function H.lacks(hay, needle, name)
    local found = type(hay) == "string" and hay:find(needle, 1, true) ~= nil
    return H.ok(not found, name, "unexpected <" .. tostring(needle) ..
        "> in <" .. tostring(hay) .. ">")
end

-- Build a fresh interpreter with the builtin names preinstalled in scope 1,
-- mirroring what Interpreter:run() does.
function H.interp()
    if not H.py then error("harness: pythonlib not installed") end
    local it = H.py.Interpreter.new()
    local builtins = it:getBuiltins()
    for k, v in pairs(builtins) do it.scopes[1][k] = v end
    return it
end

-- Run `src` and capture print() output. Returns ok, result, output where
-- result is the interpreter (on success) or the error value (on failure).
function H.run(src)
    local printed = {}
    local savedPrint = _G.print
    _G.print = function(...)
        local count = select("#", ...)
        local parts = {}
        for i = 1, count do parts[i] = tostring((select(i, ...))) end
        printed[#printed + 1] = table.concat(parts, " ")
    end
    local ok, result = pcall(function()
        local it = H.interp()
        local tokens = H.py.Lexer.new(src):tokenize()
        local ast = H.py.Parser.new(tokens):parse()
        it:run(ast)
        return it
    end)
    _G.print = savedPrint
    return ok, result, table.concat(printed, "\n")
end

-- Output-only convenience wrapper.
function H.out(src)
    local ok, result, out = H.run(src)
    if ok then return out, nil end
    return out, result
end

-- Parse only (no evaluation). Returns ok, ast-or-error.
function H.parse(src)
    local ok, result = pcall(function()
        local tokens = H.py.Lexer.new(src):tokenize()
        return H.py.Parser.new(tokens):parse()
    end)
    return ok, result
end

-- Turn any thrown value (python exception table or Lua error) into text.
function H.errText(e)
    if type(e) == "table" and e.__pyexception then
        if e.value == nil or e.value == "" then return tostring(e.type) end
        return tostring(e.type) .. ": " .. tostring(e.value)
    end
    return tostring(e)
end

-- Run `src` and assert its captured print() output equals `want`.
function H.expect(src, want, name)
    local ok, result, printed = H.run(src)
    if not ok then
        H.ok(false, name, "raised " .. H.errText(result))
        return false
    end
    return H.eq(printed, want, name)
end

-- Run `src` and assert it fails with a message containing `needle`.
function H.expectError(src, needle, name)
    local ok, result = H.run(src)
    if ok then
        H.ok(false, name, "expected failure containing <" .. needle .. ">")
        return false
    end
    return H.contains(H.errText(result), needle, name)
end

function H.summary()
    emit("PYLIB_PASS " .. H.pass)
    emit("PYLIB_FAIL " .. H.fail)
    emit("PYLIB_GROUPS " .. H.groups)
    emit("PYLIB_DONE")
end

return H
