-- t_mode.lua -- run mode: config resolution, the override file, and the two
-- end-to-end chains (pass stays exactly as it was, free opens the station).
--
-- The mode resolver (/itnpass_mode.lua) is the single place that decides, and
-- every reader goes through it, so the priority under test is the real one:
-- /auth/itnpass_mode.txt > itnpass_config.mode > "pass". Anything invalid must
-- fail safe to "pass" (a broken override can never open a paid station).

local function run(H)
    local MODE_MODULE = "/itnpass_mode.lua"
    local MODE_FILE = "/auth/itnpass_mode.txt"
    local MODE_LOG = "/auth/itnpass_mode.log"
    local CONFIG = "/auth/itnpass_config.lua"
    local SERVER = "/system/itnpass_server.lua"
    local CLIENT = "/auth/itnpass_client.lua"
    local KERNEL = "/system/kernel.lua"
    local UI = "/system/ui.lua"
    local ADMIN = "/system/itnpass_admin.lua"
    local TERMINAL_STARTUP = "/tests/terminal_startup.lua"
    local SERVER_LOG = "/auth/itnpass_server.log"

    -- Real functions, captured before any test stubs the globals they shadow.
    local realDofile = dofile
    local realLoadfile = loadfile

    local modeModule = realDofile(MODE_MODULE)

    local function deleteFile(path)
        if fs.exists(path) then
            fs.delete(path)
        end
    end

    -- Back to the shipped default: no override file, no mode log.
    local function resetMode()
        deleteFile(MODE_FILE)
        deleteFile(MODE_LOG)
    end

    local function writeMode(text)
        H.writeFile(MODE_FILE, text)
    end

    local function modeLog()
        return H.readFile(MODE_LOG) or ""
    end

    local function serverLog()
        return H.readFile(SERVER_LOG) or ""
    end

    local function summary(...)
        local parts = {}
        for i = 1, select("#", ...) do
            parts[i] = tostring((select(i, ...)))
        end
        return table.concat(parts, "/")
    end

    ------------------------------------------------------------------------
    -- parsing the override file
    ------------------------------------------------------------------------
    H.group("mode.parse")

    H.check("mode.default_is_pass", modeModule.DEFAULT == "pass",
        tostring(modeModule.DEFAULT))
    H.check("mode.pass_is_valid", modeModule.is_valid("pass") == true)
    H.check("mode.free_is_valid", modeModule.is_valid("free") == true)
    H.check("mode.uppercase_is_invalid", modeModule.is_valid("FREE") == false)
    H.check("mode.mixed_case_is_invalid", modeModule.is_valid("Free") == false)
    H.check("mode.nil_is_invalid", modeModule.is_valid(nil) == false)
    H.check("mode.number_is_invalid", modeModule.is_valid(1) == false)
    H.check("mode.empty_is_invalid", modeModule.is_valid("") == false)
    H.check("mode.parse_plain_pass", modeModule.parse("pass") == "pass")
    H.check("mode.parse_plain_free", modeModule.parse("free") == "free")
    H.check("mode.parse_trailing_newline", modeModule.parse("free\n") == "free")
    H.check("mode.parse_crlf", modeModule.parse("free\r\n") == "free")
    H.check("mode.parse_surrounding_spaces", modeModule.parse("  free  ") == "free")
    H.check("mode.parse_blank_lines", modeModule.parse("\n\nfree\n\n") == "free")
    H.check("mode.parse_trailing_comment", modeModule.parse("free # open day\n") == "free")
    H.check("mode.parse_whole_line_comment", modeModule.parse("# open day\nfree\n") == "free")
    H.check("mode.parse_comment_only_is_nil", modeModule.parse("# free\n") == nil)
    H.check("mode.parse_empty_is_nil", modeModule.parse("") == nil)
    H.check("mode.parse_nil_is_nil", modeModule.parse(nil) == nil)
    H.check("mode.parse_garbage_is_nil", modeModule.parse("open") == nil)
    H.check("mode.parse_conflict_is_nil", modeModule.parse("pass\nfree\n") == nil)
    H.check("mode.parse_repeat_is_fine", modeModule.parse("free\nfree\n") == "free")
    H.check("mode.summarize_flattens", modeModule.summarize(" fr ee \n x ") == "fr ee x")
    H.check("mode.summarize_caps_length", #modeModule.summarize(string.rep("x", 200)) == 40)

    ------------------------------------------------------------------------
    -- priority: mode file > config value > default, fail safe to "pass"
    ------------------------------------------------------------------------
    H.group("mode.resolve")
    resetMode()

    local mode, source, problem = modeModule.resolve(nil)
    H.check("mode.resolve_no_config_is_pass", mode == "pass", summary(mode, source))
    H.check("mode.resolve_no_config_source_default", source == "default", tostring(source))
    H.check("mode.resolve_no_config_no_problem", problem == nil, tostring(problem))

    mode, source = modeModule.resolve({})
    H.check("mode.resolve_empty_table_is_pass", mode == "pass" and source == "default",
        summary(mode, source))

    mode, source = modeModule.resolve({ mode = "pass" })
    H.check("mode.resolve_config_pass", mode == "pass" and source == "config",
        summary(mode, source))

    mode, source = modeModule.resolve({ mode = "free" })
    H.check("mode.resolve_config_free", mode == "free" and source == "config",
        summary(mode, source))

    mode, source, problem = modeModule.resolve({ mode = "bogus" })
    H.check("mode.resolve_bad_config_falls_back_to_pass",
        mode == "pass" and source == "config_bad", summary(mode, source))
    H.check("mode.resolve_bad_config_reports_problem", problem == "config_bad",
        tostring(problem))
    H.check("mode.resolve_bad_config_logged",
        modeLog():find("ITNP_CONFIG_BAD key=mode value=bogus fallback=pass", 1, true) ~= nil,
        modeLog())

    mode, source = modeModule.resolve({ mode = "Free" })
    H.check("mode.resolve_config_is_case_sensitive",
        mode == "pass" and source == "config_bad", summary(mode, source))

    mode, source = modeModule.resolve({ mode = false })
    H.check("mode.resolve_false_config_falls_back",
        mode == "pass" and source == "config_bad", summary(mode, source))

    -- The override file beats a valid config value in both directions.
    writeMode("free\n")
    mode, source = modeModule.resolve({ mode = "pass" })
    H.check("mode.resolve_file_free_beats_config_pass",
        mode == "free" and source == "file", summary(mode, source))

    writeMode("pass\n")
    mode, source = modeModule.resolve({ mode = "free" })
    H.check("mode.resolve_file_pass_beats_config_free",
        mode == "pass" and source == "file", summary(mode, source))

    -- The override file also beats an invalid config value (the file wins, the
    -- config problem is still reported).
    writeMode("free\n")
    mode, source, problem = modeModule.resolve({ mode = "bogus" })
    H.check("mode.resolve_file_beats_bad_config",
        mode == "free" and source == "file", summary(mode, source))
    H.check("mode.resolve_file_beats_bad_config_notes_problem",
        problem == "config_bad", tostring(problem))

    -- Invalid override content keeps the config value and logs ITNP_MODE_BAD.
    resetMode()
    writeMode("nonsense\n")
    mode, source, problem = modeModule.resolve({ mode = "free" })
    H.check("mode.resolve_bad_file_keeps_config",
        mode == "free" and source == "config", summary(mode, source))
    H.check("mode.resolve_bad_file_reports_problem", problem == "file_bad",
        tostring(problem))
    H.check("mode.resolve_bad_file_logged",
        modeLog():find("ITNP_MODE_BAD path=/auth/itnpass_mode.txt value=nonsense"
            .. " keep=free", 1, true) ~= nil, modeLog())

    writeMode("FREE\n")
    mode, source, problem = modeModule.resolve({ mode = "pass" })
    H.check("mode.resolve_uppercase_file_ignored",
        mode == "pass" and source == "config" and problem == "file_bad",
        summary(mode, source, problem))

    writeMode("# open day\n")
    mode, source, problem = modeModule.resolve({ mode = "pass" })
    H.check("mode.resolve_comment_only_file_ignored",
        mode == "pass" and problem == "file_bad", summary(mode, source, problem))

    writeMode("pass\nfree\n")
    mode, source, problem = modeModule.resolve({ mode = "pass" })
    H.check("mode.resolve_conflicting_file_ignored",
        mode == "pass" and problem == "file_bad", summary(mode, source, problem))

    writeMode("free\r\n")
    mode, source = modeModule.resolve({ mode = "pass" })
    H.check("mode.resolve_crlf_file_used", mode == "free" and source == "file",
        summary(mode, source))

    resetMode()

    ------------------------------------------------------------------------
    -- the real config module applies the same resolution at load time
    ------------------------------------------------------------------------
    H.group("mode.config")

    local okConf, conf = pcall(realDofile, CONFIG)
    H.check("mode.config.loads", okConf and type(conf) == "table", tostring(conf))
    H.check("mode.config.default_pass", okConf and conf.mode == "pass",
        okConf and tostring(conf.mode) or tostring(conf))
    H.check("mode.config.default_source", okConf and conf.mode_source == "config",
        okConf and tostring(conf.mode_source))
    H.check("mode.config.channel_kept", okConf and conf.channel == 33,
        okConf and tostring(conf.channel))
    H.check("mode.config.protocol_kept", okConf and conf.protocol == "itnpass_v1",
        okConf and tostring(conf.protocol))
    H.check("mode.config.other_keys_kept",
        okConf and conf.default_uses == 2 and conf.payload_dir == "/payload")

    writeMode("free\n")
    local okFree, fileConf = pcall(realDofile, CONFIG)
    H.check("mode.config.file_override", okFree and fileConf.mode == "free",
        okFree and tostring(fileConf.mode) or tostring(fileConf))
    H.check("mode.config.file_source", okFree and fileConf.mode_source == "file",
        okFree and tostring(fileConf.mode_source))

    local currentMode, currentSource
    currentMode, currentSource = modeModule.current()
    H.check("mode.current_reads_config", currentMode == "free" and currentSource == "file",
        summary(currentMode, currentSource))

    writeMode("bogus\n")
    local okBadFile, badFileConf = pcall(realDofile, CONFIG)
    H.check("mode.config.bad_file_keeps_pass",
        okBadFile and badFileConf.mode == "pass", okBadFile and tostring(badFileConf.mode))
    H.check("mode.config.bad_file_source",
        okBadFile and badFileConf.mode_source == "config",
        okBadFile and tostring(badFileConf.mode_source))

    resetMode()

    -- An invalid config value is injected by rewriting the staged file, then
    -- restored immediately, so the rest of the suite sees the shipped file.
    local realConfig = H.readFile(CONFIG)
    H.check("mode.config.source_readable", type(realConfig) == "string" and #realConfig > 0)
    local marker = '    mode = "pass",'
    local at = realConfig:find(marker, 1, true)
    H.check("mode.config.source_has_marker", at ~= nil, tostring(at))
    if at ~= nil then
        local badSource = realConfig:sub(1, at - 1) .. '    mode = "bogus",'
            .. realConfig:sub(at + #marker)
        H.writeFile(CONFIG, badSource)
        local okBad, badConf = pcall(realDofile, CONFIG)
        H.writeFile(CONFIG, realConfig)
        H.check("mode.config.bad_value_loads", okBad, tostring(badConf))
        H.check("mode.config.bad_value_falls_back",
            okBad and badConf.mode == "pass", okBad and tostring(badConf.mode))
        H.check("mode.config.bad_value_source",
            okBad and badConf.mode_source == "config_bad",
            okBad and tostring(badConf.mode_source))
        H.check("mode.config.bad_value_logged",
            modeLog():find("ITNP_CONFIG_BAD key=mode value=bogus", 1, true) ~= nil,
            modeLog())
    end
    local okRestored, restoredConf = pcall(realDofile, CONFIG)
    H.check("mode.config.source_restored",
        okRestored and restoredConf.mode == "pass" and restoredConf.mode_source == "config",
        okRestored and summary(restoredConf.mode, restoredConf.mode_source)
            or tostring(restoredConf))

    ------------------------------------------------------------------------
    -- station: free mode never touches the pass database
    ------------------------------------------------------------------------
    H.group("mode.server")
    resetMode()
    deleteFile(SERVER_LOG)

    local server = H.load(SERVER, "test")

    local function conf(overrides)
        local base = dofile(CONFIG)
        local out = {}
        for k, v in pairs(base) do
            out[k] = v
        end
        for k, v in pairs(overrides or {}) do
            out[k] = v
        end
        return out
    end

    -- Any read of this table is a test failure: free mode must not consult the
    -- pass database at all.
    local function forbiddenStore()
        return setmetatable({}, {
            __index = function(_, key)
                error("store touched: " .. tostring(key), 0)
            end,
        })
    end

    local function writerOk(info)
        local w = { calls = 0 }
        w.write = function()
            w.calls = w.calls + 1
            return true, info or { files = 2, dirs = 1, bytes = 9000 }
        end
        return w
    end

    local function writerFail(reason, detail)
        local w = { calls = 0 }
        w.write = function()
            w.calls = w.calls + 1
            return false, reason, detail
        end
        return w
    end

    local function writerError(message)
        local w = { calls = 0 }
        w.write = function()
            w.calls = w.calls + 1
            error(message)
        end
        return w
    end

    -- A tiny pass database stand-in: only the paid path may call it.
    local function fakeStore()
        local st = {
            uses_left = 2,
            uses_total = 2,
            reserved = {},
            calls = { lookup = 0, reserve = 0, commit = 0, release = 0 },
        }
        st.lookup = function(code)
            st.calls.lookup = st.calls.lookup + 1
            if code == "GOODCODE" then
                return { uses_left = st.uses_left, uses_total = st.uses_total }
            end
            return nil, "unknown code"
        end
        st.reserve = function(code, id)
            st.calls.reserve = st.calls.reserve + 1
            if code ~= "GOODCODE" then
                return nil, "unknown code"
            end
            if st.uses_left <= 0 then
                return nil, "used up"
            end
            st.reserved[id] = true
            return { fp = "fp" }
        end
        st.commit = function(id)
            st.calls.commit = st.calls.commit + 1
            if not st.reserved[id] then
                return nil, "no such reservation"
            end
            st.reserved[id] = nil
            st.uses_left = st.uses_left - 1
            return { uses_left = st.uses_left, uses_total = st.uses_total }, true
        end
        st.release = function(id)
            st.calls.release = st.calls.release + 1
            st.reserved[id] = nil
            return true
        end
        return st
    end

    local seq = 0
    local function nextNonce(tag)
        seq = seq + 1
        return (tag or "n") .. "-" .. tostring(seq)
    end

    local function verify(ctx, fields)
        local msg = {
            protocol = "itnpass_v1",
            type = "verify_request",
            terminal_id = "T-1",
        }
        for k, v in pairs(fields or {}) do
            msg[k] = v
        end
        return server.handleMessage(ctx, msg)
    end

    local function writeReq(ctx, fields)
        local msg = {
            protocol = "itnpass_v1",
            type = "write_request",
            terminal_id = "T-1",
        }
        for k, v in pairs(fields or {}) do
            msg[k] = v
        end
        return server.handleMessage(ctx, msg)
    end

    local freeWriter = writerOk({ files = 2, dirs = 1, bytes = 9000 })
    local freeCtx = server.newContext(conf({ mode = "free" }), forbiddenStore(),
        freeWriter, "TEST-SRV")

    local n = nextNonce("free")
    local reply = verify(freeCtx, { nonce = n, code = "" })
    H.check("mode.server.free_verify_type",
        reply ~= nil and reply.type == "verify_response", tostring(reply and reply.type))
    H.check("mode.server.free_verify_protocol",
        reply ~= nil and reply.protocol == "itnpass_v1")
    H.check("mode.server.free_verify_server_id",
        reply ~= nil and reply.server_id == "TEST-SRV")
    H.check("mode.server.free_verify_nonce",
        reply ~= nil and reply.nonce == n, tostring(reply and reply.nonce))
    H.check("mode.server.free_verify_success",
        reply ~= nil and reply.success == true and reply.message == "OK",
        tostring(reply and reply.message))
    H.check("mode.server.free_verify_flag", reply ~= nil and reply.free == true)
    H.check("mode.server.free_verify_mode", reply ~= nil and reply.mode == "free")
    H.check("mode.server.free_verify_omits_uses",
        reply ~= nil and reply.uses_left == nil and reply.uses_total == nil,
        summary(reply and reply.uses_left, reply and reply.uses_total))
    H.check("mode.server.free_verify_logged",
        serverLog():find("ITNP_FREE_VERIFY terminal=T-1 uses=none", 1, true) ~= nil,
        serverLog())

    n = nextNonce("free")
    reply = verify(freeCtx, { nonce = n, code = "NOT-A-KEY" })
    H.check("mode.server.free_verify_any_code",
        reply ~= nil and reply.success == true, tostring(reply and reply.message))

    reply = verify(freeCtx, { nonce = n, code = "" })
    H.check("mode.server.free_verify_replay_rejected",
        reply ~= nil and reply.success == false and reply.message == "duplicate request",
        tostring(reply and reply.message))

    reply = verify(freeCtx, { code = "" })
    H.check("mode.server.free_verify_malformed_rejected",
        reply ~= nil and reply.success == false and reply.message == "malformed request",
        tostring(reply and reply.message))

    n = nextNonce("freew")
    local resId = "T-1-" .. n
    reply = writeReq(freeCtx, { nonce = n, code = "", reservation_id = resId })
    H.check("mode.server.free_write_success",
        reply ~= nil and reply.success == true, tostring(reply and reply.message))
    H.check("mode.server.free_write_uncharged",
        reply ~= nil and reply.charged == false, tostring(reply and reply.charged))
    H.check("mode.server.free_write_flag", reply ~= nil and reply.free == true)
    H.check("mode.server.free_write_mode", reply ~= nil and reply.mode == "free")
    H.check("mode.server.free_write_stats",
        reply ~= nil and reply.files == 2 and reply.dirs == 1 and reply.bytes == 9000,
        summary(reply and reply.files, reply and reply.dirs, reply and reply.bytes))
    H.check("mode.server.free_write_omits_uses",
        reply ~= nil and reply.uses_left == nil, tostring(reply and reply.uses_left))
    H.check("mode.server.free_write_calls_writer", freeWriter.calls == 1,
        freeWriter.calls)
    H.check("mode.server.free_write_logged",
        serverLog():find("ITNP_FREE_WRITE ok=1 files=2 dirs=1 bytes=9000", 1, true) ~= nil,
        serverLog())
    H.check("mode.server.free_write_never_reserves",
        serverLog():find("ITNP_GRANT", 1, true) == nil, serverLog())
    H.check("mode.server.free_write_never_commits",
        serverLog():find("ITNP_COMMIT", 1, true) == nil, serverLog())

    n = nextNonce("freew")
    reply = writeReq(freeCtx, { nonce = n, code = "" })
    H.check("mode.server.free_write_needs_reservation",
        reply ~= nil and reply.success == false and reply.message == "missing reservation id",
        tostring(reply and reply.message))

    reply = writeReq(freeCtx, { code = "" })
    H.check("mode.server.free_write_needs_nonce",
        reply ~= nil and reply.success == false and reply.message == "malformed request",
        tostring(reply and reply.message))

    local failingWriter = writerFail("no drive",
        "no disk drive is visible; check the drive network")
    local failingCtx = server.newContext(conf({ mode = "free" }), forbiddenStore(),
        failingWriter, "TEST-SRV")
    n = nextNonce("freef")
    resId = "T-1-" .. n
    reply = writeReq(failingCtx, { nonce = n, code = "", reservation_id = resId })
    H.check("mode.server.free_write_failure_message",
        reply ~= nil and reply.success == false and reply.message == "disk write error",
        tostring(reply and reply.message))
    H.check("mode.server.free_write_failure_detail",
        reply ~= nil and reply.detail ==
            "no drive: no disk drive is visible; check the drive network",
        tostring(reply and reply.detail))
    H.check("mode.server.free_write_failure_uncharged",
        reply ~= nil and reply.charged == false)
    H.check("mode.server.free_write_failure_logged",
        serverLog():find("ITNP_FREE_WRITE ok=0 reason=no drive", 1, true) ~= nil,
        serverLog())
    H.check("mode.server.free_write_failure_calls_writer", failingWriter.calls == 1,
        failingWriter.calls)

    local explodingWriter = writerError("drive exploded")
    local explodingCtx = server.newContext(conf({ mode = "free" }), forbiddenStore(),
        explodingWriter, "TEST-SRV")
    n = nextNonce("freex")
    resId = "T-1-" .. n
    reply = writeReq(explodingCtx, { nonce = n, code = "", reservation_id = resId })
    H.check("mode.server.free_write_exception_message",
        reply ~= nil and reply.success == false and reply.message == "disk write error",
        tostring(reply and reply.message))
    H.check("mode.server.free_write_exception_detail",
        reply ~= nil and tostring(reply.detail):find("drive exploded", 1, true) ~= nil,
        tostring(reply and reply.detail))
    H.check("mode.server.free_write_exception_logged",
        serverLog():find("ITNP_FREE_WRITE ok=0 reason=exception", 1, true) ~= nil,
        serverLog())

    -- Free mode is opt-in: anything but the literal "free" is the paid path.
    local oddCtx = server.newContext(conf({ mode = "FREE" }), forbiddenStore(),
        writerOk(), "TEST-SRV")
    n = nextNonce("odd")
    reply = verify(oddCtx, { nonce = n, code = "" })
    H.check("mode.server.mode_is_case_sensitive",
        reply ~= nil and reply.success == false and reply.message == "empty code",
        tostring(reply and reply.message))

    ------------------------------------------------------------------------
    -- station: pass mode is unchanged by the new code path
    ------------------------------------------------------------------------
    H.group("mode.server.pass")
    -- Only the lines this paid-mode block appends are relevant: the free-mode
    -- checks above already wrote their own tags into the same file.
    local passLogStart = #serverLog() + 1
    local function passLog()
        return serverLog():sub(passLogStart)
    end
    local store = fakeStore()
    local paidWriter = writerOk({ files = 3, dirs = 2, bytes = 4096 })
    local paidCtx = server.newContext(conf({ mode = "pass" }), store, paidWriter,
        "TEST-SRV")

    n = nextNonce("pass")
    reply = verify(paidCtx, { nonce = n, code = "GOODCODE" })
    H.check("mode.server.pass_verify_ok",
        reply ~= nil and reply.success == true and reply.message == "OK",
        tostring(reply and reply.message))
    H.check("mode.server.pass_verify_uses",
        reply ~= nil and reply.uses_left == 2 and reply.uses_total == 2,
        summary(reply and reply.uses_left, reply and reply.uses_total))
    H.check("mode.server.pass_verify_no_free_flag",
        reply ~= nil and reply.free == nil and reply.mode == nil,
        summary(reply and reply.free, reply and reply.mode))
    H.check("mode.server.pass_verify_looks_up", store.calls.lookup == 1, store.calls.lookup)
    H.check("mode.server.pass_verify_logged",
        passLog():find("ITNP_CHECK terminal=T-1 success=1 uses_left=2", 1, true) ~= nil,
        passLog())

    n = nextNonce("pass")
    reply = verify(paidCtx, { nonce = n, code = "BADCODE" })
    H.check("mode.server.pass_verify_denies_unknown",
        reply ~= nil and reply.success == false and reply.message == "unknown code",
        tostring(reply and reply.message))
    H.check("mode.server.pass_verify_deny_logged",
        passLog():find("ITNP_DENY terminal=T-1 reason=unknown code", 1, true) ~= nil,
        passLog())

    n = nextNonce("pass")
    reply = verify(paidCtx, { nonce = n, code = "" })
    H.check("mode.server.pass_verify_rejects_empty",
        reply ~= nil and reply.success == false and reply.message == "empty code",
        tostring(reply and reply.message))

    n = nextNonce("passw")
    reply = writeReq(paidCtx, { nonce = n, code = "", reservation_id = "T-1-" .. n })
    H.check("mode.server.pass_write_rejects_empty",
        reply ~= nil and reply.success == false and reply.message == "empty code",
        tostring(reply and reply.message))
    H.check("mode.server.pass_write_rejected_before_writer", paidWriter.calls == 0,
        paidWriter.calls)

    n = nextNonce("passw")
    reply = writeReq(paidCtx, { nonce = n, code = "BADCODE", reservation_id = "T-1-" .. n })
    H.check("mode.server.pass_write_denied_without_reservation",
        reply ~= nil and reply.success == false and reply.message == "unknown code",
        tostring(reply and reply.message))
    H.check("mode.server.pass_write_deny_skips_writer", paidWriter.calls == 0,
        paidWriter.calls)

    n = nextNonce("passw")
    resId = "T-1-" .. n
    reply = writeReq(paidCtx, { nonce = n, code = "GOODCODE", reservation_id = resId })
    H.check("mode.server.pass_write_ok",
        reply ~= nil and reply.success == true, tostring(reply and reply.message))
    H.check("mode.server.pass_write_charges", reply ~= nil and reply.charged == true)
    H.check("mode.server.pass_write_uses_after_commit",
        reply ~= nil and reply.uses_left == 1, tostring(reply and reply.uses_left))
    H.check("mode.server.pass_write_stats",
        reply ~= nil and reply.files == 3 and reply.dirs == 2 and reply.bytes == 4096,
        summary(reply and reply.files, reply and reply.dirs, reply and reply.bytes))
    H.check("mode.server.pass_write_no_free_flag",
        reply ~= nil and reply.free == nil, tostring(reply and reply.free))
    H.check("mode.server.pass_write_committed", store.calls.commit == 1, store.calls.commit)
    H.check("mode.server.pass_write_logged",
        passLog():find("ITNP_COMMIT reservation=" .. resId .. " charged=1 uses_left=1",
            1, true) ~= nil, passLog())
    H.check("mode.server.pass_keeps_use_counter", store.uses_left == 1, store.uses_left)
    H.check("mode.server.pass_no_free_tags",
        passLog():find("ITNP_FREE_VERIFY", 1, true) == nil
            and passLog():find("ITNP_FREE_WRITE", 1, true) == nil, passLog())

    -- A config table without "mode" is the paid path as well (fail safe).
    local noModeCtx = server.newContext(conf({ mode = nil }), fakeStore(), writerOk(),
        "TEST-SRV")
    n = nextNonce("nomode")
    reply = verify(noModeCtx, { nonce = n, code = "" })
    H.check("mode.server.missing_mode_is_pass",
        reply ~= nil and reply.success == false and reply.message == "empty code",
        tostring(reply and reply.message))

    ------------------------------------------------------------------------
    -- terminal client: empty code is a valid request only in free mode
    ------------------------------------------------------------------------
    H.group("mode.client")
    resetMode()

    local FORMATTED = "2345-6789-ABCD-EFGH"

    local function heartbeats(ids)
        for _, id in ipairs(ids) do
            H.pushEvent("modem_message", "left", 33, 33, {
                protocol = "itnpass_v1",
                type = "heartbeat",
                server_id = id,
            })
        end
    end

    local function wired(onTransmit)
        return H.installPeripheral({
            names = { "left" },
            types = { left = "modem" },
            onTransmit = onTransmit,
        })
    end

    local function answered(replyFor)
        return function(HH, name, channel, replyChannel, message)
            local reply = replyFor(message)
            if reply then
                HH.pushEvent("modem_message", name, replyChannel, 33, reply)
            end
        end
    end

    local function replyFor(kind, fields)
        return function(message)
            local reply = {
                protocol = "itnpass_v1",
                type = kind,
                server_id = "SRV-A",
                nonce = message.nonce,
                success = true,
                message = "OK",
            }
            for k, v in pairs(fields or {}) do
                reply[k] = v
            end
            return reply
        end
    end

    local passRec = wired(answered(replyFor("write_response",
        { charged = true, uses_left = 1, files = 2, dirs = 0, bytes = 9000 })))
    heartbeats({ "SRV-A" })
    local client = realDofile(CLIENT)
    H.check("mode.client.pass_mode", client.mode() == "pass", tostring(client.mode()))
    local ok, reason = client.check("")
    H.check("mode.client.pass_check_empty", ok == false and reason == "empty code",
        tostring(reason))
    ok, reason = client.write("")
    H.check("mode.client.pass_write_empty", ok == false and reason == "empty code",
        tostring(reason))
    H.check("mode.client.pass_write_sends_nothing", #passRec.sent == 0, #passRec.sent)

    ok, reason = client.write(FORMATTED)
    H.check("mode.client.pass_write_ok", ok == true, tostring(reason))
    H.check("mode.client.pass_write_charged", ok == true and reason.charged == true)
    H.check("mode.client.pass_write_code_on_wire",
        #passRec.sent == 1 and passRec.sent[1].message.code == FORMATTED,
        #passRec.sent > 0 and tostring(passRec.sent[1].message.code) or "none")
    H.check("mode.client.pass_write_has_reservation",
        #passRec.sent == 1 and type(passRec.sent[1].message.reservation_id) == "string")
    H.check("mode.client.pass_no_free_flag",
        ok == true and reason.free == nil, tostring(ok == true and reason.free))

    -- Free mode: the same terminal accepts an empty code and sends it.
    writeMode("free\n")
    local freeRec = wired(answered(replyFor("write_response",
        { charged = false, free = true, mode = "free", files = 2, dirs = 1, bytes = 9000 })))
    heartbeats({ "SRV-A" })
    client = realDofile(CLIENT)
    H.check("mode.client.free_mode", client.mode() == "free", tostring(client.mode()))
    ok, reason = client.write("")
    H.check("mode.client.free_write_ok", ok == true, tostring(reason))
    H.check("mode.client.free_write_uncharged",
        ok == true and reason.charged == false, tostring(ok == true and reason.charged))
    H.check("mode.client.free_write_flag", ok == true and reason.free == true)
    H.check("mode.client.free_write_mode", ok == true and reason.mode == "free")
    H.check("mode.client.free_write_stats",
        ok == true and reason.files == 2 and reason.dirs == 1 and reason.bytes == 9000,
        ok == true and summary(reason.files, reason.dirs, reason.bytes) or "none")
    H.check("mode.client.free_write_sends_empty_code",
        #freeRec.sent == 1 and freeRec.sent[1].message.code == "",
        #freeRec.sent > 0 and tostring(freeRec.sent[1].message.code) or "none")
    H.check("mode.client.free_write_sends_reservation",
        #freeRec.sent == 1 and type(freeRec.sent[1].message.reservation_id) == "string")

    local freeVerifyRec = wired(answered(replyFor("verify_response",
        { free = true, mode = "free" })))
    heartbeats({ "SRV-A" })
    client = realDofile(CLIENT)
    ok, reason = client.check("")
    H.check("mode.client.free_check_empty_ok", ok == true, tostring(reason))
    H.check("mode.client.free_check_flag", ok == true and reason.free == true)
    H.check("mode.client.free_check_no_uses",
        ok == true and reason.uses_left == nil)
    H.check("mode.client.free_check_code_on_wire",
        #freeVerifyRec.sent == 1 and freeVerifyRec.sent[1].message.code == "")

    -- A real code still works in free mode (nothing breaks for old terminals).
    local freeCodeRec = wired(answered(replyFor("verify_response",
        { free = true, mode = "free" })))
    heartbeats({ "SRV-A" })
    client = realDofile(CLIENT)
    ok = client.check(FORMATTED)
    H.check("mode.client.free_check_real_code_ok", ok == true)
    H.check("mode.client.free_check_real_code_on_wire",
        #freeCodeRec.sent == 1 and freeCodeRec.sent[1].message.code == FORMATTED)

    resetMode()

    ------------------------------------------------------------------------
    -- terminal kernel: free skips the login screen, pass keeps it
    ------------------------------------------------------------------------
    H.group("mode.kernel")
    resetMode()

    local function driveKernel(configMode)
        local rec = {
            loginCalls = 0,
            uiCalls = 0,
            tokens = 0,
            destroys = 0,
            uiUser = nil,
            uiToken = nil,
            prints = {},
            sleeps = 0,
        }
        local saved = {
            dofile = dofile,
            loadfile = loadfile,
            sleep = sleep,
            print = print,
        }
        local chunk = assert(saved.loadfile(KERNEL))
        dofile = function(path)
            if path == "/system/sandbox.lua" then
                return { init = function() return true end }
            end
            if path == "/auth/itnpass_login.lua" then
                return {
                    login = function()
                        rec.loginCalls = rec.loginCalls + 1
                        return { name = "cardkey", code = "CODE", uses_left = 1 }
                    end,
                }
            end
            if path == "/auth/session.lua" then
                return {
                    create = function(user)
                        rec.tokens = rec.tokens + 1
                        rec.uiUser = user
                        return "token-1"
                    end,
                    destroy = function()
                        rec.destroys = rec.destroys + 1
                    end,
                }
            end
            if path == MODE_MODULE then
                return modeModule
            end
            if path == CONFIG and configMode ~= false then
                return { mode = configMode }
            end
            error("unexpected dofile: " .. tostring(path), 0)
        end
        loadfile = function(path)
            if path == UI then
                return function(token, session, sandbox, user)
                    rec.uiCalls = rec.uiCalls + 1
                    rec.uiToken = token
                    rec.uiUser = user
                end, nil
            end
            error("unexpected loadfile: " .. tostring(path), 0)
        end
        sleep = function()
            rec.sleeps = rec.sleeps + 1
            error("KERNEL_STOP", 0)
        end
        print = function(...)
            local parts = {}
            for i = 1, select("#", ...) do
                parts[i] = tostring((select(i, ...)))
            end
            rec.prints[#rec.prints + 1] = table.concat(parts, " ")
        end
        local ok, err = pcall(chunk)
        dofile = saved.dofile
        loadfile = saved.loadfile
        sleep = saved.sleep
        print = saved.print
        rec.stopped = (ok == false and tostring(err):find("KERNEL_STOP", 1, true) ~= nil)
            or ok == true
        rec.err = err
        return rec
    end

    local function hasLine(lines, needle)
        for _, line in ipairs(lines) do
            if tostring(line):find(needle, 1, true) ~= nil then
                return true
            end
        end
        return false
    end

    -- pass: login screen, real card key user, no free log line.
    resetMode()
    local passKernel = driveKernel("pass")
    H.check("mode.kernel.pass_ran", passKernel.stopped, tostring(passKernel.err))
    H.check("mode.kernel.pass_shows_login", passKernel.loginCalls == 1,
        passKernel.loginCalls)
    H.check("mode.kernel.pass_reaches_ui", passKernel.uiCalls == 1, passKernel.uiCalls)
    H.check("mode.kernel.pass_user_is_cardkey",
        passKernel.uiUser ~= nil and passKernel.uiUser.name == "cardkey",
        passKernel.uiUser and tostring(passKernel.uiUser.name))
    H.check("mode.kernel.pass_user_not_free",
        passKernel.uiUser ~= nil and passKernel.uiUser.free == nil)
    H.check("mode.kernel.pass_session_created", passKernel.tokens == 1, passKernel.tokens)
    H.check("mode.kernel.pass_session_destroyed", passKernel.destroys == 1,
        passKernel.destroys)
    H.check("mode.kernel.pass_no_free_log",
        modeLog():find("ITNP_FREE_SESSION", 1, true) == nil, modeLog())
    H.check("mode.kernel.pass_no_free_banner",
        not hasLine(passKernel.prints, "Free mode"))

    -- free via the config value: no login call at all.
    resetMode()
    local freeKernel = driveKernel("free")
    H.check("mode.kernel.free_ran", freeKernel.stopped, tostring(freeKernel.err))
    H.check("mode.kernel.free_skips_login", freeKernel.loginCalls == 0,
        freeKernel.loginCalls)
    H.check("mode.kernel.free_reaches_ui", freeKernel.uiCalls == 1, freeKernel.uiCalls)
    H.check("mode.kernel.free_guest_name",
        freeKernel.uiUser ~= nil and freeKernel.uiUser.name == "guest",
        freeKernel.uiUser and tostring(freeKernel.uiUser.name))
    H.check("mode.kernel.free_guest_flag",
        freeKernel.uiUser ~= nil and freeKernel.uiUser.free == true)
    H.check("mode.kernel.free_guest_empty_code",
        freeKernel.uiUser ~= nil and freeKernel.uiUser.code == "",
        freeKernel.uiUser and tostring(freeKernel.uiUser.code))
    H.check("mode.kernel.free_guest_no_uses",
        freeKernel.uiUser ~= nil and freeKernel.uiUser.uses_left == nil)
    H.check("mode.kernel.free_session_created", freeKernel.tokens == 1)
    H.check("mode.kernel.free_logged",
        modeLog():find("ITNP_FREE_SESSION id=", 1, true) ~= nil, modeLog())

    -- free via the override file with no config file on the terminal disk:
    -- the mode file alone is enough (same priority as the station).
    resetMode()
    writeMode("free\n")
    local fileKernel = driveKernel(false)
    H.check("mode.kernel.file_free_ran", fileKernel.stopped, tostring(fileKernel.err))
    H.check("mode.kernel.file_free_skips_login", fileKernel.loginCalls == 0,
        fileKernel.loginCalls)
    H.check("mode.kernel.file_free_reaches_ui", fileKernel.uiCalls == 1)

    -- the mode file also wins over a "pass" config.
    resetMode()
    writeMode("free\n")
    local mixedKernel = driveKernel("pass")
    H.check("mode.kernel.file_beats_config", mixedKernel.loginCalls == 0,
        mixedKernel.loginCalls)
    resetMode()

    ------------------------------------------------------------------------
    -- terminal menu: free wording, pass wording unchanged
    ------------------------------------------------------------------------
    H.group("mode.ui")

    local function driveUi(user, clientResult, input)
        local rec = { lines = {}, written = {}, code = nil }
        local saved = {
            dofile = dofile,
            loadfile = loadfile,
            print = print,
            write = write,
            read = read,
            sleep = sleep,
        }
        local chunk = assert(saved.loadfile(UI))
        dofile = function(path)
            if path == CLIENT then
                return {
                    write = function(code)
                        rec.code = code
                        local ok, info, detail = clientResult()
                        if not ok then
                            return ok, info, detail
                        end
                        return ok, info
                    end,
                }
            end
            error("unexpected dofile: " .. tostring(path), 0)
        end
        print = function(...)
            local parts = {}
            for i = 1, select("#", ...) do
                parts[i] = tostring((select(i, ...)))
            end
            rec.lines[#rec.lines + 1] = table.concat(parts, "")
        end
        write = function(...)
            local parts = {}
            for i = 1, select("#", ...) do
                parts[i] = tostring((select(i, ...)))
            end
            rec.written[#rec.written + 1] = table.concat(parts, "")
        end
        read = function()
            return input
        end
        sleep = function()
        end
        local ok, err = pcall(chunk, "token-1", {}, {}, user)
        dofile = saved.dofile
        loadfile = saved.loadfile
        print = saved.print
        write = saved.write
        read = saved.read
        sleep = saved.sleep
        rec.ok = ok
        rec.err = err
        rec.text = table.concat(rec.lines, "\n")
        return rec
    end

    resetMode()
    local passUi = driveUi(
        { name = "cardkey", code = "CODE", uses_left = 1, free = nil },
        function()
            return true, { charged = true, files = 2, dirs = 0, bytes = 9000, uses_left = 1 }
        end,
        "1")
    H.check("mode.ui.pass_ran", passUi.ok, tostring(passUi.err))
    H.check("mode.ui.pass_writes_with_code", passUi.code == "CODE", tostring(passUi.code))
    H.check("mode.ui.pass_success_text",
        passUi.text:find("[OK] Disk written and key charged.", 1, true) ~= nil, passUi.text)
    H.check("mode.ui.pass_shows_uses",
        passUi.text:find("Uses left on this key: 1", 1, true) ~= nil, passUi.text)
    H.check("mode.ui.pass_no_free_banner",
        passUi.text:find("Free mode", 1, true) == nil, passUi.text)
    H.check("mode.ui.pass_no_free_text",
        passUi.text:find("No card key was charged", 1, true) == nil, passUi.text)

    local unchargedUi = driveUi(
        { name = "cardkey", code = "CODE", uses_left = 0, free = nil },
        function()
            return true, { charged = false, files = 1, dirs = 0, bytes = 10, uses_left = 0 }
        end,
        "1")
    H.check("mode.ui.pass_uncharged_warning",
        unchargedUi.text:find("[Warning] Use was NOT charged:", 1, true) ~= nil,
        unchargedUi.text)
    H.check("mode.ui.pass_uncharged_detail",
        unchargedUi.text:find("the server could not confirm it.", 1, true) ~= nil,
        unchargedUi.text)

    local freeUi = driveUi(
        { name = "guest", code = "", free = true },
        function()
            return true, { charged = false, free = true, files = 2, dirs = 1, bytes = 9000 }
        end,
        "1")
    H.check("mode.ui.free_ran", freeUi.ok, tostring(freeUi.err))
    H.check("mode.ui.free_writes_empty_code", freeUi.code == "", tostring(freeUi.code))
    H.check("mode.ui.free_banner",
        freeUi.text:find("Free mode: no card key needed.", 1, true) ~= nil, freeUi.text)
    H.check("mode.ui.free_success_text",
        freeUi.text:find("[OK] Disk written (free mode).", 1, true) ~= nil, freeUi.text)
    H.check("mode.ui.free_no_charge_text",
        freeUi.text:find("No card key was charged.", 1, true) ~= nil, freeUi.text)
    H.check("mode.ui.free_no_warning",
        freeUi.text:find("[Warning] Use was NOT charged:", 1, true) == nil, freeUi.text)
    H.check("mode.ui.free_no_uses",
        freeUi.text:find("Uses left on this key", 1, true) == nil, freeUi.text)
    H.check("mode.ui.free_shows_dirs",
        freeUi.text:find("Dirs:  1", 1, true) ~= nil, freeUi.text)

    local freeFailUi = driveUi(
        { name = "guest", code = "", free = true },
        function()
            return false, "disk write error", "no disk: insert a disk into drive_0"
        end,
        "1")
    H.check("mode.ui.free_failure_text",
        freeFailUi.text:find("[Failed] disk write error", 1, true) ~= nil, freeFailUi.text)
    H.check("mode.ui.free_failure_detail",
        freeFailUi.text:find("no disk: insert a disk into drive_0", 1, true) ~= nil,
        freeFailUi.text)
    H.check("mode.ui.free_failure_no_key_story",
        freeFailUi.text:find("Your card key was NOT charged.", 1, true) == nil,
        freeFailUi.text)
    H.check("mode.ui.free_failure_message",
        freeFailUi.text:find("The disk was not written.", 1, true) ~= nil, freeFailUi.text)

    local cancelUi = driveUi({ name = "guest", code = "", free = true },
        function() return true, {} end, "0")
    H.check("mode.ui.free_cancel_returns",
        cancelUi.ok and cancelUi.text:find("Writing disk...", 1, true) == nil, cancelUi.text)

    ------------------------------------------------------------------------
    -- console: MODE line follows the same resolution
    ------------------------------------------------------------------------
    H.group("mode.admin")
    resetMode()

    local admin = H.load(ADMIN, "test")
    H.check("mode.admin.text_pass", admin.modeText({ mode = "pass" }) == "MODE: pass",
        admin.modeText({ mode = "pass" }))
    H.check("mode.admin.text_free", admin.modeText({ mode = "free" }) == "MODE: free",
        admin.modeText({ mode = "free" }))
    H.check("mode.admin.text_bad_falls_back", admin.modeText({ mode = "bogus" }) == "MODE: pass",
        admin.modeText({ mode = "bogus" }))
    H.check("mode.admin.text_nil_falls_back", admin.modeText(nil) == "MODE: pass",
        admin.modeText(nil))

    local sha = dofile("/sha256.lua")
    local adminSalt = "abcdefgh12345678"
    local adminPassword = "mode1234"
    H.writeFile("/auth/itnpass_admin.db", textutils.serialize({
        salt = adminSalt,
        hash = sha.hash(adminPassword .. adminSalt),
    }))

    local function runConsole()
        local console = H.load(ADMIN, "test")
        H.beginCapture()
        local okMain, errMain = pcall(console.main)
        local out = H.endCapture()
        return out, okMain, errMain
    end

    H.setInputs(adminPassword, "0")
    local consoleOut, consoleOk, consoleErr = runConsole()
    H.check("mode.admin.home_ran", consoleOk, tostring(consoleErr))
    H.check("mode.admin.home_shows_pass",
        consoleOut:find("MODE: pass", 1, true) ~= nil, consoleOut)
    H.check("mode.admin.home_still_shows_home",
        consoleOut:find("ITN-Pass Station", 1, true) ~= nil
            and consoleOut:find("1. Generate card keys", 1, true) ~= nil, consoleOut)

    writeMode("free\n")
    H.setInputs(adminPassword, "0")
    consoleOut, consoleOk, consoleErr = runConsole()
    H.check("mode.admin.home_free_ran", consoleOk, tostring(consoleErr))
    H.check("mode.admin.home_shows_free",
        consoleOut:find("MODE: free", 1, true) ~= nil, consoleOut)

    writeMode("bogus\n")
    H.setInputs(adminPassword, "0")
    consoleOut, consoleOk = runConsole()
    H.check("mode.admin.home_bad_file_is_pass",
        consoleOk and consoleOut:find("MODE: pass", 1, true) ~= nil, consoleOut)

    resetMode()

    ------------------------------------------------------------------------
    -- terminal boot: netcheck keeps running in free mode
    ------------------------------------------------------------------------
    H.group("mode.startup")

    local function driveStartup(netcheckOk)
        local rec = { kernel = 0, kernelPath = nil, checks = 0, checkSecs = nil,
            flagText = nil, prints = {}, pulls = 0, lockCalls = 0 }
        local saved = {
            dofile = dofile,
            loadfile = loadfile,
            print = print,
            fsOpen = fs.open,
            pullEventRaw = os.pullEventRaw,
            run = os.run,
        }
        local chunk = assert(saved.loadfile(TERMINAL_STARTUP))
        dofile = function(path)
            if path == "/system/sandbox.lua" then
                return {
                    lockEvents = function()
                        rec.lockCalls = rec.lockCalls + 1
                        return true
                    end,
                }
            end
            if path == "/system/netcheck.lua" then
                return {
                    check = function(seconds)
                        rec.checks = rec.checks + 1
                        rec.checkSecs = seconds
                        if netcheckOk then
                            return true, { ["SRV-A"] = true }, nil
                        end
                        return false, {}, "no modem"
                    end,
                }
            end
            error("unexpected dofile: " .. tostring(path), 0)
        end
        fs.open = function(path, mode)
            if path == "/auth/itnpass_lock.flag" and mode == "w" then
                return {
                    write = function(text)
                        rec.flagText = text
                    end,
                    close = function()
                    end,
                }
            end
            return saved.fsOpen(path, mode)
        end
        os.pullEventRaw = function()
            rec.pulls = rec.pulls + 1
            error("STARTUP_HALT", 0)
        end
        os.run = function(_, path)
            rec.kernel = rec.kernel + 1
            rec.kernelPath = path
        end
        print = function(...)
            local parts = {}
            for i = 1, select("#", ...) do
                parts[i] = tostring((select(i, ...)))
            end
            rec.prints[#rec.prints + 1] = table.concat(parts, " ")
        end
        local ok, err = pcall(chunk)
        dofile = saved.dofile
        loadfile = saved.loadfile
        print = saved.print
        fs.open = saved.fsOpen
        os.pullEventRaw = saved.pullEventRaw
        os.run = saved.run
        rec.ok = ok
        rec.err = err
        rec.text = table.concat(rec.prints, "\n")
        return rec
    end

    resetMode()
    local failBoot = driveStartup(false)
    H.check("mode.startup.netcheck_runs", failBoot.checks == 1, failBoot.checks)
    H.check("mode.startup.netcheck_window", failBoot.checkSecs == 3,
        tostring(failBoot.checkSecs))
    H.check("mode.startup.lock_events_called", failBoot.lockCalls == 1)
    H.check("mode.startup.lock_flag_reason", failBoot.flagText == "no modem",
        tostring(failBoot.flagText))
    H.check("mode.startup.failure_banner",
        failBoot.text:find("NETWORK SECURITY CHECK FAILED", 1, true) ~= nil, failBoot.text)
    H.check("mode.startup.failure_reason_text",
        failBoot.text:find("Reason: no modem", 1, true) ~= nil, failBoot.text)
    H.check("mode.startup.failure_hangs",
        failBoot.text:find("Fix the network and reboot.", 1, true) ~= nil
            and failBoot.kernel == 0 and failBoot.pulls >= 1,
        summary(failBoot.kernel, failBoot.pulls))

    resetMode()
    H.writeFile("/auth/itnpass_lock.flag", "stale\n")
    local okBoot = driveStartup(true)
    H.check("mode.startup.success_clears_lock",
        not fs.exists("/auth/itnpass_lock.flag"))
    H.check("mode.startup.success_starts_kernel",
        okBoot.kernel == 1 and okBoot.kernelPath == "/system/kernel.lua",
        summary(okBoot.kernel, okBoot.kernelPath))
    H.check("mode.startup.success_no_banner",
        okBoot.text:find("NETWORK SECURITY CHECK FAILED", 1, true) == nil, okBoot.text)

    -- free mode must not skip the network check: the station still writes the
    -- disk, so the terminal still has to reach it.
    writeMode("free\n")
    local freeBoot = driveStartup(true)
    H.check("mode.startup.free_still_checks_network", freeBoot.checks == 1,
        freeBoot.checks)
    H.check("mode.startup.free_still_starts_kernel", freeBoot.kernel == 1, freeBoot.kernel)
    local freeFailBoot = driveStartup(false)
    H.check("mode.startup.free_failure_still_locks",
        freeFailBoot.kernel == 0 and freeFailBoot.flagText == "no modem",
        summary(freeFailBoot.kernel, tostring(freeFailBoot.flagText)))

    ------------------------------------------------------------------------
    -- static: the resolver is deployed and stays pure ASCII
    ------------------------------------------------------------------------
    H.group("mode.static")
    resetMode()
    H.check("mode.static.resolver_staged", fs.exists(MODE_MODULE))
    H.check("mode.static.mode_file_path",
        modeModule.MODE_FILE == "/auth/itnpass_mode.txt", modeModule.MODE_FILE)
    H.check("mode.static.log_path",
        modeModule.LOG_PATH == "/auth/itnpass_mode.log", modeModule.LOG_PATH)
    local source = H.readFile(MODE_MODULE) or ""
    H.check("mode.static.source_readable", #source > 0, #source)
    H.check("mode.static.source_ascii", source:find("[\128-\255]") == nil)
    H.check("mode.static.no_mode_file_left", not fs.exists(MODE_FILE))

    -- Leave the disk exactly as the rest of the suite expects: no override.
    resetMode()
end

return run
