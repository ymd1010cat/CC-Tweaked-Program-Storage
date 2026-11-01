-- t_modules.lua - import coverage for the 15 exported pylib/*.py modules.
--
-- Classification is two-stage and each stage is attributed to the module
-- itself:
--   parse_error   - the subset parser cannot parse the module's own source
--                   (message keeps the parser's own "line N")
--   runtime_error - the module parses, but running its module body fails
--   ok            - parses and runs; the module table is cached by the
--                   interpreter and exposes at least one name
--
-- COVERAGE.md mirrors this table; the expected values below are what the
-- export actually does today, so a change in either direction shows up as a
-- failing assertion instead of a silently stale document.

local H = ...

local EXPECTED = {
    argparse = "ok",              -- class ArgumentError(Exception) now works
    cc = "ok",                    -- needs the lua()/lua_call() builtins
    cc_utf8 = "ok",
    collections = "ok",
    copy = "ok",                  -- class Error(Exception) now works
    dataclasses = "ok",
    datetime = "ok",
    enum = "ok",
    functools = "ok",
    itertools = "ok",
    json = "ok",
    pathlib = "ok",               -- import os.path: builtin module now exists
    string = "ok",
    sys = "ok",
    typing = "ok",
}

local ORDER = {"argparse", "cc", "cc_utf8", "collections", "copy",
    "dataclasses", "datetime", "enum", "functools", "itertools", "json",
    "pathlib", "string", "sys", "typing"}

H.group("modules:staged")
local staged = {}
for _, f in ipairs(fs.list("/pylib") or {}) do
    if f:match("%.py$") then staged[#staged + 1] = f:gsub("%.py$", "") end
end
table.sort(staged)
H.eq(#staged, 15, "15 .py modules staged under /pylib")
H.eq(table.concat(staged, ","), table.concat(ORDER, ","),
    "staged module set matches the expected list")

-- Stage 1: parse each module's own source with a fresh lexer/parser.
local parsedOk = {}
local parseErrText = {}
H.group("modules:parse")
for _, name in ipairs(ORDER) do
    local f = fs.open("/pylib/" .. name .. ".py", "r")
    H.ok(f ~= nil, name .. ": readable", "/pylib/" .. name .. ".py")
    local src = f and f.readAll() or ""
    if f then f.close() end
    local ok, err = H.parse(src)
    parsedOk[name] = ok
    parseErrText[name] = H.errText(err)
    -- the parser message already carries "line N"; prefix the module name
    H.ok(ok, name .. ": parses",
        "module=" .. name .. " " .. parseErrText[name])
end

-- Stage 2: import (parse + module body execution + module table).
H.group("modules:import")
for _, name in ipairs(ORDER) do
    local status, detail
    if not parsedOk[name] then
        status = "parse_error"
        detail = "module=" .. name .. " " .. parseErrText[name]
    else
        local ok, err = pcall(function()
            local it = H.interp()
            return it:importModule(name)
        end)
        if ok then
            local mod = err
            local exposed = 0
            for k in pairs(mod.__scope or {}) do
                if type(k) == "string" then exposed = exposed + 1 end
            end
            if exposed > 0 then
                status, detail = "ok", "names=" .. exposed
            else
                status, detail = "runtime_error", "module table exposes no names"
            end
            H.ok(exposed > 0, name .. ": exposes names", "names=" .. exposed)
        else
            status = "runtime_error"
            -- runtime failures carry no source line (the interpreter does not
            -- track one); the module name is prefixed so the line is attributable.
            detail = "module=" .. name .. " " .. H.errText(err)
            if detail:match("Parse error at line") then
                -- A module-body import of another .py fails during parse of that
                -- file; keep the message, it names the line.
                status = "runtime_error"
            end
        end
    end
    H.emit("MODULE " .. name .. " status=" .. status .. " detail=" .. detail)
    H.eq(status, EXPECTED[name], name .. ": status matches COVERAGE.md")
end

-- Import must not change behaviour of an already working module: the
-- interpreter caches module tables, so a second import returns the same table.
H.group("modules:cache")
local ok1, mod1 = pcall(function()
    local it = H.interp()
    return it:importModule("json")
end)
local ok2, mod2 = pcall(function()
    local it = H.interp()
    return it:importModule("json")
end)
H.ok(ok1 and ok2, "json imports twice", H.errText(mod1))
if ok1 and ok2 then
    H.ok(mod1 == mod2, "the module table is cached across interpreters",
        tostring(mod1) .. " vs " .. tostring(mod2))
end

-- Functional smoke tests: "ok" must mean usable, not merely importable.
H.group("modules:functional")
H.expect('import string\nprint(string.capwords("hello world"))',
    "Hello World", "string.capwords works")
H.expect('import string\nprint(string.ascii_lowercase[:3])', "abc",
    "module constant + slice")
H.expect('import sys\nprint(sys.version)', "3.11.0 (pythonlib)",
    "sys.version is readable")
H.expect('import math\nprint(math.floor(2.9))', "2", "builtin math module")
H.expect('import json\ncode = json.dumps({"a": 1})\n' ..
    'print(json.loads(code)["a"])', "1", "json round trip")
H.expectError('import nosuchmod', "No module named", "unknown module import")

-- The three modules that used to stop at import time are exercised for real
-- below: import success alone would not prove the exception-class model or the
-- os.path surface actually work.
H.expect('import argparse\np = argparse.ArgumentParser(description="demo")\n' ..
    'p.add_argument("--count", help="how many")\nprint(p.format_help())',
    "demo\n  --count  how many", "argparse: parser + add_argument + help")
H.expect('import argparse\nprint(isinstance(argparse.ArgumentError("x"), ' ..
    'Exception))', "True", "argparse: ArgumentError is an Exception subclass")
H.expect('import argparse\np = argparse.ArgumentParser()\n' ..
    'p.add_argument("--verbose", action="store_true")\n' ..
    'ns = p.parse_args(["--verbose"])\nprint(ns.verbose)', "True",
    "argparse: parse_args with action=store_true populates the namespace")
H.expect('import copy\nl = [1, 2]\nm = copy.copy(l)\nm.append(3)\n' ..
    'print(l)\nprint(m)', "[1, 2]\n[1, 2, 3]", "copy: shallow copy is a new list")
H.expect('import copy\nd = {"a": [1]}\ne = copy.deepcopy(d)\n' ..
    'e["a"].append(2)\nprint(d["a"])\nprint(e["a"])', "[1]\n[1, 2]",
    "copy: deepcopy copies nested lists")
H.expect('import copy\nprint(isinstance(copy.error("x"), Exception))',
    "True", "copy: error alias is an Exception subclass")
H.expect('import pathlib\np = pathlib.PurePath("/a/b/c.txt")\n' ..
    'print(p.name)\nprint(p.stem)\nprint(p.suffix)\nprint(p.parent)',
    "c.txt\nc\n.txt\n/a/b", "pathlib: properties via os.path")
H.expect('import pathlib\nprint(pathlib.PurePath("/a", "b.py"))',
    "/a/b.py", "pathlib: multi-part join via _osp.join(*list)")
H.expect('import pathlib\n' ..
    'print(pathlib.Path("/pylib/pathlib.py").exists())\n' ..
    'print(pathlib.Path("/pylib/pathlib.py").is_file())\n' ..
    'print(pathlib.Path("/nope-xyz").exists())', "True\nTrue\nFalse",
    "pathlib: Path queries the real filesystem")
