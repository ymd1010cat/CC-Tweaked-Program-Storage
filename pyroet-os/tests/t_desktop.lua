--[[- pyroet-os/tests/t_desktop.lua -- the boot chain with the desktop on top.

Covers the wiring in pyroet-os/startup.lua: the permission table is attached
before anything starts, the table is *read* after the first frame, the launcher
is started through the runtime, the commit happens last -- and the launcher
really starts net.app on Enter.

No non-ASCII bytes in this file.
]]

_G.PYROET_STARTUP_TEST = true
local startup = dofile("/system/startup.lua")
rawset(_G, "PYROET_STARTUP_TEST", nil)

local APPS = dofile("/system/kernel/apps.lua")

rawset(_G, "PYROET_LAUNCHER_TEST", true)
local LAUNCHER = assert(loadfile("/system/system/launcher.app/main.lua"))()
rawset(_G, "PYROET_LAUNCHER_TEST", nil)

return function(H)
    local F = H.real_fs()

    -- P6: one /system tree plus a global credential; there is no slot any more
    local function bootable(dir)
        H.mkdirp(dir .. "/system")
        H.write(dir .. "/boot.ok", "PYROET-BOOT-OK-2 version=1.0.0 manifest_sha="
            .. H.HEX64 .. " ts=1700000000000")
    end

    local function reset_perms()
        H.rmrf("/etc/perms")
        return "/etc/perms"
    end

    -- -----------------------------------------------------------------
    H.group("desktop.startup")
    do
        reset_perms()
        local dir = H.case_dir("desktop", "chain")
        bootable(dir)
        local log, lines = H.logger()
        local frames = 0
        local result = startup.run({
            fs = F,
            root = dir,
            log = log,
            apps_root = dir .. "/apps",
            reboot = function() error("rebooted unexpectedly") end,
            frame = function() frames = frames + 1; return true end,
        })
        H.eq("frames", frames, 1)
        H.check("ok", result.ok == true, "boot failed")
        H.check("committed", result.committed == true, "not committed")
        H.table("perms", result.perms)
        H.eq("launcher_name", result.launcher, "launcher")
        H.table("apps", result.apps)

        -- the system packages are scanned next to the boot chain
        H.has(lines, "APP_SCAN root=/system/system loaded=3 failed=0")
        H.has(lines, "APP_LOAD name=launcher version=0.1.0 caps=fs.read,fs.write")
        H.has(lines, "APP_LOAD name=net version=0.1.0 caps=net.rpv,fs.read")
        H.has(lines, "APP_LOAD name=settings version=0.1.0 caps=fs.read")

        -- nothing is decided yet, and reading the table does not prompt
        H.has(lines, "STARTUP_PERMS_READY root=/etc/perms")
        H.has(lines, "STARTUP_PERMS_TABLE apps=3 loaded=0 pending=3 bad=0")
        H.eq("no_prompt_before_launcher", H.count(lines, "PERMS_PROMPT"), 1)
        H.has(lines, "PERMS_PROMPT app=launcher caps=fs.read,fs.write")

        -- a system package is granted what it declares, and the answers persist
        H.has(lines, "PERMS_PREGRANT app=launcher cap=fs.read")
        H.has(lines, "PERMS_DECISION app=launcher cap=fs.write granted=true")
        H.has(lines, "APP_PERMS_APPLIED app=launcher granted=2 denied=0")
        H.has(lines, "STARTUP_LAUNCHER_STARTED name=launcher")
        H.has(lines, "APP_START name=launcher")
        H.has(lines, "STARTUP_DESKTOP_TICK advanced=true")
        H.eq("launcher_running", result.apps:app("launcher").state, "running")
        H.eq("net_loaded_only", result.apps:app("net").state, "loaded")
        H.eq("settings_loaded_only", result.apps:app("settings").state, "loaded")

        local cfg = H.read("/etc/perms/launcher.cfg")
        H.contains("cfg_header", cfg, "# PYROET-PERMS-1 app=launcher")
        H.contains("cfg_read", cfg, "fs.read=granted")
        H.contains("cfg_write", cfg, "fs.write=granted")
        H.eq("no_net_decision_yet", H.exists("/etc/perms/net.cfg"), false)

        -- order: frame, then permission table, then launcher, then commit
        local ready = H.index_of(lines, "STARTUP_UI_READY")
        local table_at = H.index_of(lines, "STARTUP_PERMS_TABLE")
        local launcher_at = H.index_of(lines, "STARTUP_LAUNCHER_STARTED")
        local commit_at = H.index_of(lines, "STARTUP_COMMITTED")
        H.check("frames_before_table", ready ~= nil and table_at ~= nil
            and ready < table_at, "ready=" .. tostring(ready) .. " table=" .. tostring(table_at))
        H.check("table_before_launcher", table_at ~= nil and launcher_at ~= nil
            and table_at < launcher_at, "table=" .. tostring(table_at)
            .. " launcher=" .. tostring(launcher_at))
        H.check("launcher_before_commit", launcher_at ~= nil and commit_at ~= nil
            and launcher_at < commit_at, "launcher=" .. tostring(launcher_at)
            .. " commit=" .. tostring(commit_at))
        H.ascii_check("logs_ascii", H.joined(lines))
    end

    -- -----------------------------------------------------------------
    H.group("desktop.fallback")
    do
        reset_perms()
        local dir = H.case_dir("desktop", "fallback")
        bootable(dir)
        local apps_root = dir .. "/apps"
        H.app_package(apps_root .. "/hello.app", {
            manifest = 'return { name = "hello", version = "0.1.0",'
                .. ' capabilities = { "fs.read" } }',
            main = "return function(manifest, api) api.yield() end",
        })
        local log, lines = H.logger()
        local result = startup.run({
            fs = F,
            root = dir,
            log = log,
            apps_root = apps_root,
            system_root = false,
            reboot = function() error("rebooted unexpectedly") end,
            frame = function() return true end,
        })
        H.check("fallback_ok", result.ok == true, "boot failed")
        H.has(lines, "STARTUP_LAUNCHER_MISSING name=launcher")
        H.has(lines, "STARTUP_FALLBACK name=hello state=running")
        H.eq("fallback_name", result.launcher, "hello")
        H.eq("hello_running", result.apps:app("hello").state, "running")
        -- a user package has no image grant: the boot policy denies, so the app
        -- runs with the capability stub instead of a silent grant
        H.has(lines, "PERMS_DECISION app=hello cap=fs.read granted=false")
        H.has(lines, "APP_PERMS_APPLIED app=hello granted=0 denied=1")
        H.lacks("no_system_scan", lines, "APP_SCAN root=/system/system")
    end

    -- -----------------------------------------------------------------
    H.group("desktop.denied")
    do
        reset_perms()
        local dir = H.case_dir("desktop", "denied")
        bootable(dir)
        local log, lines = H.logger()
        local result = startup.run({
            fs = F,
            root = dir,
            log = log,
            apps_root = dir .. "/apps",
            ask = function() return false end,
            reboot = function() error("rebooted unexpectedly") end,
            frame = function() return true end,
        })
        H.check("denied_ok", result.ok == true, "a denial must not block the boot")
        H.has(lines, "PERMS_PROMPT app=launcher caps=fs.read,fs.write")
        H.has(lines, "PERMS_DECISION app=launcher cap=fs.read granted=false")
        H.has(lines, "APP_PERMS_APPLIED app=launcher granted=0 denied=2")
        H.has(lines, "STARTUP_LAUNCHER_STARTED name=launcher")
        H.eq("denied_launcher_running", result.apps:app("launcher").state, "running")
        -- the launcher tried to read, got the stub, and kept going
        H.has(lines, "APP_CAP_DENIED app=launcher cap=fs.read")
        H.contains("denied_cfg", H.read("/etc/perms/launcher.cfg") or "",
            "fs.read=denied")
        H.lacks("no_grant_on_deny", lines, "PERMS_PREGRANT app=launcher")
    end

    -- -----------------------------------------------------------------
    H.group("desktop.launch_net")
    do
        local log, lines = H.logger()
        local rt = APPS.new({ fs = F, log = log, apps_root = "/system/system" })
        H.eq("scan", rt:scan(), 3)

        local function read_file(path)
            if not F.exists(path) then return nil end
            local handle = F.open(path, "r")
            if not handle then return nil end
            local text = handle.readAll()
            handle.close()
            return text
        end

        local api = {
            fs = {
                read = function(path) return read_file(path) end,
                list = function(path)
                    if not F.exists(path) then return nil, "no directory" end
                    return F.list(path)
                end,
                exists = function(path) return F.exists(path) end,
                write = function(path, text) return H.write(path, text) end,
                makeDir = function(path) return pcall(F.makeDir, path) end,
            },
            sys = {
                status = function()
                    return { health = "ok", services = {
                        { name = "net", state = "running", healthy = "ok" },
                    } }
                end,
                apps = function() return rt:status().apps end,
                launch = function(name) return rt:start(name) end,
            },
            log = function(message) end,
            yield = function() end,
        }

        local state = LAUNCHER.build(api)
        H.eq("entries", #state.entries, 3)
        H.eq("entry_names", table.concat({
            state.entries[1].name, state.entries[2].name, state.entries[3].name }, ","),
            "launcher,net,settings")
        H.eq("net_version", state.entries[2].version, "0.1.0")
        local lines_first = LAUNCHER.render(state, 26, 20)
        H.eq("render_rows", #lines_first, 20)
        H.contains("status_first", lines_first[20], "3 apps sel 1/3")

        -- Enter on the second row starts net.app through the runtime
        H.eq("down", LAUNCHER.handle_key(state, "down", api), "move")
        H.eq("selected", state.entries[state.index].name, "net")
        H.eq("enter", LAUNCHER.handle_key(state, "enter", api), "launch")
        H.eq("launch_message", state.message, "started net")
        H.eq("net_running", rt:app("net").state, "running")
        H.has(lines, "APP_START name=net")
        rt:tick()
        H.has(lines, "APP_LOG app=net msg=capability unavailable: net.rpv")
        H.eq("still_running", rt:app("net").state, "running")

        -- and the whole frame loop does the same from a key sequence
        local rt2 = APPS.new({ fs = F, log = function() end, apps_root = "/system/system" })
        rt2:scan()
        local api2 = {
            fs = api.fs,
            sys = {
                status = api.sys.status,
                apps = function() return rt2:status().apps end,
                launch = function(name) return rt2:start(name) end,
            },
            log = function() end,
            yield = function() end,
        }
        local seen = nil
        local run_state = LAUNCHER.run(nil, api2, {
            max_frames = 3,
            keys = { "down", "enter" },
            paint = false,
            each = function(value) seen = value end,
        })
        H.eq("run_launched", run_state.launched, "net")
        H.eq("run_net_running", rt2:app("net").state, "running")
        H.table("run_seen", seen)
        H.eq("run_seen_index", seen and seen.index, 2)
        rt2:kill("net")
        rt:kill("net")
    end

    -- -----------------------------------------------------------------
    H.group("desktop.system_surface")
    do
        -- the host decides who sees api.sys: a system package gets it, a user
        -- package gets the stubs, and neither one raises
        local dir = H.case_dir("desktop", "sys")
        local system_dir = dir .. "/system"
        H.app_package(system_dir .. "/inner.app", {
            manifest = 'return { name = "inner", version = "0.1.0" }',
            main = [[
return function(manifest, api)
    local list = api.sys.apps()
    api.log("apps=" .. tostring(type(list)) .. " count="
        .. tostring(type(list) == "table" and #list or -1))
    local called, why = api.sys.launch("inner")
    api.log("launch=" .. tostring(called) .. " why=" .. tostring(why))
    api.yield()
end
]],
        })
        H.app_package(dir .. "/apps/user.app", {
            manifest = 'return { name = "user", version = "0.1.0" }',
            main = [[
return function(manifest, api)
    local called, value, why = pcall(api.sys.apps)
    api.log("sys=" .. tostring(called) .. " value=" .. tostring(value)
        .. " why=" .. tostring(why))
    api.yield()
end
]],
        })

        local log, lines = H.logger()
        local rt
        rt = APPS.new({
            fs = F,
            log = log,
            apps_root = dir .. "/apps",
            sys = function(record)
                local record_dir = tostring(record and record.dir or "")
                if record_dir:sub(1, #system_dir + 1) == system_dir .. "/" then
                    return {
                        status = function() return { health = "ok", services = {} } end,
                        apps = function() return rt:status().apps end,
                        perms = function() return {} end,
                        launch = function(name) return rt:start(name) end,
                    }
                end
                return nil
            end,
        })
        rt:scan()
        rt:scan(system_dir)
        H.eq("sys_apps_loaded", rt:app("inner") ~= nil, true)
        rt:start("inner")
        rt:tick()
        H.has(lines, "APP_LOG app=inner msg=apps=table count=2")
        H.has(lines, "APP_LOG app=inner msg=launch=nil why=app already running: inner")
        rt:start("user")
        rt:tick()
        H.has(lines, "APP_LOG app=user msg=sys=true value=nil why=system unavailable: apps")
        H.has(lines, "APP_SYS_UNAVAILABLE app=user fn=apps")
        H.eq("user_running", rt:app("user").state, "running")
        rt:kill("inner")
        rt:kill("user")
    end
end
