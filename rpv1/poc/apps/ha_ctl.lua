--[[- apps/ha_ctl.lua - one-shot control CLI for the RPV1 hot-standby switch.

What this file is
  The operator front end apps/backup_router.lua never had: a way to look at the
  standby state and, above all, a way to revoke a takeover by hand without
  rebooting the computer. All state lives on node.ha (the runtime
  backup_router.start_router returns), so this file owns no state of its own: it
  reads that table, calls the module function that performs the transition and
  prints one ASCII line per command.

Commands (one command per run)
    status               mode, shared VIP, synced pool, last master, misses and
                         the age of the last mode change, on one line
    standby              revoke a takeover by hand: M.standby(rt, "manual_revoke")
                         idempotent; on an idle STANDBY it prints a no-op line
    takeover --yes       take over by hand; without --yes it refuses and prints
                         the usage, so a typo can never steal the VIP
    help                 the usage text

Where the command comes from, in this order
  1. the arguments the app was started with. node2/startup.lua takes
     `app=ha_ctl:status` from role.txt and passes everything after the first
     colon as the argument string, so `app=ha_ctl:takeover --yes` works too.
  2. one line of /disk/ha_ctl.cmd -- the no-keyboard case. Blank lines and
     everything after `#` are ignored. --path=<file> overrides the path; a
     command file may not point at another file.
  3. the built-in default: `status`.

  A broken command file is never ignored silently: the app prints
  `HA_CTL reject reason=command_file_<why>` and exits.

Output and logging (all lines ASCII)
  Every command prints one or more `HA_CTL ...` lines and logs `HA_CTL <cmd> ...`
  through node:log when the node has one. The tags are:
    HA_CTL status mode=.. shared=.. pool=.. master=.. misses=..
    HA_CTL takeover result=active|denied|noop [reason=..]
    HA_CTL standby result=ok|noop mode=.. [reason=manual_revoke]
    HA_CTL reject reason=..
  Nothing here is fatal: a rejected or impossible command returns a result table
  with ok=false and a reason, and the app form still let the boot continue.

Usage
  -- A) node2/startup.lua: `app=ha_ctl` (reads /disk/ha_ctl.cmd) or
  --    `app=ha_ctl:takeover --yes` / `app=ha_ctl:standby`
  -- B) by hand, with the node and the module table in scope:
  local ctl = dofile("apps/ha_ctl.lua")
  local result = ctl.execute(node, rpv, "status")      -- or "standby"
  print(result.ok, result.reason)
  -- C) the module object exposes M.execute / M.main / M.status_line / M.parse

Why takeover needs --yes
  A takeover moves the DHCP service and the VIP to this box. The automatic path
  waits for 15 s of silence (backup_router.evaluate) precisely so a single lost
  datagram cannot do it; a keystroke must be at least as deliberate.

The file is ASCII only and uses the CraftOS fs API plus the node object.
]]

local M = {}

M.VERSION = "1.0"
M.TAG = "HA_CTL"
M.CMD_PATH = "/disk/ha_ctl.cmd"   -- default command file (no keyboard case)
M.MAX_CMD_BYTES = 256             -- one short command line, never a script
M.COMMANDS = {
    status = true, standby = true, takeover = true, help = true,
}

M.out = nil                       -- tests may install a sink instead of print()

local floor = math.floor

-- ===== small helpers ========================================================

local function trim(s)
    s = tostring(s or "")
    return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function log(node, fmt, ...)
    if type(node) == "table" and type(node.log) == "function" then
        pcall(node.log, node, fmt, ...)
    end
end

local function emit(ctx, line)
    local sink = type(ctx) == "table" and ctx.out or nil
    if type(sink) == "function" then
        sink(line)
        return
    end
    if type(M.out) == "function" then
        M.out(line)
        return
    end
    print(line)
end

local function now_of(rt)
    if type(rt) == "table" and type(rt.clock) == "function" then
        return rt.clock()
    end
    return os.clock()
end

-- dotted quad of an integer address; unlike backup_router.int2ip this one is
-- local, so ha_ctl works even when only the runtime table is available
local function ip_text(n)
    if type(n) ~= "number" then return tostring(n) end
    local value = floor(n)
    if value < 0 then value = 0 end
    return string.format("%d.%d.%d.%d",
        floor(value / 16777216) % 256, floor(value / 65536) % 256,
        floor(value / 256) % 256, value % 256)
end

-- ===== usage and argument parsing ===========================================

function M.usage()
    return {
        "ha_ctl: RPV1 hot-standby control",
        "  status              show mode, shared VIP, synced pool, master, misses",
        "  standby             revoke a takeover by hand (manual_revoke), idempotent",
        "  takeover --yes      take over now; --yes is required on purpose",
        "  help                this text",
        "  --path=<file>       read the command from <file> instead of " .. M.CMD_PATH,
        "  default with no argument: status (or the first line of " .. M.CMD_PATH .. ")",
    }
