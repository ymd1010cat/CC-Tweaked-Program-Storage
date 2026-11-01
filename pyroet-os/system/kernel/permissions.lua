--[[- pyroet-os/system/kernel/permissions.lua -- capability decisions for the first start of an app.

A manifest's `capabilities` list is a *declaration*, not a grant. This module
turns the declaration into a decision:

    1. `/etc/perms/<app>.cfg` exists and parses -> that file IS the decision
       (one `cap=granted|denied` line per capability, `#` starts a comment).
    2. no file -> first start: one prompt for the whole list (PERMS_PROMPT
       app=.. caps=..), then one question per capability, then the answers are
       written to the file.
    3. file exists but does not parse -> PERMS_BAD_FILE, every capability is
       DENIED, and the file is left on disk untouched for inspection: a corrupt
       decision file must never be silently rewritten into a grant.
    4. a line for a capability the manifest no longer declares is stale, not
       corrupt: it is ignored with PERMS_PRUNE. A line naming a capability that
       does not exist at all IS corrupt (see 3).
    5. a capability the file does not mention is *undecided*, not denied: an
       image update can add a capability to a package that was already started
       once, and the old file cannot have a line for it. Those caps go back
       through the same `ask` policy that decided the first start (D1-fix), are
       logged as PERMS_STALE + PERMS_DECISION, and the file is rewritten with the
       answers so the migration happens exactly once. For an image package under
       the system root the policy is the pre-grant, so the new capability is
       granted; for a user package the default policy still answers no, so
       nothing widens. A *denial* is always written as `denied`, which is why an
       absent line can be treated as "never decided" without losing a decision.
       `ensure(..., { prompt = false })` (the boot chain's read-only pass) never
       migrates and never writes.
    6. the policy may answer `"ask"`: that boot cannot decide for itself, so the
       capability is queued (`PERM_ASK`) and `ensure` answers `nil` -- nothing
       cached, nothing written. `answer(app, cap, verdict)` writes the line
       (`PERM_ANSWER ... by=user`) and drops the request, so the retry finds an
       ordinary file. Android's rule: asked once, remembered; a line that already
       exists is never asked again. `set(app, cap, granted)` is the same write
       without a request (`PERM_SET`, the Settings toggle).

The question itself is an `ask` callback, supplied by the caller:
`P.new({ ask = function(app, cap, info) return true end })`. The default answers
`false` -- fail closed, never grant what nobody approved. The line the user reads
is drawn by the launcher (pyroet-os/system/system/launcher.app), which owns the
keyboard; this module only owns the queue and the file.

Log lines (ASCII, one line each, greppable):

    PERMS_PROMPT app=<name> caps=<a,b|->
    PERMS_STALE app=<name> caps=<a,b>          (file predates the manifest, see 5)
    PERMS_DECISION app=<name> cap=<cap> granted=true|false
    PERMS_SAVED app=<name> path=<path> granted=<n> denied=<n>
    PERMS_SAVE_FAIL app=<name> path=<path> err=<reason>
    PERMS_BAD_FILE app=<name> path=<path> err=<reason>
    PERMS_PRUNE app=<name> cap=<cap>
    PERMS_ASK_FAIL app=<name> cap=<cap> err=<reason>
    PERMS_RESET app=<name> path=<path> existed=true|false
    PERM_ASK app=<name> cap=<cap>                  (queued for the desktop, rule 6)
    PERM_ANSWER app=<name> cap=<cap> verdict=allowed|denied by=user
    PERM_SET app=<name> cap=<cap> verdict=allowed|denied by=user

Usage:

    local perms = dofile("/system/kernel/permissions.lua")
    local p = perms.new({ fs = fs, log = print, root = "/etc/perms" })
    local decisions, info = p:ensure("net", { "net.rpv", "fs.read" })
    decisions["net.rpv"]   -- true / false, nil when info.source == "ask"
    p:answer("net", "net.rpv", "allowed")   -- write granted, drop the request
    perms.reset("net", { fs = fs })   -- forget the file, ask again next start

No non-ASCII bytes in this file.
]]

local P = {}

P.VERSION = "1.1"
P.ROOT = "/etc/perms"
P.FILE_HEADER = "# PYROET-PERMS-1"

-- Kept in sync with kernel/apps.lua A.CAPS; tests assert the two lists match,
-- and apps.lua hands its own list in through `known`, so a drift here can only
-- show up as a refused line, never as an invented capability. The last three were
-- appended (O3, then the RHTP service protocol) so existing decision files, which
-- list a prefix of this order, keep parsing and keep their meaning.
P.CAPS = { "fs.read", "fs.write", "net.rpv", "net.rednet", "redstone", "peripheral",
    "http", "input", "terminal", "net.rhtp" }

local function short(value, max)
    local s = tostring(value == nil and "nil" or value)
    s = s:gsub("[\r\n\t]+", " ")
    s = s:gsub("[^%w%._%-:=/ ]", "_")
    max = max or 60
    if #s > max then s = s:sub(1, max) end
    if s == "" then s = "-" end
    return s
end

local function trim(text)
    return (tostring(text):gsub("^%s+", ""):gsub("%s+$", ""))
end

local function cap_set(list)
    local set = {}
    if type(list) == "table" then
        for i = 1, #list do
            if type(list[i]) == "string" then set[list[i]] = true end
        end
    end
    return set
end

local function join(root, name)
    local head = tostring(root == nil and P.ROOT or root):gsub("/+$", "")
    if head == "" then head = "/" end
    return head .. "/" .. name
end

-- ---------------------------------------------------------------------------
-- construction
-- ---------------------------------------------------------------------------

function P.new(opts)
    local o = opts or {}
    local self = setmetatable({}, { __index = P })
    self.opts = o
    self.fs = o.fs or rawget(_G, "fs")
    self.root = o.root or P.ROOT
    self.sink = o.log
    self.logs = {}
    self.ask = o.ask
    self.now = o.now
    self.cache = {}
    -- rule 6: capabilities this boot has to ask the user about, oldest first
    self.requests = {}
    self.known_list = o.caps or P.CAPS
    self.known = cap_set(self.known_list)
    return self
end

function P.deny_all()
    return false
end

-- ---------------------------------------------------------------------------
-- logging
-- ---------------------------------------------------------------------------

function P:log(line)
    line = tostring(line)
    self.logs[#self.logs + 1] = line
    if self.sink then
        local ok = pcall(self.sink, line)
        if not ok then self.sink = nil end
    end
    return line
end

function P:lines()
    return self.logs
end

function P:text()
    return table.concat(self.logs, "\n")
end

function P:count(fragment)
    local n = 0
    for i = 1, #self.logs do
        if self.logs[i]:find(fragment, 1, true) then n = n + 1 end
    end
    return n
end

function P:has_line(fragment)
    return self:count(fragment) > 0
end

-- ---------------------------------------------------------------------------
-- file system plumbing (best effort: every refusal is a logged decision, never
-- a crash -- this module runs during boot)
-- ---------------------------------------------------------------------------

function P:read(path)
    if not (self.fs and self.fs.exists(path)) then return nil, "missing" end
    local ok, handle = pcall(self.fs.open, path, "r")
    if not ok or not handle then return nil, tostring(handle) end
    local text
    local read_ok, a, b = pcall(function()
        if handle.readAll then return handle.readAll() end
        return handle.read("*a")
    end)
    pcall(handle.close)
    if read_ok then text = a else return nil, tostring(a) end
    if text == nil then return nil, tostring(b or "unreadable") end
    return text
end

function P:write(path, text)
    local ok, handle = pcall(self.fs.open, path, "w")
    if not ok or not handle then
        return nil, "cannot open " .. tostring(path) .. ": " .. tostring(handle)
    end
    local wrote, err = pcall(handle.write, text)
    pcall(handle.close)
    if not wrote then return nil, tostring(err) end
    return true
end

-- makeDir only creates the last component, so walk down from the root
function P:mkdirp(path)
    if path == nil or path == "" or path == "/" then return true end
    if self.fs.exists(path) then return true end
    local parent = self.fs.getDir(path)
    if parent ~= nil and parent ~= "" and parent ~= "/" then
        self:mkdirp(parent)
    end
    pcall(self.fs.makeDir, path)
    return self.fs.exists(path) == true
end

function P:path(app)
    return join(self.root, tostring(app) .. ".cfg")
end

-- ---------------------------------------------------------------------------
-- parsing / persistence
-- ---------------------------------------------------------------------------

-- text -> decisions, nil | nil, reason. Strict: one bad line rejects the file.
function P:parse(text, known)
    local set = known or self.known
    if type(text) ~= "string" then return nil, "no text" end
    local decisions = {}
    local seen, number, pos = 0, 0, 1
    while pos <= #text do
        local stop = text:find("[\r\n]", pos)
        local line
        if stop then
            line = text:sub(pos, stop - 1)
            pos = stop + 1
            if text:sub(pos, pos) == "\n" and text:sub(stop, stop) == "\r" then
                pos = pos + 1
            end
        else
            line = text:sub(pos)
            pos = #text + 1
        end
        number = number + 1
        local body = trim(line)
        if body ~= "" and body:sub(1, 1) ~= "#" then
            local cap, value = body:match("^([%w][%w%._%-]*)%s*=%s*(%S+)$")
            if not cap then
                return nil, "line " .. tostring(number) .. ": expected cap=value"
            end
            if not set[cap] then
                return nil, "line " .. tostring(number) .. ": unknown capability '" .. cap .. "'"
            end
            if value ~= "granted" and value ~= "denied" then
                return nil, "line " .. tostring(number) .. ": bad value '" .. value .. "'"
            end
            decisions[cap] = (value == "granted")
            seen = seen + 1
        end
    end
    if seen == 0 then return nil, "no decisions" end
    return decisions
end

-- -> decisions, "file" | "bad" | "none", path
function P:load(app, known)
    local path = self:path(app)
    if not (self.fs and self.fs.exists(path)) then return nil, "none", path end
    local text, err = self:read(path)
    if text == nil then
        self:log("PERMS_BAD_FILE app=" .. tostring(app)
            .. " path=" .. short(path, 48) .. " err=unreadable:" .. short(err, 24))
        return nil, "bad", path
    end
    local decisions, why = self:parse(text, known)
    if not decisions then
        self:log("PERMS_BAD_FILE app=" .. tostring(app)
            .. " path=" .. short(path, 48) .. " err=" .. short(why, 40))
        return nil, "bad", path
    end
    return decisions, "file", path
end

-- decisions -> true | nil, reason. Order follows the cap list so the file is
-- stable and diffable across starts.
function P:save(app, decisions, opts)
    local o = opts or {}
    local order = o.order or self.known_list
    local lines = { P.FILE_HEADER .. " app=" .. tostring(app) }
    local granted, denied = 0, 0
    local written = {}
    for i = 1, #order do
        local cap = order[i]
        if not written[cap] and decisions[cap] ~= nil then
            written[cap] = true
            if decisions[cap] then granted = granted + 1 else denied = denied + 1 end
            lines[#lines + 1] = cap .. "=" .. (decisions[cap] and "granted" or "denied")
        end
    end
    local path = self:path(app)
    if not self:mkdirp(self.root) then
        self:log("PERMS_SAVE_FAIL app=" .. tostring(app)
            .. " path=" .. short(path, 48) .. " err=cannot_create_root")
        return nil, "cannot create " .. tostring(self.root)
    end
    local ok, err = self:write(path, table.concat(lines, "\n") .. "\n")
    if not ok then
        self:log("PERMS_SAVE_FAIL app=" .. tostring(app)
            .. " path=" .. short(path, 48) .. " err=" .. short(err, 40))
        return nil, err
    end
    self:log("PERMS_SAVED app=" .. tostring(app) .. " path=" .. short(path, 48)
        .. " granted=" .. tostring(granted) .. " denied=" .. tostring(denied))
    return true
end

-- instance hook used by the module-level permissions.reset(app)
function P:forget(app)
    local path = self:path(app)
    self.cache[app] = nil
    local existed = self.fs and self.fs.exists(path)
    if existed then pcall(self.fs.delete, path) end
    self:log("PERMS_RESET app=" .. tostring(app) .. " path=" .. short(path, 48)
        .. " existed=" .. (existed and "true" or "false"))
    return true
end

-- module level, so a caller that holds no instance (tests, a future Settings
-- action) can drop one app's decisions: permissions.reset("net", { fs = fs })
function P.reset(app, opts)
    local o = opts or {}
    local self = P.new({
        fs = o.fs or rawget(_G, "fs"),
        root = o.root,
        log = o.log,
    })
    return self:forget(app)
end

-- every `*.cfg` under the root, as app names (sorted), for reporting
function P:list()
    local names = {}
    if not (self.fs and self.fs.exists(self.root)) then return names end
    local ok, entries = pcall(self.fs.list, self.root)
    if not ok or type(entries) ~= "table" then return names end
    for i = 1, #entries do
        local name = entries[i]
        if type(name) == "string" and name:sub(-4) == ".cfg" then
            names[#names + 1] = name:sub(1, #name - 4)
        end
    end
    table.sort(names)
    return names
end

-- ---------------------------------------------------------------------------
-- rule 6: the request queue and the one write an answer makes
-- ---------------------------------------------------------------------------

-- Queue one question. A capability is queued at most once: a start retried before
-- the user answered must not stack duplicates.
function P:enqueue(app, cap, info)
    local key = tostring(app) .. "/" .. tostring(cap)
    for i = 1, #self.requests do
        if self.requests[i].key == key then return false end
    end
    local item = {
        app = tostring(app),
        cap = tostring(cap),
        dir = type(info) == "table" and info.dir or nil,
        key = key,
    }
    self.requests[#self.requests + 1] = item
    self:log("PERM_ASK app=" .. item.app .. " cap=" .. item.cap)
    return true
end

-- the oldest unanswered question, or nil
function P:next_request()
    return self.requests[1]
end

function P:pending()
    return #self.requests
end

function P:take(app, cap)
    local key = tostring(app) .. "/" .. tostring(cap)
    for i = 1, #self.requests do
        if self.requests[i].key == key then
            return table.remove(self.requests, i)
        end
    end
    return nil
end

-- Write exactly one decision over the file's existing decisions, keeping every
-- other line, and drop the cache: an answer can only be *seen* through a re-read.
function P:store(app, cap, granted)
    local decisions = self:load(app)
    local merged = {}
    if type(decisions) == "table" then
        for key, value in pairs(decisions) do merged[key] = value end
    end
    merged[tostring(cap)] = (granted == true)
    self.cache[app] = nil
    local ok, err = self:save(app, merged, { order = self.known_list })
    if not ok then return nil, err end
    return true
end

local function allowed_by(verdict)
    return verdict == true or verdict == "allowed" or verdict == "allow"
        or verdict == "granted"
end

-- The user answered a queued request (A = allowed, D = denied). This is the only
-- path that turns a question into a line, and it always logs the vote.
function P:answer(app, cap, verdict, by)
    local denied = not allowed_by(verdict)
    self:take(app, cap)
    local ok, err = self:store(app, cap, not denied)
    self:log("PERM_ANSWER app=" .. tostring(app) .. " cap=" .. tostring(cap)
        .. " verdict=" .. (denied and "denied" or "allowed")
        .. " by=" .. tostring(by or "user"))
    if not ok then return nil, err end
    return true
end

-- Settings toggle: the same write, no queue involved.
function P:set(app, cap, granted)
    local ok, err = self:store(app, cap, granted == true)
    if not ok then return nil, err end
    self:log("PERM_SET app=" .. tostring(app) .. " cap=" .. tostring(cap)
        .. " verdict=" .. (granted == true and "allowed" or "denied") .. " by=user")
    return true
end

-- cap -> "granted" | "denied" | "ask", read from the file (never the cache): the
-- Settings screen shows what is on disk, not what a past start saw.
function P:states(app, caps)
    local decisions = self:load(app)
    local out = {}
    for i = 1, #caps do
        local cap = caps[i]
        if type(decisions) == "table" and decisions[cap] == true then
            out[cap] = "granted"
        elseif type(decisions) == "table" and decisions[cap] == false then
            out[cap] = "denied"
        else
            out[cap] = "ask"
        end
    end
    return out
end

-- ---------------------------------------------------------------------------
-- the decision itself
-- ---------------------------------------------------------------------------

-- one question per capability; `ask` is the caller's input channel, and an ask
-- that raises is a denial (fail closed). An ask that answers `"ask"` cannot be
-- decided on this boot: the capability is queued and the loop stops (nil
-- decisions, the queued capability as third value), so nothing half-decided is
-- ever returned, cached or written.
function P:decide(app, caps, ctx)
    local o = ctx or {}
    local ask = o.ask or self.ask or P.deny_all
    local decisions, order = {}, {}
    for i = 1, #caps do
        local cap = caps[i]
        order[#order + 1] = cap
        local called, answer = pcall(ask, tostring(app), cap, o)
        if not called then
            self:log("PERMS_ASK_FAIL app=" .. tostring(app) .. " cap=" .. cap
                .. " err=" .. short(answer, 32))
            answer = false
        end
        if answer == "ask" then
            self:enqueue(app, cap, o)
            return nil, order, cap
        end
        local granted = (answer == true or answer == "granted"
            or answer == "y" or answer == "yes")
        decisions[cap] = granted
        self:log("PERMS_DECISION app=" .. tostring(app) .. " cap=" .. cap
            .. " granted=" .. (granted and "true" or "false"))
    end
    return decisions, order
end

local function tally(decisions, caps)
    local granted, denied = 0, 0
    for i = 1, #caps do
        if decisions[caps[i]] == true then granted = granted + 1 else denied = denied + 1 end
    end
    return granted, denied
end

-- ensure(app, caps, { dir=, known=, ask=, prompt=false, force=false })
-- -> decisions, info { source = "cache"|"file"|"bad"|"prompt"|"none"|"ask",
--                     prompted, granted, denied, path, pending, pending_cap,
--                     migrated }
-- `prompt = false` reads the table only: used by the boot chain to show what is
-- decided before anything asks a question (it never migrates and never writes).
-- `pending` counts the declared caps the file does not mention; a real start
-- resolves them (rule 5 above) and reports how many it migrated.
-- `source == "ask"` means the decisions are nil on purpose: the capability named
-- by `pending_cap` is queued (rule 6), so the caller must not start the app.
function P:ensure(app, caps, ctx)
    local o = ctx or {}
    local known = o.known and cap_set(o.known) or self.known
    local list = type(caps) == "table" and caps or {}
    local info = {
        app = tostring(app),
        source = nil,
        prompted = false,
        granted = 0,
        denied = 0,
        path = self:path(app),
    }
    if o.force then self.cache[app] = nil end
    local cached = self.cache[app]
    if cached then
        info.source = "cache"
        info.granted, info.denied = tally(cached, list)
        return cached, info
    end
    if #list == 0 then
        info.source = "none"
        return {}, info
    end
    local decisions, source = self:load(app, known)
    if source == "file" then
        local filtered = {}
        local declared = cap_set(list)
        local missing = {}
        for i = 1, #list do
            if decisions[list[i]] ~= nil then
                filtered[list[i]] = decisions[list[i]]
            else
                missing[#missing + 1] = list[i]
            end
        end
        for cap in pairs(decisions) do
            if not declared[cap] then
                self:log("PERMS_PRUNE app=" .. tostring(app) .. " cap=" .. cap)
            end
        end
        -- An absent line is "never decided", not a denial (a denial is stored as
        -- `denied`). That is what an image update looks like from the file's
        -- side: the package already started once, its manifest then gained a
        -- capability (D1 added `input` + `terminal` to the launcher), and the old
        -- file cannot have a line for it. Ask the same policy that decided the
        -- first start -- the pre-grant for an image package, the default `no`
        -- for a user package -- and persist the answers so the migration runs
        -- exactly once. The read-only pass (`prompt = false`) never migrates.
        if #missing > 0 and o.prompt ~= false then
            self:log("PERMS_STALE app=" .. tostring(app)
                .. " caps=" .. table.concat(missing, ","))
            local decided, _, asked = self:decide(app, missing, o)
            if decided == nil then
                -- rule 6: the new capability is a question for the user, so this
                -- start cannot be decided. Nothing is written or cached; the retry
                -- after the answer re-reads the file and migrates the rest.
                info.source = "ask"
                info.pending = #missing
                info.pending_cap = tostring(asked)
                info.granted, info.denied = tally(filtered, list)
                return nil, info
            end
            for i = 1, #missing do
                filtered[missing[i]] = decided[missing[i]]
            end
            local saved, err = self:save(app, filtered, { order = list })
            if not saved then
                -- the decisions still hold for this boot; the next one asks again
                info.save_error = tostring(err)
                info.migrate_error = tostring(err)
            end
            info.migrated = #missing
            missing = {}
        end
        -- a read-only pass must not cache a table with undecided caps: the start
        -- that follows has to see them as missing and migrate them
        if #missing == 0 then self.cache[app] = filtered end
        info.pending = #missing
        info.source = "file"
        info.granted, info.denied = tally(filtered, list)
        return filtered, info
    end
    if source == "bad" then
        local denied = {}
        for i = 1, #list do denied[list[i]] = false end
        self.cache[app] = denied
        info.source = "bad"
        info.granted, info.denied = tally(denied, list)
        return denied, info
    end
    if o.prompt == false then
        info.source = "none"
        return nil, info
    end
    self:log("PERMS_PROMPT app=" .. tostring(app)
        .. " caps=" .. table.concat(list, ","))
    local decided, order, asked = self:decide(app, list, o)
    info.prompted = true
    if decided == nil then
        -- rule 6: queue only. nil decisions is what the runtime turns into
        -- "permission pending" and the desktop turns into a dialog.
        info.source = "ask"
        info.pending = #list
        info.pending_cap = tostring(asked)
        return nil, info
    end
    info.source = "prompt"
    local saved, err = self:save(app, decided, { order = order })
    if not saved then info.save_error = tostring(err) end
    self.cache[app] = decided
    info.granted, info.denied = tally(decided, list)
    return decided, info
end

-- read every decision file the boot chain already has, and count what is still
-- pending (no file). Never prompts, never writes.
function P:prefetch(apps, known)
    local result = { apps = 0, loaded = 0, pending = 0, bad = 0 }
    local list = type(apps) == "table" and apps or {}
    for i = 1, #list do
        local entry = list[i]
        local name = entry and entry.name
        local caps = entry and entry.manifest and entry.manifest.capabilities
        if type(name) == "string" and type(caps) == "table" and #caps > 0 then
            result.apps = result.apps + 1
            local _, info = self:ensure(name, caps, {
                dir = entry.dir, known = known, prompt = false,
            })
            if info.source == "file" then
                result.loaded = result.loaded + 1
            elseif info.source == "bad" then
                result.bad = result.bad + 1
            else
                result.pending = result.pending + 1
            end
        end
    end
    return result
end

function P:decisions_for(app)
    return self.cache[app]
end

return P
