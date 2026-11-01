-- watchdog_app.lua - runtime driver for watchdog.lua
--
-- Samples a redstone level, feeds watchdog.lua and, when the state machine
-- crosses an edge, acts exactly once: the alarm sample drives the alarm relay
-- and switches the power mode to watchdog.switch_to (default 2 = backup
-- battery) through power.lua; the recovery sample drives the relay back and -
-- when watchdog.restore is true - restores the mode that was active before the
-- alarm.
--
-- All tunables are read from the controller's ini file through power.lua;
-- nothing is read from CraftOS' per-computer configuration store.
--
-- This is NOT a continuous ATS controller: it only acts on those two
-- transitions, never re-corrects the mode on every poll (so a manual mode change
-- between transitions is left alone), and it never edits the controller's ini
-- file itself (power.lua owns that write).
--
-- Two ways to use it:
--   * as a program on a monitoring computer: run `watchdog_app` from the shell
--     (or make it /startup.lua). The guard at the bottom of this file only
--     autostarts in that case.
--   * as a module: `local app = dofile("watchdog_app.lua").new{...}`, then
--     app:start / tick / run with injected clock, redstone, logger and reader
--     (that is how the offline suite drives it).
--
-- Log keywords (logger.lua keeps the usual "[tag] YYYY.MM.DD HH:MM message"
-- format, so grep the keyword, not the tag):
--   WATCHDOG_START      monitor armed
--   WATCHDOG_ALARM      alarm raised (relay on)
--   WATCHDOG_CLEAR      level reached high again (relay off)
--   WATCHDOG_DISABLED   enabled=false, nothing is sampled or driven
--   WATCHDOG_CONFIG_BAD one line per rejected ini value / ignored line / unknown key
--   WATCHDOG_CONFIG     parse summary of the ini file (path/format/mode)
--   WATCHDOG_CONFIG_FAIL the watchdog section could not be read (defaults are used)
--   WATCHDOG_READ_FAIL  the sensor could not be read (first failure, then 1/60)
--   WATCHDOG_RELAY_FAIL the alarm side could not be driven
--   WATCHDOG_SWITCH     the alarm switched the power mode (from=X to=Y ...)
--   WATCHDOG_SWITCH_FAIL the switch could not be done (no power module/read/write)
--   WATCHDOG_RESTORE    recovery switched the mode back to the pre-alarm mode
--   WATCHDOG_RESTORE_SKIP recovery had nothing to restore, or restore is off
--   WATCHDOG_RESTORE_FAIL the restore read/write failed
--   WATCHDOG_STATUS     status snapshot on demand
--   WATCHDOG_CRASH      the main loop died

local M = {}

M.VERSION = "1.1"

local NULL_LOGGER = {}
function NULL_LOGGER.write() return false end
function NULL_LOGGER.info() return false end
function NULL_LOGGER.warn() return false end
function NULL_LOGGER.error() return false end
function NULL_LOGGER.debug() return false end
M.NULL_LOGGER = NULL_LOGGER

local function flag(value)
    if value == true then return "1" end
    return "0"
end
M.flag = flag

local function fmt(value)
    if type(value) ~= "number" or value ~= value then return "?" end
    if value == math.floor(value) and math.abs(value) < 1e15 then
        return string.format("%d", value)
    end
    return string.format("%.1f", value)
end
M.fmt = fmt

-- Resolve a sibling module without hard-failing when require is unavailable or
-- the files sit at the computer root.
local function resolveModule(name)
    if type(require) == "function" then
        local ok, mod = pcall(require, name)
        if ok and type(mod) == "table" then return mod end
    end
    local ok, mod = pcall(dofile, "/" .. name .. ".lua")
    if ok and type(mod) == "table" then return mod end
    return nil
end
M.resolveModule = resolveModule

local function defaultClock()
    if type(os) == "table" and type(os.clock) == "function" then
        return os.clock()
    end
    return 0
end

