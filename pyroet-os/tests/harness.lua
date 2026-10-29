--[[- pyroet-os/tests/harness.lua -- tiny assertion + fixture kit for the P2 tests.

No framework, no dependencies: the runner is CraftOS-PC in headless mode, so
everything here has to work inside the emulator with the real `fs`.

Markers (parsed by tests/run-tests.ps1, de-duplicated because the console redraws
partial lines):

    OFFLINE_GROUP <name>              one per group, printed as it starts
    OFFLINE_FAIL_AT <group>.<name> <detail>
    OFFLINE_PASS <n>
    OFFLINE_FAIL <n>
    OFFLINE_GROUPS <n>
    OFFLINE_DONE                      always last

`H.fs()` returns an instrumented proxy over the real file system: every call is
recorded and any method can be overridden, which is how the fault paths (a
refusing `fs.move`, a broken `fs.copy`, a failing write) are provoked without
writing a whole second file system. The proxy delegates to the real thing, so
the semantics under test are CraftOS semantics, not a mock's idea of them.

No non-ASCII bytes in this file.
]]

local H = {}

H.pass = 0
H.fail = 0
H.groups = 0
H.group_name = "(none)"
H.root = "/t"
H.failures = {}
H.report_path = nil
H.group_names = {}

local FS_METHODS = {
    "exists", "isDir", "isReadOnly", "open", "move", "copy", "delete",
    "makeDir", "getDir", "getName", "getSize", "list", "combine", "attributes",
}

local function str(value)
    if value == nil then return "nil" end
    return tostring(value)
end

local function clean(text, max)
    local s = str(text):gsub("[\r\n\t]+", " ")
    max = max or 90
    if #s > max then s = s:sub(1, max) end
    return s
end

function H.real_fs()
    return rawget(_G, "fs")
end

-- ---------------------------------------------------------------------------
-- assertions
-- ---------------------------------------------------------------------------

