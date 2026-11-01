--[[- tests/t_ha_ctl.lua - apps/ha_ctl.lua: the operator CLI of the hot standby.

Driven offline against a fake runtime and a fake backup_router module, so the
command plumbing is tested without DHCP sockets or modem channels: which command
a set of arguments becomes, where that command comes from (arguments, then
/disk/ha_ctl.cmd, then the default), what each command prints and logs, and that
`takeover` refuses to run without --yes. The transitions themselves belong to
backup_router and are covered by tests/t_backup_router.lua and t_ha_e2e.lua.

Groups: module surface, argument parsing, the command file, status, standby,
takeover (the --yes guard), logging and the node2 app form.
]]
local T, M = ...

local CTL = M.ha_ctl
T.ok(CTL ~= nil, "ha_ctl module is loaded")
if not CTL then return end

-- ===== fixtures =============================================================
local VIP = 10 * 16777216 + 200 * 65536 + 1        -- 10.200.0.1
local MASTER_ID = 133
local NOW = 100

local function make_node(opts)
    local o = opts or {}
    local node = { id = 42, mac = 42, id_display = 42, cfg = o.cfg or {}, logs = {} }
    if o.ha then node.ha = o.ha end
    if o.ha_module then node.ha_module = o.ha_module end
    function node:log(fmt, ...)
        local line = tostring(fmt)
        if select("#", ...) > 0 then
            local ok, text = pcall(string.format, fmt, ...)
            if ok then line = text end
        end
        node.logs[#node.logs + 1] = line
    end
    return node
end

-- the real backup_router transitions are side-effecting on node.cfg and expect
-- a DHCP server table; the CLI only has to call them with the right words, so
-- the fake records the call and performs the visible state change
local function make_backup(opts)
    local o = opts or {}
    local br = { calls = {} }
    function br.takeover(rt, why)
        br.calls[#br.calls + 1] = { fn = "takeover", why = why }
        if o.takeover_ok == false then return false end
        rt.mode = "ACTIVE"
        rt.dhcp_server = { lo = 1, hi = 2 }
        rt.stats = rt.stats or {}
        rt.stats.takeovers = (rt.stats.takeovers or 0) + 1
        return true
    end
    function br.standby(rt, why, master_id)
        br.calls[#br.calls + 1] = { fn = "standby", why = why, master = master_id }
        if o.standby_ok == false then return false end
        local was_active = (rt.mode == "ACTIVE")
        rt.mode = "STANDBY"
        rt.dhcp_server = nil
        return was_active
    end
    return br
end

local function make_rt(extra)
    local node = (extra and extra.node) or make_node()
    local rt = {
        node = node, role = "standby", mode = "STANDBY", vip = VIP,
        shared = true, misses = 2, started_at = 60, last_master_seen = 95,
        last_master_id = MASTER_ID, last_change = 97,
        clock = function() return NOW end,
        synced_dhcp_config = {
            pool_start = "10.200.0.50", pool_end = "10.200.0.150",
            lease_time = 600, gateway = "10.200.0.1", dns = "10.200.0.1",
            prefix = 24, dhcp_port = 6700,
        },
        stats = { takeovers = 0 },
    }
    for key, value in pairs(extra or {}) do
        if key ~= "node" then rt[key] = value end
    end
    return rt
end

local function run(node, args, opts)
    local out = {}
    local ctx = { out = function(line) out[#out + 1] = line end }
    for key, value in pairs(opts or {}) do ctx[key] = value end
    local result = CTL.execute(node, nil, args, ctx)
    return result, out
end

local function joined(lines)
    return table.concat(lines or {}, "\n")
end

local function count_log(node, tag)
    local n = 0
    for _, line in ipairs(node.logs or {}) do
        if tostring(line):find(tag, 1, true) then n = n + 1 end
    end
    return n
end

local function has_log(node, tag)
    return count_log(node, tag) > 0
end

-- run fn with a fake fs that knows only the given files, then restore fs
local function with_fs(files, fn)
    local saved = rawget(_G, "fs")
    local stub = {}
    function stub.exists(path) return files[path] ~= nil end
    function stub.open(path, mode)
        local text = files[path]
        if text == nil then return nil end
        local handle = { path = path, mode = mode, closed = false }
        function handle.readAll() return text end
        function handle.close() handle.closed = true end
        return handle
    end
    _G.fs = stub
    local ok, err = pcall(fn)
    _G.fs = saved
    if not ok then error(err, 0) end
end

-- ===== module surface =======================================================
T.eq(CTL.VERSION, "1.0", "the CLI reports version 1.0")
T.eq(CTL.CMD_PATH, "/disk/ha_ctl.cmd", "the command file lives on the disk")
T.eq(CTL.MAX_CMD_BYTES, 256, "a command line is short")
T.eq(CTL.COMMANDS.status, true, "status is a command")
T.eq(CTL.COMMANDS.standby, true, "standby is a command")
T.eq(CTL.COMMANDS.takeover, true, "takeover is a command")
T.eq(CTL.COMMANDS.help, true, "help is a command")
T.eq(CTL.COMMANDS.reboot, nil, "unknown words are not commands")
local usage = CTL.usage()
T.ok(#usage >= 6, "the usage text has several lines")
T.ok(joined(usage):find("takeover --yes", 1, true) ~= nil, "the usage documents takeover --yes")
T.ok(joined(usage):find(CTL.CMD_PATH, 1, true) ~= nil, "the usage documents the command file")
T.eq(type(CTL.main), "function", "M.main is exported for boot scripts")
T.eq(type(CTL.control), "function", "M.control drives one runtime")
T.eq(type(CTL.status_line), "function", "M.status_line is exported")

-- ===== argument parsing =====================================================
local s1 = CTL.parse({ "status" })
T.eq(s1 and s1.cmd, "status", "status parses")
T.eq(s1 and s1.yes, false, "status needs no confirmation")
T.eq(s1 and s1.path, CTL.CMD_PATH, "the default command file is the disk path")

local s2 = CTL.parse({ "takeover" })
T.eq(s2 and s2.cmd, "takeover", "takeover parses")
T.eq(s2 and s2.yes, false, "takeover has no implicit confirmation")
local s3 = CTL.parse({ "takeover", "--yes" })
T.eq(s3 and s3.yes, true, "--yes is recognised")
local s4 = CTL.parse({ "takeover", "-y" })
T.eq(s4 and s4.yes, true, "-y is the short form")
local s5 = CTL.parse({ "takeover", "--yes", "--yes" })
T.eq(s5 and s5.yes, true, "repeating --yes is harmless")
T.eq(s5 and s5.cmd, "takeover", "the repeated flag keeps the command")

local missing, missing_err = CTL.parse({})
T.eq(missing, nil, "an empty command line is refused")
T.eq(missing_err, "missing_command", "the empty line names its reason")
local unknown, unknown_err = CTL.parse({ "reboot" })
T.eq(unknown, nil, "an unknown command is refused")
T.eq(unknown_err, "unknown_command", "the unknown command names its reason")
local two, two_err = CTL.parse({ "status", "standby" })
T.eq(two, nil, "two commands are refused")
T.eq(two_err, "too_many_arguments", "the extra argument names its reason")
local badflag, badflag_err = CTL.parse({ "status", "--frobnicate" })
T.eq(badflag, nil, "an unknown flag is refused")
T.eq(badflag_err, "unknown_argument", "the unknown flag names its reason")
local helpflag = CTL.parse({ "--help" })
T.eq(helpflag and helpflag.cmd, "help", "--help maps to the help command")
local shorthelp = CTL.parse({ "-h" })
T.eq(shorthelp and shorthelp.cmd, "help", "-h maps to the help command")

local pathflag = CTL.parse({ "status", "--path=/disk/other.cmd" })
T.eq(pathflag and pathflag.path, "/disk/other.cmd", "--path= sets the path")
local pathsep = CTL.parse({ "status", "--path", "/disk/two.cmd" })
T.eq(pathsep and pathsep.path, "/disk/two.cmd", "--path <value> sets the path")
local pathmiss = CTL.parse({ "status", "--path" })
T.eq(pathmiss, nil, "a dangling --path is refused")
local _, pathmiss_err = CTL.parse({ "status", "--path" })
T.eq(pathmiss_err, "missing_path", "the dangling --path names its reason")
local fileflag = CTL.parse({ "status", "--file=/disk/x.cmd" })
T.eq(fileflag and fileflag.path, "/disk/x.cmd", "--file= is an alias")
T.eq(CTL.parse(nil), nil, "a nil token list is refused")

T.eq(#CTL.split(nil), 0, "nil splits into no tokens")
T.eq(#CTL.split(""), 0, "an empty string splits into no tokens")
T.eq(#CTL.split("status"), 1, "one word is one token")
T.eq(#CTL.split("takeover   --yes"), 2, "extra whitespace separates tokens")
T.eq(CTL.split("takeover --yes")[2], "--yes", "the flag survives the split")
T.eq(#CTL.split({ "a", "b" }), 2, "a token table is passed through")
T.eq(CTL.split(7)[1], "7", "a number argument becomes a token")

-- ===== the command file =====================================================
local file_ok, file_line = nil, nil
with_fs({ ["/disk/ha_ctl.cmd"] = "standby\n" }, function()
    file_ok, file_line = CTL.read_command_file("/disk/ha_ctl.cmd")
end)
T.eq(file_ok, "standby", "the first line of the command file is the command")

with_fs({ ["/disk/ha_ctl.cmd"] = "# a comment\n\n   \ntakeover --yes\nstandby\n" }, function()
    file_ok = CTL.read_command_file("/disk/ha_ctl.cmd")
end)
T.eq(file_ok, "takeover --yes", "blank lines and comments are skipped")

with_fs({ ["/disk/ha_ctl.cmd"] = "standby # revoke now\n" }, function()
    file_ok = CTL.read_command_file("/disk/ha_ctl.cmd")
end)
T.eq(file_ok, "standby", "a trailing comment is stripped")

with_fs({
    ["/disk/ha_ctl.cmd"] = "status\n",
    ["/disk/other.cmd"] = "standby\n",
}, function()
    local node = make_node({ ha = make_rt() })
    local result = run(node, {}, { backup = make_backup() })
    T.eq(result.cmd, "status", "the file supplies the command when there is no argument")
    T.eq(result.source, "file", "the result records the file as the source")
end)

with_fs({}, function()
    local node = make_node({ ha = make_rt() })
    local result, out = run(node, {}, { backup = make_backup() })
    T.eq(result.cmd, "status", "a missing command file falls back to status")
    T.eq(result.source, "default", "the result records the default source")
    T.eq(result.ok, true, "the default command succeeds")
    T.ok(joined(out):find("HA_CTL status", 1, true) ~= nil, "the default status is printed")
end)

with_fs({ ["/disk/ha_ctl.cmd"] = "# nothing but a comment\n" }, function()
    local node = make_node({ ha = make_rt() })
    local result = run(node, {}, { backup = make_backup() })
    T.eq(result.cmd, "status", "a comment-only file falls back to status")
    T.eq(result.source, "default", "the comment-only file is the default source")
end)

with_fs({ ["/disk/ha_ctl.cmd"] = "takeover\n" }, function()
    local node = make_node({ ha = make_rt() })
    local backup = make_backup()
    local result = run(node, {}, { backup = backup })
    T.eq(result.cmd, "takeover", "a file command is honoured")
    T.eq(result.ok, false, "a file cannot smuggle in a takeover confirmation")
    T.eq(result.reason, "no_confirm", "the file still needs --yes")
    T.eq(#backup.calls, 0, "the refused takeover never reached the module")
end)

with_fs({ ["/disk/ha_ctl.cmd"] = "takeover --yes\n" }, function()
    local node = make_node({ ha = make_rt() })
    local backup = make_backup()
    local result = run(node, {}, { backup = backup })
    T.eq(result.cmd, "takeover", "takeover --yes from a file is honoured")
    T.eq(result.ok, true, "the confirmed takeover succeeds")
    T.eq(#backup.calls, 1, "the confirmed takeover reached the module")
end)

with_fs({ ["/disk/ha_ctl.cmd"] = "standby\n" }, function()
    local node = make_node({ ha = make_rt() })
    local result = run(node, "status", { backup = make_backup() })
    T.eq(result.cmd, "status", "arguments win over the command file")
    T.eq(result.source, "args", "the result records the arguments as the source")
end)

with_fs({ ["/disk/ha_ctl.cmd"] = string.rep("x", CTL.MAX_CMD_BYTES + 1) }, function()
    local node = make_node({ ha = make_rt() })
    local result = run(node, {}, { backup = make_backup() })
    T.eq(result.ok, false, "an oversized command file is refused")
    T.eq(result.reason, "command_file_too_large", "the oversized file names its reason")
    T.ok(has_log(node, "HA_CTL reject reason=command_file_too_large"),
        "the oversized file is logged")
end)

with_fs({ ["/disk/ha_ctl.cmd"] = "status --path=/disk/other.cmd\n" }, function()
    local node = make_node({ ha = make_rt() })
    local result = run(node, {}, { backup = make_backup() })
    T.eq(result.ok, false, "a command file may not redirect to another file")
    T.eq(result.reason, "file_path_rejected", "the redirection names its reason")
end)

with_fs({ ["/disk/ha_ctl.cmd"] = "reboot\n" }, function()
    local node = make_node({ ha = make_rt() })
    local result, out = run(node, {}, { backup = make_backup() })
    T.eq(result.ok, false, "an unknown command in the file is refused")
    T.eq(result.reason, "unknown_command", "the unknown file command names its reason")
    T.ok(joined(out):find("ha_ctl: RPV1 hot-standby control", 1, true) ~= nil,
        "a refused command prints the usage")
end)

local resolved = nil
with_fs({ ["/disk/ha_ctl.cmd"] = "  standby  \n" }, function()
    local node = make_node({ ha = make_rt() })
    resolved = CTL.resolve(node, nil, nil, {})
end)
T.eq(resolved and resolved.cmd, "standby", "resolve() reads the command file")
T.eq(resolved and resolved.source, "file", "resolve() reports the file source")
T.eq(resolved and resolved.tokens and resolved.tokens[1], "standby",
    "resolve() keeps the parsed tokens")
-- ===== status ===============================================================
local snode = make_node()
local srt = make_rt({ node = snode })
snode.ha = srt
local sres, sout = run(snode, "status", { backup = make_backup() })
T.eq(sres.ok, true, "status succeeds")
T.eq(sres.cmd, "status", "status reports its command")
T.eq(#sout, 1, "status prints exactly one line")
local line = sout[1] or ""
T.ok(line:find("HA_CTL status mode=STANDBY", 1, true) ~= nil, "status prints the mode")
T.ok(line:find("shared=true", 1, true) ~= nil, "status prints the shared VIP flag")
T.ok(line:find("pool=10.200.0.50-10.200.0.150", 1, true) ~= nil, "status prints the pool")
T.ok(line:find("master=133", 1, true) ~= nil, "status prints the last master id")
T.ok(line:find("misses=2", 1, true) ~= nil, "status prints the miss count")
T.ok(line:find("silent=5.0s", 1, true) ~= nil, "status prints the silent window")
T.ok(line:find("last_change=3.0s", 1, true) ~= nil, "status prints the last mode change")
T.ok(line:find("synced=true", 1, true) ~= nil, "status prints the synced flag")
T.ok(line:find("dhcp=false", 1, true) ~= nil, "status prints the DHCP flag")
T.ok(line:find("vip=10.200.0.1", 1, true) ~= nil, "status prints the VIP")
T.ok(has_log(snode, "HA_CTL status"), "status is logged as HA_CTL status")
T.ok(has_log(snode, "mode=STANDBY"), "the log line names the mode")

local never_rt = make_rt()
never_rt.last_change = nil
local never_line = CTL.status_line(never_rt, snode)
T.ok(never_line:find("last_change=never", 1, true) ~= nil,
    "a runtime that never changed a mode says never")

local view = CTL.describe(srt, snode)
T.eq(view.mode, "STANDBY", "describe reports the mode")
T.eq(view.shared, true, "describe reports the shared flag")
T.eq(view.master, MASTER_ID, "describe reports the master id")
T.eq(view.misses, 2, "describe reports the misses")
T.eq(view.pool, "10.200.0.50-10.200.0.150", "describe reports the pool")
T.ok(view.last_change ~= nil and view.last_change > 2.9, "describe reports the change age")

local live_rt = make_rt()
live_rt.synced_dhcp_config = nil
live_rt.dhcp_server = { lo = 10 * 16777216 + 200 * 65536 + 50, hi = 10 * 16777216 + 200 * 65536 + 60 }
T.eq(CTL.pool_text(live_rt, snode), "10.200.0.50-10.200.0.60",
    "without a synced config the running server names the pool")
local cfg_only = make_rt()
cfg_only.synced_dhcp_config = nil
T.eq(CTL.pool_text(cfg_only, make_node({ cfg = { dhcp_pool = "10.200.0.9-10.200.0.19" } })),
    "10.200.0.9-10.200.0.19", "the local role.txt pool is the last resort")
T.eq(CTL.pool_text(cfg_only, make_node()), "none", "no pool at all reads none")

local bh_rt = make_rt()
bh_rt.synced_dhcp_config = nil
bh_rt.dhcp_server = { lo = 10 * 16777216 + 200 * 65536 + 50, hi = 10 * 16777216 + 200 * 65536 + 60 }
T.eq(CTL.describe(bh_rt, snode).dhcp, true, "a running server sets the dhcp flag")

local ornode = make_node()
local orres, orout = run(ornode, "status", { backup = make_backup() })
T.eq(orres.ok, false, "status without a runtime is refused")
T.eq(orres.reason, "no_runtime", "the missing runtime names its reason")
T.ok(joined(orout):find("HA_CTL reject reason=no_runtime", 1, true) ~= nil,
    "the missing runtime is printed")
T.ok(has_log(ornode, "HA_CTL reject reason=no_runtime"), "the missing runtime is logged")

-- ===== standby (the manual revoke) =========================================
local anode = make_node()
local art = make_rt({ node = anode, mode = "ACTIVE",
    dhcp_server = { lo = 1, hi = 2 } })
anode.ha = art
local abackup = make_backup()
local ares, aout = run(anode, "standby", { backup = abackup })
T.eq(ares.ok, true, "standby from ACTIVE succeeds")
T.eq(ares.changed, true, "standby from ACTIVE changed the state")
T.eq(#abackup.calls, 1, "standby reached the module once")
T.eq(abackup.calls[1] and abackup.calls[1].fn, "standby", "the module saw standby")
T.eq(abackup.calls[1] and abackup.calls[1].why, "manual_revoke",
    "the revoke reason is manual_revoke")
T.eq(art.mode, "STANDBY", "the runtime is back on standby")
T.ok(joined(aout):find("HA_CTL standby result=ok", 1, true) ~= nil,
    "the revoke is printed")
T.ok(joined(aout):find("reason=manual_revoke", 1, true) ~= nil,
    "the printed revoke names the reason")
T.ok(has_log(anode, "HA_CTL standby result=ok"), "the revoke is logged")

local ares2, aout2 = run(anode, "standby", { backup = abackup })
T.eq(ares2.ok, true, "a second standby is still fine")
T.eq(ares2.changed, false, "a second standby changes nothing")
T.eq(#abackup.calls, 1, "a second standby does not reach the module")
T.ok(joined(aout2):find("HA_CTL standby result=noop", 1, true) ~= nil,
    "the idle no-op is printed")
T.ok(joined(aout2):find("mode=STANDBY", 1, true) ~= nil, "the no-op names the mode")
T.ok(has_log(anode, "HA_CTL standby result=noop"), "the idle no-op is logged")

local wbackup = make_backup({ standby_ok = false })
local wnode = make_node()
local wrt = make_rt({ node = wnode, mode = "ACTIVE", dhcp_server = { lo = 1, hi = 2 } })
wnode.ha = wrt
local wres, wout = run(wnode, "standby", { backup = wbackup })
T.eq(wres.changed, false, "a module that reports no change is reported as noop")
T.ok(joined(wout):find("result=noop", 1, true) ~= nil, "the refused revoke is printed as noop")

local nrnode = make_node()
local nrres = run(nrnode, "standby", { backup = make_backup() })
T.eq(nrres.ok, false, "standby without a runtime is refused")
T.eq(nrres.reason, "no_runtime", "the missing runtime blocks standby")

-- ===== takeover (the --yes guard) ==========================================
local tnode = make_node()
local trt = make_rt({ node = tnode })
tnode.ha = trt
local tbackup = make_backup()
local tres, tout = run(tnode, "takeover", { backup = tbackup })
T.eq(tres.ok, false, "takeover without --yes is refused")
T.eq(tres.reason, "no_confirm", "the refusal names the missing confirmation")
T.eq(#tbackup.calls, 0, "the unconfirmed takeover never reached the module")
T.eq(trt.mode, "STANDBY", "the unconfirmed takeover changed nothing")
T.ok(joined(tout):find("HA_CTL reject reason=no_confirm", 1, true) ~= nil,
    "the refusal is printed")
T.ok(joined(tout):find("takeover --yes", 1, true) ~= nil, "the refusal prints the usage")
T.ok(has_log(tnode, "HA_CTL reject reason=no_confirm"), "the refusal is logged")
T.ok(count_log(tnode, "HA_CTL takeover") == 0, "a refused takeover logs no takeover line")

local ybackup = make_backup()
local yres, yout = run(tnode, "takeover --yes", { backup = ybackup })
T.eq(yres.ok, true, "takeover --yes succeeds")
T.eq(yres.changed, true, "takeover --yes changed the state")
T.eq(#ybackup.calls, 1, "the confirmed takeover reached the module")
T.eq(ybackup.calls[1] and ybackup.calls[1].fn, "takeover", "the module saw takeover")
T.eq(ybackup.calls[1] and ybackup.calls[1].why, "manual", "the takeover reason is manual")
T.eq(trt.mode, "ACTIVE", "the runtime is ACTIVE after the takeover")
T.ok(joined(yout):find("HA_CTL takeover result=active", 1, true) ~= nil,
    "the takeover is printed")
T.ok(has_log(tnode, "HA_CTL takeover result=active"), "the takeover is logged")

local yres2, yout2 = run(tnode, "takeover --yes", { backup = ybackup })
T.eq(yres2.ok, true, "a takeover while ACTIVE is not an error")
T.eq(yres2.changed, false, "a takeover while ACTIVE changes nothing")
T.eq(#ybackup.calls, 1, "a takeover while ACTIVE does not reach the module")
T.ok(joined(yout2):find("result=noop", 1, true) ~= nil, "the ACTIVE no-op is printed")

local dnode = make_node()
local drt = make_rt({ node = dnode })
dnode.ha = drt
local dres, dout = run(dnode, "takeover --yes", { backup = make_backup({ takeover_ok = false }) })
T.eq(dres.ok, false, "a refused takeover is reported")
T.eq(dres.reason, "denied", "the generic refusal names denied")
T.ok(joined(dout):find("HA_CTL takeover result=denied", 1, true) ~= nil,
    "the refusal is printed")
T.ok(has_log(dnode, "HA_CTL takeover result=denied"), "the refusal is logged")

local vnode = make_node()
local vrt = make_rt({ node = vnode, shared = false })
vnode.ha = vrt
local vres, vout = run(vnode, "takeover --yes", { backup = make_backup({ takeover_ok = false }) })
T.eq(vres.reason, "vip_not_local", "a non-shared VIP is named as the reason")
T.ok(joined(vout):find("reason=vip_not_local", 1, true) ~= nil,
    "the non-shared reason is printed")

local cnode = make_node()
local crt = make_rt({ node = cnode })
crt.synced_dhcp_config = nil
cnode.ha = crt
local cres, cout = run(cnode, "takeover --yes", { backup = make_backup({ takeover_ok = false }) })
T.eq(cres.reason, "no_synced_config", "an unsynced runtime is named as the reason")
T.ok(joined(cout):find("reason=no_synced_config", 1, true) ~= nil,
    "the unsynced reason is printed")

local prnode = make_node()
local prres = run(prnode, "takeover --yes", { backup = make_backup() })
T.eq(prres.ok, false, "takeover without a runtime is refused")
T.eq(prres.reason, "no_runtime", "the missing runtime blocks takeover")

-- ===== help, logging and output plumbing ===================================
local hnode = make_node()
local hres, hout = run(hnode, "help", { backup = make_backup() })
T.eq(hres.ok, true, "help succeeds")
T.eq(hres.cmd, "help", "help reports its command")
T.ok(#hout >= 6, "help prints the whole usage")
T.eq(count_log(hnode, "HA_CTL"), 0, "help logs nothing (it changes no state)")

local every_logged = 0
local lnode = make_node()
local lrt = make_rt({ node = lnode, mode = "ACTIVE", dhcp_server = { lo = 1, hi = 2 } })
lnode.ha = lrt
run(lnode, "status", { backup = make_backup() })
run(lnode, "standby", { backup = make_backup() })
run(lnode, "standby", { backup = make_backup() })
for _, entry in ipairs(lnode.logs) do
    if tostring(entry):find("HA_CTL ", 1, true) == 1 then every_logged = every_logged + 1 end
end
T.eq(every_logged, #lnode.logs, "every log line of the CLI starts with HA_CTL")
T.eq(count_log(lnode, "HA_CTL status"), 1, "the status run logged once")
T.ok(count_log(lnode, "HA_CTL standby") >= 2, "both standby runs were logged")

local sink_node = make_node()
sink_node.ha = make_rt({ node = sink_node })
local sink_lines = {}
local sink_result = CTL.execute(sink_node, nil, "status", {
    out = function(text) sink_lines[#sink_lines + 1] = text end,
    backup = make_backup(),
})
T.eq(#sink_lines, #sink_result.lines, "the output sink sees every reported line")
T.eq(sink_lines[1], sink_result.lines[1], "the sink and the result agree")

local saved_out = CTL.out
local mod_lines = {}
CTL.out = function(text) mod_lines[#mod_lines + 1] = text end
local modres = CTL.execute(sink_node, nil, "status", { backup = make_backup() })
CTL.out = saved_out
T.eq(#mod_lines, 1, "M.out is the module-level fallback sink")
T.eq(modres.ok, true, "the module-level sink run still succeeded")

-- a command list from role.txt is a string, not a table
local role_node = make_node()
role_node.ha = make_rt({ node = role_node })
local role_res = run(role_node, "takeover --yes", { backup = make_backup() })
T.eq(role_res.cmd, "takeover", "a role.txt style argument string is parsed")
T.eq(role_res.yes, true, "the flag inside the argument string is honoured")

-- ===== node2 app form ======================================================
local an_node = make_node()
an_node.ha = make_rt({ node = an_node })
local app = CTL.new({ node = an_node, args = "status" })
T.eq(type(app.start), "function", "the app form has start()")
T.ok(app:start() ~= false, "start() never fails the boot")
T.ok(app.result ~= nil, "start() keeps the result")
T.eq(app.result and app.result.cmd, "status", "the app ran the requested command")
T.ok(type(app:status()) == "string", "the app form can print a status line")

local an_backup = make_backup()
local an_app = CTL.new({ node = an_node, args = nil, backup = an_backup })
T.ok(an_app:start() ~= false, "the app form survives a refused command")
T.eq(an_app.result and an_app.result.source, "default", "no argument and no file means status")

local mres = CTL.main(an_node, nil, "status", { backup = make_backup() })
T.eq(mres and mres.cmd, "status", "M.main runs a command")

local ctl_rt = make_rt()
ctl_rt.node = an_node
local cres2 = CTL.control(ctl_rt, "status", { node = an_node, out = function() end })
T.eq(cres2 and cres2.ok, true, "M.control drives one runtime")
T.eq(cres2 and cres2.cmd, "status", "M.control reports the command")

-- a runtime reached only through opts.rt is honoured (the app has no node.ha yet)
local rt_only_node = make_node()
local rt_only = make_rt({ node = rt_only_node })
local rr = CTL.execute(rt_only_node, nil, "status", { rt = rt_only, out = function() end })
T.eq(rr.ok, true, "opts.rt provides the runtime when node.ha is missing")
