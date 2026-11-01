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
        reason = self.reason,
        exited = self.exited,
    }
end

-- ---------------------------------------------------------------------------
-- the app runtime as a name -> running input app map
-- ---------------------------------------------------------------------------

function D:running_inputs()
    local out = {}
    local rt = self.rt
    if type(rt) ~= "table" or type(rt.status) ~= "function" then return out end
    local ok, status = pcall(rt.status, rt)
    if not ok or type(status) ~= "table" then return out end
    local apps = status.apps or {}
    for i = 1, #apps do
        local entry = apps[i]
        if type(entry) == "table" and entry.name ~= nil and entry.state == "running" then
            local caps = entry.capabilities
            local wants = false
            for j = 1, #(caps or {}) do
                if caps[j] == "input" then wants = true break end
            end
            if wants then out[entry.name] = entry end
        end
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
    local ok, advanced = pcall(self.rt.tick, self.rt)
    if not ok then
        self:log("DESKTOP_TICK_FAIL err=" .. short(advanced))
        return false
    end
    return advanced ~= nil
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

-- runs after the tick: did the desktop leave, and who owns the keyboard now
function D:settle(before)
    local after = self:running_inputs()

    if not after[self.name] then
        local reason = self:detach_reason()
        self:log("DESKTOP_DETACH app=" .. short(self.name, 24)
            .. " reason=" .. short(reason, 24))
        return true, reason
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
        local pick = self:pick(after, self.foreground)
        if pick == nil then
            self:log("DESKTOP_DETACH app=" .. short(self.foreground, 24) .. " reason=no_app")
            return true, "no_app"
        end
        self.foreground = pick
        self.handovers = self.handovers + 1
        self:log("DESKTOP_FOREGROUND app=" .. short(pick, 24) .. " reason=settle")
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
        self:log("DESKTOP_EVENT n=" .. tostring(self.pulled) .. " event="
            .. short(name, 16) .. " app=-")
        return true, "terminate"
    end
    local before = self:running_inputs()
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
