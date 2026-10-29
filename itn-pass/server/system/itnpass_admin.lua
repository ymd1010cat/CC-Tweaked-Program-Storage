-- itnpass_admin.lua -- password-protected ITN-Pass station console.
-- Deploy as /system/itnpass_admin.lua on the station.
--
-- The console owns the screen and is restarted by /startup.lua after it exits.
-- It never touches the modem: uses not charged are decided by the service.
--
-- The file is loadable without starting: loadfile(path)("test") returns the
-- module; os.run({}, path) (no arguments) runs the console.

local M = {}

local okSha, sha = pcall(dofile, "/sha256.lua")
local ALNUM = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789"
local DEFAULT_ADMIN_FILE = "/auth/itnpass_admin.db"
local FAULT_PATH = "/auth/itnpass_fault.flag"

local function pause()
    write("Press Enter to continue...")
    read()
end

local function clearScreen()
    term.clear()
    term.setCursorPos(1, 1)
end

local function parentOf(path)
    local p = tostring(path):gsub("/+$", "")
    local cut = p:match("^.*()/")
    if not cut or cut == 1 then
        return "/"
    end
    return p:sub(1, cut - 1)
end

local function ensureDir(path)
    if path == nil or path == "" or path == "/" then
        return true
    end
    if fs.exists(path) then
        return fs.isDir(path)
    end
    if not ensureDir(parentOf(path)) then
        return false
    end
    local made = fs.makeDir(path)
    if made == nil then
        made = false
    end
    return made or (fs.exists(path) and fs.isDir(path))
end

local function loadModules()
    local okConfig, conf = pcall(dofile, "/auth/itnpass_config.lua")
    if not okConfig or type(conf) ~= "table" then
        return nil, nil, nil, "cannot load /auth/itnpass_config.lua: " .. tostring(conf)
    end
    local okStore, store = pcall(dofile, "/auth/itnpass_store.lua")
    if not okStore then
        return nil, nil, nil, "cannot load /auth/itnpass_store.lua: " .. tostring(store)
    end
    local okWriter, writer = pcall(dofile, "/system/disk_writer.lua")
    if not okWriter then
        return nil, nil, nil, "cannot load /system/disk_writer.lua: " .. tostring(writer)
    end
    return conf, store, writer, nil
end