function H.group(name)
    H.group_name = tostring(name)
    H.groups = H.groups + 1
    H.group_names[#H.group_names + 1] = H.group_name
    print("OFFLINE_GROUP " .. H.group_name)
end

function H.check(name, condition, detail)
    if condition then
        H.pass = H.pass + 1
        return true
    end
    H.fail = H.fail + 1
    local where = H.group_name .. "." .. tostring(name)
    local text = clean(detail, 200)
    H.failures[#H.failures + 1] = { where = where, detail = text }
    -- no spaces inside the marker payload: the CraftOS console redraws partial
    -- lines, so a space-joined message can bleed into the next marker fragment
    print("OFFLINE_FAIL_AT " .. where .. "|" .. text:gsub(" ", "_"))
    return false
end

function H.eq(name, actual, expected)
    local a, e = str(actual), str(expected)
    return H.check(name, a == e, "got=" .. a .. " want=" .. e)
end

function H.match(name, text, pattern)
    local ok = type(text) == "string" and text:find(pattern) ~= nil
    return H.check(name, ok, "no match [" .. str(pattern) .. "] in " .. clean(text))
end

function H.contains(name, text, needle)
    local ok = type(text) == "string" and text:find(needle, 1, true) ~= nil
    return H.check(name, ok, "missing [" .. str(needle) .. "] in " .. clean(text))
end

function H.absent(name, text, needle)
    local ok = type(text) == "string" and text:find(needle, 1, true) == nil
    return H.check(name, ok, "unexpected [" .. str(needle) .. "] in " .. clean(text))
end

function H.ge(name, actual, want)
    local ok = type(actual) == "number" and actual >= want
    return H.check(name, ok, "got=" .. str(actual) .. " want>=" .. str(want))
end

function H.table(name, value)
    return H.check(name, type(value) == "table", "type=" .. type(value))
end

function H.truthy(name, value)
    return H.check(name, value and value ~= false, "got=" .. str(value))
end

-- every byte printable ASCII, tab/newline/cr allowed
function H.ascii(text)
    for i = 1, #text do
        local byte = text:byte(i)
        if not ((byte >= 32 and byte <= 126) or byte == 9 or byte == 10 or byte == 13) then
            return false, i
        end
    end
    return true
end

function H.ascii_check(name, text)
    local ok, at = H.ascii(text)
    return H.check(name, ok, "non-ASCII byte at " .. str(at))
end

-- ---------------------------------------------------------------------------
-- logs
-- ---------------------------------------------------------------------------

function H.logger()
    local lines = {}
    local function log(line)
        lines[#lines + 1] = tostring(line)
    end
    return log, lines
end

function H.count(lines, fragment)
    local n = 0
    for i = 1, #lines do
        if tostring(lines[i]):find(fragment, 1, true) then n = n + 1 end
    end
    return n
end

-- H.has ASSERTS. It is never a bare predicate: a `H.has(lines, "...")`
-- statement has to be able to fail, otherwise it is a comment that looks like a
-- test. The assertion name is derived from the fragment so call sites stay
-- readable (`H.has(lines, "BOOT_TRIAL slot=b tries=1 max=2")`).
function H.has(lines, fragment)
    local needle = tostring(fragment)
    local found = H.count(lines, needle) > 0
    local label = "has:" .. needle:gsub("[^%w%.%-_:=/%%]", "_"):sub(1, 56)
    return H.check(label, found,
        "missing [" .. needle .. "] in: " .. clean(H.joined(lines), 160))
end

-- non-asserting predicate, for call sites that build their own condition
function H.found(lines, fragment)
    return H.count(lines, tostring(fragment)) > 0
end

-- assert that a line is NOT there (the pair of H.has)
function H.lacks(name, lines, fragment)
    local needle = tostring(fragment)
    return H.check(name, not H.found(lines, needle),
        "unexpected [" .. needle .. "] in: " .. clean(H.joined(lines), 160))
end

function H.joined(lines)
    return table.concat(lines, "\n")
end

-- index of the first line containing `fragment`, or nil
function H.index_of(lines, fragment)
    for i = 1, #lines do
        if tostring(lines[i]):find(fragment, 1, true) then return i end
    end
    return nil
end

-- ---------------------------------------------------------------------------
-- instrumented file system
-- ---------------------------------------------------------------------------

-- Returns proxy, calls. `calls` is an array of { method = ..., n = ..., [1] = ... }.
-- opts.overrides[method] = function(...) -> replaces that method entirely.
function H.fs(opts)
    local o = opts or {}
    local real = o.real or H.real_fs()
    local overrides = o.overrides or {}
    local calls = {}
    local proxy = {}
    for i = 1, #FS_METHODS do
        local method = FS_METHODS[i]
        proxy[method] = function(...)
            calls[#calls + 1] = { method = method, n = select("#", ...), ... }
            local hook = overrides[method]
            if hook then return hook(...) end
            local fn = real[method]
            if not fn then return nil end
            return fn(...)
        end
    end
    return proxy, calls
end

function H.calls_to(calls, method)
    local n = 0
    for i = 1, #calls do
        if calls[i].method == method then n = n + 1 end
    end
    return n
end

-- first index of a call to `method` whose first argument equals `first`, or nil
function H.call_index(calls, method, first)
    for i = 1, #calls do
        local call = calls[i]
        if call.method == method and (first == nil or call[1] == first) then return i end
    end
    return nil
end

-- ---------------------------------------------------------------------------
-- fixtures (always the real file system)
-- ---------------------------------------------------------------------------

function H.exists(path)
    return H.real_fs().exists(path)
end

function H.is_dir(path)
    local fsx = H.real_fs()
    return fsx.exists(path) and fsx.isDir(path)
end

function H.mkdirp(path, fsx)
    fsx = fsx or H.real_fs()
    if path == nil or path == "" then return true end
    if fsx.exists(path) then return true end
    local parent = fsx.getDir(path)
    if parent ~= nil and parent ~= "" and parent ~= "/" then H.mkdirp(parent, fsx) end
    pcall(fsx.makeDir, path)
    return fsx.exists(path)
end

function H.write(path, text, fsx)
    fsx = fsx or H.real_fs()
    local parent = fsx.getDir(path)
    if parent and parent ~= "" then H.mkdirp(parent, fsx) end
    local handle = fsx.open(path, "w")
    if not handle then return nil, "cannot open " .. tostring(path) end
    handle.write(tostring(text))
    handle.close()
    return true
end

function H.read(path, fsx)
    fsx = fsx or H.real_fs()
    if not fsx.exists(path) then return nil end
    local handle = fsx.open(path, "r")
    if not handle then return nil end
    local text
    if handle.readAll then text = handle.readAll() else text = handle.read("*a") end
    handle.close()
    return text
end

function H.rmrf(path)
    local fsx = H.real_fs()
    if path and fsx.exists(path) then pcall(fsx.delete, path) end
    return not (path and fsx.exists(path))
end

function H.list(path)
    local fsx = H.real_fs()
    if not fsx.exists(path) then return {} end
    local names = fsx.list(path) or {}
    table.sort(names)
    return names
end

-- fresh empty sandbox directory for one case
function H.case_dir(file, name)
    local dir = H.root .. "/" .. file .. "/" .. name
    H.rmrf(dir)
    H.mkdirp(dir)
    return dir
end

-- a fake CRC-truncated marker payload so log/string assertions can use it
local HEX64 = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
H.HEX64 = HEX64

-- write an app package into `dir`; opts: manifest, main, lifecycle
function H.app_package(dir, opts)
    local o = opts or {}
    H.rmrf(dir)
    H.mkdirp(dir)
    H.write(dir .. "/manifest.lua", o.manifest
        or 'return { name = "probe", version = "0.1.0" }')
    if o.main ~= false then
        H.write(dir .. "/main.lua", o.main or "return function(manifest, api) end")
    end
    if o.lifecycle then H.write(dir .. "/lifecycle.lua", o.lifecycle) end
    return dir
end

-- ---------------------------------------------------------------------------
-- report
-- ---------------------------------------------------------------------------

-- The console is a redrawing terminal, so the authoritative record is written to
-- a file when a path is configured: one self-contained line per failure, which
-- run-tests.ps1 reads back instead of reconstructing markers out of fragments.
function H.write_report()
    if not H.report_path then return nil end
    local fsx = H.real_fs()
    local handle = fsx.open(H.report_path, "w")
    if not handle then return nil end
    handle.write("COUNTS pass=" .. tostring(H.pass) .. " fail=" .. tostring(H.fail)
        .. " groups=" .. tostring(H.groups) .. "\n")
    for i = 1, #H.group_names do
        handle.write("GROUP " .. H.group_names[i] .. "\n")
    end
    for i = 1, #H.failures do
        handle.write("FAIL " .. H.failures[i].where .. " " .. H.failures[i].detail .. "\n")
    end
    handle.close()
    return H.report_path
end

function H.finish()
    print("OFFLINE_ASSERTS " .. tostring(H.pass + H.fail)
        .. " pass=" .. tostring(H.pass) .. " fail=" .. tostring(H.fail))
    print("OFFLINE_GROUPS " .. tostring(H.groups))
    if H.write_report() then
        print("OFFLINE_REPORT " .. H.report_path)
    end
    if H.fail == 0 then
        print("OFFLINE_PASS " .. tostring(H.pass))
    else
        print("OFFLINE_FAIL " .. tostring(H.fail))
    end
    print("OFFLINE_DONE")
end

return H