local function defaultSleep(seconds)
    if type(os) == "table" and type(os.sleep) == "function" then
        os.sleep(seconds)
        return
    end
    error("os.sleep is unavailable", 0)
end

-- Default reader: the analog value of one side (0-15). Redstone input is the
-- same scale as the analog output the controller uses, so a comparator / energy
-- sensor on that side maps directly onto low/high.
local function makeReader(redstone, side)
    return function()
        if type(redstone) ~= "table" or type(redstone.getAnalogInput) ~= "function" then
            return nil, "no redstone API"
        end
        local ok, value = pcall(redstone.getAnalogInput, side)
        if not ok then return nil, tostring(value) end
        local n = tonumber(value)
        if n == nil then return nil, "not a number" end
        return n
    end
end
M.makeReader = makeReader

-- field -> ini key mapping (owned by power.lua; the conventional prefix is the
-- fallback when the module is absent or is a test double).
function M.iniKeys(powerApi)
    if type(powerApi) == "table" and type(powerApi.WATCHDOG_KEYS) == "table" then
        return powerApi.WATCHDOG_KEYS
    end
    return {}
end

local function iniKeyOf(app, field)
    local key = M.iniKeys(app.power)[field]
    if type(key) == "string" then return key end
    return "watchdog." .. tostring(field)
end

-- Read the watchdog section out of the ini file through power.lua. Returns the
-- raw field table (strings) plus the parse report; an empty table plus a reason
-- when the module is absent.
local function iniConfig(powerApi, powerOpts)
    if type(powerApi) ~= "table" or type(powerApi.config) ~= "function" then
        return {}, { ok = false, reason = "no_power_module" }
    end
    local ok, raw, info = pcall(powerApi.config, powerOpts)
    if not ok then
        return {}, { ok = false, reason = "config_error" }
    end
    if type(raw) ~= "table" then raw = {} end
    if type(info) ~= "table" then info = {} end
    info.ok = true
    return raw, info
end

-- Build the app. opts:
--   config   raw watchdog options (skips the ini read when given)
--   path     ini path override passed to the power module (tests/deploys)
--   watchdog watchdog module (default require/dofile watchdog.lua)
--   logger   logger module (default require/dofile logger.lua, else no-op)
--   redstone redstone API (default _G.redstone)
--   read     function() -> level[, err] (default: analog input of input_side)
--   clock    function() -> seconds (default os.clock)
--   sleep    function(seconds) (default os.sleep)
--   power    power.lua-style module with config()/read()/apply(value);
--            pass false to simulate the module being absent
--            (default require/dofile power.lua)
function M.new(opts)
    if type(opts) ~= "table" then opts = {} end

    local wd = opts.watchdog
    if type(wd) ~= "table" or type(wd.new) ~= "function" then
        wd = resolveModule("watchdog")
    end
    if type(wd) ~= "table" or type(wd.new) ~= "function" then
        error("watchdog_app: watchdog.lua was not found", 0)
    end

    local log = opts.logger
    if type(log) ~= "table" or type(log.info) ~= "function" then
        log = resolveModule("logger") or NULL_LOGGER
    end

    local redstone = opts.redstone
    if redstone == nil then redstone = _G.redstone end

    -- power.lua is both the power primitive and the configuration source: the
    -- watchdog section lives in the ini file. Passing false means "there is no
    -- power module in this deployment": the monitor still alarms with defaults,
    -- but a switch attempt is logged as WATCHDOG_SWITCH_FAIL instead of
    -- crashing.
    local powerApi = opts.power
    if powerApi == nil then powerApi = resolveModule("power") end
    if powerApi == false then powerApi = nil end

    local powerOpts = nil
    if type(opts.path) == "string" then powerOpts = { path = opts.path } end

    local config = opts.config
    local configInfo = nil
    if type(config) ~= "table" then
        config, configInfo = iniConfig(powerApi, powerOpts)
    end

    local state = wd.new(config)
    local app = {
        version = M.VERSION,
        watchdog = wd,
        logger = log,
        redstone = redstone,
        power = powerApi,
        power_opts = powerOpts,
        ini = configInfo,
        clock = opts.clock or defaultClock,
        sleep = opts.sleep or defaultSleep,
        state = state,
        status = "new",
        started = false,
        polls = 0,
        read_errors = 0,
        relay = false,
        relay_writes = 0,
        last_mode = nil,
        switch_from = nil,
        switch_target = nil,
        switched = false,
        switches = 0,
        restores = 0,
    }
    if opts.read ~= nil then
        app.read = opts.read
    else
        app.read = makeReader(redstone, state.cfg.input_side)
    end
    return app