end

-- nil, string or table -> list of tokens
function M.split(args)
    local out = {}
    if type(args) == "table" then
        for i = 1, #args do out[i] = tostring(args[i]) end
        return out
    end
    if type(args) == "string" then
        for token in args:gmatch("%S+") do out[#out + 1] = token end
        return out
    end
    if args ~= nil then out[1] = tostring(args) end
    return out
end

-- tokens -> { cmd, yes, path } or nil, reason
function M.parse(tokens)
    if type(tokens) ~= "table" then return nil, "no_tokens" end
    local spec = { cmd = nil, yes = false, path = M.CMD_PATH }
    local positional = {}
    local i = 1
    while i <= #tokens do
        local token = tostring(tokens[i] or "")
        local key, value = token:match("^%-%-([%w_]+)=(.*)$")
        if token == "--yes" or token == "-y" then
            spec.yes = true
        elseif token == "--help" or token == "-h" then
            positional[#positional + 1] = "help"
        elseif key == "path" or key == "file" then
            spec.path = value
        elseif key then
            return nil, "unknown_argument"
        elseif token == "--path" or token == "--file" then
            i = i + 1
            if tokens[i] == nil then return nil, "missing_path" end
            spec.path = tostring(tokens[i])
        elseif token:sub(1, 1) == "-" then
            return nil, "unknown_argument"
        elseif token == "" then
            return nil, "empty_argument"
        else
            positional[#positional + 1] = token
        end
        i = i + 1
    end
    if #positional == 0 then return nil, "missing_command" end
    if #positional > 1 then return nil, "too_many_arguments" end
    local cmd = positional[1]
    if not M.COMMANDS[cmd] then return nil, "unknown_command" end
    spec.cmd = cmd
    return spec
end

-- first meaningful line of the command file, or nil plus a short reason
function M.read_command_file(path)
    local file = path or M.CMD_PATH
    if type(fs) ~= "table" then return nil, "fs_unavailable" end
    if type(fs.exists) == "function" then
        local ok, present = pcall(fs.exists, file)
        if not ok or not present then return nil, "missing" end
    end
    local ok_open, handle = pcall(fs.open, file, "r")
    if not ok_open or type(handle) ~= "table" then return nil, "unreadable" end
    local ok_read, text = pcall(handle.readAll, handle)
    pcall(handle.close, handle)
    if not ok_read or type(text) ~= "string" then return nil, "unreadable" end
    if #text > M.MAX_CMD_BYTES then return nil, "too_large" end
    for raw in (text .. "\n"):gmatch("(.-)\n") do
        local line = trim(raw:gsub("#.*$", ""))
        if line ~= "" then return line end
    end
    return nil, "empty"
end

-- arguments, then the command file, then the default. Returns a spec table with
-- .source ("args" | "file" | "default") and .tokens, or nil plus a reason.
function M.resolve(node, rpv, args, opts)
    local ctx = type(opts) == "table" and opts or {}
    local tokens = M.split(args)
    local source = "args"

    if #tokens == 0 then
        local line, why = M.read_command_file(ctx.path or M.CMD_PATH)
        if line then
            tokens = M.split(line)
            source = "file"
        elseif why == "missing" or why == "empty" then
            tokens = { "status" }
            source = "default"
        else
            return nil, "command_file_" .. tostring(why)
        end
    end

    local spec, err = M.parse(tokens)
    if not spec then return nil, tostring(err) end
    -- a command file must not redirect the reader to another path: a file would
    -- then be able to run a command the operator never typed
    if source == "file" and spec.path ~= M.CMD_PATH then
        return nil, "file_path_rejected"
    end
    spec.source = source
    spec.tokens = tokens
    return spec
end

-- ===== state views ==========================================================

local function find_backup(node, ctx)
    local explicit = type(ctx) == "table" and ctx.backup or nil
    if type(explicit) == "table" and type(explicit.takeover) == "function" then return explicit end
    if type(node) == "table" and type(node.ha_module) == "table" then return node.ha_module end
    local global = rawget(_G, "backup_router")
    if type(global) == "table" and type(global.takeover) == "function" then return global end
    local package_table = rawget(_G, "package")
    if type(package_table) == "table" and type(package_table.loaded) == "table" then
        local cached = package_table.loaded.backup_router
        if type(cached) == "table" and type(cached.takeover) == "function" then return cached end
    end
    -- last resort: the app file next to this one. The module has no state the
    -- transitions need (they only read/write the runtime and the node), so a
    -- second instance is safe here.
    if type(loadfile) == "function" then
        local chunk = loadfile("apps/backup_router.lua")
        if chunk then
            local ok, mod = pcall(chunk)
            if ok and type(mod) == "table" and type(mod.takeover) == "function" then return mod end
        end
    end
    return nil
end

local function find_runtime(node, ctx)
    if type(ctx) == "table" and type(ctx.rt) == "table" then return ctx.rt end
    if type(node) == "table" and type(node.ha) == "table" then return node.ha end
    return nil
end

-- the pool the switch would serve right now: the synced configuration first,
-- then a running DHCP server, then the local role.txt key
function M.pool_text(rt, node)
    local cfg = type(rt) == "table" and rt.synced_dhcp_config or nil
    if type(cfg) == "table" and cfg.pool_start ~= nil then
        return tostring(cfg.pool_start) .. "-" .. tostring(cfg.pool_end)
    end
    local live = type(rt) == "table" and rt.dhcp_server or nil
    if type(live) == "table" and type(live.lo) == "number" then
        return ip_text(live.lo) .. "-" .. ip_text(live.hi)
    end
    local local_srv = type(node) == "table" and node.dhcp_server or nil
    if type(local_srv) == "table" and type(local_srv.lo) == "number" then
        return ip_text(local_srv.lo) .. "-" .. ip_text(local_srv.hi)
    end
    if type(node) == "table" and type(node.cfg) == "table" and node.cfg.dhcp_pool ~= nil then
        return tostring(node.cfg.dhcp_pool)
    end
    return "none"
end

-- plain table of the fields every command reports; no side effects
function M.describe(rt, node, now)
    local at = tonumber(now) or now_of(rt)
    local view = {
        mode = "?", role = "?", vip = "?", shared = false, pool = "none",
        master = nil, synced = false, dhcp = false, misses = 0, silent = 0,
        last_change = nil, started = false,
    }
    if type(rt) ~= "table" then return view end

    view.started = true
    view.mode = tostring(rt.mode or "?")
    view.role = tostring(rt.role or "?")
    view.vip = ip_text(rt.vip)
    view.shared = (rt.shared == true)
    view.pool = M.pool_text(rt, node)
    view.master = rt.last_master_id
    view.synced = (type(rt.synced_dhcp_config) == "table")
    view.dhcp = (type(rt.dhcp_server) == "table")
        or (type(node) == "table" and type(node.dhcp_server) == "table")
        or false
    view.misses = tonumber(rt.misses) or 0
    local anchor = rt.last_master_seen or rt.started_at or at
    view.silent = at - anchor
    if tonumber(rt.last_change) then view.last_change = at - rt.last_change end
    return view
end

-- the single status line: the status_text fields plus the ones a CLI needs
function M.status_line(rt, node, now)
    local view = M.describe(rt, node, now)
    local migrated = view.last_change and string.format("%.1fs", view.last_change) or "never"
    return string.format(
        "HA_CTL status mode=%s role=%s vip=%s shared=%s pool=%s master=%s synced=%s dhcp=%s misses=%d silent=%.1fs last_change=%s",
        view.mode, view.role, view.vip, tostring(view.shared), view.pool,
        tostring(view.master or "-"), tostring(view.synced), tostring(view.dhcp),
        view.misses, view.silent, migrated)
end

-- ===== commands =============================================================

local function reject(node, ctx, say, reason)
    log(node, "HA_CTL reject reason=%s", tostring(reason))
    say("HA_CTL reject reason=%s", tostring(reason))
    ctx.ok = false
    ctx.reason = tostring(reason)
    return ctx
end

local function cmd_status(node, ctx, rt, say)
    if type(rt) ~= "table" then
        return reject(node, ctx, say, "no_runtime")
    end
    local view = M.describe(rt, node)
    say("%s", M.status_line(rt, node))
    log(node, "HA_CTL status mode=%s shared=%s pool=%s master=%s misses=%d",
        view.mode, tostring(view.shared), view.pool, tostring(view.master or "-"), view.misses)
    return ctx
end

local function cmd_standby(node, ctx, rt, backup, say)
    if type(rt) ~= "table" then
        return reject(node, ctx, say, "no_runtime")
    end
    if type(backup) ~= "table" or type(backup.standby) ~= "function" then
        return reject(node, ctx, say, "no_backup_module")
    end
    if rt.mode ~= "ACTIVE" then
        ctx.changed = false
        say("HA_CTL standby result=noop mode=%s (nothing to revoke)", tostring(rt.mode))
        log(node, "HA_CTL standby result=noop mode=%s", tostring(rt.mode))
        return ctx
    end
    local changed = backup.standby(rt, "manual_revoke")
    ctx.changed = (changed == true)
    say("HA_CTL standby result=%s mode=%s reason=manual_revoke",
        ctx.changed and "ok" or "noop", tostring(rt.mode))
    log(node, "HA_CTL standby result=%s mode=%s",
        ctx.changed and "ok" or "noop", tostring(rt.mode))
    return ctx
end

-- why a takeover would be refused right now, most specific first. The module
-- logs the same reason itself; this is only what the CLI prints.
local function takeover_blocker(rt)
    if rt.shared ~= true then return "vip_not_local" end
    if type(rt.synced_dhcp_config) ~= "table" then return "no_synced_config" end
    if rt.role == "primary" then return "role_primary" end
    return nil
end

local function cmd_takeover(node, ctx, rt, backup, spec, say)
    if spec.yes ~= true then
        -- no usage print on the rejection path of an actual command: the guard
        -- is here so a typo cannot move the VIP, and the operator gets the usage
        reject(node, ctx, say, "no_confirm")
        for _, line in ipairs(M.usage()) do say("%s", line) end
        return ctx
    end
    if type(rt) ~= "table" then
        return reject(node, ctx, say, "no_runtime")
    end
    if type(backup) ~= "table" or type(backup.takeover) ~= "function" then
        return reject(node, ctx, say, "no_backup_module")
    end
    if rt.mode == "ACTIVE" then
        ctx.changed = false
        say("HA_CTL takeover result=noop mode=ACTIVE (already serving)")
        log(node, "HA_CTL takeover result=noop mode=ACTIVE")
        return ctx
    end

    local blocker = takeover_blocker(rt)
    local ok = backup.takeover(rt, "manual")
    ctx.changed = (ok == true)
    if ctx.changed then
        say("HA_CTL takeover result=active mode=%s pool=%s",
            tostring(rt.mode), M.pool_text(rt, node))
        log(node, "HA_CTL takeover result=active mode=%s", tostring(rt.mode))
    else
        local reason = blocker or "denied"
        say("HA_CTL takeover result=denied reason=%s mode=%s", reason, tostring(rt.mode))
        log(node, "HA_CTL takeover result=denied reason=%s", reason)
        ctx.ok = false
        ctx.reason = reason
    end
    return ctx
end

-- Run one command. node/rpv may be nil for pure argument tests. Returns
-- { ok, cmd, source, reason, changed, lines } -- never throws.
function M.execute(node, rpv, args, opts)
    local ctx = type(opts) == "table" and opts or {}
    ctx.lines = {}
    ctx.ok = true
    ctx.reason = nil
    ctx.changed = nil

    local function say(fmt, ...)
        local line = select("#", ...) > 0 and string.format(fmt, ...) or fmt
        ctx.lines[#ctx.lines + 1] = line
        emit(ctx, line)
    end

    local spec, err = M.resolve(node, rpv, args, ctx)
    if not spec then
        ctx.cmd = nil
        ctx.source = "none"
        for _, line in ipairs(M.usage()) do say("%s", line) end
        return reject(node, ctx, say, tostring(err))
    end

    ctx.cmd = spec.cmd
    ctx.source = spec.source
    ctx.yes = spec.yes

    if spec.cmd == "help" then
        for _, line in ipairs(M.usage()) do say("%s", line) end
        return ctx
    end

    local rt = find_runtime(node, ctx)
    local backup = find_backup(node, ctx)
    if spec.cmd == "status" then return cmd_status(node, ctx, rt, say) end
    if spec.cmd == "standby" then return cmd_standby(node, ctx, rt, backup, say) end
    return cmd_takeover(node, ctx, rt, backup, spec, say)
end

-- the name a boot script (and the tests) can call without knowing about execute
function M.main(node, rpv, args, opts)
    return M.execute(node, rpv, args, opts)
end

-- control one runtime directly: M.control(rt, "standby", { backup = br })
function M.control(rt, args, opts)
    local ctx = type(opts) == "table" and opts or {}
    ctx.rt = rt
    return M.execute(ctx.node, ctx.rpv, args, ctx)
end

-- ===== loader forms =========================================================
-- node2/startup.lua app form: `app=ha_ctl` or `app=ha_ctl:takeover --yes`.
-- start() never blocks and never reports failure to the boot: a refused command
-- has already printed and logged why, and taking the switch down over it would
-- be worse than the refusal itself.
function M.new(opts)
    local base = type(opts) == "table" and opts or {}
    local app = { node = base.node, rpv = base.rpv, args = base.args, opts = base }
    function app:start()
        self.result = M.execute(self.node, self.rpv, self.args, self.opts)
        return true
    end
    function app:status()
        return M.status_line(find_runtime(self.node, self.opts), self.node)
    end
    return app
end

if type(_G) == "table" then
    _G.ha_ctl = M
end

return M
