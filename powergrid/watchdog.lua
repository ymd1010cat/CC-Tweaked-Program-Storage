-- watchdog.lua - hysteresis watchdog state machine for the Power Grid Controller
--
-- Monitor only. This module never switches the power source; it watches a 0-15
-- redstone level and reports when that level has stayed unhealthy for long
-- enough, and when it is healthy again. Callers decide what to do with the
-- events (see watchdog_app.lua for the relay + log driver).
--
-- Pure logic: no filesystem, no logger, no game APIs and no internal clock
-- reads. The caller passes the sample and the current time in, which keeps the
-- whole state machine testable offline (powergrid/tests/t_watchdog.lua).
--
-- Zone and hysteresis rules (low=2, high=10 by default):
--   level <  low          low zone    -> the degraded streak runs from here
--   low <= level < high   deadband    -> nothing changes at all (anti-flap)
--   level >= high         healthy     -> clears the alarm and the streak
--
-- The streak started by a dip below low is only cleared by reaching high, so a
-- grid that keeps bouncing inside low..high still alarms after window seconds.
-- Exactly one "alarm" event is reported per excursion; recovery reports one
-- "clear" event.

local M = {}

M.VERSION = "1.0"

M.DEFAULTS = {
    low = 2,
    high = 10,
    window = 300,
    poll = 10,
    alarm_side = "left",
    input_side = "back",
    switch_to = 2,
    restore = true,
    enabled = true,
}

M.SIDES = {
    top = true,
    bottom = true,
    left = true,
    right = true,
    front = true,
    back = true,
}

-- Largest accepted window and poll, in seconds (a week / a day).
M.MAX_WINDOW = 604800
M.MAX_POLL = 86400
M.MIN_POLL = 0.1

local function tonum(value)
    local n = tonumber(value)
    if n == nil then return nil end
    if n ~= n or n == math.huge or n == -math.huge then return nil end
    return n
end
M.tonum = tonum

local function tobool(value)
    if value == true or value == 1 then return true end
    if value == false or value == 0 then return false end
    if type(value) == "string" then
        local s = value:lower()
        if s == "true" or s == "1" or s == "yes" or s == "on" then return true end
        if s == "false" or s == "0" or s == "no" or s == "off" then return false end
    end
    return nil
end
M.tobool = tobool

local function toside(value)
    if type(value) ~= "string" then return nil end
    local s = value:lower()
    if M.SIDES[s] then return s end
    return nil
end
M.toside = toside

-- Copy a number into the greppable status text without ever tripping
-- string.format("%d", <non integer>).
local function fmt(value)
    if type(value) ~= "number" or value ~= value then return "?" end
    if value == math.floor(value) and math.abs(value) < 1e15 then
        return string.format("%d", value)
    end
    return string.format("%.1f", value)
end
M.fmt = fmt

local function flag(value)
    if value == true then return "1" end
    return "0"
end
M.flag = flag

