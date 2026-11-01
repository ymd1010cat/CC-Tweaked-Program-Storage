--[[- pyroet-os/system/kernel/desktop.lua -- the resident desktop: one event loop, one dispatcher.

The boot chain used to end at `STARTUP_COMMITTED` and return, which dropped the
machine straight back to the CraftOS shell: the launcher painted exactly one
frame and nobody was listening to the keyboard afterwards. This module is the
missing half -- the thing that owns the machine after the first frame.

Ownership split (DECISIONS.md 20):

  * this module owns the ONE blocking pull (`opts.pullEvent`, the ROM's
    `os.pullEvent` on a real boot). Nothing else in the system blocks on it, so
    a machine with no events sleeps in `os.pullEvent` instead of spinning;
  * the raw event is normalized into a small vocabulary and pushed into the
    input queue the app runtime was built with (`opts.input.push`), then the
    scheduler gets exactly one step (`rt:tick()`);
  * the foreground app pulls it through `api.input.pullEvent()` (a queue pop:
    `nil` means "nothing delivered yet, yield") -- so an app never blocks the
    machine inside somebody else's event source.

Normalization: a `key` event is delivered as `("key", "<name>")` using the
ROM's `keys` table, because an app should not have to know that `up` is a
number. Everything else is passed through untouched, so an interactive app can
still see `mouse_click`, `term_resize`, `rednet_message` or `peripheral`. An
unmapped keycode is delivered as the number, which no app has to understand.

Foreground: the desktop app (`opts.name`, the launcher) unless another app that
declares `input` started during the step -- then the keyboard is handed to that
app (the launcher started a full-screen application), and handed back when it
stops. `DESKTOP_FOREGROUND` records each handover.

Parking (D1-fix): an app that was started during the step and does NOT declare
`input` can never become the foreground, so it is parked (`DESKTOP_PARK`,
handed to `rt:tick` as a skip map). It stays `running` but never gets a time
slice, because a time slice is all a launched app needs to paint over a console
it does not own: on the real machine the image's `installer` (started by a stray
Enter) repainted its own `s <pkg>` frame on every tick the launcher did not
repaint on -- the `key_up` after each key press -- which looked like "an S in
front of every row" plus "the selection does not move". A desktop is one screen
and one keyboard; background work belongs to a kernel service, not to a launched
app.

Exit semantics: the loop ends when
  * an app the dispatcher is following returns from its body -- `"quit"` gives
    `reason=quit`, anything else is reported back verbatim, and a crash is
    `reason=crash`. The desktop app leaving the scheduler is what ends the
    desktop;
  * the event is `terminate` / `shutdown` (Ctrl+T), which the dispatcher handles
    itself and never hands to an app;
  * `opts.max_events` is reached (tests only: a real desktop has no limit);
  * there is nothing to drive it (no runtime, no pull source, no input queue):
    `DESKTOP_SKIP`, never a crash -- the boot chain logs `STARTUP_DESKTOP_SKIP`
    and returns, which is what a machine without a launcher does.

Every decision is one ASCII log line (`DESKTOP_*`), one pull is one tick, and a
return of `"quit"` means "the caller may fall back to the shell". The module
never calls `os.shutdown`, `os.reboot` or `shell`; unwinding is the boot
chain's business.

Usage:

    local desktop = dofile("/system/kernel/desktop.lua")
    local d = desktop.new({ rt = rt, input = host, pullEvent = os.pullEvent,
                            name = "launcher", log = print })
    local reason = d:run()          -- blocks; "quit" / "terminate" / "limit" / "skip"

No non-ASCII bytes in this file.
]]

local D = {}

D.VERSION = "1.0"

-- the keys an app may see by name, in priority order (a keys table can map one
-- code to several names; the first name in this list wins)
D.KEY_NAMES = { "up", "down", "left", "right", "enter", "escape", "backspace",
    "tab", "delete", "space" }

-- The ROM's `keys` table has no `escape` entry (Minecraft intercepts that key),
-- but a terminal emulator can still deliver it, and the key events carry GLFW
-- key codes. 256 is GLFW's escape; mapping it defensively costs one line and
-- gives the desktop a third exit next to `q` and Ctrl+T (`terminate`).
D.ESCAPE_CODE = 256

