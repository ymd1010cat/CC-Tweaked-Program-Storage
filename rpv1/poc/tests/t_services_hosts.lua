--[[- tests/t_services_hosts.lua - node.hosts itself (rpv/services.lua + rpv/node.lua).

Bug 1: the hot-reload watcher must follow cfg.hosts_file, not a hard-coded
"hosts.txt", and the setup() baseline must be the same file the watcher compares
against. Bug 2: hosts_load must skip malformed lines instead of raising, so one
bad hand-edited line cannot abort services_setup (and the rest of the boot).

Both are driven through the real code paths: node:setup() for the boot load and
node:tick() for the 2-second file watcher (fs.attributes is stubbed so the test
does not depend on filesystem mtime granularity).
]]
local T, M = ...

local CUSTOM = "t_hosts_custom.txt"
local BAD = "t_hosts_bad.txt"
local DEFAULT = "hosts.txt"          -- the hard-coded name the old watcher used
local LOGFILE = "rpv-log.txt"

local function write(path, text)
    local f = fs.open(path, "w")
    if not f then return false end
    f.write(text)
    f.close()
    return true
end

local function read(path)
    local f = fs.open(path, "r")
    if not f then return nil end
    local s = f.readAll()
    f.close()
    return s
end

local function clean(path)
    if fs.exists(path) then pcall(fs.delete, path) end
end

-- local aliases keep the stubs below off tools/lint.lua's accidental-global list
local FS, OS = fs, os
local real_attributes = FS.attributes
local real_start_timer = OS.startTimer

-- a pre-existing hosts.txt (developer machine) is restored at the end
local default_backup = read(DEFAULT)
local had_log = FS.exists(LOGFILE)
for _, p in ipairs({ CUSTOM, BAD }) do clean(p) end
clean(DEFAULT)

-- ===== bug 1: the watcher follows cfg.hosts_file ============================
T.ok(write(CUSTOM, "alpha 10.0.1.5\n"), "custom hosts file written")
T.ok(write(DEFAULT, "decoy 10.0.9.9\n"), "default hosts.txt written")

local mtimes = {}
mtimes[CUSTOM], mtimes[DEFAULT] = 1000, 2000
local function stub_attributes(path)
    if mtimes[path] ~= nil then return { size = 1, modification = mtimes[path] } end
    return real_attributes(path)
end

-- boot: services_setup loads cfg.hosts_file; setup() records the watcher baseline
if not OS.startTimer then OS.startTimer = function() return 1 end end
FS.attributes = stub_attributes
local n = M.node_new({ role = "host", hosts_file = CUSTOM })
local ok_setup, setup_err = pcall(function() n:setup() end)
FS.attributes = real_attributes
OS.startTimer = real_start_timer

T.ok(ok_setup, "boot with a custom hosts_file completes: " .. tostring(setup_err))
T.eq(n.hosts and n.hosts.alpha, M.ip2int("10.0.1.5"), "boot loads node.hosts from cfg.hosts_file")
T.eq(n.hosts and n.hosts.decoy, nil, "boot does not load the default hosts.txt")
T.eq(n.hosts_mtime, mtimes[CUSTOM], "the watcher baseline is cfg.hosts_file's mtime")

-- node:tick() is the hot-reload path under test from here on
local logs = {}
n.log = function(_, fmt, ...) logs[#logs + 1] = string.format(fmt, ...) end
function n:after() end                   -- do not schedule another tick
FS.attributes = stub_attributes

-- (a) only the default file changes: the configured table must survive untouched
mtimes[DEFAULT] = 3000
n.route_check = -1
n:tick()
T.eq(n.hosts.alpha, M.ip2int("10.0.1.5"), "editing the default hosts.txt keeps the configured table")
T.eq(n.hosts.decoy, nil, "the default file's entries never leak into node.hosts")
T.eq(n.hosts_mtime, mtimes[CUSTOM], "editing the default hosts.txt does not move the baseline")

-- (b) the configured file changes: that is the file that must be reloaded
T.ok(write(CUSTOM, "alpha 10.0.1.5\ngamma 10.0.1.7\n"), "custom hosts file edited")
mtimes[CUSTOM] = 4000
n.route_check = -1
n:tick()
T.eq(n.hosts.gamma, M.ip2int("10.0.1.7"), "editing cfg.hosts_file reloads node.hosts")
T.eq(n.hosts.decoy, nil, "the reload reads the configured file only")
T.ok(logs[#logs] and logs[#logs]:find("HOSTS_RELOADED", 1, true) ~= nil, "the reload is logged")
T.ok(logs[#logs] and logs[#logs]:find(CUSTOM, 1, true) ~= nil, "the reload log names the configured file")
FS.attributes = real_attributes

-- ===== bug 2: malformed hosts lines do not abort services_setup ============
local bad_body = "# comment line\n"
    .. "\n"
    .. "alpha 10.0.1.5\n"
    .. "truncated 10.0.1\n"              -- ip2int used to raise on this line
    .. "toobig 10.0.1.256\n"
    .. "leading 010.0.1.7\n"
    .. "spaced out\n"
    .. "lonely 10.0.1.8 extra\n"
    .. "beta 10.0.1.6\n"
T.ok(write(BAD, bad_body), "malformed hosts fixture written")

local n2 = T.node({ hosts_file = BAD, dns = "1" }, {})
local logs2 = {}
n2.log = function(_, fmt, ...) logs2[#logs2 + 1] = string.format(fmt, ...) end
n2.bind = function(self, port, cb) return { port = port, handler = cb } end
local ok2, err2 = pcall(M.services_setup, n2)
T.ok(ok2, "services_setup survives malformed hosts lines: " .. tostring(err2))
T.eq(n2.hosts and n2.hosts.alpha, M.ip2int("10.0.1.5"), "the first good line is loaded")
T.eq(n2.hosts and n2.hosts.beta, M.ip2int("10.0.1.6"), "a good line after the bad ones is loaded")
T.eq(n2.hosts and n2.hosts.truncated, nil, "a truncated address is skipped")
T.eq(n2.hosts and n2.hosts.toobig, nil, "an out-of-range octet is skipped")
T.eq(n2.hosts and n2.hosts.leading, nil, "a leading-zero octet is skipped")
T.eq(n2.hosts and n2.hosts.spaced, nil, "a malformed line is skipped")
T.eq(n2.hosts and n2.hosts.lonely, nil, "a line with extra tokens is skipped")
T.eq(n2.hosts_bad, 5, "every skipped line is counted")
T.ok(n2.dns ~= nil, "services after hosts_load still start")
local bad_logs = 0
for _, line in ipairs(logs2) do
    if line:find("HOSTS_BAD_LINE", 1, true) then bad_logs = bad_logs + 1 end
end
T.eq(bad_logs, 5, "every skipped line is logged")

-- ===== cleanup =============================================================
clean(CUSTOM)
clean(BAD)
if default_backup then write(DEFAULT, default_backup) else clean(DEFAULT) end
if n.logfile and n.logfile.close then pcall(n.logfile.close, n.logfile) end
if not had_log then clean(LOGFILE) end
