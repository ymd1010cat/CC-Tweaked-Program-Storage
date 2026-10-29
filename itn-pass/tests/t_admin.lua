-- t_admin.lua -- itnpass_admin: password database and the three menus.
--
-- The password flow runs through M.main() (the real read/write prompts); the
-- menus are called directly because they are exported and take (conf, store).

local ADMIN = "/system/itnpass_admin.lua"
local ADMIN_DB = "/auth/itnpass_admin.db"
local STORE = "/auth/itnpass_store.lua"
local DB = "/auth/itnpass_passes.db"
local PEPPER_PATH = "/auth/itnpass_pepper.txt"
local CONFIG = "/auth/itnpass_config.lua"
local FAULT = "/auth/itnpass_fault.flag"
local PEPPER = string.rep("Ef5", 16)

local function run(H)
    local function sha()
        return dofile("/sha256.lua")
    end

    local function resetAdminDb()
        if fs.exists(ADMIN_DB) then
            fs.delete(ADMIN_DB)
        end
    end

    local function resetStoreDb()
        if fs.exists(DB) then
            fs.delete(DB)
        end
        H.writeFile(PEPPER_PATH, PEPPER .. "\n")
    end

    local function writeAdminDb(password, salt)
        salt = salt or "abcdefgh12345678"
        H.writeFile(ADMIN_DB, textutils.serialize({
            salt = salt,
            hash = sha().hash(password .. salt),
        }))
        return salt
    end

    local function capture(fn)
        H.beginCapture()
        local ok, err = pcall(fn)
        local out = H.endCapture()
        return out, ok, err
    end

    local function runMain(tag)
        local admin = H.load(ADMIN, "test")
        local out, ok, err = capture(function() admin.main() end)
        H.check("admin." .. tag .. ".ran", ok, tostring(err))
        return out
    end

    local function codesFromExport(path, store)
        local text = H.readFile(path) or ""
        local codes = {}
        for line in text:gmatch("[^\n]+") do
            local norm = store.normalize(line)
            if norm then
                codes[#codes + 1] = norm
            end
        end
        return codes
    end

    ------------------------------------------------------------------------
    -- password database
    ------------------------------------------------------------------------
    H.group("admin.password")

    resetAdminDb()
    H.setInputs("secret1", "secret1", "0")
    local out = runMain("first_run")
    H.check("admin.first_run_banner",
        out:find("=== First run: create admin password ===", 1, true) ~= nil, out)
    H.check("admin.first_run_prompts",
        out:find("New password: ", 1, true) ~= nil
        and out:find("Confirm password: ", 1, true) ~= nil)
    H.check("admin.first_run_ok_message",
        out:find("[OK] Admin password set.", 1, true) ~= nil, out)
    H.check("admin.first_run_creates_db", fs.exists(ADMIN_DB))
    local db = textutils.unserialize(H.readFile(ADMIN_DB) or "")
    H.check("admin.first_run_db_shape",
        type(db) == "table" and type(db.salt) == "string" and type(db.hash) == "string")
    H.check("admin.first_run_salt_len16", db ~= nil and #db.salt == 16,
        db and #db.salt)
    H.check("admin.first_run_salt_alnum",
        db ~= nil and db.salt:match("^[A-Za-z0-9]+$") ~= nil)
    H.check("admin.first_run_hash_matches",
        db ~= nil and db.hash == sha().hash("secret1" .. db.salt))
    H.check("admin.first_run_reaches_home",
        out:find("1. Generate card keys", 1, true) ~= nil, out)

    resetAdminDb()
    H.setInputs("secret1", "secret2")
    out = runMain("mismatch")
    H.check("admin.mismatch_message",
        out:find("[Error] Passwords do not match.", 1, true) ~= nil, out)
    H.check("admin.mismatch_creates_no_db", not fs.exists(ADMIN_DB))

    resetAdminDb()
    H.setInputs("abc", "abc")
    out = runMain("short")
    H.check("admin.short_password_message",
        out:find("[Error] Password must be at least 4 characters.", 1, true) ~= nil,
        out)
    H.check("admin.short_password_creates_no_db", not fs.exists(ADMIN_DB))

    H.writeFile(ADMIN_DB, "this is not a serialized table")
    H.setInputs()
    out = runMain("corrupt")
    H.check("admin.corrupt_db_message",
        out:find("[Error] Admin database is corrupt. Delete /auth/itnpass_admin.db"
            .. " to start over.", 1, true) ~= nil, out)

    H.writeFile(ADMIN_DB, textutils.serialize({ salt = "only-a-salt" }))
    H.setInputs()
    out = runMain("wrong_shape")
    H.check("admin.wrong_shape_is_corrupt",
        out:find("Admin database is corrupt", 1, true) ~= nil, out)

    local salt = writeAdminDb("pw123456")
    H.setInputs("pw123456", "0")
    out = runMain("login_ok")
    H.check("admin.login_ok_no_wrong_password_warning",
        out:find("[Error] Wrong password.", 1, true) == nil, out)
    H.check("admin.login_ok_reaches_home",
        out:find("ITN-Pass Station", 1, true) ~= nil, out)

    H.setInputs("bad1", "bad2", "bad3")
    out = runMain("wrong_password")
    local _, wrongCount = out:gsub("%[Error%] Wrong password%.", "")
    H.check("admin.wrong_password_three_attempts", wrongCount == 3, wrongCount)
    H.check("admin.wrong_password_access_denied",
        out:find("Access denied.", 1, true) ~= nil, out)
    H.check("admin.wrong_password_never_reaches_home",
        out:find("1. Generate card keys", 1, true) == nil, out)

    H.writeFile(FAULT, "modem_side 'left' is not a modem\n")
    H.installPeripheral({ names = { "left" }, types = { left = "drive" } })
    H.installDisk({ present = function() return false end })
    H.setInputs("pw123456", "0")
    out = runMain("fault_and_disk")
    H.check("admin.home_shows_service_fault",
        out:find("[SERVICE FAULT] modem_side 'left' is not a modem", 1, true) ~= nil,
        out)
    H.check("admin.home_shows_no_disk",
        out:find("disk: no disk (left)", 1, true) ~= nil, out)
    H.check("admin.home_shows_stats", out:find("usable=", 1, true) ~= nil)
    fs.delete(FAULT)

    H.installDisk({
        present = function() return true end,
        mount = function() return "/disk" end,
    })
    H.ensureDir("/disk")
    H.setFreeSpace(1000000)
    H.setInputs("pw123456", "0")
    out = runMain("disk_ready")
    H.check("admin.home_shows_ready_disk",
        out:find("disk: ready (left)", 1, true) ~= nil, out)
    H.check("admin.home_shows_free_space",
        out:find("free: 1000000 bytes", 1, true) ~= nil, out)

    ------------------------------------------------------------------------
    -- menus
    ------------------------------------------------------------------------
    H.group("admin.menus")
    resetAdminDb()
    resetStoreDb()
    H.rmTree("/cardkeys")
    local admin = H.load(ADMIN, "test")
    local conf = dofile(CONFIG)
    local store = dofile(STORE)

    H.setInputs("2", "", "hello note", "")
    local genOut, genOk, genErr = capture(function()
        admin.menuGenerate(conf, store)
    end)
    H.check("admin.generate_no_crash", genOk, tostring(genErr))
    H.check("admin.generate_summary",
        genOut:find("=== 2 card key(s), 2 use(s) each ===", 1, true) ~= nil, genOut)
    H.check("admin.generate_saved_to", genOut:find("Saved to:", 1, true) ~= nil)
    H.check("admin.generate_latest_path",
        genOut:find("/cardkeys/latest.txt", 1, true) ~= nil, genOut)
    H.check("admin.generate_stored_keys", store.stats().total == 2,
        store.stats().total)
    H.check("admin.generate_remaining_uses", store.stats().remaining == 4,
        store.stats().remaining)
    local all = codesFromExport("/cardkeys/latest.txt", store)
    H.check("admin.generate_export_file", #all == 2, #all)
    H.check("admin.generate_prints_formatted_key",
        #all == 2 and genOut:find(store.format(all[1]), 1, true) ~= nil, genOut)

    H.setInputs("0")
    local cancelOut = capture(function() admin.menuGenerate(conf, store) end)
    H.check("admin.generate_cancelled_zero",
        cancelOut:find("Cancelled.", 1, true) ~= nil, cancelOut)
    H.setInputs("abc")
    cancelOut = capture(function() admin.menuGenerate(conf, store) end)
    H.check("admin.generate_cancelled_non_numeric",
        cancelOut:find("Cancelled.", 1, true) ~= nil, cancelOut)

    local confText = H.readFile(CONFIG)
    H.writeFile(CONFIG, (confText:gsub("max_batch = 200", "max_batch = 3")))
    H.setInputs("10", "1", "", "")
    local capOut = capture(function()
        admin.menuGenerate(dofile(CONFIG), dofile(STORE))
    end)
    H.check("admin.generate_cap_message",
        capOut:find("Too many, capped at 3.", 1, true) ~= nil, capOut)
    H.check("admin.generate_cap_summary",
        capOut:find("=== 3 card key(s), 1 use(s) each ===", 1, true) ~= nil, capOut)
    H.writeFile(CONFIG, confText)

    H.writeFile("/blocked", "not a directory")
    H.writeFile(CONFIG, (confText:gsub('export_dir = "/cardkeys"',
        'export_dir = "/blocked"')))
    local keysBefore = dofile(STORE).stats().total
    H.setInputs("1", "1", "", "")
    local failOut = capture(function()
        admin.menuGenerate(dofile(CONFIG), dofile(STORE))
    end)
    H.check("admin.generate_export_error_header",
        failOut:find("[ERROR] Could not save the plaintext file:", 1, true) ~= nil,
        failOut)
    H.check("admin.generate_export_error_reason",
        failOut:find("cannot create /blocked", 1, true) ~= nil, failOut)
    H.check("admin.generate_export_error_nothing_stored",
        failOut:find("Nothing was stored. No keys were created, and no", 1, true)
            ~= nil, failOut)
    H.check("admin.generate_export_error_keeps_db",
        dofile(STORE).stats().total == keysBefore, dofile(STORE).stats().total)
    H.writeFile(CONFIG, confText)
    fs.delete("/blocked")

    all = codesFromExport("/cardkeys/latest.txt", dofile(STORE))
    H.check("admin.list_precondition", #all == 3, #all)

    H.setInputs(all[1], "")
    local listOut = capture(function() admin.menuList(conf, store) end)
    H.check("admin.list_header", listOut:find("=== Card keys ===", 1, true) ~= nil,
        listOut)
    H.check("admin.list_stats_line",
        listOut:find("total=", 1, true) ~= nil
        and listOut:find("usable=", 1, true) ~= nil, listOut)
    H.check("admin.list_shows_fingerprint_row",
        listOut:find(store.fingerprint(all[1]):sub(1, 12), 1, true) ~= nil, listOut)
    H.check("admin.list_revoke_ok",
        listOut:find("[OK] revoked", 1, true) ~= nil, listOut)
    H.check("admin.list_revoke_effective",
        select(2, store.lookup(all[1])) == "revoked")

    H.setInputs("")
    listOut = capture(function() admin.menuList(conf, store) end)
    H.check("admin.list_enter_returns",
        listOut:find("[OK] revoked", 1, true) == nil
        and listOut:find("[Error]", 1, true) == nil, listOut)

    H.setInputs("abc", "")
    listOut = capture(function() admin.menuList(conf, store) end)
    H.check("admin.list_prefix_too_short",
        listOut:find("[Error] prefix too short (min 4 chars)", 1, true) ~= nil,
        listOut)

    H.setInputs("zzzz", "")
    listOut = capture(function() admin.menuList(conf, store) end)
    H.check("admin.list_no_match", listOut:find("[Error] no match", 1, true) ~= nil,
        listOut)

    H.setInputs(all[1], "")
    local restoreOut = capture(function() admin.menuRestore(conf, store) end)
    H.check("admin.restore_ok", restoreOut:find("[OK] restored", 1, true) ~= nil,
        restoreOut)
    H.check("admin.restore_effective", select(2, store.lookup(all[1])) == nil)

    H.setInputs("bad", "")
    restoreOut = capture(function() admin.menuRestore(conf, store) end)
    H.check("admin.restore_invalid_code",
        restoreOut:find("[Error] invalid code format", 1, true) ~= nil, restoreOut)

    H.setInputs("23456789ABCDEFGH", "")
    restoreOut = capture(function() admin.menuRestore(conf, store) end)
    H.check("admin.restore_unknown_code",
        restoreOut:find("[Error] no match (unrevoke needs the full code)", 1, true)
            ~= nil, restoreOut)

    ------------------------------------------------------------------------
    -- missing dependencies are reported, not crashed on
    ------------------------------------------------------------------------
    H.group("admin.deps")
    H.setInputs()

    -- Hide a required file by copying it aside and deleting the original;
    -- fs.move is not used because its availability differs between builds.
    local function hide(path, backup)
        local text = H.readFile(path)
        if text == nil then
            return false
        end
        H.writeFile(backup, text)
        fs.delete(path)
        return (not fs.exists(path)) and fs.exists(backup) or false
    end

    local function restore(backup, path)
        local text = H.readFile(backup)
        if text == nil then
            return false
        end
        H.writeFile(path, text)
        fs.delete(backup)
        return fs.exists(path)
    end

    local hidden = hide("/sha256.lua", "/logs/sha256.off")
    H.check("admin.deps.sha_hidden", hidden == true)
    local shaOut, shaOk, shaErr = capture(function()
        local mod = H.load(ADMIN, "test")
        mod.main()
    end)
    local restored = restore("/logs/sha256.off", "/sha256.lua")
    H.check("admin.deps.sha_restored", restored == true)
    H.check("admin.deps.sha_missing_no_crash", shaOk, tostring(shaErr))
    H.check("admin.deps.sha_missing_message",
        shaOut:find("[ERROR] cannot load /sha256.lua:", 1, true) ~= nil, shaOut)

    hidden = hide(CONFIG, "/logs/config.off")
    H.check("admin.deps.config_hidden", hidden == true)
    local cfgOut, cfgOk, cfgErr = capture(function()
        local mod = H.load(ADMIN, "test")
        mod.main()
    end)
    restored = restore("/logs/config.off", CONFIG)
    H.check("admin.deps.config_restored", restored == true)
    H.check("admin.deps.config_missing_no_crash", cfgOk, tostring(cfgErr))
    H.check("admin.deps.config_missing_message",
        cfgOut:find("[ERROR] cannot load /auth/itnpass_config.lua:", 1, true) ~= nil,
        cfgOut)

    -- The stored hash is salted: the same password must not hash the same way
    -- for a different installation.
    H.check("admin.password_hash_includes_salt",
        sha().hash("pw123456" .. salt) ~= sha().hash("pw123456" .. "anothersalt23456"))
end

return run