local function randomSalt()
    local out = {}
    for i = 1, 16 do
        local idx = math.random(1, #ALNUM)
        out[i] = ALNUM:sub(idx, idx)
    end
    return table.concat(out)
end

-- nil = no database yet, false = unreadable database, table = loaded record.
local function readAdminDb(path)
    if not fs.exists(path) then
        return nil
    end
    local f = fs.open(path, "rb")
    if not f then
        return false
    end
    local raw = f.readAll()
    f.close()
    local ok, t = pcall(textutils.unserialize, raw or "")
    if ok and type(t) == "table" and type(t.salt) == "string" and
        type(t.hash) == "string" then
        return t
    end
    return false
end

local function saveAdminDb(path, salt, hash)
    ensureDir(parentOf(path))
    local f = fs.open(path, "wb")
    if not f then
        return false
    end
    local text = textutils.serialize({salt = salt, hash = hash})
    local ok = pcall(function()
        f.write(text)
    end)
    f.close()
    if not ok then
        return false
    end
    -- CraftOS-PC's file:write returns nothing, so success is checked by size.
    return (fs.getSize(path) or -1) == #text
end

local function ensurePassword(conf)
    local path = tostring(conf.admin_file or DEFAULT_ADMIN_FILE)
    local db = readAdminDb(path)
    if db == false then
        print("[Error] Admin database is corrupt. Delete " .. path .. " to start over.")
        return false
    end
    if db == nil then
        print("=== First run: create admin password ===")
        write("New password: ")
        local first = tostring(read("*") or "")
        write("Confirm password: ")
        local second = tostring(read("*") or "")
        if #first < 4 then
            print("[Error] Password must be at least 4 characters.")
            return false
        end
        if first ~= second then
            print("[Error] Passwords do not match.")
            return false
        end
        local salt = randomSalt()
        if not saveAdminDb(path, salt, sha.hash(first .. salt)) then
            print("[Error] Could not save " .. path .. ".")
            return false
        end
        print("[OK] Admin password set.")
        return true
    end
    print("ITN-Pass Station")
    for attempt = 1, 3 do
        if attempt > 1 then
            print("Attempt " .. tostring(attempt) .. " of 3")
        end
        write("Password: ")
        local typed = tostring(read("*") or "")
        if sha.hash(typed .. db.salt) == db.hash then
            return true
        end
        print("[Error] Wrong password.")
    end
    print("Access denied.")
    os.sleep(5)
    return false
end

local function faultText()
    if not fs.exists(FAULT_PATH) then
        return nil
    end
    local f = fs.open(FAULT_PATH, "rb")
    if not f then
        return nil
    end
    local line = f.readLine()
    f.close()
    if line == nil or line == "" then
        return nil
    end
    return line
end

local function showHome(conf, store, writer)
    clearScreen()
    print("ITN-Pass Station")
    local stats = store.stats()
    print("usable=" .. tostring(stats.alive) .. "  remaining=" .. tostring(stats.remaining))
    local fault = faultText()
    if fault then
        print("[SERVICE FAULT] " .. fault)
    end
    local status = writer.status()
    local diskLine = "disk: " .. tostring(status.state)
    if status.drive then
        diskLine = diskLine .. " (" .. tostring(status.drive) .. ")"
    end
    print(diskLine)
    if status.state == "ready" and status.free then
        print("free: " .. tostring(status.free) .. " bytes")
    end
    print("")
    print("1. Generate card keys")
    print("2. List / revoke")
    print("3. Restore revoked key")
    print("0. Exit")
    write("Select: ")
    return tostring(read() or "")
end

function M.menuGenerate(conf, store)
    local maxBatch = tonumber(conf.max_batch) or 200
    write("How many? (1-" .. tostring(maxBatch) .. "): ")
    local count = tonumber(read())
    if not count or count < 1 then
        print("Cancelled.")
        os.sleep(1)
        return
    end
    count = math.floor(count)
    if count > maxBatch then
        print("Too many, capped at " .. tostring(maxBatch) .. ".")
        count = maxBatch
    end
    local defaultUses = tonumber(conf.default_uses) or 2
    write("Uses per key? (default " .. tostring(defaultUses) .. "): ")
    local uses = tonumber(read())
    if not uses or uses < 1 then
        uses = defaultUses
    end
    uses = math.floor(uses)
    write("Note (optional): ")
    local note = tostring(read() or "")
    print("")

    local codes, path, latest = store.generate(count, uses, note)
    if not codes then
        print("[ERROR] Could not save the plaintext file:")
        print(tostring(path))
        print("Nothing was stored. No keys were created, and no")
        print("uses were consumed. Fix the problem and try again.")
        pause()
        return
    end
    print("=== " .. tostring(#codes) .. " card key(s), " .. tostring(uses) .. " use(s) each ===")
    if #codes <= 5 then
        for _, code in ipairs(codes) do
            print("  " .. (store.format(code) or code))
        end
    end
    print("Saved to:")
    print(tostring(path))
    print(tostring(latest))
    print("Stored " .. tostring(#codes) .. " key(s) in the database.")
    print("Copy one of these files off the server, then delete it.")
    pause()
end

function M.menuList(conf, store)
    clearScreen()
    local items = store.list()
    local stats = store.stats()
    print("=== Card keys ===")
    print(string.format("total=%d  usable=%d  used-up=%d  revoked=%d",
        stats.total, stats.alive, stats.exhausted, stats.revoked))
    print("remaining uses: " .. tostring(stats.remaining))
    print("fp            left/total  status")
    print(string.rep("-", 35))
    for _, item in ipairs(items) do
        local status = "ok"
        if item.revoked then
            status = "REVOKED"
        elseif item.uses_left <= 0 then
            status = "used up"
        end
        print(string.format("%-12s  %d/%-8d  %s",
            item.fp, item.uses_left, item.uses_total, status))
    end
    print("")
    print("Enter = back")
    write("revoke by fp prefix or full code: ")
    local input = tostring(read() or "")
    if input == "" then
        return
    end
    local ok, message = store.revoke(input)
    if ok then
        print("[OK] revoked")
    else
        print("[Error] " .. tostring(message))
    end
    pause()
end

function M.menuRestore(conf, store)
    clearScreen()
    print("=== Restore a revoked key ===")
    print("Needs the FULL code (prefixes are ambiguous).")
    write("Card key: ")
    local input = tostring(read() or "")
    local ok, message = store.unrevoke(input)
    if ok then
        print("[OK] restored")
    else
        print("[Error] " .. tostring(message))
    end
    pause()
end

function M.main()
    if not okSha then
        print("[ERROR] cannot load /sha256.lua: " .. tostring(sha))
        os.sleep(2)
        return
    end
    local conf, store, writer, loadError = loadModules()
    if not conf then
        print("[ERROR] " .. tostring(loadError))
        os.sleep(2)
        return
    end
    if not ensurePassword(conf) then
        return
    end
    while true do
        local choice = showHome(conf, store, writer)
        if choice == "1" then
            M.menuGenerate(conf, store)
        elseif choice == "2" then
            M.menuList(conf, store)
        elseif choice == "3" then
            M.menuRestore(conf, store)
        elseif choice == "0" or choice == "" then
            return
        else
            os.sleep(0.2)
        end
    end
end

local arg = ...
if arg == nil then
    M.main()
end
return M
