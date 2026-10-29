--[[- pyroet-os/tests/run.lua -- test entry point, runs inside CraftOS-PC headless.

Staged layout (created by tests/run-tests.ps1; since P6-3 the image is one
`/system` tree, with the system apps one level deeper):

    /startup.lua            generated shim: pcall(dofile, "/tests/run.lua")
    /system/startup.lua     pyroet-os/system/startup.lua (loaded with PYROET_STARTUP_TEST)
    /system/boot.lua        pyroet-os/system/boot.lua
    /system/kernel/*.lua    kernel, apps, permissions, installer, ota
    /system/rpv/*.lua       the vendored rpv subset (SHA-256)
    /system/net/*.lua       network service + static hosts
    /system/system/*.app    launcher, settings, net (system apps, image payload)
    /recovery/*.lua         pyroet-os/recovery/proto.lua + flash.lua + bootstrap.lua
    /ota/server.lua         pyroet-os/ota/server.lua (distribution side, not image)
    /install.set            pyroet-os/install.set (budget assertions)
    /tests/*.lua            this file, harness.lua and the t_*.lua suites
    /tests/root-startup.lua the computer-root starter pyroet-os/startup.lua

Every suite is loaded with pcall so one broken file cannot hide the rest, and
the harness still prints the OFFLINE_* summary through H.finish().

No non-ASCII bytes in this file.
]]

local H = dofile("/tests/harness.lua")

-- The desktop apps paint to the real terminal when they run, which would put a
-- 26x20 screen in the middle of the marker stream. The hook exists for exactly
-- that (the apps themselves check it, real boots never set it).
rawset(_G, "PYROET_APP_NOPAINT", true)

H.root = "/t"
H.report_path = "/offline-report.txt"
H.rmrf(H.root)
H.mkdirp(H.root)

local FILES = { "t_boot", "t_kernel", "t_apps", "t_startup",
    "t_net_hosts", "t_net_service", "t_net_app",
    "t_permissions", "t_launcher", "t_settings", "t_desktop",
    "t_installer", "t_ota", "t_ota_server",
    "t_recovery_proto", "t_recovery_flash", "t_recovery_bootstrap",
    "t_layout", "t_budget" }

for i = 1, #FILES do
    local name = FILES[i]
    local path = "/tests/" .. name .. ".lua"
    local ok, chunk, err = pcall(loadfile, path)
    if not ok or not chunk then
        H.group(name .. ".load")
        H.check("loadable", false, tostring(err or chunk))
    else
        -- each suite file is `local mod = dofile(...) return function(H) ... end`,
        -- so the loaded chunk has to be called once to obtain the suite itself
        local built, suite, why = pcall(chunk)
        if not built then
            H.group(name .. ".load")
            H.check("executed", false, tostring(suite))
        elseif type(suite) ~= "function" then
            H.group(name .. ".load")
            H.check("exports_suite", false, "type=" .. type(suite))
        else
            local ran, reason = pcall(suite, H)
            if not ran then
                H.group(name .. ".crash")
                H.check("completed", false, tostring(reason))
            end
        end
    end
end

H.check("suite_count", H.groups >= #FILES,
    "only " .. tostring(H.groups) .. " groups ran")

H.rmrf(H.root)
H.finish()
