-- Sentinel login dispatcher: network client or local standalone store.
-- Deploy: /auth/login.lua

local M = {}

local cachedMode = nil
local cachedModule = nil

local function readMode()
    local ok, config = pcall(dofile, "/auth/mode.lua")
    if ok and type(config) == "table" then
        return config.mode or "client"
    end
    return "client"
end

local function loadLogin(mode)
    if cachedModule and cachedMode == mode then return cachedModule end
    local path = "/auth/login_client.lua"
    if mode == "standalone" then
        path = "/auth/login_standalone.lua"
    end
    local ok, module = pcall(dofile, path)
    if not ok or type(module) ~= "table" then
        error("cannot load " .. path, 0)
    end
    cachedMode = mode
    cachedModule = module
    return module
end

local loginModule = loadLogin(readMode())

function M.login()
    return loginModule.login()
end

function M.verifyPassword(username, password)
    return loginModule.verifyPassword(username, password)
end

return M