-- how long a screen loan may last, in seconds, when the app declared no `input`
-- (it can never hand the screen back itself) and does not stop on its own
D.LOAN_SECONDS = 15
-- fallback bound for a machine whose event source cannot start a timer: after
-- this many events the loan ends anyway (never a dead end)
D.LOAN_EVENTS = 40
-- hard caps (D1-fix round 5): whatever happens, a loan ends. Hitting one of these
-- is a bug-worthy event, so it gets its own line: DESKTOP_LOAN_ABORT.
D.LOAN_ABORT_EVENTS = 200
D.LOAN_ABORT_SECONDS = 60

local function short(value, max)
    local s = tostring(value == nil and "nil" or value)
    s = s:gsub("[\r\n\t]+", " ")
    s = s:gsub("[^%w%._%-:=/ ]", "_")
    max = max or 60
    if #s > max then s = s:sub(1, max) end
    if s == "" then s = "-" end
    return s
end

local function count(map)
    local n = 0
    for _ in pairs(map or {}) do n = n + 1 end
    return n
end

local function declares(record, cap)
    local caps = record and record.manifest and record.manifest.capabilities
    if type(caps) ~= "table" then return false end
    for i = 1, #caps do
        if caps[i] == cap then return true end
    end
    return false
end

-- keycode -> name, from the ROM's keys table (nil keys table = no names)
function D.key_map(keysx)
    local out = {}
    if type(keysx) ~= "table" then return out end
    for i = 1, #D.KEY_NAMES do
        local name = D.KEY_NAMES[i]
        local code = keysx[name]
        if type(code) == "number" and out[code] == nil then out[code] = name end
    end
    for name, code in pairs(keysx) do
        if type(name) == "string" and type(code) == "number" and out[code] == nil then
            out[code] = name
        end
    end
    return out
end

-- does this app want the keyboard? (declared, not granted: a denied app still
-- gets the events and answers `capability denied` from its own api)
function D.takes_input(record)
    return declares(record, "input")
end

function D.new(opts)
    local o = opts or {}
    local self = setmetatable({}, { __index = D })
    self.rt = o.rt
    self.kernel = o.kernel
    self.input = o.input
    self.pull = o.pullEvent or o.pull
    self.sink = o.log
    self.name = tostring(o.name or "launcher")
    self.max_events = o.max_events
    self.key_names = D.key_map(o.keys or (type(o.input) == "table" and o.input.keys))
    self.logs = {}
    self.pulled = 0
    self.delivered = 0
    self.ticked = 0
    self.handovers = 0
    self.foreground = self.name
    -- apps the desktop parked: launched, the loan is over (or they never had a
    -- screen), and they are frozen so they can never paint over the desktop
    self.parked = {}
    self.parked_count = 0
    -- the one screen loan in flight (see D:loan_start)
    self.loan = nil
    self.loans = 0
    self.loan_ends = 0
    self.loan_seconds = o.loan_seconds
    self.loan_events = o.loan_events
    if self.loan_seconds == nil then self.loan_seconds = D.LOAN_SECONDS end
    self.start_timer = o.startTimer
    self.clock = o.clock
    self.loan_abort_events = o.loan_abort_events
    self.loan_abort_seconds = o.loan_abort_seconds
    self.reason = nil
    self.exited = false
    return self
end

-- ---------------------------------------------------------------------------
-- logging / state
-- ---------------------------------------------------------------------------

