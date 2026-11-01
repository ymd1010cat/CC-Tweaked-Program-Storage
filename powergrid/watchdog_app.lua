-- watchdog_app.lua - runtime driver for watchdog.lua
--
-- Monitor only. This program samples a redstone level, feeds watchdog.lua and
-- drives an alarm relay (plus the logger). It does not switch the power source
-- and does not touch the controller's config file: automatic transfer
-- switching (ATS) is deliberately out of scope for this project.
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
--   WATCHDOG_CONFIG_BAD one line per rejected setting (default is used)
--   WATCHDOG_READ_FAIL  the sensor could not be read (first failure, then 1/60)
--   WATCHDOG_RELAY_FAIL the alarm side could not be driven
--   WATCHDOG_STATUS     status snapshot on demand
--   WATCHDOG_CRASH      the main loop died

local M = {}

M.VERSION = "1.0"

-- settings keys (CraftOS `set` command, per computer). The controller's own ini
-- file stays the single 0-3 value it always was.
M.KEYS = {
    enabled = "powergrid.watchdog.enabled",
    low = "powergrid.watchdog.low",
    high = "powergrid.watchdog.high",
    window = "powergrid.watchdog.window",
    poll = "powergrid.watchdog.poll",
    input_side = "powergrid.watchdog.input_side",
    alarm_side = "powergrid.watchdog.alarm_side",
}

local NULL_LOGGER = {}
function NULL_LOGGER.write() return false end
function NULL_LOGGER.info() return false end
function NULL_LOGGER.warn() return false end
function NULL_LOGGER.error() return false end
function NULL_LOGGER.debug() return false end
M.NULL_LOGGER = NULL_LOGGER

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

-- Read the raw option table out of CraftOS settings. Returns raw, usedApi.
function M.readConfig(settingsApi, keys)
    local raw = {}
    local api = settingsApi
    if api == nil then api = _G.settings end
    local map = keys or M.KEYS
    if type(api) ~= "table" or type(api.get) ~= "function" then
        return raw, false
    end
    for field, key in pairs(map) do
        local ok, value = pcall(api.get, key)
        if ok and value ~= nil then raw[field] = value end
    end
    return raw, true
end

-- Build the app. opts:
--   config   raw watchdog options (skips the settings read when given)
--   settings settings API override (default _G.settings)
--   watchdog watchdog module (default require/dofile watchdog.lua)
--   logger   logger module (default require/dofile logger.lua, else no-op)
--   redstone redstone API (default _G.redstone)
--   read     function() -> level[, err] (default: analog input of input_side)
--   clock    function() -> seconds (default os.clock)
--   sleep    function(seconds) (default os.sleep)
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

    local config = opts.config
    if type(config) ~= "table" then
        config = M.readConfig(opts.settings)
    end

    local redstone = opts.redstone
    if redstone == nil then redstone = _G.redstone end

    local state = wd.new(config)
    local app = {
        version = M.VERSION,
        watchdog = wd,
        logger = log,
        redstone = redstone,
        clock = opts.clock or defaultClock,
        sleep = opts.sleep or defaultSleep,
        state = state,
        status = "new",
        started = false,
        polls = 0,
        read_errors = 0,
        relay = false,
        relay_writes = 0,
    }
    if opts.read ~= nil then
        app.read = opts.read
    else
        app.read = makeReader(redstone, state.cfg.input_side)
    end
    return app
end

-- Arm the monitor: log rejected settings, the start line, and put the relay in
-- its safe state. Returns "running" or "disabled".
function M.start(app)
    local state = app.state
    local problems = state.problems or {}
    for i = 1, #problems do
        app.logger.warn("WATCHDOG_CONFIG_BAD " .. tostring(problems[i]))
    end
    if state.cfg.enabled ~= true then
        app.status = "disabled"
        app.started = true
        app.logger.warn("WATCHDOG_DISABLED reason=config")
        return "disabled"
    end
    app.logger.info(string.format(
        "WATCHDOG_START input=%s alarm=%s low=%s high=%s window=%s poll=%s",
        tostring(state.cfg.input_side), tostring(state.cfg.alarm_side),
        fmt(state.cfg.low), fmt(state.cfg.high), fmt(state.cfg.window),
        fmt(state.cfg.poll)))
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
    elseif event == "clear" then
        local held = 0
        if type(info) == "table" and type(info.held) == "number" then
            held = info.held
        end
        M.applyAlarm(app, false)
        app.logger.info("WATCHDOG_CLEAR level=" .. fmt(level) ..
            " held=" .. fmt(held) .. " alarms=" .. tostring(state.alarms))
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
