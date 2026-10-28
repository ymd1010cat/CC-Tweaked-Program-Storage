-- cc_env_stub.lua - a minimal CraftOS environment used by the offline logic
-- checks of the psh project (class 3: system and service abilities).
--
-- This is NOT a CraftOS emulator. It provides the API surface the project
-- really touches (fs / os / term / shell / peripheral / rednet / multishell /
-- textutils / keys / colors) with a memory filesystem and a fake event loop,
-- so that the Lua code paths can be exercised on the PC. Anything verified
-- here is a PC side logic assertion, not a CraftOS-PC result.

local realprint = print
local unpack = _G.unpack or table.unpack

-- Compile a string like the ROM does. CraftOS (and LuaJIT, which the runner
-- uses first) spells it loadstring; a Lua 5.2+ host spells it load. The stub has
-- to work under both, otherwise textutils.unserialize and the stub's own
-- loadfile quietly return nil on the newer hosts.
local compile = loadstring or load

_G.__OUT = {}
local function push(text)
    _G.__OUT[#_G.__OUT + 1] = tostring(text)
end

-- The fake console tracks its cursor the way the one the project runs on does,
-- because that is what tells the checks apart: a "\n" written through write()
-- starts a new line at the first column, while the same byte handed to
-- term.write() is stored and leaves the cursor where it was, a control byte
-- moves nothing, and print() writes its text and the break after it. The __OUT
-- table keeps every call, so the older checks that read what was written stay
-- valid.
local CURSOR = { 1, 1 }
local SCREEN_W = 51

local function advance(text)
    for i = 1, #text do
        local b = text:byte(i)
        if b == 10 or b == 13 then
            CURSOR[1], CURSOR[2] = 1, CURSOR[2] + 1
        elseif b >= 32 and b ~= 127 then
            CURSOR[1] = CURSOR[1] + 1
            if CURSOR[1] > SCREEN_W then CURSOR[1], CURSOR[2] = 1, CURSOR[2] + 1 end
        end
    end
end

local function raw_out(text)
    push(text)
end

local function console_out(text)
    text = tostring(text)
    push(text)
    advance(text)
end

_G.print = function(...)
    local parts = {}
    for i = 1, select("#", ...) do
        parts[#parts + 1] = tostring((select(i, ...)))
    end
    local text = table.concat(parts, "\t")
    push(text)
    advance(text .. "\n")
end

-- ------------------------------------------------------------------ helpers
local function norm(p)
    p = tostring(p or ""):gsub("\\", "/")
    p = p:gsub("/+", "/")
    if #p > 1 then p = p:gsub("/$", "") end
    if p == "" then p = "/" end
    return p
end

local function parent_of(p)
    p = norm(p)
    if p == "/" then return nil end
    local q = p:match("^(.*)/[^/]+$")
    if not q or q == "" then return "/" end
    return q
end

local function base_of(p)
    p = norm(p)
    if p == "/" then return "" end
    return p:match("([^/]+)$") or ""
end

-- --------------------------------------------------------- filesystem (memory)
local FS = { ["/"] = { dir = true } }
_G.__FS = FS

local function fs_error(msg)
    _G.__FS_ERR = msg
    if _G.__FS_STRICT then error(msg, 2) end
    return false
end

local fs = {}

function fs.exists(p)
    p = norm(p)
    return FS[p] ~= nil
end

function fs.isDir(p)
    p = norm(p)
    return FS[p] ~= nil and FS[p].dir == true
end

function fs.isReadOnly(p)
    p = norm(p)
    return p == "/rom" or p:sub(1, 5) == "/rom/"
end

function fs.list(p)
    p = norm(p)
    local entry = FS[p]
    if not entry or not entry.dir then return nil end
    local out = {}
    for path in pairs(FS) do
        if path ~= "/" and parent_of(path) == p then
            out[#out + 1] = base_of(path)
        end
    end
    table.sort(out)
    return out
end

function fs.makeDir(p)
    p = norm(p)
    -- NO RETURN VALUE, exactly like the ROM. Measured on CraftOS-PC: makeDir on a
    -- brand new directory returns nil (type nil), and makeDir on one that already
    -- exists also returns nil. This stub used to return true, and that difference
    -- hid a real bug -- the mktemp built-in took the return value as its success
    -- signal, so `mktemp -d` failed on every real machine with "cannot create a
    -- name" while passing every assertion here. A stub that is more generous than
    -- the thing it stands in for converts a hardware failure into a green test.
    local parts = {}
    for seg in p:gmatch("[^/]+") do parts[#parts + 1] = seg end
    local acc = ""
    for _, seg in ipairs(parts) do
        acc = acc .. "/" .. seg
        if not FS[acc] then FS[acc] = { dir = true } end
    end
end

local function drop(path)
    for p in pairs(FS) do
        if p == path or p:sub(1, #path + 1) == path .. "/" then FS[p] = nil end
    end
end

function fs.delete(p)
    p = norm(p)
    local entry = FS[p]
    if not entry then return fs_error("No such file") end
    if entry.dir then
        local kids = fs.list(p)
        if kids and #kids > 0 then return fs_error("Directory not empty") end
    end
    FS[p] = nil
    return true
end

local function copy_tree(src, dst)
    local entry = FS[src]
    if not entry then return false end
    if entry.dir then
        FS[dst] = { dir = true }
        for _, name in ipairs(fs.list(src) or {}) do
            copy_tree(src .. (src == "/" and "" or "/") .. name,
                      dst .. (dst == "/" and "" or "/") .. name)
        end
    else
        FS[dst] = { content = entry.content }
    end
    return true
end

function fs.copy(src, dst)
    src, dst = norm(src), norm(dst)
    if not FS[src] then return fs_error("No such file") end
    return copy_tree(src, dst)
end

function fs.move(src, dst)
    src, dst = norm(src), norm(dst)
    if not FS[src] then return fs_error("No such file") end
    copy_tree(src, dst)
    drop(src)
    return true
end

function fs.combine(a, b)
    if b:sub(1, 1) == "/" then return norm(b) end
    if a == "/" then return norm("/" .. b) end
    return norm(norm(a) .. "/" .. b)
end

function fs.getName(p) return base_of(p) end
function fs.getDir(p) return parent_of(p) or "/" end

function fs.getSize(p)
    local entry = FS[norm(p)]
    if not entry or entry.dir then return 0 end
    return #(entry.content or "")
end

function fs.getDrive(p) return norm(p) == "/rom" and "rom" or "hdd" end

function fs.getCapacity(p)
    p = norm(p)
    if not FS[p] then return nil end
    if p == "/rom" then return 1048576 end
    if p:sub(1, 5) == "/disk" then return 1310720 end
    return 4194304
end

function fs.getFreeSpace(p)
    p = norm(p)
    if not FS[p] then return nil end
    if p == "/rom" then return 0 end
    if p:sub(1, 5) == "/disk" then return 786432 end
    return 2097152
end

function fs.attributes(p)
    local entry = FS[norm(p)]
    if not entry then return nil end
    return { size = entry.dir and 0 or #(entry.content or ""),
             isDir = entry.dir == true, modification = os.time() }
end

-- CraftOS file handles are plain tables whose methods are closures, so project
-- code calls them with a dot (f.write("x")). The stub below accepts both
-- f.write(x) and f:write(x) by normalising the first argument.
local Handle = {}

function Handle.new(path, mode)
    local h = { path = path, mode = mode, pos = 1 }
    local function arg_of(a, b)
        if a == h then return b end
        return a
    end

    if mode == "r" or mode == "rb" then
        h.mode = "r"
        h.text = (FS[path] and FS[path].content) or ""
    else
        h.text = (mode == "a" and FS[path] and not FS[path].dir)
            and (FS[path].content or "") or ""
        h.buffer = h.text
    end

    h.read = function(a, b)
        if h.mode ~= "r" then return nil end
        local count = tonumber(arg_of(a, b))
        if not count then
            local text = h.text:sub(h.pos)
            h.pos = #h.text + 1
            return text
        end
        if count < 0 then
            local from = math.max(1, h.pos + count)
            local text = h.text:sub(from, h.pos - 1)
            h.pos = from
            return text
        end
        local text = h.text:sub(h.pos, h.pos + count - 1)
        h.pos = h.pos + #text
        return text
    end

    h.readLine = function(a, b)
        if h.mode ~= "r" then return nil end
        if h.pos > #h.text then return nil end
        local nl = h.text:find("\n", h.pos, true)
        local line
        if nl then
            line = h.text:sub(h.pos, nl - 1)
            h.pos = nl + 1
        else
            line = h.text:sub(h.pos)
            h.pos = #h.text + 1
        end
        return line
    end

    h.readAll = function(a, b)
        if h.mode ~= "r" then return nil end
        local text = h.text:sub(h.pos)
        h.pos = #h.text + 1
        return text
    end

    h.write = function(a, b)
        if h.mode == "r" then return nil end
        h.buffer = (h.buffer or "") .. tostring(arg_of(a, b))
        return h
    end

    h.writeLine = function(a, b)
        return h.write(tostring(arg_of(a, b)) .. "\n")
    end

    h.flush = function(a, b)
        if h.mode == "r" then return end
        local entry = FS[h.path]
        if entry and entry.dir then return end
        FS[h.path] = { content = h.buffer or "" }
    end

    h.seek = function(a, b)
        local whence, offset = a, b
        if whence == h then whence, offset = b, nil end
        if type(whence) == "number" then offset, whence = whence, "cur" end
        whence = whence or "cur"
        offset = tonumber(offset) or 0
        local base = h.pos
        if whence == "set" then base = 1
        elseif whence == "end" then base = #h.text + 1 end
        h.pos = math.max(1, base + offset)
        return h.pos
    end

    h.close = function(a, b)
        if h.mode ~= "r" then h.flush() end
    end

    return h
end

function fs.open(p, mode)
    p = norm(p)
    mode = mode or "r"
    local entry = FS[p]
    if mode == "r" or mode == "rb" then
        if not entry or entry.dir then return nil end
    elseif fs.isReadOnly(p) then
        return nil
    end
    return Handle.new(p, mode)
end

_G.fs = fs
_G.FS = FS

-- ------------------------------------------------------------- fake clock/io
_G.__CLOCK = 3600.0           -- "seconds since boot"
_G.__CLOCK_LIMIT = 3600.0 + 900

local function clock() return _G.__CLOCK end
local function advance(dt) _G.__CLOCK = _G.__CLOCK + dt end

local real_os_time = os.time
local real_os_date = os.date

local os_env = {}
for k, v in pairs(os) do os_env[k] = v end

os_env.time = function(...) return real_os_time(...) end
os_env.date = function(fmt, t) return real_os_date(fmt, t) end
os_env.clock = function() return clock() end
os_env.epoch = function(kind)
    if kind == "utc" then return real_os_time() * 1000 end
    return math.floor(clock() * 1000)
end
-- On CraftOS os.sleep parks the coroutine until a timer fires. Here the fake
-- clock is jumped forward and the coroutine yields once, so cooperative job
-- control sees a genuinely suspended background job.
os_env.sleep = function(t)
    advance(tonumber(t) or 0)
    if coroutine.running() then pcall(coroutine.yield, "sleep") end
end
os_env.getComputerID = function() return 5 end
os_env.getComputerLabel = function() return "cc-5" end
os_env.setComputerLabel = function() end
os_env.version = function() return "CraftOS 1.8" end

-- os.reboot() and os.shutdown() do not return on a real machine: the Lua state is
-- torn down. A stub cannot tear its own state down, so these record the request
-- and raise the same error shape the ROM uses, which lets a test assert that the
-- call was made without pretending the machine restarted.
os_env.reboot = function()
    _G.__REBOOTED = (_G.__REBOOTED or 0) + 1
    error("__stub_reboot", 0)
end
os_env.shutdown = function()
    _G.__SHUTDOWN = (_G.__SHUTDOWN or 0) + 1
    error("__stub_shutdown", 0)
end

local queue = {}
local timers = {}
local timer_seq = 0
local alarm = nil

os_env.startTimer = function(t)
    timer_seq = timer_seq + 1
    timers[timer_seq] = clock() + (tonumber(t) or 0)
    return timer_seq
end

os_env.cancelTimer = function(id) timers[id] = nil end

os_env.queueEvent = function(...)
    queue[#queue + 1] = { ... }
end

local function step_timers()
    for id, deadline in pairs(timers) do
        if clock() >= deadline then
            timers[id] = nil
            queue[#queue + 1] = { "timer", id }
        end
    end
end

local function next_event()
    while true do
        step_timers()
        if #queue > 0 then return table.remove(queue, 1) end
        if clock() > _G.__CLOCK_LIMIT then
            error("cc_env_stub: stalled, no event available", 0)
        end
        advance(0.05)
    end
end

local function pull(raw, filter)
    while true do
        local ev = next_event()
        if ev[1] == "terminate" and not raw then
            error("Terminated", 0)
        end
        if not filter or ev[1] == filter then return unpack(ev) end
    end
end

os_env.pullEvent = function(filter) return pull(false, filter) end
os_env.pullEventRaw = function(filter) return pull(true, filter) end

_G.os = os_env

-- ------------------------------------------------------------------- terminal
-- Every term.blit() call of a test, in order, with the cursor position it was
-- made at. The renderer under test draws through blit and nothing else, so this
-- is the only place the pixels it produced can be seen.
_G.__BLITS = {}

_G.term = {
    clear = function() push("<clear>"); CURSOR = { 1, 1 } end,
    clearLine = function() end,
    setCursorPos = function(x, y) CURSOR = { x, y } end,
    getCursorPos = function() return CURSOR[1], CURSOR[2] end,
    -- The cursor is OFF until a program asks for it: the terminal starts that way
    -- and CraftOS's own line reader turns the blink on while it reads. Recorded
    -- (and counted) so a test can assert that this project's editor, which
    -- replaces that reader, asks for it as well -- measured on a real machine:
    -- without the call the prompt had no cursor, so Left/Right moved an insertion
    -- point nobody could see.
    setCursorBlink = function(v)
        _G.__CURSOR_BLINK = v and true or false
        if v then
            _G.__CURSOR_BLINK_ON = (_G.__CURSOR_BLINK_ON or 0) + 1
        else
            _G.__CURSOR_BLINK_OFF = (_G.__CURSOR_BLINK_OFF or 0) + 1
        end
    end,
    getSize = function() return SCREEN_W, 19 end,
    write = function(s) raw_out(s) end,
    setTextColor = function() end,
    setTextColour = function() end,
    getTextColor = function() return 1 end,
    setBackgroundColor = function() end,
    getBackgroundColor = function() return 1 end,
    isColor = function() return true end,
    -- term.blit(text, fg, bg): one character of "text" per cell, whose bytes are
    -- NOT letters -- each byte packs six sub-pixel flags (see lib/cc_chinese.lua,
    -- which explains the layout). The stub has to accept those bytes, because the
    -- CJK renderer is the one thing in this project that emits them, and a stub
    -- that rejected them would make the renderer untestable on the PC. The call
    -- is recorded whole in __BLITS so a test can assert on the exact payload
    -- instead of on "something was drawn".
    blit = function(text, fg, bg)
        _G.__BLITS[#_G.__BLITS + 1] = { text = text, fg = fg, bg = bg,
                                        x = CURSOR[1], y = CURSOR[2] }
        push(text)
    end,
}
_G.write = function(s) console_out(s) end
_G.read = function() return nil end

_G.io = {
    write = function(s) raw_out(s) end,
    writeLine = function(s) console_out(tostring(s) .. "\n") end,
}

-- ------------------------------------------------------------------ peripherals
_G.__MODEMS = { "top" }
_G.peripheral = {
    getNames = function() return { unpack(_G.__MODEMS) } end,
    getType = function(name)
        for _, n in ipairs(_G.__MODEMS) do
            if n == name then return "modem" end
        end
        return nil
    end,
    hasType = function(name, kind)
        return _G.peripheral.getType(name) == kind
    end,
    call = function(name, method)
        if method == "isWireless" then return true end
        if method == "isOpen" then return false end
        return nil
    end,
}

_G.__REDNET_OPEN = {}
_G.rednet = {
    open = function(side)
        if not side then error("rednet: no side", 0) end
        _G.__REDNET_OPEN[side] = true
    end,
    close = function(side) _G.__REDNET_OPEN[side] = nil end,
    isOpen = function(side)
        if side then return _G.__REDNET_OPEN[side] == true end
        return next(_G.__REDNET_OPEN) ~= nil
    end,
    send = function(id, msg, proto)
        _G.__REDNET_SENT = (_G.__REDNET_SENT or 0) + 1
        return true
    end,
    broadcast = function(msg, proto)
        _G.__REDNET_SENT = (_G.__REDNET_SENT or 0) + 1
        return true
    end,
    receive = function(proto, timeout)
        local timer = os.startTimer(timeout or 1)
        while true do
            local ev, a = os.pullEvent()
            if ev == "timer" and a == timer then return nil end
            if ev == "rednet_message" then return a end
        end
    end,
}

_G.multishell = {
    getCount = function() return 1 end,
    getFocus = function() return 1 end,
    getTitle = function(i) return "shell " .. tostring(i) end,
    launch = function() return 0 end,
}

_G.shell = {
    run = function(...) return false end,
    setDir = function() end,
    dir = function() return "/" end,
    resolve = function(p) return p end,
    exit = function() end,
}

-- textutils.serialize() has to round trip through unserialize(), because the
-- project stores tables (the package command registry, the job table, ...) in
-- files. A plain tostring() would turn every stored table into the string
-- "table: 0x...", so a small recursive writer is used instead.
local function ser(v, seen)
    local t = type(v)
    if t == "string" then return string.format("%q", v) end
    if t == "number" or t == "boolean" then return tostring(v) end
    if t == "nil" then return "nil" end
    if t ~= "table" then return string.format("%q", tostring(v)) end
    seen = seen or {}
    if seen[v] then return "nil" end
    seen[v] = true
    local parts = {}
    local n = 0
    for i, item in ipairs(v) do
        n = i
        parts[#parts + 1] = ser(item, seen)
    end
    for k, item in pairs(v) do
        local skip = type(k) == "number" and k >= 1 and k <= n and
                     k == math.floor(k)
        if not skip then
            parts[#parts + 1] = "[" .. ser(k, seen) .. "]=" .. ser(item, seen)
        end
    end
    seen[v] = nil
    return "{" .. table.concat(parts, ",") .. "}"
end

_G.textutils = {
    serialize = function(v) return ser(v) end,
    unserialize = function(s)
        local f = compile("return " .. tostring(s))
        if not f then return nil end
        local ok, v = pcall(f)
        if ok then return v end
        return nil
    end,
    base64encode = function(s) return s end,
    base64decode = function(s) return s end,
}

-- The CraftOS settings API. The ROM's own default definitions live in the host's
-- bios.lua, and the two keys this project cares about are shell.allow_startup
-- (true) and shell.allow_disk_startup (default = commands == nil, i.e. true on an
-- ordinary computer). They are defined here with the same defaults so a test sees
-- what the ROM would do, not an empty table.
--
-- The file format matters and is easy to get wrong: textutils.unserialize
-- PREPENDS "return ", so /.settings must be a bare table literal -- a file
-- starting with "return" or carrying a comment parses to nil and every key
-- silently keeps its default. That is why save() below writes exactly what
-- textutils.serialize produces, the same shape the ROM writes.
_G.__SETTINGS_DEFAULTS = {
    ["shell.allow_startup"] = true,
    ["shell.allow_disk_startup"] = true,
    ["shell.autocomplete"] = true,
}
_G.__SETTINGS_VALUES = {}
_G.settings = {
    define = function(name, opts)
        if _G.__SETTINGS_DEFAULTS[name] == nil and type(opts) == "table" then
            _G.__SETTINGS_DEFAULTS[name] = opts.default
        end
    end,
    get = function(name, default)
        if _G.__SETTINGS_VALUES[name] ~= nil then return _G.__SETTINGS_VALUES[name] end
        if _G.__SETTINGS_DEFAULTS[name] ~= nil then return _G.__SETTINGS_DEFAULTS[name] end
        return default
    end,
    -- The ROM's getDetails: what "set NAME" prints. The stub keeps the declared
    -- defaults, so a details table can be built from them; the type is inferred
    -- from the default, which is enough for the settings this project touches.
    getDetails = function(name)
        local default = _G.__SETTINGS_DEFAULTS[name]
        local value = _G.__SETTINGS_VALUES[name]
        if value == nil then value = default end
        local stype = type(default)
        if default == nil then stype = nil end
        return { name = name, value = value, default = default, type = stype }
    end,
    set = function(name, value) _G.__SETTINGS_VALUES[name] = value end,
    unset = function(name) _G.__SETTINGS_VALUES[name] = nil end,
    getNames = function()
        local out = {}
        for k in pairs(_G.__SETTINGS_DEFAULTS) do out[#out + 1] = k end
        for k in pairs(_G.__SETTINGS_VALUES) do
            local seen = false
            for _, n in ipairs(out) do if n == k then seen = true end end
            if not seen then out[#out + 1] = k end
        end
        table.sort(out)
        return out
    end,
    load = function(path)
        path = path or ".settings"
        if not fs.exists(path) then return false end
        local f = fs.open(path, "r")
        if not f then return false end
        local text = f.readAll()
        f.close()
        -- same reader the ROM uses, INCLUDING its refusal of "return ..."
        local data = _G.textutils.unserialize(text)
        if type(data) ~= "table" then return false end
        for k, v in pairs(data) do _G.__SETTINGS_VALUES[k] = v end
        return true
    end,
    save = function(path)
        path = path or ".settings"
        local f = fs.open(path, "w")
        if not f then return false end
        -- the merged view, exactly as the ROM's save() writes it
        local out = {}
        for k, v in pairs(_G.__SETTINGS_DEFAULTS) do out[k] = v end
        for k, v in pairs(_G.__SETTINGS_VALUES) do out[k] = v end
        f.write(_G.textutils.serialize(out))
        f.close()
        return true
    end,
}

_G.keys = {
    enter = 28, backspace = 14, tab = 15, up = 200, down = 208,
    left = 203, right = 205, home = 199, ["end"] = 207,
    delete = 211, space = 57,
    -- NO "escape", deliberately: the ROM's own key table has no such entry
    -- (rom/apis/keys.lua ends at keys.delete) and Minecraft never delivers the key
    -- to the computer. This stub used to define escape = 1, which is exactly why
    -- lib/bios.lua's `a == keys.escape` comparisons looked fine here and were dead
    -- code on every real machine -- the same "the stub is more forgiving than the
    -- hardware" trap as fs.makeDir returning true. CraftOS-PC does forward the key
    -- as code 1, so an emulator-only screen may spell 1 by hand; a key that has to
    -- work in Minecraft may not.
    -- Modifiers are reported as key events of their own, with the codes the
    -- real machine uses, so that "Ctrl+letter" can be assembled from a Ctrl
    -- key event plus the key event of the letter (LWJGL key codes).
    leftCtrl = 29, rightCtrl = 157,
    a = 30, b = 48, c = 46, d = 32, e = 18, f = 33, g = 34, h = 35,
    i = 23, j = 36, k = 37, l = 38, m = 50, n = 49, o = 24, p = 25,
    q = 16, r = 19, s = 31, t = 20, u = 22, v = 47, w = 17, x = 45,
    y = 21, z = 44,
}

_G.colors = {
    -- The values the ROM defines, READ OFF CraftOS-PC 2.8.3 rather than
    -- transcribed: white 1 (bit 0) through black 32768 (bit 15), and the bit
    -- position IS the colour's index in the blit alphabet, which is why the
    -- mapping table below can be derived from them.
    --
    -- This table used to disagree with the machine in three places -- black was
    -- 16384 (green's value), lightBlue was 8192 and green was 16384 (swapped) --
    -- and nothing failed, because no test had ever compared a colour with the
    -- ROM. A stub that is wrong about a constant turns every assertion built on
    -- it into an assertion about the stub.
    white = 1, orange = 2, magenta = 4, lightBlue = 8, yellow = 16,
    lime = 32, pink = 64, gray = 128, lightGray = 256, cyan = 512,
    purple = 1024, blue = 2048, brown = 4096, green = 8192, red = 16384,
    black = 32768,
}

-- colors.toBlit is what turns a colour constant into the one character the
-- blit() arguments carry, and it is the exact mapping the ROM uses: the bit
-- position of the constant, plus one, as an ASCII digit or letter. Measured on
-- CraftOS-PC 2.8.3: toBlit(colors.white) == "0", toBlit(colors.black) == "f",
-- and a value that is not a colour gives "0". lib/cc_chinese.lua renders every
-- glyph through this function, so a stub without it could not run the renderer
-- at all, and an approximation of it would make every colour assertion agree
-- with a wrong implementation.
_G.__COLOR_BITS = {
    [1] = "0", [2] = "1", [4] = "2", [8] = "3", [16] = "4", [32] = "5",
    [64] = "6", [128] = "7", [256] = "8", [512] = "9", [1024] = "a",
    [2048] = "b", [4096] = "c", [8192] = "d", [16384] = "e", [32768] = "f",
}
_G.colors.toBlit = function(colour)
    return _G.__COLOR_BITS[colour] or "0"
end

_G.colours = _G.colors
_G._HOST = "CraftOS-PC"

-- Programs on a ComputerCraft machine live on the virtual disk, so a program
-- that loads a command file (psh runs "/usr/cmd/foo.lua") must not reach the
-- host file system of the PC. The shim looks the path up in the emulated file
-- system first and only falls back to the real loadfile() for host paths.
local real_loadfile = loadfile
_G.loadfile = function(p)
    if type(p) == "string" then
        local path = norm(p)
        local entry = FS[path]
        if entry and not entry.dir then
            local chunk, err = compile(entry.content or "", "@" .. path)
            if chunk then return chunk end
            return nil, err
        end
    end
    return real_loadfile(p)
end

_G.__realprint = realprint