function D:log(line)
    line = tostring(line)
    self.logs[#self.logs + 1] = line
    if self.sink then pcall(self.sink, line) end
    return line
end

function D:count_log(fragment)
    local n = 0
    local needle = tostring(fragment)
    for i = 1, #self.logs do
        if self.logs[i]:find(needle, 1, true) then n = n + 1 end
    end
    return n
end

function D:state()
    return {
        version = D.VERSION,
        name = self.name,
        pulled = self.pulled,
        delivered = self.delivered,
        ticked = self.ticked,
        handovers = self.handovers,
        foreground = self.foreground,
        parked = self.parked_count,
        loans = self.loans,
        loan_ends = self.loan_ends,
        loan = self.loan and self.loan.name or nil,
        reason = self.reason,
        exited = self.exited,
    }
end

-- ---------------------------------------------------------------------------
-- the app runtime as name -> running app / running input app maps
-- ---------------------------------------------------------------------------

function D:running_all()
    local out = {}
    local rt = self.rt
    if type(rt) ~= "table" or type(rt.status) ~= "function" then return out end
    local ok, status = pcall(rt.status, rt)
    if not ok or type(status) ~= "table" then return out end
    local apps = status.apps or {}
    for i = 1, #apps do
        local entry = apps[i]
        if type(entry) == "table" and entry.name ~= nil and entry.state == "running" then
            out[entry.name] = entry
        end
    end
    return out
end

function D.has_cap(entry, cap)
    local caps = type(entry) == "table" and entry.capabilities or nil
    for i = 1, #(caps or {}) do
        if caps[i] == cap then return true end
    end
    return false
end

function D:running_inputs()
    local out = {}
    local all = self:running_all()
    for name, entry in pairs(all) do
        if D.has_cap(entry, "input") then out[name] = entry end
    end
    return out
end

-- the most recently started candidate; `prefer` wins a tie so the current
-- foreground keeps the keyboard when nothing actually changed
function D:pick(set, prefer)
    local best, best_starts = nil, -1
    for name, entry in pairs(set) do
        local starts = tonumber(entry.starts) or 0
        if starts > best_starts or (starts == best_starts and name == prefer) then
            best, best_starts = name, starts
        end
    end
    return best
end

-- ---------------------------------------------------------------------------
-- the loop
-- ---------------------------------------------------------------------------

function D:ready()
    if type(self.rt) ~= "table" then return false, "no_runtime" end
    if type(self.pull) ~= "function" then return false, "no_pull_source" end
    if type(self.input) ~= "table" or type(self.input.push) ~= "function" then
        return false, "no_input_queue"
    end
    return true, "ok"
end

-- exactly one blocking pull per iteration: this is the sleep of the whole
-- machine, so there must be no path that loops without pulling
function D:pull_once()
    local ok, event, p1, p2, p3 = pcall(self.pull)
    if not ok then
        self:log("DESKTOP_PULL_FAIL err=" .. short(event))
        return "terminate", "pull_failed", tostring(event)
    end
    return event, p1, p2, p3
end

function D:deliver(event, p1, p2, p3)
    local ok, err = pcall(self.input.push, event, p1, p2, p3)
    if not ok then
        self:log("DESKTOP_DELIVER_FAIL err=" .. short(err))
        return false
    end
    self.delivered = self.delivered + 1
    return true
end

function D:tick()
    if type(self.rt.tick) ~= "function" then return false end
    self.ticked = self.ticked + 1
    -- parked apps are handed to the scheduler as a skip map: they stay running
    -- but never get a time slice, so they cannot paint over the foreground
    local skip = {}
    for name in pairs(self.parked) do skip[name] = true end
    -- exactly one app owns the console: the loaned app during a loan, else the
    -- foreground app. Every other app is left unscheduled, which is what stops
    -- the two failures of round 3 from coming back: a background app painting
    -- over the screen, and the launcher (record #1) draining the one shared
    -- input queue before the app that actually owns the keyboard reads it.
    local owner = self.foreground
    if self.loan ~= nil then owner = self.loan.name end
    if owner ~= nil and owner ~= self.name then
        local all = self:running_all()
        for name in pairs(all) do
            if name ~= owner then skip[name] = true end
        end
    end
    local ok, advanced = pcall(self.rt.tick, self.rt, skip)
    if not ok then
        self:log("DESKTOP_TICK_FAIL err=" .. short(advanced))
        return false
    end
    return advanced ~= nil
end

-- ---------------------------------------------------------------------------
-- screen loans (D1-fix round 3)
-- ---------------------------------------------------------------------------
--
-- Parking made a launched app invisible, which reads as "Enter did nothing": the
-- user pressed Enter on `installer` and the screen never changed. A desktop app
-- must be *seen*. The rule now is:
--
--   * an app that declares `input` gets the keyboard and the screen (handover);
--   * any other launched app gets a **screen loan**: it is scheduled for real,
--     the launcher is not scheduled at all (so it cannot repaint over the app),
--     its own first frame lands on the screen -- and the loan ends when the app
--     stops by itself, or, because an app without a keyboard can never hand the
--     screen back, when the loan timer fires.
--
-- The loan ends with the launcher focused again: it is told why via a
-- `desk_focus` event (`display only: <name>`), so it repaints immediately
-- instead of waiting for a key that no app is going to give it.

-- wall clock for the hard loan cap (injectable: tests drive it)
function D:now()
    local clock = self.clock
    if clock == nil then
        local osx = rawget(_G, "os")
        clock = type(osx) == "table" and osx.clock or nil
    end
    if type(clock) ~= "function" then return nil end
    local ok, value = pcall(clock)
    if ok and type(value) == "number" then return value end
    return nil
end

function D:park_one(name, reason)
    if name == nil or self.parked[name] then return false end
    self.parked[name] = true
    self.parked_count = self.parked_count + 1
    self:log("DESKTOP_PARK app=" .. short(name, 24) .. " reason=" .. short(reason, 16))
    return true
end

function D:loan_start(name)
    if name == nil then return false end
    if self.loan ~= nil then self:loan_end("replaced") end
    local all = self:running_all()
    local entry = all[name]
    self.loan = { name = name, timer = nil, events = 0, started = self:now() }
    self.loans = self.loans + 1
    self:log("DESKTOP_LOAN app=" .. short(name, 24) .. " reason=no_input"
        .. " caps=" .. tostring(#((entry and entry.capabilities) or {})))
    -- bound the loan: without a keyboard the app can never hand the screen back,
    -- so a timer (and, as a fallback, an event count) guarantees the machine is
    -- not stuck on a frame nobody can leave
    if type(self.start_timer) == "function" and (self.loan_seconds or 0) > 0 then
        local called, id = pcall(self.start_timer, self.loan_seconds)
        if called and id ~= nil then
            self.loan.timer = id
            self:log("DESKTOP_LOAN_TIMER id=" .. short(id, 12)
                .. " seconds=" .. tostring(self.loan_seconds))
        elseif called then
            -- the source answered "no timer": no bounded loan is possible
            self:log("DESKTOP_LOAN_TIMER_SKIP reason=no_timer")
        else
            self:log("DESKTOP_LOAN_TIMER_FAIL err=" .. short(id, 40))
        end
    else
        self:log("DESKTOP_LOAN_TIMER_SKIP reason=no_timer")
    end
    if self.loan.timer == nil then
        -- no timer means no bounded loan: parking the app (and telling the
        -- desktop why) is the only guaranteed way back to a usable screen
        self:log("DESKTOP_LOAN_ABORT app=" .. short(name, 24) .. " reason=no_timer")
        self.loan = nil
        self.loan_ends = self.loan_ends + 1
        self:park_one(name, "no_timer")
        self.foreground = self.name
        self:deliver("desk_focus", "display only: " .. name)
        self:tick()
        return false
    end
    -- draw the app's first frame now: "started" on the launcher's hint row is
    -- not the same as the app being visible
    self:tick()
    return true
end

function D:loan_end(reason)
    if self.loan == nil then return false end
    local name = self.loan.name
    self.loan = nil
    self.loan_ends = self.loan_ends + 1
    -- parked *after* the loan, never during it: frozen, so it cannot paint again
    self:park_one(name, "loan_over")
    self:log("DESKTOP_LOAN_END app=" .. short(name, 24) .. " reason=" .. short(reason, 16))
    self.foreground = self.name
    self.handovers = self.handovers + 1
    self:log("DESKTOP_FOREGROUND app=" .. short(self.name, 24) .. " reason=loan_end")
    -- the launcher gets the screen back: push the reason and step it once so the
    -- desktop frame is actually on screen when the loan ends
    self:deliver("desk_focus", "display only: " .. name)
    self:tick()
    return true
end

-- a loan ends when the app stops by itself (its body returned)
function D:loan_stopped()
    if self.loan == nil then return false end
    local all = self:running_all()
    if all[self.loan.name] == nil then return self:loan_end("stopped") end
    return false
end

-- apps that started during this step: an input app is the handover path, every
-- other one takes a screen loan
function D:launched(before_all)
    if self.loan ~= nil then return nil end
    local after = self:running_all()
    local names = {}
    for name in pairs(after) do
        if before_all[name] == nil and name ~= self.name and not self.parked[name] then
            names[#names + 1] = name
        end
    end
    table.sort(names)
    for i = 1, #names do
        local entry = after[names[i]]
        if not D.has_cap(entry, "input") then
            self:loan_start(names[i])
            return names[i]
        end
    end
    return nil
end

function D.normalize(self, event, p1, p2, p3)
    if event == nil then return "none", nil, nil, nil end
    if event == "key" then
        local name = self.key_names[p1]
        if type(name) == "string" then return "key", name, p2, p3 end
        -- the ROM has no `keys.escape`; a terminal that delivers it still sends
        -- the GLFW code, so one number is accepted by name (D.ESCAPE_CODE)
        if p1 == D.ESCAPE_CODE then return "key", "escape", p2, p3 end
    end
    return event, p1, p2, p3
end

-- the app is gone: say why, in words the boot chain can log
function D:detach_reason()
    local rt = self.rt
    if type(rt) ~= "table" or type(rt.app) ~= "function" then return "gone" end
    local ok, record = pcall(rt.app, rt, self.name)
    if not ok or type(record) ~= "table" then return "gone" end
    if record.state == "crashed" then return "crash" end
    if record.result == "quit" then return "quit" end
    if record.result == nil then return "exit" end
    return short(record.result, 24)
end

-- runs after the tick: did the desktop leave, who owns the keyboard, and did a
-- launched app have to be parked (it can never own the console)
function D:settle(before)
    local after = self:running_inputs()

    if not after[self.name] then
        local reason = self:detach_reason()
        self:log("DESKTOP_DETACH app=" .. short(self.name, 24)
            .. " reason=" .. short(reason, 24))
        return true, reason
    end

    -- the screen loan (if any) ended because the app itself stopped
    if self.loan ~= nil then
        self:loan_stopped()
        return false
    end

    -- an app that declared input started during this step: the launcher just
    -- started a full-screen app, so the keyboard follows it
    local newcomer = nil
    for name in pairs(after) do
        if before[name] == nil then newcomer = name break end
    end
    if newcomer ~= nil and newcomer ~= self.foreground then
        self.foreground = newcomer
        self.handovers = self.handovers + 1
        self:log("DESKTOP_FOREGROUND app=" .. short(newcomer, 24) .. " reason=launch")
        return false
    end

    if after[self.foreground] == nil then
        local lost = self.foreground
        local pick = self:pick(after, self.foreground)
        if pick == nil then
            self:log("DESKTOP_DETACH app=" .. short(self.foreground, 24) .. " reason=no_app")
            return true, "no_app"
        end
        self.foreground = pick
        self.handovers = self.handovers + 1
        self:log("DESKTOP_FOREGROUND app=" .. short(pick, 24) .. " reason=settle")
        -- the app that had the screen is gone (it returned "quit" or stopped):
        -- whoever takes the screen back has to be told, or the dead app's last
        -- frame stays on screen and the keyboard looks dead until a key arrives
        if pick == self.name then
            self:deliver("desk_focus", "back from " .. tostring(lost))
            self:tick()
        end
    end
    return false
end

function D:dispatch(event, p1, p2, p3)
    if event == nil then
        -- a pull source that answers nothing is not an event: no delivery, no
        -- scheduler step (a real os.pullEvent blocks instead of doing this)
        self:log("DESKTOP_EVENT n=" .. tostring(self.pulled) .. " event=none app=-")
        return false
    end
    local name, a1, a2, a3 = D.normalize(self, event, p1, p2, p3)
    if name == "terminate" or name == "shutdown" then
        -- Ctrl+T is the only way out of the desktop, but it is scoped: while an
        -- app owns the console it means "leave this app" (the same event the
        -- app's own quit path uses), and only on the desktop does it leave the
        -- whole system for the CraftOS shell.
        if self.loan ~= nil then
            self:log("DESKTOP_TERMINATE scope=app app=" .. short(self.loan.name, 24)
                .. " event=" .. short(name, 16))
            self:loan_end("terminate")
            return false
        end
        if self.foreground ~= self.name then
            local before = self:running_inputs()
            self:log("DESKTOP_TERMINATE scope=app app=" .. short(self.foreground, 24)
                .. " event=" .. short(name, 16))
            self:deliver(name, p1, p2, p3)
            self:tick()
            return self:settle(before)
        end
        self:log("DESKTOP_TERMINATE scope=desktop event=" .. short(name, 16))
        self:log("DESKTOP_EVENT n=" .. tostring(self.pulled) .. " event="
            .. short(name, 16) .. " app=-")
        return true, "terminate"
    end

    -- the loan timer: a loaned app has no keyboard, so this is how the screen
    -- comes back to the desktop when the app never stops on its own
    if self.loan ~= nil and name == "timer" then
        local timer = self.loan.timer
        local mine = (timer == nil) or (a1 == timer)
        if mine then
            self:log("DESKTOP_EVENT n=" .. tostring(self.pulled) .. " event=timer"
                .. " arg=" .. short(a1, 20) .. " app=" .. short(self.loan.name, 24))
            self:loan_end("timeout")
            return false
        end
    end

    -- a loan is in flight: the loaned app owns the screen and has no keyboard,
    -- so the event is not delivered to anyone (it is logged, never silent)
    if self.loan ~= nil then
        self:log("DESKTOP_EVENT n=" .. tostring(self.pulled) .. " event=" .. short(name, 16)
            .. " arg=" .. short(a1, 20) .. " app=-")
        self:tick()
        if self:loan_stopped() then return false end
        -- fallback bound: a handful of events is also enough to end a loan when
        -- the ROM has no startTimer (the timer is the primary one)
        self.loan.events = (self.loan.events or 0) + 1
        if self.loan.events >= (self.loan_events or D.LOAN_EVENTS) then
            self:loan_end("events")
            return false
        end
        -- hard caps: steps or wall clock. A loan that hits one of these was not
        -- ending on its own, which is exactly what DESKTOP_LOAN_ABORT records.
        local abort = nil
        if self.loan.events >= (self.loan_abort_events or D.LOAN_ABORT_EVENTS) then
            abort = "events"
        elseif self.loan.started ~= nil then
            local now = self:now()
            if now ~= nil
                and (now - self.loan.started) >= (self.loan_abort_seconds
                    or D.LOAN_ABORT_SECONDS) then
                abort = "clock"
            end
        end
        if abort ~= nil then
            self:log("DESKTOP_LOAN_ABORT app=" .. short(self.loan.name, 24)
                .. " reason=" .. abort .. " steps=" .. tostring(self.loan.events))
            self:loan_end("abort")
        end
        return false
    end

    local before = self:running_inputs()
    local before_all = self:running_all()
    local target = self.foreground
    if before[target] == nil then
        target = self:pick(before, target)
        if target ~= nil then
            self.foreground = target
            self.handovers = self.handovers + 1
            self:log("DESKTOP_FOREGROUND app=" .. short(target, 24) .. " reason=resume")
        end
    end
    if target == nil then
        self:log("DESKTOP_EVENT n=" .. tostring(self.pulled) .. " event="
            .. short(name, 16) .. " app=-")
        return true, "no_app"
    end
    self:log("DESKTOP_EVENT n=" .. tostring(self.pulled) .. " event=" .. short(name, 16)
        .. " arg=" .. short(a1, 20) .. " app=" .. short(target, 24))
    self:deliver(name, a1, a2, a3)
    self:tick()
    -- an app started during this tick either takes the keyboard (handover) or
    -- the screen (loan); the launcher is never left thinking it still owns it
    self:launched(before_all)
    return self:settle(before)
end

function D:run()
    local ready, why = self:ready()
    if not ready then
        self.reason = why
        self.exited = true
        self:log("DESKTOP_SKIP reason=" .. short(why, 24))
        return why
    end
    self:log("DESKTOP_ENTRY app=" .. short(self.name, 24)
        .. " keys=" .. tostring(count(self.key_names)))
    while not self.exited do
        if self.max_events and self.pulled >= self.max_events then
            self.reason = "limit"
            break
        end
        local event, p1, p2, p3 = self:pull_once()
        self.pulled = self.pulled + 1
        local quit, reason = self:dispatch(event, p1, p2, p3)
        if quit then
            self.reason = reason or "quit"
            break
        end
    end
    self.exited = true
    self:log("DESKTOP_EXIT reason=" .. short(self.reason, 24)
        .. " pulled=" .. tostring(self.pulled)
        .. " ticks=" .. tostring(self.ticked)
        .. " delivered=" .. tostring(self.delivered))
    return self.reason
end

return D
