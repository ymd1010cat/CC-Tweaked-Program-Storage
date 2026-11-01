-- t_legacy.lua - the archive copy pkg/py.lua (staged as /legacy-py.lua).
--
-- pkg/py.lua is byte-identical to the historic legacy-py.lua that
-- pylib/pylib/pythonlib.lua replaced (README, MANIFEST.md). It is kept for
-- reference only: it loads, but it cannot run anything, because its
-- Parser:parseBlock does not skip the NEWLINE before expecting INDENT. The
-- assertions below pin that down so the file's status stays documented instead
-- of being rediscovered.

local H = ...

H.group("legacy:load")
local savedArg = rawget(_G, "arg")
rawset(_G, "arg", nil)
local okLoad, legacy = pcall(dofile, "/legacy-py.lua")
rawset(_G, "arg", savedArg)
H.ok(okLoad, "pkg/py.lua loads as a Lua module", H.errText(legacy))
H.ok(type(legacy) == "table", "it returns a table", type(legacy))

H.group("legacy:superseded")
if type(legacy) == "table" and type(legacy.runString) == "function" then
    H.ok(true, "it exposes runString", "")
    local okRun, err = pcall(function()
        return legacy.runString('x = 1 + 1\nprint(x)')
    end)
    H.ok(not okRun, "it cannot run even a two-statement program",
        "ran without error")
    H.contains(H.errText(err), "Parse error at line 1: Expected NEWLINE, got NAME",
        "failure matches the documented legacy message")
    -- The shipped interpreter must not have that defect: the same source runs
    -- on /pythonlib.lua (asserted in t_core.lua, repeated here so the contrast
    -- is local to this file).
    local py = dofile("/pythonlib.lua")
    local okNew, errNew = pcall(function()
        local it = py.Interpreter.new()
        local builtins = it:getBuiltins()
        for k, v in pairs(builtins) do it.scopes[1][k] = v end
        local tokens = py.Lexer.new('x = 1 + 1\nprint(x)'):tokenize()
        it:run(py.Parser.new(tokens):parse())
        return it
    end)
    H.ok(okNew, "pythonlib.lua runs the same source", H.errText(errNew))
end
