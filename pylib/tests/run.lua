-- run.lua - driver for the pylib offline suite.
--
-- Loads /pythonlib.lua (the exported interpreter), then runs every
-- /tests/t_*.lua module in sorted order, passing the harness as its only
-- argument. Adding a new t_*.lua needs no edit here.
--
-- The last thing the suite does is os.shutdown(): CraftOS-PC only flushes the
-- filesystem when the computer stops, and run-tests.ps1 waits for PYLIB_DONE
-- in /logs/suite.log.

local H = dofile("/tests/harness.lua")
H.openLog("/logs/suite.log")
H.emit("PYLIB_SUITE start")

-- pythonlib.lua ends with `if type(arg)=="table" and arg[1] then ... run a
-- file ... end`; make sure a stray shell arg cannot trigger that.
local savedArg = rawget(_G, "arg")
rawset(_G, "arg", nil)
local ok, py = pcall(dofile, "/pythonlib.lua")
rawset(_G, "arg", savedArg)

H.group("interpreter-load")
H.ok(ok, "pythonlib.lua runs", H.errText(py))
if not ok then
    H.summary()
    if H.log then H.log.close() end
    pcall(os.shutdown)
    return
end
H.ok(type(py) == "table", "pythonlib returns a table", type(py))
H.ok(type(py.runString) == "function", "py.runString exported", type(py.runString))
H.ok(type(py.Lexer) == "table", "py.Lexer exported", type(py.Lexer))
H.ok(type(py.Parser) == "table", "py.Parser exported", type(py.Parser))
H.ok(type(py.Interpreter) == "table", "py.Interpreter exported",
    type(py.Interpreter))
H.py = py

local names = {}
for _, f in ipairs(fs.list("/tests") or {}) do
    if f:match("^t_.*%.lua$") then names[#names + 1] = f end
end
table.sort(names)
H.note("test modules: " .. table.concat(names, ","))

for _, name in ipairs(names) do
    local path = "/tests/" .. name
    local chunk, loadErr = loadfile(path)
    if not chunk then
        H.group("load:" .. name)
        H.ok(false, "loadfile " .. name, tostring(loadErr))
    else
        local okRun, err = pcall(chunk, H)
        if not okRun then
            H.group("crash:" .. name)
            H.ok(false, "module " .. name .. " completed",
                H.errText(err))
        end
    end
end

H.summary()
if H.log then
    H.log.flush()
    H.log.close()
end
pcall(os.shutdown)
