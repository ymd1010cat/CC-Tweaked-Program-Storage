-- run.lua -- CardKey offline regression suite (CraftOS-PC headless).
-- Staged as /tests/run.lua and started by /startup.lua.
--
-- The suite drives the real staged modules through fake hardware:
--   * common/cardkey_mode.lua        (run mode resolution, pass/free)
--   * server/auth/cardkey_config.lua (config table and its mode field)
--   * server/system/cardkey_server.lua (protocol, replay, lockout, free mode)
--   * server/system/disk_writer.lua  (real copy transaction for free mode)
--   * server/system/cardkey_admin.lua (MODE line on the home screen)
--   * terminal/auth/cardkey_client.lua, terminal/system/{kernel,ui}.lua
--   * terminal/system/netcheck.lua, terminal/auth/session.lua
--
-- Every t_*.lua file in /tests is loaded and called with the harness table, so
-- adding a module needs no edit here.

local H = dofile("/tests/harness.lua")
H.install()

H.say("CARDKEY OFFLINE SUITE")
H.say("Protocol: cardkey_v1 / channel 3")

---------------------------------------------------------------------------
-- baseline constants (behaviour this suite pins down)
---------------------------------------------------------------------------

H.group("static")
H.scenario("static", function()
    local conf = dofile("/auth/cardkey_config.lua")
    H.check("static.protocol", conf.protocol == "cardkey_v1", conf.protocol)
    H.check("static.channel", conf.channel == 3, conf.channel)
    H.check("static.reservation_ttl", conf.reservation_ttl_ms == 300000,
        conf.reservation_ttl_ms)
    H.check("static.default_uses", conf.default_uses == 2, conf.default_uses)
    H.check("static.max_batch", conf.max_batch == 200, conf.max_batch)
    H.check("static.payload_dir", conf.payload_dir == "/payload", conf.payload_dir)
    H.check("static.export_dir", conf.export_dir == "/cardkeys", conf.export_dir)
    H.check("static.admin_file", conf.admin_file == "/auth/admin.db", conf.admin_file)
    H.check("static.challenge_ttl", conf.challenge_ttl_ms == 15000,
        conf.challenge_ttl_ms)
    H.check("static.mode_default_pass", conf.mode == "pass", conf.mode)
    H.check("static.mode_source_config", conf.mode_source == "config", conf.mode_source)
end)

---------------------------------------------------------------------------
-- module discovery and run
---------------------------------------------------------------------------

local modules = {}
for _, name in ipairs(fs.list("/tests")) do
    if name:match("^t_.+%.lua$") then
        modules[#modules + 1] = name
    end
end
table.sort(modules)

for _, name in ipairs(modules) do
    local path = "/tests/" .. name
    H.resetStubs()
    local marker = fs.open("/logs/last_module.txt", "wb")
    if marker then
        marker.write(name)
        marker.close()
    end
    local okLoad, chunk = pcall(dofile, path)
    if not okLoad then
        H.check(name .. ".load", false, tostring(chunk))
    else
        local okRun, err = pcall(chunk, H)
        if not okRun then
            H.check(name .. ".run", false, tostring(err))
        end
    end
end

H.say("OFFLINE_PASS " .. tostring(H.pass))
H.say("OFFLINE_FAIL " .. tostring(H.fail))
H.say("OFFLINE_GROUPS " .. tostring(H.groupCount))
H.say("OFFLINE_RESULT pass=" .. tostring(H.pass) .. " fail=" .. tostring(H.fail))
H.say("TEST_DONE")

-- Shut the computer down so CraftOS-PC exits and flushes stdout; otherwise the
-- runner has to kill the process and may lose buffered output.
pcall(function()
    os.shutdown()
end)