end

-- Arm the monitor: report the ini parse, log every rejected value, the start
-- line, and put the relay in its safe state. Returns "running" or "disabled".
function M.start(app)
    local state = app.state
    local problems = state.problems or {}
    for i = 1, #problems do
        local problem = problems[i]
        app.logger.warn("WATCHDOG_CONFIG_BAD key=" ..
            iniKeyOf(app, problem.field) ..
            " value=" .. tostring(problem.raw) ..
            " fallback=" .. tostring(problem.fallback) ..
            " reason=" .. tostring(problem.reason))
    end

    local info = app.ini
    if type(info) == "table" and info.format ~= nil then
        if info.format ~= nil then
            app.logger.info("WATCHDOG_CONFIG path=" .. tostring(info.path) ..
                " format=" .. tostring(info.format) ..
                " mode=" .. fmt(info.mode))
        end
        if info.mode_error ~= nil then
            app.logger.warn("WATCHDOG_CONFIG_FAIL code=" ..
                tostring(info.mode_error) .. " fallback=defaults")
        end
        local badLines = info.bad_lines or {}
        for i = 1, #badLines do
            app.logger.warn("WATCHDOG_CONFIG_BAD line=" .. tostring(badLines[i]) ..
                " fallback=ignored")
        end
        local unknown = info.unknown or {}
        for i = 1, #unknown do
            app.logger.warn("WATCHDOG_CONFIG_BAD key=" .. tostring(unknown[i].key) ..
                " value=" .. tostring(unknown[i].value) .. " fallback=ignored")
        end
    elseif type(info) == "table" and info.reason ~= nil then
        app.logger.warn("WATCHDOG_CONFIG_FAIL reason=" .. tostring(info.reason) ..
            " fallback=defaults")
    end

    if state.cfg.enabled ~= true then
        app.status = "disabled"
        app.started = true
        app.logger.warn("WATCHDOG_DISABLED reason=config")
        return "disabled"
    end
    app.logger.info(string.format(
        "WATCHDOG_START input=%s alarm=%s low=%s high=%s window=%s poll=%s " ..
        "switch_to=%s restore=%s",
        tostring(state.cfg.input_side), tostring(state.cfg.alarm_side),
        fmt(state.cfg.low), fmt(state.cfg.high), fmt(state.cfg.window),
        fmt(state.cfg.poll), fmt(state.cfg.switch_to),
        M.flag(state.cfg.restore)))
    app.status = "running"
    app.started = true
    M.applyAlarm(app, false)
    return "running"
end

-- Drive the alarm relay. Only the configured alarm side is written; the power
-- output side is never touched.
function M.applyAlarm(app, on)
    local side = app.state.cfg.alarm_side
    local redstone = app.redstone
    if type(redstone) ~= "table" or type(redstone.setOutput) ~= "function" then
        app.logger.warn("WATCHDOG_RELAY_FAIL side=" .. tostring(side) ..
            " err=no redstone API")
        return false
    end
    local ok, err = pcall(redstone.setOutput, side, on == true)
    if not ok then
        app.logger.warn("WATCHDOG_RELAY_FAIL side=" .. tostring(side) ..
            " err=" .. tostring(err))
        return false
    end
    app.relay = (on == true)
    app.relay_writes = app.relay_writes + 1
    return true
end