-- Turn a raw option table (settings strings, whatever) into a trustworthy
-- config. Every rejected value is recorded in the second return value as
-- "key=value (reason)" so the driver can log one WATCHDOG_CONFIG_BAD line per
-- problem; the field itself falls back to its default, so a typo can never
-- leave the monitor half-configured.
function M.sanitize(opts)
    if type(opts) ~= "table" then opts = {} end
    local cfg = {}
    local problems = {}
    local function bad(key, value, why)
        problems[#problems + 1] = tostring(key) .. "=" .. tostring(value) ..
            " (" .. why .. ")"
    end

    if opts.enabled == nil then
        cfg.enabled = M.DEFAULTS.enabled
    else
        local b = tobool(opts.enabled)
        if b == nil then
            bad("enabled", opts.enabled, "expected true/false")
            cfg.enabled = M.DEFAULTS.enabled
        else
            cfg.enabled = b
        end
    end

    local function level(key)
        local value = opts[key]
        if value == nil then return M.DEFAULTS[key] end
        local n = tonum(value)
        if n == nil or n ~= math.floor(n) or n < 0 or n > 15 then
            bad(key, value, "expected integer 0-15")
            return M.DEFAULTS[key]
        end
        return n
    end
    cfg.low = level("low")
    cfg.high = level("high")
    if cfg.high <= cfg.low then
        problems[#problems + 1] = "high=" .. tostring(opts.high) ..
            " (must be above low=" .. tostring(opts.low) .. "; reset both)"
        cfg.low = M.DEFAULTS.low
        cfg.high = M.DEFAULTS.high
    end

    if opts.window == nil then
        cfg.window = M.DEFAULTS.window
    else
        local n = tonum(opts.window)
        if n == nil or n <= 0 or n > M.MAX_WINDOW then
            bad("window", opts.window, "expected seconds in 0.." ..
                tostring(M.MAX_WINDOW))
            cfg.window = M.DEFAULTS.window
        else
            cfg.window = n
        end
    end

    if opts.poll == nil then
        cfg.poll = M.DEFAULTS.poll
    else
        local n = tonum(opts.poll)
        if n == nil or n < M.MIN_POLL or n > M.MAX_POLL then
            bad("poll", opts.poll, "expected seconds in " .. tostring(M.MIN_POLL) ..
                ".." .. tostring(M.MAX_POLL))
            cfg.poll = M.DEFAULTS.poll
        else
            cfg.poll = n
        end
    end

    local function side(key)
        local value = opts[key]
        if value == nil then return M.DEFAULTS[key] end
        local s = toside(value)
        if s == nil then
            bad(key, value, "expected top/bottom/left/right/front/back")
            return M.DEFAULTS[key]
        end
        return s
    end
    cfg.alarm_side = side("alarm_side")
    cfg.input_side = side("input_side")

    -- Power mode to switch to when the alarm fires (0 disable, 1 main grid,
    -- 2 backup battery, 3 external). The state machine only carries the number;
    -- watchdog_app.lua turns it into a power.lua call.
    if opts.switch_to == nil then
        cfg.switch_to = M.DEFAULTS.switch_to
    else
        local n = tonum(opts.switch_to)
        if n == nil or n ~= math.floor(n) or n < 0 or n > 3 then
            bad("switch_to", opts.switch_to, "expected integer 0-3")
            cfg.switch_to = M.DEFAULTS.switch_to
        else
            cfg.switch_to = n
        end
    end

    -- Whether recovery restores the mode that was active before the alarm.
    if opts.restore == nil then
        cfg.restore = M.DEFAULTS.restore
    else
        local b = tobool(opts.restore)
        if b == nil then
            bad("restore", opts.restore, "expected true/false")
            cfg.restore = M.DEFAULTS.restore
        else
            cfg.restore = b
        end
    end

    return cfg, problems
end

-- Build a watchdog state. Invalid options fall back to their defaults and are
-- kept in w.problems / w.problem_count.
function M.new(opts)
    local cfg, problems = M.sanitize(opts)
    local w = {
        cfg = cfg,
        problems = problems,
        problem_count = #problems,
        state = "init",
        zone = "init",
        alarm = false,
        level = nil,
        low_since = nil,
        alarm_at = nil,
        alarm_level = nil,
        last_clear_at = nil,
        last_now = nil,
        checks = 0,
        alarms = 0,
        recoveries = 0,
        bad_samples = 0,
        clock_skew = 0,
    }
    return w
end

-- Advance the state machine with one reading.
--
-- Returns event, info with event one of:
--   "alarm"    the level has been below low for at least window seconds (once
--              per excursion)
--   "clear"    the level reached high again after an alarm
--   "none"     nothing to do
--   "disabled" the watchdog is switched off; nothing is sampled or counted
-- info is a small table (zone/level/sustained/since or reason) for logging.
function M.sample(w, level, now)
    if type(w) ~= "table" or type(w.cfg) ~= "table" then
        return "none", { reason = "bad_state" }
    end
    local cfg = w.cfg
    if cfg.enabled ~= true then
        w.state = "disabled"
        w.zone = "disabled"
        return "disabled", { reason = "disabled" }
    end

    local lv = tonum(level)
    if lv == nil then
        w.bad_samples = w.bad_samples + 1
        return "none", { reason = "bad_level", level = level }
    end
    local at = tonum(now)
    if at == nil then
        return "none", { reason = "bad_now" }
    end
    if w.last_now ~= nil and at < w.last_now then
        -- A clock that jumped backwards must not un-alarm or shorten a streak.
        w.clock_skew = w.clock_skew + 1
        at = w.last_now
    end

    w.checks = w.checks + 1
    w.level = lv
    w.last_now = at
    local was_alarm = w.alarm

    if lv >= cfg.high then
        w.zone = "healthy"
        w.state = "ok"
        w.low_since = nil
        if was_alarm then
            local held = 0
            if w.alarm_at ~= nil then held = at - w.alarm_at end
            w.alarm = false
            w.alarm_at = nil
            w.alarm_level = nil
            w.recoveries = w.recoveries + 1
            w.last_clear_at = at
            return "clear", { level = lv, zone = "healthy", held = held }
        end
        return "none", { level = lv, zone = "healthy" }
    elseif lv < cfg.low then
        w.zone = "low"
        if w.low_since == nil then w.low_since = at end
        local sustained = at - w.low_since
        if w.alarm then
            return "none", { level = lv, zone = "low", since = w.low_since,
                sustained = sustained, alarm = true }
        end
        w.state = "low"
        if sustained >= cfg.window then
            w.alarm = true
            w.alarm_at = at
            w.alarm_level = lv
            w.alarms = w.alarms + 1
            w.state = "alarm"
            return "alarm", { level = lv, zone = "low", since = w.low_since,
                sustained = sustained, window = cfg.window }
        end
        return "none", { level = lv, zone = "low", since = w.low_since,
            sustained = sustained }
    else
        -- Deadband: deliberately no state change. The streak keeps running and
        -- a latched alarm stays latched until a healthy sample clears it.
        w.zone = "deadband"
        local sustained = 0
        if w.low_since ~= nil then sustained = at - w.low_since end
        return "none", { level = lv, zone = "deadband", since = w.low_since,
            sustained = sustained, alarm = w.alarm }
    end
end

-- Snapshot for screens/logs. Returns the table plus a one-line, greppable
-- summary ("WATCHDOG state=... zone=... alarm=... ...").
function M.status(w)
    local source = w
    if type(source) ~= "table" then source = {} end
    local cfg = source.cfg
    if type(cfg) ~= "table" then cfg = M.DEFAULTS end

    local low_for = 0
    if type(source.low_since) == "number" and type(source.last_now) == "number" then
        low_for = source.last_now - source.low_since
        if low_for < 0 then low_for = 0 end
    end

    local s = {
        version = M.VERSION,
        state = source.state or "init",
        zone = source.zone or "init",
        alarm = source.alarm == true,
        enabled = cfg.enabled == true,
        level = source.level,
        low = cfg.low,
        high = cfg.high,
        window = cfg.window,
        poll = cfg.poll,
        alarm_side = cfg.alarm_side,
        input_side = cfg.input_side,
        switch_to = cfg.switch_to,
        restore = cfg.restore == true,
        low_since = source.low_since,
        low_for = low_for,
        alarm_at = source.alarm_at,
        last_clear_at = source.last_clear_at,
        last_now = source.last_now,
        checks = source.checks or 0,
        alarms = source.alarms or 0,
        recoveries = source.recoveries or 0,
        bad_samples = source.bad_samples or 0,
        clock_skew = source.clock_skew or 0,
        problems = source.problems or {},
    }

    local text = string.format(
        "WATCHDOG state=%s zone=%s alarm=%s enabled=%s level=%s low=%s high=%s " ..
        "window=%s low_for=%s checks=%s alarms=%s recoveries=%s " ..
        "switch_to=%s restore=%s",
        s.state, s.zone, flag(s.alarm), flag(s.enabled), fmt(s.level),
        fmt(s.low), fmt(s.high), fmt(s.window), fmt(math.floor(low_for)),
        fmt(s.checks), fmt(s.alarms), fmt(s.recoveries),
        fmt(s.switch_to), flag(s.restore))
    return s, text
end

return M
