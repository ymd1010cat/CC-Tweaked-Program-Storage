-- t_batch.lua -- itnpass_batch: scripted generation, listing, export, revoke.
--
-- Every command goes through M.main() with the console captured, so the tests
-- drive the exact path a shell command takes; M.parse/buildNote/statusOf are
-- pinned down directly. The plaintext keys the tool never prints are read from
-- its staging files under /cardkeys/.stage.

local BATCH = "/system/itnpass_batch.lua"
local STORE = "/auth/itnpass_store.lua"
local CONFIG = "/auth/itnpass_config.lua"
local DB = "/auth/itnpass_passes.db"
local PEPPER_PATH = "/auth/itnpass_pepper.txt"
local LOG = "/auth/itnpass_server.log"
local KEYS_DIR = "/cardkeys"
local STAGE = KEYS_DIR .. "/.stage"
local OUTBOX = "/outbox"
local PEPPER = string.rep("Qw7", 16)
local DAY = 86400000

local function run(H)
    local startedNow = H.now
    local startedStamp = H.stamp

    local function store()
        return dofile(STORE)
    end

    local function reset()
        if fs.exists(DB) then
            fs.delete(DB)
        end
        for _, name in ipairs(fs.list("/auth")) do
            if name:find("itnpass_passes.db.corrupt-", 1, true) == 1 then
                fs.delete("/auth/" .. name)
            end
        end
        H.writeFile(PEPPER_PATH, PEPPER .. "\n")
        H.rmTree(KEYS_DIR)
        H.rmTree(OUTBOX)
        H.writeFile(LOG, "")
        H.stamp = nil
    end

    local function runCmd(tool, ...)
        H.beginCapture()
        local ok, err = tool.main({...})
        local out = H.endCapture()
        return out, ok, err
    end

    local function jsonLines(text)
        local lines = {}
        for line in (text or ""):gmatch("[^\n]+") do
            if line:sub(1, 1) == "{" then
                lines[#lines + 1] = line
            end
        end
        return lines
    end

    local function stagedPath(out)
        return (out or ""):match("staged=(%S+)")
    end

    local function batchId(out)
        return (out or ""):match("batch=(%S+)")
    end

    local function codesIn(path)
        local codes = {}
        local text = H.readFile(path) or ""
        local st = store()
        for line in text:gmatch("[^\n]+") do
            local norm = st.normalize(line)
            if norm then
                codes[#codes + 1] = norm
            end
        end
        return codes
    end

    -- True when none of the plaintext keys (raw or formatted) appears in the
    -- captured console output.
    local function noPlaintext(out, codes)
        local st = store()
        for _, code in ipairs(codes or {}) do
            if out:find(code, 1, true) then
                return false
            end
            local formatted = st.format(code)
            if formatted and out:find(formatted, 1, true) then
                return false
            end
        end
        return true
    end

    local configText = H.readFile(CONFIG)
    local function setConfig(pattern, replacement)
        H.writeFile(CONFIG, (H.readFile(CONFIG) or ""):gsub(pattern, replacement))
    end
    local function restoreConfig()
        H.writeFile(CONFIG, configText)
    end

    local tool = H.load(BATCH)

    ------------------------------------------------------------------------
    -- argument parsing
    ------------------------------------------------------------------------
    H.group("batch.parse")
    H.check("batch.version", type(tool.VERSION) == "string" and #tool.VERSION > 0)
    H.check("batch.note_tag", tool.NOTE_TAG == "itnp-batch/1", tool.NOTE_TAG)
    H.check("batch.max_uses", tool.MAX_USES == 1000, tool.MAX_USES)
    H.check("batch.max_expires", tool.MAX_EXPIRES_DAYS == 3650, tool.MAX_EXPIRES_DAYS)
    H.check("batch.stage_dir_name", tool.STAGE_DIR_NAME == ".stage")
    H.check("batch.day_ms", tool.DAY_MS == 86400000)

    local spec = tool.parse({"new", "5"})
    H.check("batch.parse_command", spec ~= nil and spec.command == "new")
    H.check("batch.parse_count", spec and spec.positional[1] == "5",
        spec and spec.positional[1])
    spec = tool.parse({"new", "5", "--uses", "3", "--prefix", "labA",
        "--profile", "pyroet-os", "--expires", "30"})
    H.check("batch.parse_uses", spec and spec.uses == "3", spec and spec.uses)
    H.check("batch.parse_prefix", spec and spec.prefix == "labA")
    H.check("batch.parse_profile", spec and spec.profile == "pyroet-os")
    H.check("batch.parse_expires", spec and spec.expires == "30")
    spec = tool.parse({"list", "--status", "used"})
    H.check("batch.parse_status", spec and spec.status == "used")
    spec = tool.parse({"export", "--out", "/outbox/a.txt", "--keep",
        "--batch", "batch-20260101-000000"})
    H.check("batch.parse_out", spec and spec.out == "/outbox/a.txt",
        spec and spec.out)
    H.check("batch.parse_keep", spec and spec.keep == true)
    H.check("batch.parse_batch_id", spec and spec.batch == "batch-20260101-000000")
    spec = tool.parse({"revoke", "abcdef", "--yes"})
    H.check("batch.parse_yes", spec and spec.yes == true)
    H.check("batch.parse_target", spec and spec.positional[1] == "abcdef")

    local bad, why = tool.parse({"new", "--uses"})
    H.check("batch.parse_missing_value", bad == nil and why == "missing value for --uses",
        tostring(why))
    bad, why = tool.parse({"new", "--bogus"})
    H.check("batch.parse_unknown_flag",
        bad == nil and tostring(why):find("unknown option --bogus", 1, true) ~= nil,
        tostring(why))
    bad, why = tool.parse({})
    H.check("batch.parse_missing_command", bad == nil and why == "missing command",
        tostring(why))
    bad, why = tool.parse(nil)
    H.check("batch.parse_no_args", bad == nil and why == "no arguments", tostring(why))

    ------------------------------------------------------------------------
    -- note format / status precedence / labels
    ------------------------------------------------------------------------
    H.group("batch.note")
    local note = tool.buildNote({
        batch = "labA-20260101-000000",
        profile = "pyroet-os",
        prefix = "labA",
        uses = 3,
        expires = 1600000000000,
    })
    H.check("batch.note_starts_with_tag", note:sub(1, #tool.NOTE_TAG) == tool.NOTE_TAG)
    H.check("batch.note_has_batch",
        note:find("batch=labA-20260101-000000", 1, true) ~= nil, note)
    H.check("batch.note_single_line", note:find("\n", 1, true) == nil)
    local meta = tool.parseNote(note)
    H.check("batch.note_parse_batch", meta ~= nil and meta.batch == "labA-20260101-000000")
    H.check("batch.note_parse_profile", meta ~= nil and meta.profile == "pyroet-os")
    H.check("batch.note_parse_prefix", meta ~= nil and meta.prefix == "labA")
    H.check("batch.note_parse_uses", meta ~= nil and meta.uses == 3)
    H.check("batch.note_parse_expires", meta ~= nil and meta.expires == 1600000000000)
    H.check("batch.note_default_expires",
        tool.buildNote({batch = "b", profile = "p", prefix = "x", uses = 1})
            :find("expires=0", 1, true) ~= nil)
    H.check("batch.note_parse_console_note", tool.parseNote("hello note") == nil)
    H.check("batch.note_parse_nil", tool.parseNote(nil) == nil)
    H.check("batch.note_parse_number", tool.parseNote(5) == nil)
    local tagged = tool.parseNote(tool.NOTE_TAG)
    H.check("batch.note_tag_only", tagged ~= nil and tagged.uses == 0
        and tagged.expires == 0 and tagged.batch == "" and tagged.profile == "")
    H.check("batch.note_parse_bad_number",
        tool.parseNote(tool.NOTE_TAG .. " uses=abc").uses == 0)

    H.group("batch.labels")
    H.check("batch.label_plain", tool.safeLabel("labA", 24) == "labA")
    H.check("batch.label_dots_dashes", tool.safeLabel("a.b-c_1", 24) == "a.b-c_1")
    H.check("batch.label_empty", tool.safeLabel("", 24) == nil)
    H.check("batch.label_nil", tool.safeLabel(nil, 24) == nil)
    H.check("batch.label_number", tool.safeLabel(7, 24) == nil)
    H.check("batch.label_space", tool.safeLabel("lab A", 24) == nil)
    H.check("batch.label_slash", tool.safeLabel("lab/A", 24) == nil)
    H.check("batch.label_leading_dash", tool.safeLabel("-lab", 24) == nil)
    H.check("batch.label_too_long", tool.safeLabel(string.rep("a", 25), 24) == nil)
    H.check("batch.label_at_limit",
        tool.safeLabel(string.rep("a", 24), 24) == string.rep("a", 24))
    H.check("batch.integer_ok", tool.integerOf("12") == 12)
    H.check("batch.integer_zero", tool.integerOf("0") == 0)
    H.check("batch.integer_number", tool.integerOf(7) == 7)
    H.check("batch.integer_negative", tool.integerOf("-2") == nil)
    H.check("batch.integer_float", tool.integerOf("1.5") == nil)
    H.check("batch.integer_word", tool.integerOf("abc") == nil)
    H.check("batch.integer_nil", tool.integerOf(nil) == nil)

    H.group("batch.status")
    local NOW = 1600000000000
    H.check("batch.status_active", tool.statusOf({
        fp = "a1b2c3d4e5f6", uses_left = 2, uses_total = 2, revoked = false,
        note = ""}, NOW) == "active")
    H.check("batch.status_used", tool.statusOf({
        fp = "b", uses_left = 0, uses_total = 2, revoked = false, note = ""},
        NOW) == "used")
    H.check("batch.status_revoked", tool.statusOf({
        fp = "c", uses_left = 2, uses_total = 2, revoked = true, note = ""},
        NOW) == "revoked")
    local expiredNote = tool.buildNote({
        batch = "x", profile = "p", prefix = "x", uses = 1, expires = NOW})
    H.check("batch.status_expired_at_boundary", tool.statusOf({
        fp = "d", uses_left = 1, uses_total = 1, revoked = false,
        note = expiredNote}, NOW) == "expired")
    H.check("batch.status_not_yet_expired", tool.statusOf({
        fp = "d", uses_left = 1, uses_total = 1, revoked = false,
        note = expiredNote}, NOW - 1) == "active")
    H.check("batch.status_revoked_beats_expired", tool.statusOf({
        fp = "d", uses_left = 1, uses_total = 1, revoked = true,
        note = expiredNote}, NOW) == "revoked")
    H.check("batch.status_used_beats_expired", tool.statusOf({
        fp = "d", uses_left = 0, uses_total = 1, revoked = false,
        note = expiredNote}, NOW) == "used")
    H.check("batch.status_no_note", tool.statusOf({
        fp = "e", uses_left = 1, uses_total = 1, revoked = false}, NOW) == "active")
    H.check("batch.status_zero_expires", tool.statusOf({
        fp = "f", uses_left = 1, uses_total = 1, revoked = false,
        note = tool.buildNote({
            batch = "b", profile = "p", prefix = "x", uses = 1,
            expires = 0})}, NOW) == "active")
    H.check("batch.status_nil_item", tool.statusOf(nil, NOW) == "active")

    local line = tool.keyLine({
        fp = "a1b2c3d4e5f6", uses_left = 2, uses_total = 2, revoked = false,
        note = ""}, NOW)
    H.check("batch.keyline_braces", line:sub(1, 1) == "{" and line:sub(-1) == "}",
        line)
    H.check("batch.keyline_id", line:find('"id":"a1b2c3d4e5f6"', 1, true) ~= nil, line)
    H.check("batch.keyline_fp6", line:find('"fp6":"a1b2c3"', 1, true) ~= nil, line)
    H.check("batch.keyline_uses", line:find('"uses_left":2', 1, true) ~= nil, line)
    H.check("batch.keyline_status", line:find('"status":"active"', 1, true) ~= nil, line)
    H.check("batch.json_escaped", tool.jsonString('a"b') == '"a\\"b"',
        tool.jsonString('a"b'))
    H.check("batch.json_newline", tool.jsonString("a\nb") == '"a b"',
        tool.jsonString("a\nb"))

    ------------------------------------------------------------------------
    -- dispatch and usage
    ------------------------------------------------------------------------
    H.group("batch.main")
    local out, ok, err
    out, ok, err = runCmd(tool, "help")
    H.check("batch.help_ok", ok == true, tostring(err))
    H.check("batch.help_usage", out:find("usage:", 1, true) ~= nil, out)
    H.check("batch.help_new", out:find("new <count>", 1, true) ~= nil, out)
    H.check("batch.help_unrevoke", out:find("unrevoke <full key>", 1, true) ~= nil, out)
    H.check("batch.help_mentions_staging", out:find(".stage/", 1, true) ~= nil, out)
    out, ok, err = runCmd(tool)
    H.check("batch.no_command_fails", ok == false
        and tostring(err):find("missing command", 1, true) ~= nil, tostring(err))
    out, ok, err = runCmd(tool, "bogus")
    H.check("batch.unknown_command", ok == false
        and out:find("unknown command bogus", 1, true) ~= nil, out)

    -- Standalone entry point: any argument makes the file run main() itself.
    H.beginCapture()
    local standalone = H.load(BATCH, "help")
    local standaloneOut = H.endCapture()
    H.check("batch.standalone_help_returns_module", type(standalone) == "table")
    H.check("batch.standalone_help_prints_usage",
        standaloneOut:find("usage:", 1, true) ~= nil, standaloneOut)
    H.beginCapture()
    local raised, raisedText = pcall(H.load, BATCH, "bogus")
    H.endCapture()
    H.check("batch.standalone_failure_raises", raised == false
        and tostring(raisedText):find("itnpass_batch:", 1, true) ~= nil,
        tostring(raisedText))

    ------------------------------------------------------------------------
    -- new
    ------------------------------------------------------------------------
    H.group("batch.new")
    reset()
    H.stamp = "20260101-000000"
    local st = store()
    H.check("batch.new_empty_db", st.stats().total == 0, st.stats().total)

    out, ok, err = runCmd(tool, "new", "3")
    H.check("batch.new_ok", ok == true, tostring(err))
    H.check("batch.new_summary", out:find("ITNP_BATCH new count=3 ok=1", 1, true) ~= nil,
        out)
    H.check("batch.new_default_uses", out:find("uses=2", 1, true) ~= nil, out)
    H.check("batch.new_default_profile", out:find("profile=default", 1, true) ~= nil, out)
    H.check("batch.new_default_batch_id",
        (batchId(out) or ""):match("^batch%-20260101%-000000") ~= nil,
        tostring(batchId(out)))
    local path1 = stagedPath(out)
    H.check("batch.new_staged_path", path1 == STAGE .. "/batch-20260101-000000.txt",
        tostring(path1))
    H.check("batch.new_staged_exists", path1 ~= nil and fs.exists(path1) == true)
    local codes1 = codesIn(path1)
    H.check("batch.new_staged_code_count", #codes1 == 3, #codes1)
    H.check("batch.new_no_plaintext_on_screen", noPlaintext(out, codes1), out)
    local lines1 = jsonLines(out)
    H.check("batch.new_json_count", #lines1 == 3, #lines1)
    H.check("batch.new_json_id",
        lines1[1] ~= nil and lines1[1]:find(
            '"id":"' .. st.fingerprint(codes1[1]):sub(1, 12) .. '"', 1, true) ~= nil,
        tostring(lines1[1]))
    H.check("batch.new_json_fp6",
        lines1[1] ~= nil and lines1[1]:find(
            '"fp6":"' .. st.fingerprint(codes1[1]):sub(1, 6) .. '"', 1, true) ~= nil,
        tostring(lines1[1]))
    H.check("batch.new_json_uses",
        lines1[1] ~= nil and lines1[1]:find('"uses_left":2', 1, true) ~= nil)
    H.check("batch.new_json_status",
        lines1[1] ~= nil and lines1[1]:find('"status":"active"', 1, true) ~= nil)
    H.check("batch.new_json_batch",
        lines1[1] ~= nil and lines1[1]:find('"batch":"batch-20260101-000000"', 1,
            true) ~= nil, tostring(lines1[1]))
    H.check("batch.new_json_closed", lines1[1] ~= nil and lines1[1]:sub(-1) == "}")
    H.check("batch.new_stored_total", st.stats().total == 3, st.stats().total)
    H.check("batch.new_stored_remaining", st.stats().remaining == 6, st.stats().remaining)
    local stagedText = H.readFile(path1) or ""
    H.check("batch.new_staged_header",
        stagedText:find("# ITN-Pass batch", 1, true) ~= nil)
    H.check("batch.new_staged_uses", stagedText:find("# uses each: 2", 1, true) ~= nil)
    H.check("batch.new_staged_note",
        stagedText:find("# note: itnp-batch/1 batch=batch-20260101-000000", 1, true)
            ~= nil, stagedText:sub(1, 200))
    H.check("batch.new_note_recorded",
        (st.list()[1].note or ""):find("batch=batch-20260101-000000", 1, true) ~= nil,
        st.list()[1].note)
    H.check("batch.new_note_parsed",
        (tool.parseNote(st.list()[1].note) or {}).profile == "default")
    local logText = H.readFile(LOG) or ""
    H.check("batch.new_log_line",
        logText:find("ITNP_BATCH new count=3 ok=1", 1, true) ~= nil, logText)
    H.check("batch.new_log_batch",
        logText:find("batch=batch-20260101-000000", 1, true) ~= nil)

    out, ok, err = runCmd(tool, "new", "1", "--uses", "4", "--prefix", "labA",
        "--profile", "pyroet-os", "--expires", "30")
    H.check("batch.new_custom_ok", ok == true, tostring(err))
    H.check("batch.new_custom_uses", out:find("uses=4", 1, true) ~= nil, out)
    H.check("batch.new_custom_profile", out:find("profile=pyroet-os", 1, true) ~= nil, out)
    H.check("batch.new_custom_batch_id",
        (batchId(out) or ""):match("^labA%-20260101%-000000") ~= nil,
        tostring(batchId(out)))
    local expires = tonumber((out or ""):match("expires=(%d+)"))
    H.check("batch.new_custom_expires", expires ~= nil and expires > H.now,
        tostring(expires))
    H.check("batch.new_custom_stored", st.stats().total == 4, st.stats().total)
    H.check("batch.new_custom_remaining", st.stats().remaining == 10,
        st.stats().remaining)
    local path2 = stagedPath(out)
    H.check("batch.new_custom_staged", path2 == STAGE .. "/labA-20260101-000000.txt",
        tostring(path2))
    local codes2 = codesIn(path2)
    H.check("batch.new_custom_no_plaintext", noPlaintext(out, codes2), out)
    local customId = batchId(out)
    local found = nil
    for _, item in ipairs(st.list()) do
        local parsed = tool.parseNote(item.note)
        if parsed and parsed.batch == customId then
            found = parsed
        end
    end
    H.check("batch.new_custom_note_batch", found ~= nil and found.batch == customId,
        tostring(customId))
    H.check("batch.new_custom_note_expires",
        found ~= nil and found.expires == expires, found and tostring(found.expires))
    H.check("batch.new_custom_note_uses", found ~= nil and found.uses == 4)
    H.check("batch.new_custom_note_prefix", found ~= nil and found.prefix == "labA")

    local beforeTotal = st.stats().total
    out, ok = runCmd(tool, "new", "0")
    H.check("batch.new_zero_rejected",
        ok == false and out:find("error=bad_count", 1, true) ~= nil, out)
    out, ok = runCmd(tool, "new", "abc")
    H.check("batch.new_word_rejected",
        ok == false and out:find("error=bad_count", 1, true) ~= nil, out)
    out, ok = runCmd(tool, "new", "1", "--uses", "0")
    H.check("batch.new_uses_zero",
        ok == false and out:find("error=bad_uses", 1, true) ~= nil, out)
    out, ok = runCmd(tool, "new", "1", "--uses", tostring(tool.MAX_USES + 1))
    H.check("batch.new_uses_ceiling",
        ok == false and out:find("error=bad_uses", 1, true) ~= nil, out)
    out, ok = runCmd(tool, "new", "1", "--uses", tostring(tool.MAX_USES))
    H.check("batch.new_uses_at_ceiling", ok == true, out)
    out, ok = runCmd(tool, "new", "1", "--expires", "0")
    H.check("batch.new_expires_zero",
        ok == false and out:find("error=bad_expires", 1, true) ~= nil, out)
    out, ok = runCmd(tool, "new", "1", "--expires", tostring(tool.MAX_EXPIRES_DAYS + 1))
    H.check("batch.new_expires_ceiling",
        ok == false and out:find("error=bad_expires", 1, true) ~= nil, out)
    out, ok = runCmd(tool, "new", "1", "--expires", "7")
    H.check("batch.new_expires_ok", ok == true, out)
    out, ok = runCmd(tool, "new", "1", "--profile", "bad profile")
    H.check("batch.new_bad_profile",
        ok == false and out:find("error=bad_profile", 1, true) ~= nil, out)
    out, ok = runCmd(tool, "new", "1", "--prefix", "lab/A")
    H.check("batch.new_bad_prefix",
        ok == false and out:find("error=bad_prefix", 1, true) ~= nil, out)
    out, ok = runCmd(tool, "new", "4", "5")
    H.check("batch.new_extra_args",
        ok == false and out:find("error=bad_args", 1, true) ~= nil, out)
    H.check("batch.new_rejections_store_nothing",
        st.stats().total == beforeTotal + 2, st.stats().total)

    setConfig("max_batch = 200", "max_batch = 3")
    out, ok = runCmd(tool, "new", "4")
    H.check("batch.new_over_max_batch",
        ok == false and out:find("error=count_too_large", 1, true) ~= nil, out)
    H.check("batch.new_over_max_batch_reason",
        out:find("max_batch (3)", 1, true) ~= nil, out)
    out, ok = runCmd(tool, "new", "3")
    H.check("batch.new_at_max_batch", ok == true, out)
    restoreConfig()

    setConfig("default_uses = 2", "default_uses = 5")
    out, ok = runCmd(tool, "new", "1", "--prefix", "cfgA")
    H.check("batch.new_config_default_uses",
        ok == true and out:find("uses=5", 1, true) ~= nil, out)
    restoreConfig()

    H.writeFile("/blocked", "not a directory")
    setConfig('export_dir = "/cardkeys"', 'export_dir = "/blocked"')
    local totalNow = st.stats().total
    out, ok = runCmd(tool, "new", "2")
    H.check("batch.new_stage_failure",
        ok == false and out:find("error=stage_failed", 1, true) ~= nil, out)
    H.check("batch.new_stage_failure_reason",
        out:find("cannot create /blocked", 1, true) ~= nil, out)
    H.check("batch.new_stage_failure_nothing_stored",
        st.stats().total == totalNow, st.stats().total)
    H.check("batch.new_stage_failure_no_staging",
        out:find("staged=none", 1, true) ~= nil, out)
    restoreConfig()
    fs.delete("/blocked")
    H.stamp = nil

    ------------------------------------------------------------------------
    -- list
    ------------------------------------------------------------------------
    H.group("batch.list")
    reset()
    H.stamp = "20260202-020202"
    out, ok = runCmd(tool, "new", "3", "--uses", "2", "--prefix", "listA")
    H.check("batch.list_setup_a", ok == true and out:find("count=3", 1, true) ~= nil, out)
    local codesA = codesIn(stagedPath(out))
    out, ok = runCmd(tool, "new", "2", "--uses", "1", "--prefix", "listB")
    H.check("batch.list_setup_b", ok == true, out)
    local codesB = codesIn(stagedPath(out))
    out, ok = runCmd(tool, "new", "1", "--uses", "2", "--prefix", "listC",
        "--expires", "1")
    H.check("batch.list_setup_c", ok == true, out)
    local codesC = codesIn(stagedPath(out))
    H.check("batch.list_setup_total",
        #codesA == 3 and #codesB == 2 and #codesC == 1 and st.stats().total == 6,
        st.stats().total)

    H.check("batch.list_setup_revoke",
        st.revoke(st.fingerprint(codesA[1])) == true)
    H.check("batch.list_setup_reserve", st.reserve(codesA[2], "list-res-1") ~= nil)
    H.check("batch.list_setup_commit", st.commit("list-res-1") ~= nil)
    H.check("batch.list_setup_reserve2", st.reserve(codesA[2], "list-res-2") ~= nil)
    H.check("batch.list_setup_commit2", st.commit("list-res-2") ~= nil)
    H.advance(2 * DAY)

    out, ok = runCmd(tool, "list")
    H.check("batch.list_ok", ok == true)
    H.check("batch.list_summary",
        out:find("ITNP_BATCH list count=6 ok=1 total=6 shown=6", 1, true) ~= nil, out)
    H.check("batch.list_json_count", #jsonLines(out) == 6, #jsonLines(out))
    H.check("batch.list_no_plaintext",
        noPlaintext(out, codesA) and noPlaintext(out, codesB)
        and noPlaintext(out, codesC), out)
    H.check("batch.list_log",
        (H.readFile(LOG) or ""):find("ITNP_BATCH list count=6 ok=1 total=6 shown=6",
            1, true) ~= nil)

    out, ok = runCmd(tool, "list", "--status", "active")
    H.check("batch.list_active_count", out:find("shown=3", 1, true) ~= nil, out)
    H.check("batch.list_active_filter_field",
        out:find("status=active", 1, true) ~= nil, out)
    H.check("batch.list_active_every_line",
        #jsonLines(out) == 3 and jsonLines(out)[1]:find('"status":"active"', 1,
            true) ~= nil, out)

    out, ok = runCmd(tool, "list", "--status", "used")
    H.check("batch.list_used_count", ok == true and out:find("shown=1", 1, true) ~= nil,
        out)
    H.check("batch.list_used_json",
        (jsonLines(out)[1] or ""):find('"status":"used"', 1, true) ~= nil,
        tostring(jsonLines(out)[1]))
    H.check("batch.list_used_no_uses", out:find('"uses_left":0', 1, true) ~= nil, out)

    out, ok = runCmd(tool, "list", "--status", "expired")
    H.check("batch.list_expired_count", ok == true and out:find("shown=1", 1, true) ~= nil,
        out)
    H.check("batch.list_expired_json",
        (jsonLines(out)[1] or ""):find('"status":"expired"', 1, true) ~= nil)
    H.check("batch.list_expired_has_expiry",
        (jsonLines(out)[1] or ""):find('"expires":0', 1, true) == nil,
        tostring(jsonLines(out)[1]))

    out, ok = runCmd(tool, "list", "--status", "revoked")
    H.check("batch.list_revoked_count", ok == true and out:find("shown=1", 1, true) ~= nil,
        out)
    H.check("batch.list_revoked_json",
        (jsonLines(out)[1] or ""):find('"status":"revoked"', 1, true) ~= nil)

    out, ok = runCmd(tool, "list", "--status", "bogus")
    H.check("batch.list_bad_status",
        ok == false and out:find("error=bad_status", 1, true) ~= nil, out)
    out, ok = runCmd(tool, "list", "extra")
    H.check("batch.list_extra_arg",
        ok == false and out:find("error=bad_args", 1, true) ~= nil, out)
    out, ok = runCmd(tool, "list", "--status", "ACTIVE")
    H.check("batch.list_status_case_insensitive",
        ok == true and out:find("shown=3", 1, true) ~= nil, out)

    out, ok = runCmd(tool, "list", "--status", "used")
    local usedLine = jsonLines(out)[1] or ""
    local usedId = usedLine:match('"id":"(%x+)"')
    H.check("batch.list_json_id_len", usedId ~= nil and #usedId == 12,
        tostring(usedId))
    local usedFp6 = usedLine:match('"fp6":"(%x+)"')
    H.check("batch.list_json_fp6", usedFp6 ~= nil and #usedFp6 == 6
        and usedId:sub(1, 6) == usedFp6, tostring(usedFp6))
    H.check("batch.list_json_has_total", usedLine:find('"uses_total":2', 1, true) ~= nil,
        usedLine)
    H.check("batch.list_json_closed", usedLine:sub(-1) == "}")
    H.stamp = nil

    ------------------------------------------------------------------------
    -- export
    ------------------------------------------------------------------------
    H.group("batch.export")
    reset()
    H.stamp = "20260303-030303"
    out, ok = runCmd(tool, "new", "2", "--uses", "3", "--prefix", "expA")
    H.check("batch.export_setup", ok == true, out)
    local stageA = stagedPath(out)
    local codesA = codesIn(stageA)
    local textA = H.readFile(stageA) or ""
    H.check("batch.export_setup_keys", #codesA == 2, #codesA)

    out, ok = runCmd(tool, "export")
    H.check("batch.export_needs_out",
        ok == false and out:find("error=no_out", 1, true) ~= nil, out)
    H.check("batch.export_needs_out_changes_nothing", fs.exists(stageA) == true)

    out, ok = runCmd(tool, "export", "--out", OUTBOX .. "/expA.txt")
    H.check("batch.export_ok", ok == true, out)
    H.check("batch.export_summary",
        out:find("ITNP_BATCH export count=2 ok=1", 1, true) ~= nil, out)
    H.check("batch.export_batch_field",
        out:find("batch=expA-20260303-030303", 1, true) ~= nil, out)
    H.check("batch.export_no_plaintext", noPlaintext(out, codesA), out)
    H.check("batch.export_file_exists", fs.exists(OUTBOX .. "/expA.txt") == true)
    H.check("batch.export_file_bytes_equal",
        H.readFile(OUTBOX .. "/expA.txt") == textA)
    H.check("batch.export_file_header",
        (H.readFile(OUTBOX .. "/expA.txt") or ""):find("# ITN-Pass batch", 1, true)
            ~= nil)
    H.check("batch.export_json_keys",
        (jsonLines(out)[1] or ""):find('"keys":2', 1, true) ~= nil,
        tostring(jsonLines(out)[1]))
    H.check("batch.export_json_bytes",
        (jsonLines(out)[1] or ""):find('"bytes":' .. tostring(#textA), 1, true) ~= nil,
        tostring(jsonLines(out)[1]))
    H.check("batch.export_json_staging",
        (jsonLines(out)[1] or ""):find('"staging":"purged"', 1, true) ~= nil)
    H.check("batch.export_staging_purged", fs.exists(stageA) == false)
    H.check("batch.export_log",
        (H.readFile(LOG) or ""):find("ITNP_BATCH export count=2 ok=1", 1, true) ~= nil)
    local secondOut, secondOk = runCmd(tool, "export", "--out", OUTBOX .. "/again.txt")
    H.check("batch.export_nothing_left",
        secondOk == false and secondOut:find("error=no_staging", 1, true) ~= nil,
        secondOut)

    H.stamp = "20260303-030304"
    out, ok = runCmd(tool, "new", "1", "--prefix", "keepA")
    H.check("batch.export_keep_setup", ok == true, out)
    local stageKeep = stagedPath(out)
    out, ok = runCmd(tool, "export", "--out", OUTBOX .. "/keep1.txt", "--keep")
    H.check("batch.export_keep_ok", ok == true, out)
    H.check("batch.export_keep_staging", fs.exists(stageKeep) == true)
    H.check("batch.export_keep_json",
        (jsonLines(out)[1] or ""):find('"staging":"kept"', 1, true) ~= nil)
    out, ok = runCmd(tool, "export", "--out", OUTBOX .. "/keep2.txt")
    H.check("batch.export_keep_twice", ok == true, out)
    H.check("batch.export_keep_twice_equal",
        H.readFile(OUTBOX .. "/keep2.txt") == H.readFile(OUTBOX .. "/keep1.txt"))
    H.check("batch.export_keep_twice_purged", fs.exists(stageKeep) == false)

    H.stamp = "20260303-030305"
    local outOne, okOne = runCmd(tool, "new", "1", "--prefix", "ambA")
    local stageOne = stagedPath(outOne)
    H.stamp = "20260303-030306"
    local outTwo, okTwo = runCmd(tool, "new", "1", "--prefix", "ambB")
    local stageTwo = stagedPath(outTwo)
    H.check("batch.export_ambiguous_setup", okOne == true and okTwo == true)
    out, ok = runCmd(tool, "export", "--out", OUTBOX .. "/amb.txt")
    H.check("batch.export_ambiguous_refused",
        ok == false and out:find("error=ambiguous_staging", 1, true) ~= nil, out)
    H.check("batch.export_ambiguous_nothing_written",
        fs.exists(OUTBOX .. "/amb.txt") == false)
    H.check("batch.export_ambiguous_hint", out:find("--batch", 1, true) ~= nil, out)
    local textTwo = H.readFile(stageTwo)
    out, ok = runCmd(tool, "export", "--out", OUTBOX .. "/amb.txt", "--batch",
        batchId(outTwo))
    H.check("batch.export_explicit_batch_ok", ok == true, out)
    H.check("batch.export_explicit_batch_content",
        textTwo ~= nil and H.readFile(OUTBOX .. "/amb.txt") == textTwo)
    H.check("batch.export_explicit_batch_purged",
        fs.exists(stageTwo) == false and fs.exists(stageOne) == true)
    out, ok = runCmd(tool, "export", "--out", OUTBOX .. "/none.txt", "--batch",
        "missing-1")
    H.check("batch.export_unknown_batch",
        ok == false and out:find("error=no_staging", 1, true) ~= nil, out)

    H.writeFile("/blocked", "not a directory")
    out, ok = runCmd(tool, "export", "--out", "/blocked/x.txt")
    H.check("batch.export_out_dir_blocked",
        ok == false and out:find("error=out_dir", 1, true) ~= nil, out)
    fs.delete("/blocked")
    H.ensureDir(OUTBOX .. "/adir")
    out, ok = runCmd(tool, "export", "--out", OUTBOX .. "/adir")
    H.check("batch.export_out_is_dir",
        ok == false and out:find("error=out_is_dir", 1, true) ~= nil, out)
    out, ok = runCmd(tool, "export", "--out", stageOne)
    H.check("batch.export_same_path",
        ok == false and out:find("error=same_path", 1, true) ~= nil, out)
    H.writeFile(STAGE .. "/empty-20260101-000000.txt", "# ITNP-Pass batch\n")
    out, ok = runCmd(tool, "export", "--out", OUTBOX .. "/empty.txt", "--batch",
        "empty-20260101-000000")
    H.check("batch.export_no_keys",
        ok == false and out:find("error=no_keys", 1, true) ~= nil, out)
    H.check("batch.export_no_keys_removed", fs.exists(OUTBOX .. "/empty.txt") == false)
    out, ok = runCmd(tool, "export", "--out", OUTBOX .. "/badid.txt", "--batch",
        "bad id")
    H.check("batch.export_bad_batch_id",
        ok == false and out:find("error=bad_batch", 1, true) ~= nil, out)
    H.stamp = nil

    ------------------------------------------------------------------------
    -- revoke / unrevoke
    ------------------------------------------------------------------------
    H.group("batch.revoke")
    reset()
    H.stamp = "20260404-040404"
    out, ok = runCmd(tool, "new", "2", "--uses", "2", "--prefix", "revA")
    H.check("batch.revoke_setup", ok == true, out)
    local codes = codesIn(stagedPath(out))
    local id1 = st.fingerprint(codes[1]):sub(1, 12)
    local id2 = st.fingerprint(codes[2]):sub(1, 12)
    H.check("batch.revoke_setup_ids", #id1 == 12 and #id2 == 12)

    out, ok = runCmd(tool, "revoke", id1)
    H.check("batch.revoke_needs_yes",
        ok == false and out:find("error=confirmation_required", 1, true) ~= nil, out)
    H.check("batch.revoke_needs_yes_hint", out:find("--yes", 1, true) ~= nil, out)
    H.check("batch.revoke_needs_yes_ineffective", st.lookup(codes[1]) ~= nil)
    H.check("batch.revoke_needs_yes_logged",
        (H.readFile(LOG) or ""):find("ITNP_BATCH revoke count=0 ok=0", 1, true)
            ~= nil)

    out, ok = runCmd(tool, "revoke", id1:sub(1, 6), "--yes")
    H.check("batch.revoke_ok", ok == true and
        out:find("ITNP_BATCH revoke count=1 ok=1", 1, true) ~= nil, out)
    H.check("batch.revoke_effective", select(2, st.lookup(codes[1])) == "revoked")
    H.check("batch.revoke_output_no_key", noPlaintext(out, codes), out)
    H.check("batch.revoke_log",
        (H.readFile(LOG) or ""):find("ITNP_BATCH revoke count=1 ok=1", 1, true) ~= nil)

    out, ok = runCmd(tool, "revoke", codes[2], "--yes")
    H.check("batch.revoke_full_key_ok", ok == true, out)
    H.check("batch.revoke_full_key_masked", noPlaintext(out, {codes[2]}), out)
    H.check("batch.revoke_full_key_effective",
        select(2, st.lookup(codes[2])) == "revoked")

    out, ok = runCmd(tool, "revoke", "ffff", "--yes")
    H.check("batch.revoke_no_match",
        ok == false and out:find("error=revoke_failed", 1, true) ~= nil
        and out:find("no match", 1, true) ~= nil, out)
    out, ok = runCmd(tool, "revoke", "abc", "--yes")
    H.check("batch.revoke_prefix_short",
        ok == false and out:find("prefix too short", 1, true) ~= nil, out)
    out, ok = runCmd(tool, "revoke", "--yes")
    H.check("batch.revoke_no_target",
        ok == false and out:find("error=no_target", 1, true) ~= nil, out)
    out, ok = runCmd(tool, "revoke", id1, "extra", "--yes")
    H.check("batch.revoke_extra_arg",
        ok == false and out:find("error=bad_args", 1, true) ~= nil, out)
    H.check("batch.revoke_prefix_six_shown",
        out:find(id1:sub(1, 6), 1, true) == nil)  -- failure path prints nothing

    H.group("batch.unrevoke")
    out, ok = runCmd(tool, "unrevoke", id1)
    H.check("batch.unrevoke_needs_full_key",
        ok == false and out:find("error=needs_full_key", 1, true) ~= nil, out)
    H.check("batch.unrevoke_needs_full_key_detail",
        out:find("full key", 1, true) ~= nil, out)
    H.check("batch.unrevoke_prefix_ineffective",
        select(2, st.lookup(codes[1])) == "revoked")
    out, ok = runCmd(tool, "unrevoke", codes[1])
    H.check("batch.unrevoke_ok", ok == true and
        out:find("ITNP_BATCH unrevoke count=1 ok=1", 1, true) ~= nil, out)
    H.check("batch.unrevoke_effective", st.lookup(codes[1]) ~= nil)
    H.check("batch.unrevoke_no_key_on_screen", noPlaintext(out, {codes[1]}), out)
    H.check("batch.unrevoke_log",
        (H.readFile(LOG) or ""):find("ITNP_BATCH unrevoke count=1 ok=1", 1, true)
            ~= nil)
    out, ok = runCmd(tool, "unrevoke", "ZZZZZZZZZZZZ")
    H.check("batch.unrevoke_bad_format",
        ok == false and out:find("error=needs_full_key", 1, true) ~= nil, out)
    out, ok = runCmd(tool, "unrevoke", "23456789ABCDEFGH")
    H.check("batch.unrevoke_unknown_key",
        ok == false and out:find("error=unrevoke_failed", 1, true) ~= nil, out)
    H.check("batch.unrevoke_unknown_reason", out:find("no match", 1, true) ~= nil, out)
    out, ok = runCmd(tool, "unrevoke")
    H.check("batch.unrevoke_no_target",
        ok == false and out:find("error=no_target", 1, true) ~= nil, out)
    out, ok = runCmd(tool, "unrevoke", codes[1], codes[2])
    H.check("batch.unrevoke_extra_arg",
        ok == false and out:find("error=bad_args", 1, true) ~= nil, out)
    H.stamp = nil

    ------------------------------------------------------------------------
    -- prune
    ------------------------------------------------------------------------
    H.group("batch.prune")
    reset()
    H.stamp = "20260505-050505"
    out, ok = runCmd(tool, "new", "2", "--uses", "2", "--prefix", "pruneA")
    H.check("batch.prune_setup", ok == true, out)
    local stageA = stagedPath(out)
    local codesA = codesIn(stageA)
    out, ok = runCmd(tool, "prune")
    H.check("batch.prune_clean_ok", ok == true, out)
    H.check("batch.prune_clean_summary",
        out:find("ITNP_BATCH prune count=0 ok=1 reservations=0 expired=0 staging=0",
            1, true) ~= nil, out)
    H.check("batch.prune_live_staging_kept", fs.exists(stageA) == true)

    H.check("batch.prune_reserve_setup",
        st.reserve(codesA[1], "prune-res") ~= nil)
    H.advance(400000)
    out, ok = runCmd(tool, "prune")
    H.check("batch.prune_reservations",
        ok == true and out:find("reservations=1", 1, true) ~= nil, out)
    H.check("batch.prune_reservations_count",
        out:find("ITNP_BATCH prune count=1 ok=1", 1, true) ~= nil, out)
    H.check("batch.prune_reservation_still_usable", st.lookup(codesA[1]) ~= nil)

    H.stamp = "20260505-050506"
    out, ok = runCmd(tool, "new", "2", "--uses", "2", "--prefix", "pruneB",
        "--expires", "1")
    H.check("batch.prune_expiring_setup", ok == true, out)
    local stageB = stagedPath(out)
    local codesB = codesIn(stageB)
    H.check("batch.prune_expiring_revoke_one",
        st.revoke(st.fingerprint(codesB[1])) == true)
    H.advance(2 * DAY)
    out, ok = runCmd(tool, "prune")
    H.check("batch.prune_expired_ok", ok == true, out)
    H.check("batch.prune_expired_count", out:find("expired=1", 1, true) ~= nil, out)
    H.check("batch.prune_expired_total",
        out:find("ITNP_BATCH prune count=2 ok=1", 1, true) ~= nil, out)
    H.check("batch.prune_expired_revoked",
        select(2, st.lookup(codesB[2])) == "revoked")
    H.check("batch.prune_dead_batch_staging_removed", fs.exists(stageB) == false)
    H.check("batch.prune_staging_count", out:find("staging=1", 1, true) ~= nil, out)
    H.check("batch.prune_log",
        (H.readFile(LOG) or ""):find("ITNP_BATCH prune count=2 ok=1", 1, true) ~= nil)

    H.writeFile(STAGE .. "/orphan-20260101-000000.txt", "# ITNP-Pass batch\n")
    out, ok = runCmd(tool, "prune")
    H.check("batch.prune_orphan_staging_kept",
        fs.exists(STAGE .. "/orphan-20260101-000000.txt") == true)
    H.check("batch.prune_orphan_not_counted",
        out:find("staging=0", 1, true) ~= nil, out)
    H.check("batch.prune_live_batch_staging_still_there", fs.exists(stageA) == true)

    out, ok = runCmd(tool, "prune", "now")
    H.check("batch.prune_extra_arg",
        ok == false and out:find("error=bad_args", 1, true) ~= nil, out)

    reset()
    H.ensureDir(KEYS_DIR)
    H.writeFile(STAGE, "not a directory")
    out, ok = runCmd(tool, "prune")
    H.check("batch.prune_staging_not_dir",
        ok == true and out:find("staging=0", 1, true) ~= nil, out)
    out, ok = runCmd(tool, "export", "--out", OUTBOX .. "/x.txt")
    H.check("batch.export_staging_not_dir",
        ok == false and out:find("error=no_staging", 1, true) ~= nil, out)
    fs.delete(STAGE)

    ------------------------------------------------------------------------
    -- broken database and missing store
    ------------------------------------------------------------------------
    H.group("batch.corrupt")
    reset()
    H.writeFile(DB, "this is not a serialized table")
    local stamp = tostring(math.floor(H.now / 1000))
    H.stamp = "20260606-060606"
    out, ok = runCmd(tool, "list")
    H.check("batch.corrupt_list_ok", ok == true, out)
    H.check("batch.corrupt_list_empty", out:find("total=0", 1, true) ~= nil, out)
    H.check("batch.corrupt_backup_kept", fs.exists(DB .. ".corrupt-" .. stamp) == true)
    H.check("batch.corrupt_store_fault_logged",
        (H.readFile(LOG) or ""):find("STORE_DB_CORRUPT", 1, true) ~= nil)
    out, ok = runCmd(tool, "new", "2", "--uses", "1", "--prefix", "corA")
    H.check("batch.corrupt_new_ok", ok == true, out)
    H.check("batch.corrupt_new_stored", st.stats().total == 2, st.stats().total)
    H.check("batch.corrupt_new_log",
        (H.readFile(LOG) or ""):find("ITNP_BATCH new count=2 ok=1", 1, true) ~= nil)
    out, ok = runCmd(tool, "prune")
    H.check("batch.corrupt_prune_ok", ok == true and out:find("reservations=0", 1,
        true) ~= nil, out)

    local storeText = H.readFile("/auth/itnpass_store.lua")
    fs.delete("/auth/itnpass_store.lua")
    out, ok = runCmd(tool, "list")
    H.check("batch.store_missing",
        ok == false and out:find("error=store_unavailable", 1, true) ~= nil, out)
    H.check("batch.store_missing_logged",
        (H.readFile(LOG) or ""):find("ITNP_BATCH list count=0 ok=0 error=store_unavailable",
            1, true) ~= nil)
    H.writeFile("/auth/itnpass_store.lua", storeText)
    out, ok = runCmd(tool, "list")
    H.check("batch.store_restored", ok == true and out:find("total=2", 1, true) ~= nil,
        out)
    H.stamp = nil

    ------------------------------------------------------------------------
    -- charge semantics are the store's, not a second implementation
    ------------------------------------------------------------------------
    H.group("batch.consistency")
    reset()
    H.stamp = "20260707-070707"
    out, ok = runCmd(tool, "new", "1", "--uses", "2", "--prefix", "conA")
    H.check("batch.consistency_setup", ok == true, out)
    local code = codesIn(stagedPath(out))[1]
    H.check("batch.consistency_new_total", st.stats().total == 1, st.stats().total)
    H.check("batch.consistency_new_not_charged", st.lookup(code).uses_left == 2)
    H.check("batch.consistency_new_uses_total", st.list()[1].uses_total == 2)
    H.check("batch.consistency_list_active",
        out:find('"uses_left":2', 1, true) ~= nil, out)

    local reservation = st.reserve(code, "con-res-1")
    H.check("batch.consistency_reserve", reservation ~= nil)
    local rec, charged = st.commit("con-res-1")
    H.check("batch.consistency_commit_charged", charged == true and rec.uses_left == 1)
    out, ok = runCmd(tool, "list")
    H.check("batch.consistency_list_after_charge",
        out:find('"uses_left":1', 1, true) ~= nil, out)
    H.check("batch.consistency_list_status_active",
        out:find('"status":"active"', 1, true) ~= nil, out)

    H.check("batch.consistency_reserve_last",
        st.reserve(code, "con-res-2") ~= nil)
    local rec2, charged2 = st.commit("con-res-2")
    H.check("batch.consistency_commit_last", charged2 == true and rec2.uses_left == 0)
    H.check("batch.consistency_lookup_used_up",
        select(2, st.lookup(code)) == "used up")
    out, ok = runCmd(tool, "list", "--status", "used")
    H.check("batch.consistency_list_used",
        ok == true and out:find("shown=1", 1, true) ~= nil, out)
    H.check("batch.consistency_reserve_used_up",
        select(2, st.reserve(code, "con-res-3")) == "used up")
    H.check("batch.consistency_persisted",
        select(1, dofile(STORE).lookup(code)) == nil)
    H.check("batch.consistency_zero_after_commit", st.stats().remaining == 0,
        st.stats().remaining)
    H.stamp = nil

    -- Leave the shared /auth state as clean as the other suites expect.
    H.setNow(startedNow)
    H.stamp = startedStamp
end

return run
