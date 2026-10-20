-- terminal_keys.lua -- terminal id to shared key database (server side).
-- Deploy path: /auth/terminal_keys.lua
--
-- /auth/terminal_keys.db holds textutils.serialize({ [terminalId] = key }) with
-- 32 alphanumeric characters per key. The same file is copied to the audit
-- server, so both machines can verify terminal signatures.
--
-- The file is read on every call instead of being cached: the service and the
-- root console are separate Lua chunks that share this file, and a stale cache
-- would hand out keys the other chunk has just replaced.

local M = {}

local DB_PATH = "/auth/terminal_keys.db"
local KEY_LENGTH = 32
local MAX_ID_LENGTH = 64
local ALNUM = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789"

-- Ids end up inside "|" separated signed strings, so "|" itself and control
-- characters are not allowed. Spaces are legal (computer labels may have them).
local function validId(id)
    if type(id) ~= "string" or id == "" or #id > MAX_ID_LENGTH then return false end
    if id:find("|", 1, true) then return false end
    if id:find("%c") then return false end
    return true
end

local function readDb()
    if not fs.exists(DB_PATH) then return {} end
    local handle = fs.open(DB_PATH, "r")
    if not handle then return {} end
    local text = handle.readAll()
    handle.close()
    if type(text) ~= "string" or text == "" then return {} end
    local ok, data = pcall(textutils.unserialize, text)
    if not ok or type(data) ~= "table" then return {} end
    return data
end

local function writeDb(db)
    local ok, text = pcall(textutils.serialize, db)
    if not ok or type(text) ~= "string" then return false end
    local dir = fs.getDir(DB_PATH)
    if dir and dir ~= "" and not fs.exists(dir) then
        pcall(fs.makeDir, dir)
    end
    local handle = fs.open(DB_PATH, "w")
    if not handle then return false end
    handle.write(text)
    handle.close()
    return true
end

local function randomKey()
    local out = {}
    for i = 1, KEY_LENGTH do
        local index = math.random(1, #ALNUM)
        out[i] = ALNUM:sub(index, index)
    end
    return table.concat(out)
end

--- Key of a terminal, or nil when the terminal is not registered.
function M.get(id)
    if not validId(id) then return nil end
    local key = readDb()[id]
    if type(key) == "string" and key ~= "" then return key end
    return nil
end

--- Registers a terminal id and returns its key.
--- An already registered id keeps its key (add doubles as "show").
function M.add(id)
    if not validId(id) then return nil end
    local db = readDb()
    local existing = db[id]
    if type(existing) == "string" and existing ~= "" then return existing end
    local key = randomKey()
    db[id] = key
    if not writeDb(db) then return nil end
    return key
end

--- Removes a terminal id; false when it was not registered.
function M.remove(id)
    if not validId(id) then return false end
    local db = readDb()
    if db[id] == nil then return false end
    db[id] = nil
    return writeDb(db)
end

--- Registered terminal ids, sorted ascending.
function M.list()
    local ids = {}
    for id in pairs(readDb()) do
        if type(id) == "string" then
            ids[#ids + 1] = id
        end
    end
    table.sort(ids)
    return ids
end

return M