-- Read the current power mode through power.lua. Returns mode, or nil, reason.
local function readMode(app)
    if type(app.power) ~= "table" or type(app.power.read) ~= "function" then
        return nil, "no_power_module"
    end
    local ok, mode, code = pcall(app.power.read, app.power_opts)
    if not ok then return nil, "read_error" end
    if type(mode) ~= "number" then
        return nil, tostring(code or "read_fail")
    end
    return mode
end
M.readMode = readMode

-- Switch the power mode for an alarm. Called once per excursion, on the alarm
-- sample only. Returns true when power.lua actually rewrote the mode; an
-- already-in-target mode is a logged noop, not a write.
function M.switchPower(app, reason, level)
    local cfg = app.state.cfg
    local target = cfg.switch_to
    if type(app.power) ~= "table" or type(app.power.apply) ~= "function" then
        app.logger.warn("WATCHDOG_SWITCH_FAIL reason=no_power_module")
        return false
    end
    local current, code = readMode(app)
    if current == nil then
        app.logger.warn("WATCHDOG_SWITCH_FAIL reason=read_fail code=" ..
            tostring(code))
        return false
    end
    app.last_mode = current
    if current == target then
        app.logger.info("WATCHDOG_SWITCH to=" .. fmt(target) .. " noop")
        return false
    end
    local ok, applied, err = pcall(app.power.apply, target, app.power_opts)
    if not ok or not applied then
        local why = err
        if not ok then why = applied end
        app.logger.warn("WATCHDOG_SWITCH_FAIL reason=write_failed code=" ..
            tostring(why))
        return false
    end
    app.switched = true
    app.switch_from = current
    app.switch_target = target
    app.switches = app.switches + 1
    app.last_mode = target
    app.logger.info("WATCHDOG_SWITCH from=" .. fmt(current) ..
        " to=" .. fmt(target) .. " reason=" .. tostring(reason) ..
        " level=" .. fmt(level))
    return true
end

-- Restore the pre-alarm mode on recovery (once, on the clear sample only).
-- watchdog.restore=false keeps the backup mode instead.
function M.restorePower(app)
    local cfg = app.state.cfg
    if app.switched ~= true or app.switch_from == nil then
        app.logger.info("WATCHDOG_RESTORE_SKIP reason=no_switch")
        return false
    end
    if cfg.restore ~= true then
        app.switched = false
        app.switch_from = nil
        app.switch_target = nil
        app.logger.info("WATCHDOG_RESTORE_SKIP reason=restore_disabled")
        return false
    end
    if type(app.power) ~= "table" or type(app.power.apply) ~= "function" then
        app.logger.warn("WATCHDOG_RESTORE_FAIL reason=no_power_module")
        return false
    end
    local target = app.switch_from
    local current, code = readMode(app)
    if current == nil then
        app.logger.warn("WATCHDOG_RESTORE_FAIL reason=read_fail code=" ..
            tostring(code))
        return false
    end
    app.last_mode = current
    if current == target then
        app.switched = false
        app.switch_from = nil
        app.switch_target = nil
        app.logger.info("WATCHDOG_RESTORE to=" .. fmt(target) .. " noop")
        return false
    end
    local ok, applied, err = pcall(app.power.apply, target, app.power_opts)
    if not ok or not applied then
        local why = err
        if not ok then why = applied end
        app.logger.warn("WATCHDOG_RESTORE_FAIL reason=write_failed code=" ..
            tostring(why))
        return false
    end
    app.switched = false
    app.switch_from = nil
    app.switch_target = nil
    app.last_mode = target
    app.restores = app.restores + 1
    app.logger.info("WATCHDOG_RESTORE to=" .. fmt(target))
    return true
end

