--[[- pyroet-os/tests/t_caps.lua -- O3/O4: the `input`, `terminal` and `net.rhtp` capabilities.

What a new capability has to prove, and what this suite pins for these two:

    declared + host supplied  -> the app reaches the host object
    not declared / denied     -> nil, "capability denied: <cap>" + APP_CAP_DENIED
    declared + no host        -> nil, "capability unavailable: <cap>"
    legacy manifest (no caps) -> no implicit grant, the app still starts and runs
    decision file without it  -> denied: a stale file cannot grow permissions
    file grants what is not declared -> still denied (the manifest is the ceiling)

`input` and `terminal` are independent: a package may take the keyboard without
the screen and vice versa, and neither is implied by any other capability. The
handle shapes are asserted too, because a denial must never become a nil-index:
`api.terminal` stays a table, `api.input.pullEvent` stays a function and
`api.input.keys` stays a table in every branch.

No non-ASCII bytes in this file.
]]

local apps = dofile("/system/kernel/apps.lua")
local perms = dofile("/system/kernel/permissions.lua")

return function(H)
    local F = H.real_fs()

    local function new_rt(log, opts)
        local o = opts or {}
        return apps.new({
            fs = F,
            log = log,
            apps_root = o.apps_root,
            input = o.input,
            terminal = o.terminal,
            rhtp = o.rhtp,
        })
    end

    local function status_of(rt, name)
        local status = rt:status()
        for i = 1, #status.apps do
            if status.apps[i].name == name then return status.apps[i] end
        end
        return nil
    end

    local KEYS = {
        getName = function(code) return "key" .. tostring(code) end,
    }

    -- hosts the way startup.lua hands them in: one table for the event side and
    -- one term-like table for the screen side; `seen`/`written` record the call
    local function fake_input(seen)
        return {
            pullEvent = function(...)
                seen[#seen + 1] = { ... }
                return "key", 30
            end,
            keys = KEYS,
        }
    end

    local function fake_term(written)
        return {
            marker = "term-host",
            write = function(text)
                written[#written + 1] = tostring(text)
                return true
            end,
            getSize = function() return 26, 20 end,
        }
    end

    -- -----------------------------------------------------------------
    H.group("caps.list")
    do
        H.table("caps_list", apps.CAPS)
        H.eq("caps_count", #apps.CAPS, 10)
        H.eq("input_known", apps.cap_known("input"), true)
        H.eq("terminal_known", apps.cap_known("terminal"), true)
        -- only the two names are capabilities; their sub-surfaces are not
        H.eq("input_pullevents_not_cap", apps.cap_known("input.pullEvent"), false)
        H.eq("keys_not_cap", apps.cap_known("keys"), false)
        H.eq("term_not_cap", apps.cap_known("term"), false)
        -- the decision module and the runtime must agree entry for entry, order
        -- included: the saved file follows the permission module's list
        H.eq("perms_count", #perms.CAPS, #apps.CAPS)
        for i = 1, #apps.CAPS do
            H.eq("cap_" .. tostring(i) .. "_same", perms.CAPS[i], apps.CAPS[i])
        end
        -- neither is a system call: api.sys is a separate, host-supplied surface
        local leaked = false
        for i = 1, #apps.SYS_FUNCTIONS do
            local name = apps.SYS_FUNCTIONS[i]
            if name == "input" or name == "terminal" then leaked = true end
        end
        H.check("not_a_sys_function", leaked == false, "input/terminal leaked into api.sys")
    end

    -- -----------------------------------------------------------------
    H.group("caps.denied")
    do
        local dir = H.case_dir("caps", "denied")
        local log, lines = H.logger()
        -- the hosts exist; the app simply did not declare the capabilities
        local rt = new_rt(log, { input = fake_input({}), terminal = fake_term({}) })
        H.app_package(dir .. "/apps/denied.app", {
            manifest = 'return { name = "denied", capabilities = { "fs.read" } }',
            main = [[
return function(manifest, api)
    local pull, perr = api.input.pullEvent("key")
    api.log("pull=" .. tostring(pull) .. " err=" .. tostring(perr))
    local key, kerr = api.input.keys.getName(30)
    api.log("key=" .. tostring(key) .. " err=" .. tostring(kerr))
    local wrote, terr = api.terminal.write("x")
    api.log("term=" .. tostring(wrote) .. " err=" .. tostring(terr))
    local size = api.terminal.getSize()
    api.log("size=" .. tostring(size))
    api.log("types=" .. type(api.input) .. "/" .. type(api.input.pullEvent)
        .. "/" .. type(api.input.keys) .. "/" .. type(api.terminal))
    api.yield()
end
]],
        })
        local record = rt:load(dir .. "/apps/denied.app")
        rt:start("denied")
        H.eq("denied_tick", rt:tick(), 1)
        H.has(lines, "APP_LOG app=denied msg=pull=nil err=capability denied: input")
        H.has(lines, "APP_LOG app=denied msg=key=nil err=capability denied: input")
        H.has(lines, "APP_LOG app=denied msg=term=nil err=capability denied: terminal")
        H.has(lines, "APP_LOG app=denied msg=size=nil")
        -- the stubs keep their shape: table / function / table / table
        H.has(lines, "APP_LOG app=denied msg=types=table/function/table/table")
        H.eq("input_denied_log", rt:count("APP_CAP_DENIED app=denied cap=input"), 2)
        H.eq("terminal_denied_log", rt:count("APP_CAP_DENIED app=denied cap=terminal"), 2)
        H.eq("denied_total", record and record.denied, 4)
        H.eq("denied_alive", record and record.state, "running")
        -- per-capability tally, which is what status exposes (aggregate is not enough)
        local entry = status_of(rt, "denied")
        H.table("status_denied_caps", entry and entry.denied_caps)
        H.eq("status_denied_input", entry and entry.denied_caps.input, 2)
        H.eq("status_denied_terminal", entry and entry.denied_caps.terminal, 2)
        H.ascii_check("denied_ascii", H.joined(lines))
    end

    -- -----------------------------------------------------------------
    H.group("caps.input_granted")
    do
        local dir = H.case_dir("caps", "input")
        local log, lines = H.logger()
        local seen = {}
        local rt = new_rt(log, { input = fake_input(seen) })
        H.app_package(dir .. "/apps/granted.app", {
            manifest = 'return { name = "granted", capabilities = { "input" } }',
            main = [[
return function(manifest, api)
    local a, b = api.input.pullEvent("key", "timer")
    api.log("pull=" .. tostring(a) .. "/" .. tostring(b))
    api.log("keyname=" .. tostring(api.input.keys.getName(30)))
    local wrote, terr = api.terminal.write("x")
    api.log("term=" .. tostring(wrote) .. " err=" .. tostring(terr))
    api.yield()
end
]],
        })
        rt:load(dir .. "/apps/granted.app")
        rt:start("granted")
        rt:tick()
        H.eq("host_called_once", #seen, 1)
        H.eq("host_arg_one", seen[1] and seen[1][1], "key")
        H.eq("host_arg_two", seen[1] and seen[1][2], "timer")
        H.has(lines, "APP_LOG app=granted msg=pull=key/30")
        H.has(lines, "APP_LOG app=granted msg=keyname=key30")
        H.lacks("input_not_denied", lines, "APP_CAP_DENIED app=granted cap=input")
        -- the other UI capability is independent and still refused
        H.has(lines, "APP_LOG app=granted msg=term=nil err=capability denied: terminal")
        H.has(lines, "APP_CAP_DENIED app=granted cap=terminal")
    end

    -- -----------------------------------------------------------------
    H.group("caps.terminal_granted")
    do
        local dir = H.case_dir("caps", "terminal")
        local log, lines = H.logger()
        local written = {}
        local rt = new_rt(log, { terminal = fake_term(written) })
        H.app_package(dir .. "/apps/painter.app", {
            manifest = 'return { name = "painter", capabilities = { "terminal" } }',
            main = [[
return function(manifest, api)
    api.log("marker=" .. tostring(api.terminal.marker))
    local cols, rows = api.terminal.getSize()
    api.log("size=" .. tostring(cols) .. "x" .. tostring(rows))
    local ok = api.terminal.write("hello")
    api.log("wrote=" .. tostring(ok))
    local pull, perr = api.input.pullEvent("key")
    api.log("pull=" .. tostring(pull) .. " err=" .. tostring(perr))
    api.yield()
end
]],
        })
        rt:load(dir .. "/apps/painter.app")
        rt:start("painter")
        rt:tick()
        -- granted means the host object itself, not a copy and not a proxy
        H.has(lines, "APP_LOG app=painter msg=marker=term-host")
        H.has(lines, "APP_LOG app=painter msg=size=26x20")
        H.has(lines, "APP_LOG app=painter msg=wrote=true")
        H.eq("bytes_written", #written, 1)
        H.eq("written_text", written[1], "hello")
        H.has(lines, "APP_LOG app=painter msg=pull=nil err=capability denied: input")
        H.has(lines, "APP_CAP_DENIED app=painter cap=input")
        H.lacks("terminal_not_denied", lines, "APP_CAP_DENIED app=painter cap=terminal")
    end

    -- -----------------------------------------------------------------
    H.group("caps.unavailable")
    do
        local dir = H.case_dir("caps", "nohost")
        local log, lines = H.logger()
        local rt = new_rt(log)   -- no hosts at all (a machine with no UI)
        H.app_package(dir .. "/apps/nohost.app", {
            manifest = 'return { name = "nohost", capabilities = { "input", "terminal" } }',
            main = [[
return function(manifest, api)
    local pull, perr = api.input.pullEvent("key")
    api.log("pull=" .. tostring(pull) .. " err=" .. tostring(perr))
    local key, kerr = api.input.keys.getName(30)
    api.log("key=" .. tostring(key) .. " err=" .. tostring(kerr))
    local wrote, terr = api.terminal.write("x")
    api.log("term=" .. tostring(wrote) .. " err=" .. tostring(terr))
    api.log("types=" .. type(api.input.pullEvent) .. "/" .. type(api.input.keys)
        .. "/" .. type(api.terminal))
    api.yield()
end
]],
        })
        rt:load(dir .. "/apps/nohost.app")
        rt:start("nohost")
        rt:tick()
        -- declared but not supplied is "unavailable", never "denied"
        H.has(lines, "APP_LOG app=nohost msg=pull=nil err=capability unavailable: input")
        H.has(lines, "APP_LOG app=nohost msg=key=nil err=capability unavailable: input")
        H.has(lines, "APP_LOG app=nohost msg=term=nil err=capability unavailable: terminal")
        H.has(lines, "APP_CAP_UNAVAILABLE app=nohost cap=input")
        H.has(lines, "APP_CAP_UNAVAILABLE app=nohost cap=terminal")
        H.lacks("unavailable_not_denied", lines, "APP_CAP_DENIED app=nohost")
        H.has(lines, "APP_LOG app=nohost msg=types=function/table/table")
    end


    -- -----------------------------------------------------------------
    H.group("caps.rhtp")
    -- `net.rhtp` (DECISIONS.md 45) is the service protocol capability: the two
    -- api entries are gated FUNCTIONS, so a denial is a callable stub and never a
    -- nil-index; a declared capability with no host client is "unavailable".
    do
        local dir = H.case_dir("caps", "rhtp")
        local log, lines = H.logger()
        local seen = {}
        local client = {
            get = function(url)
                seen[#seen + 1] = { "get", url }
                return "body:" .. tostring(url)
            end,
            fetch = function(url, size)
                seen[#seen + 1] = { "fetch", url, size }
                return "chunked:" .. tostring(size)
            end,
        }
        local rt = new_rt(log, { rhtp = client })
        H.app_package(dir .. "/apps/denied.app", {
            manifest = 'return { name = "denied", capabilities = { "fs.read" } }',
            main = [[
return function(manifest, api)
    local body, err = api.net.rhtp_get("rhtp://box/x")
    api.log("get=" .. tostring(body) .. " err=" .. tostring(err))
    local data, derr = api.net.rhtp_fetch("rhtp://box/big", 10)
    api.log("fetch=" .. tostring(data) .. " err=" .. tostring(derr))
    api.log("types=" .. type(api.net.rhtp_get) .. "/" .. type(api.net.rhtp_fetch))
    api.yield()
end
]],
        })
        rt:load(dir .. "/apps/denied.app")
        rt:start("denied")
        rt:tick()
        H.has(lines, "APP_LOG app=denied msg=get=nil err=capability denied: net.rhtp")
        H.has(lines, "APP_LOG app=denied msg=fetch=nil err=capability denied: net.rhtp")
        -- both stay functions: the denial keeps the shape of the granted api
        H.has(lines, "APP_LOG app=denied msg=types=function/function")
        H.eq("rhtp_denied_log", rt:count("APP_CAP_DENIED app=denied cap=net.rhtp"), 2)
        H.eq("rhtp_host_untouched", #seen, 0)

        -- declared + host supplied: the real client is reached, arguments pass
        -- through, and the two names are separate entries
        H.app_package(dir .. "/apps/net.app", {
            manifest = 'return { name = "netuser", capabilities = { "net.rhtp" } }',
            main = [[
return function(manifest, api)
    local body = api.net.rhtp_get("rhtp://box/x")
    api.log("get=" .. tostring(body))
    local data = api.net.rhtp_fetch("rhtp://box/big", 10)
    api.log("fetch=" .. tostring(data))
    api.yield()
end
]],
        })
        local rt2 = new_rt(log, { rhtp = client })
        rt2:load(dir .. "/apps/net.app")
        rt2:start("netuser")
        rt2:tick()
        H.has(lines, "APP_LOG app=netuser msg=get=body:rhtp://box/x")
        H.has(lines, "APP_LOG app=netuser msg=fetch=chunked:10")
        H.eq("rhtp_host_calls", #seen, 2)
        H.eq("rhtp_get_url", seen[1] and seen[1][2], "rhtp://box/x")
        H.eq("rhtp_fetch_size", seen[2] and seen[2][3], 10)
        H.lacks("rhtp_not_denied", lines, "APP_CAP_DENIED app=netuser cap=net.rhtp")

        -- declared + no host client: "unavailable", which is not a denial
        H.app_package(dir .. "/apps/nohost.app", {
            manifest = 'return { name = "nohost", capabilities = { "net.rhtp" } }',
            main = [[
return function(manifest, api)
    local body, err = api.net.rhtp_get("rhtp://box/x")
    api.log("nohost=" .. tostring(body) .. " err=" .. tostring(err))
    api.yield()
end
]],
        })
        local rt3 = new_rt(log, {})
        rt3:load(dir .. "/apps/nohost.app")
        rt3:start("nohost")
        rt3:tick()
        H.has(lines,
            "APP_LOG app=nohost msg=nohost=nil err=capability unavailable: net.rhtp")
        H.has(lines, "APP_CAP_UNAVAILABLE app=nohost cap=net.rhtp")
        H.lacks("nohost_not_denied", lines, "APP_CAP_DENIED app=nohost cap=net.rhtp")
    end

    -- -----------------------------------------------------------------
    H.group("caps.unknown")
    do
        local ok = apps.validate_manifest({
            name = "d", capabilities = { "input", "terminal" },
        }, "/x")
        H.table("both_ok", ok)
        H.eq("both_count", ok and #ok.capabilities, 2)

        local dup = apps.validate_manifest({
            name = "d", capabilities = { "input", "input", "terminal", "terminal" },
        }, "/x")
        H.eq("both_deduped", dup and #dup.capabilities, 2)

        -- a near miss is still unknown: the list is exact, no prefixes
        local cases = {
            { "keyboard", "unknown capability 'keyboard'" },
            { "input.pullEvent", "unknown capability 'input.pullEvent'" },
            { "key", "unknown capability 'key'" },
            { "term", "unknown capability 'term'" },
        }
        for i = 1, #cases do
            local case = cases[i]
            local value, err = apps.validate_manifest({
                name = "d", capabilities = { "input", case[1] },
            }, "/x")
            H.check(case[1] .. "_rejected", value == nil, "accepted capability " .. case[1])
            H.contains(case[1] .. "_error", err, case[2])
        end
    end

    -- -----------------------------------------------------------------
    H.group("caps.legacy")
    do
        local dir = H.case_dir("caps", "legacy")
        local log, lines = H.logger()
        local rt = new_rt(log, { input = fake_input({}), terminal = fake_term({}) })
        -- a package written before these capabilities existed: no `capabilities`
        H.app_package(dir .. "/apps/legacy.app", {
            manifest = 'return { name = "legacy", version = "0.1.0" }',
            main = [[
return function(manifest, api)
    local pull, perr = api.input.pullEvent("key")
    api.log("pull=" .. tostring(pull) .. " err=" .. tostring(perr))
    local wrote, terr = api.terminal.write("x")
    api.log("term=" .. tostring(wrote) .. " err=" .. tostring(terr))
    api.log("declared=" .. tostring(#manifest.capabilities))
    api.yield()
end
]],
        })
        local record = rt:load(dir .. "/apps/legacy.app")
        H.has(lines, "APP_LOAD name=legacy version=0.1.0 caps=-")
        local started = rt:start("legacy")
        H.eq("legacy_started", started, true)
        rt:tick()
        -- the compatibility policy: an empty declaration is an empty grant, so
        -- the two new capabilities are denied and nothing is implicitly granted
        H.has(lines, "APP_LOG app=legacy msg=pull=nil err=capability denied: input")
        H.has(lines, "APP_LOG app=legacy msg=term=nil err=capability denied: terminal")
        H.has(lines, "APP_LOG app=legacy msg=declared=0")
        H.has(lines, "APP_CAP_DENIED app=legacy cap=input")
        H.has(lines, "APP_CAP_DENIED app=legacy cap=terminal")
        H.eq("legacy_state", record and record.state, "running")
        H.eq("legacy_starts", record and record.starts, 1)
        local entry = status_of(rt, "legacy")
        H.eq("legacy_caps_empty", entry and #entry.capabilities, 0)
        H.eq("legacy_denied_input", entry and entry.denied_caps.input, 1)
        H.eq("legacy_denied_terminal", entry and entry.denied_caps.terminal, 1)
    end

    -- -----------------------------------------------------------------
    H.group("caps.perms_file")
    do
        local dir = H.case_dir("caps", "perms")
        local log, lines = H.logger()
        H.write(dir .. "/data.txt", "DATA")
        -- a decision file that predates the two capabilities: it names only the
        -- old one, so `input` is missing from the decision and must be denied
        H.write(dir .. "/perms/app.cfg", "# PYROET-PERMS-1 app=app\nfs.read=granted\n")
        H.app_package(dir .. "/apps/app.app", {
            manifest = 'return { name = "app", capabilities = { "fs.read", "input" } }',
            main = string.format([[
return function(manifest, api)
    local data, derr = api.fs.read(%q)
    api.log("read=" .. tostring(data) .. " err=" .. tostring(derr))
    local pull, perr = api.input.pullEvent("key")
    api.log("pull=" .. tostring(pull) .. " err=" .. tostring(perr))
    api.yield()
end
]], dir .. "/data.txt"),
        })
        local p = perms.new({
            fs = F, log = log, root = dir .. "/perms",
            ask = function() return false end,
        })
        local rt = new_rt(log, { input = fake_input({}) })
        rt:set_permissions(p)
        rt:load(dir .. "/apps/app.app")
        rt:start("app")
        rt:tick()
        H.has(lines, "APP_PERMS_APPLIED app=app granted=1 denied=1")
        H.has(lines, "APP_LOG app=app msg=read=DATA err=nil")
        -- missing from the file = denied, and no question is asked at runtime
        -- missing from the file = undecided, not denied: the start asks the same
        -- policy once (D1-fix), which denies here, and the answer is persisted
        H.has(lines, "APP_LOG app=app msg=pull=nil err=capability denied: input")
        H.lacks("no_prompt_for_input", lines, "PERMS_PROMPT app=app")
        H.has(lines, "PERMS_STALE app=app caps=input")
        local entry = status_of(rt, "app")
        H.eq("file_grants_read", entry and entry.grants["fs.read"], true)
        H.eq("file_no_input_grant", entry and entry.grants["input"], false)
        H.eq("file_denied_input", entry and entry.denied_caps.input, 1)
        H.contains("file_input_persisted", H.read(dir .. "/perms/app.cfg") or "",
            "input=denied")

        -- the manifest is the ceiling: a file entry for an undeclared capability
        -- is pruned and still refused
        H.write(dir .. "/perms/beyond.cfg",
            "# PYROET-PERMS-1 app=beyond\nfs.read=granted\ninput=granted\n")
        H.app_package(dir .. "/apps/beyond.app", {
            manifest = 'return { name = "beyond", capabilities = { "fs.read" } }',
            main = [[
return function(manifest, api)
    local pull, perr = api.input.pullEvent("key")
    api.log("pull=" .. tostring(pull) .. " err=" .. tostring(perr))
    api.yield()
end
]],
        })
        local rt2 = new_rt(log, { input = fake_input({}) })
        rt2:set_permissions(perms.new({
            fs = F, log = log, root = dir .. "/perms",
            ask = function() return false end,
        }))
        rt2:load(dir .. "/apps/beyond.app")
        rt2:start("beyond")
        rt2:tick()
        H.has(lines, "PERMS_PRUNE app=beyond cap=input")
        H.has(lines, "APP_LOG app=beyond msg=pull=nil err=capability denied: input")
        H.has(lines, "APP_CAP_DENIED app=beyond cap=input")
    end

    -- -----------------------------------------------------------------
    H.group("caps.startup")
    do
        -- end to end through the real boot chain: the hosts handed to
        -- startup.run are the ones the app sees, which is the half of "landing"
        -- the runtime tests above cannot prove on their own
        rawset(_G, "PYROET_STARTUP_TEST", true)
        local startup = dofile("/system/startup.lua")
        rawset(_G, "PYROET_STARTUP_TEST", nil)

        local dir = H.case_dir("caps", "chain")
        H.mkdirp(dir .. "/system")
        H.write(dir .. "/system/kernel/ota.lua", "-- ota\n")
        H.write(dir .. "/boot.ok", "PYROET-BOOT-OK-2 version=1.0.0 manifest_sha="
            .. H.HEX64 .. " ts=1700000000000")
        H.app_package(dir .. "/apps/ui.app", {
            manifest = 'return { name = "ui", version = "0.1.0",'
                .. ' capabilities = { "input", "terminal" } }',
            main = [[
return function(manifest, api)
    api.log("marker=" .. tostring(api.terminal.marker))
    local a, b = api.input.pullEvent("key")
    api.log("pull=" .. tostring(a) .. "/" .. tostring(b))
    api.yield()
end
]],
        })

        local seen, written = {}, {}
        local log, lines = H.logger()
        local result = startup.run({
            fs = F,
            root = dir,
            log = log,
            apps_root = dir .. "/apps",
            system_root = false,
            perms_root = dir .. "/perms",
            -- the chain has no interactive prompt (DECISIONS.md 10.4)
            ask = function() return true end,
            launcher = "ui",
            input = fake_input(seen),
            terminal = fake_term(written),
            reboot = function() error("rebooted unexpectedly") end,
            frame = function() return true end,
        })
        H.check("chain_ok", result.ok == true, "ok=" .. tostring(result.ok))
        H.eq("chain_launcher", result.launcher, "ui")
        H.has(lines, "STARTUP_LAUNCHER_STARTED name=ui")
        H.has(lines, "STARTUP_DESKTOP_TICK advanced=true")
        H.has(lines, "APP_LOG app=ui msg=marker=term-host")
        H.has(lines, "APP_LOG app=ui msg=pull=key/30")
        H.eq("chain_host_called", #seen, 1)
        H.lacks("chain_no_cap_denied", lines, "APP_CAP_DENIED app=ui")
        H.has(lines, "APP_PERMS_APPLIED app=ui granted=2 denied=0")
    end
end