-- One poll cycle: read the level, advance the state machine, log and relay.
-- Returns event, info (see watchdog.sample for the event names, plus
-- "read_fail" when the sensor could not be read).
function M.tick(app, now)
    local state = app.state
    if state.cfg.enabled ~= true then
        app.status = "disabled"
        return "disabled", { reason = "disabled" }
    end

    local at = now
    if at == nil then at = app.clock() end

    app.polls = app.polls + 1
    local okRead, first, second = pcall(app.read)
    local level, readErr
    if okRead then
        level, readErr = first, second
    else
        level, readErr = nil, tostring(first)
    end
    if type(level) ~= "number" then
        app.read_errors = app.read_errors + 1
        if app.read_errors == 1 or app.read_errors % 60 == 0 then
            app.logger.warn("WATCHDOG_READ_FAIL side=" ..
                tostring(state.cfg.input_side) .. " errors=" ..
                tostring(app.read_errors) .. " err=" .. tostring(readErr))
        end
        return "read_fail", { errors = app.read_errors, err = readErr }
    end

    local event, info = app.watchdog.sample(state, level, at)
    if event == "alarm" then
        local sustained = 0
        if type(info) == "table" and type(info.sustained) == "number" then
            sustained = info.sustained
        end
        M.applyAlarm(app, true)
        app.logger.error(string.format(
            "WATCHDOG_ALARM side=%s level=%s low=%s high=%s window=%s sustained=%s",
            tostring(state.cfg.alarm_side), fmt(level), fmt(state.cfg.low),
            fmt(state.cfg.high), fmt(state.cfg.window), fmt(sustained)))
        M.switchPower(app, "low", level)
    elseif event == "clear" then
        local held = 0
        if type(info) == "table" and type(info.held) == "number" then
            held = info.held
        end
        M.applyAlarm(app, false)
        app.logger.info("WATCHDOG_CLEAR level=" .. fmt(level) ..
            " held=" .. fmt(held) .. " alarms=" .. tostring(state.alarms))
        M.restorePower(app)
    end
    return event, info
end

-- Main loop: arm, then tick every poll seconds. Only returns when the watchdog
-- is disabled.
function M.run(app)
    local mode = M.start(app)
    if mode ~= "running" then
        return app, mode
    end
    local poll = app.state.cfg.poll
    while true do
        M.tick(app, app.clock())
        app.sleep(poll)
    end
end

-- One-line status including the driver side (relay state, poll counters).
function M.statusLine(app)
    local state, text = app.watchdog.status(app.state)
    text = text .. " status=" .. tostring(app.status) ..
        " relay=" .. (app.relay and "on" or "off") ..
        " mode=" .. fmt(app.last_mode) ..
        " switches=" .. tostring(app.switches) ..
        " restores=" .. tostring(app.restores) ..
        " polls=" .. tostring(app.polls) ..
        " read_fail=" .. tostring(app.read_errors)
    return text, state
end

function M.report(app)
    local text = M.statusLine(app)
    app.logger.info("WATCHDOG_STATUS " .. text)
    return text
end

-- Only autostart when this very file is the program being run. dofile/require
-- from another program (the controller, the offline suite) just gets the table.
local function isMainProgram()
    if _G.POWERGRID_WATCHDOG_TEST then return false end
    local args = _G.arg
    if type(args) ~= "table" or type(args[0]) ~= "string" then return false end
    if type(_G.shell) ~= "table" or type(_G.shell.getRunningProgram) ~= "function" then
        return false
    end
    local ok, running = pcall(_G.shell.getRunningProgram)
    if not ok or type(running) ~= "string" then return false end
    if running ~= args[0] then return false end
    return running:find("watchdog_app", 1, true) ~= nil
end
M.isMainProgram = isMainProgram

if isMainProgram() then
    local okNew, app = pcall(M.new, {})
    if not okNew then
        if type(print) == "function" then
            pcall(print, "watchdog_app: cannot start: " .. tostring(app))
        end
    else
        local okRun, err = pcall(M.run, app)
        if not okRun then
            pcall(app.logger.error, "WATCHDOG_CRASH " .. tostring(err))
            if type(print) == "function" then
                pcall(print, "watchdog_app stopped: " .. tostring(err))
            end
        end
    end
end

return M
