-- Sentinel offline test suite (CraftOS-PC headless, no real modems/redstone).
-- Staged as /tests/run.lua and started by /startup.lua.
--
-- The suite drives the real modules:
--   * role_policy pure functions
--   * auth_server.handleMessage (login role downlink + open_request actuator)
--   * login.lua / login_client.lua against a loopback modem bus backed by the
--     real auth_server handlers and the real PSK/terminal_keys databases
--   * terminal audit.lua -> audit_server.handleEvent (role in the signature)
-- plus static assertions on the cleaned-up source files.

local pass, fail = 0, 0

local function check(name, ok, detail)
    if ok then
        pass = pass + 1
        print("TEST " .. name .. " ok=true")
    else
        fail = fail + 1
        print("TEST " .. name .. " ok=false")
        print("TEST_FAIL " .. name .. ": " .. tostring(detail or ""))
    end
end

local function readFile(path)
    if not fs.exists(path) then return nil end
    local handle = fs.open(path, "r")
    if not handle then return nil end
    local text = handle.readAll()
    handle.close()
    return text
end

local function writeFile(path, text)
    local handle = fs.open(path, "w")
    if not handle then return false end
    handle.write(text)
    handle.close()
    return true
end

local function ensureDir(path)
    if not fs.exists(path) then
        pcall(fs.makeDir, path)
    end
    return fs.exists(path)
end

local function source(path)
    return readFile(path) or ""
end

local function contains(text, needle)
    return text:find(needle, 1, true) ~= nil
end

---------------------------------------------------------------------------
-- stubs: fake modem bus, redstone recorder, timers and console input
---------------------------------------------------------------------------

local eventQueue = {}
local readQueue = {}
local redstoneCalls = {}
local bus = { sent = {}, handler = nil }
local activeTimer = 0

local function clearQueue()
    for i = #eventQueue, 1, -1 do eventQueue[i] = nil end
end

local function clearSent()
    for i = #bus.sent, 1, -1 do bus.sent[i] = nil end
end

local function clearRedstone()
    for i = #redstoneCalls, 1, -1 do redstoneCalls[i] = nil end
end

local function isRequestType(kind)
    return kind == "salt_request" or kind == "auth_request"
        or kind == "open_request"
end

local fakeModem = {
    transmit = function(channel, replyChannel, message)
        bus.sent[#bus.sent + 1] = {
            channel = channel,
            replyChannel = replyChannel,
            message = message,
        }
        if type(message) == "table" and isRequestType(message.type) then
            if bus.handler then bus.handler(message, replyChannel) end
            return
        end
        eventQueue[#eventQueue + 1] = {
            "modem_message", "left", channel, replyChannel, message,
        }
    end,
    open = function(channel) return true end,
    close = function(channel) return true end,
    isWireless = function() return false end,
}

peripheral = {
    getNames = function() return { "left" } end,
    getType = function(name)
        if name == "left" then return "modem" end
        return nil
    end,
    call = function(name, method, ...)
        local fn = fakeModem[method]
        if type(fn) ~= "function" then return nil end
        return fn(...)
    end,
    wrap = function(name) return fakeModem end,
}

redstone = {
    setOutput = function(side, level)
        redstoneCalls[#redstoneCalls + 1] = { side = side, level = level }
    end,
}

os.startTimer = function(seconds)
    activeTimer = activeTimer + 1
    return activeTimer
end

-- No event means "the peer never answered": hand back the armed timer, which
-- is exactly the timeout path the modules expect.
os.pullEvent = function()
    if #eventQueue > 0 then
        local ev = table.remove(eventQueue, 1)
        return ev[1], ev[2], ev[3], ev[4], ev[5]
    end
    return "timer", activeTimer
end

-- Disable real waiting: the door pulse and the netcheck window are never slept.
os.sleep = function(seconds) end

read = function(mask)
    return table.remove(readQueue, 1)
end

local function setInputs(...)
    for i = #readQueue, 1, -1 do readQueue[i] = nil end
    local args = { ... }
    for i = 1, #args do readQueue[i] = args[i] end
end

local function seedHeartbeat()
    eventQueue[#eventQueue + 1] = {
        "modem_message", "left", 1, 0, {
            protocol = "secure_auth_v5",
            type = "heartbeat",
            server_id = "TEST-SERVER",
        },
    }
end

local function lastSentMessage(kind)
    for i = #bus.sent, 1, -1 do
        local message = bus.sent[i].message
        if type(message) == "table" and message.type == kind then
            return message
        end
    end
    return nil
end

local function countSentMessage(kind)
    local count = 0
    for i = 1, #bus.sent do
        local message = bus.sent[i].message
        if type(message) == "table" and message.type == kind then
            count = count + 1
        end
    end
    return count
end

local function countPulses(side, level)
    local count = 0
    for i = 1, #redstoneCalls do
        if redstoneCalls[i].side == side and redstoneCalls[i].level == level then
            count = count + 1
        end
    end
    return count
end

---------------------------------------------------------------------------
-- static assertions (the cleanup this stage is about)
---------------------------------------------------------------------------

local function staticTests()
    local login = source("/auth/login.lua")
    check("static.login_loads_client", contains(login, "login_client.lua"))
    check("static.login_has_no_standalone", not contains(login, "login_standalone"))
    check("static.login_has_no_mode", not contains(login, "mode.lua"))
    check("static.login_exports_request_open", contains(login, "requestOpen"))

    local client = source("/auth/login_client.lua")
    check("static.client_v5", contains(client, "secure_auth_v5"))
    check("static.client_no_guest_fallback", not contains(client, 'or "guest"'))
    check("static.client_request_open", contains(client, "open_request"))
    check("static.client_role_policy", contains(client, "role_policy"))

    local standalone = source("/auth/login_standalone.lua")
    check("static.standalone_disabled",
        contains(standalone, "Offline mode is disabled"))

    local authServer = source("/system/auth_server.lua")
    check("static.auth_server_v5", contains(authServer, "secure_auth_v5"))
    check("static.auth_server_no_guest_fallback", not contains(authServer, 'or "guest"'))
    check("static.auth_server_open_request", contains(authServer, "open_request"))
    check("static.auth_server_policy", contains(authServer, "role_policy"))

    local ui = source("/system/ui.lua")
    check("static.ui_no_redstone", not contains(ui, "redstone"))
    check("static.ui_no_root_compare", not contains(ui, 'user.role == "root"'))
    check("static.ui_request_open", contains(ui, "requestOpen"))
    check("static.ui_policy", contains(ui, "role_policy"))

    local admin = source("/system/user_admin.lua")
    check("static.user_admin_no_root_compare", not contains(admin, 'user.role == "root"'))
    check("static.user_admin_policy", contains(admin, "role_policy"))

    local terminalAudit = source("/system/audit.lua")
    check("static.audit_client_v5", contains(terminalAudit, "secure_auth_v5"))
    check("static.audit_client_no_standalone", not contains(terminalAudit, "standalone"))
    check("static.audit_client_role_arg", contains(terminalAudit, "role"))

    local auditServer = source("/system/audit_server.lua")
    check("static.audit_server_v5", contains(auditServer, "secure_auth_v5"))
    check("static.audit_server_role", contains(auditServer, "ROLE="))

    local netcheck = source("/system/netcheck.lua")
    check("static.netcheck_v5", contains(netcheck, "secure_auth_v5"))

    local kernel = source("/system/kernel.lua")
    check("static.kernel_no_mode", not contains(kernel, "mode.lua"))
    check("static.kernel_no_standalone", not contains(kernel, "standalone"))

    check("static.mode_file_removed", not fs.exists("/auth/mode.lua"))

    local v4 = {}
    local function scan(path)
        if fs.isDir(path) then
            for _, name in ipairs(fs.list(path)) do
                scan(path == "/" and ("/" .. name) or (path .. "/" .. name))
            end
        elseif path:sub(-4) == ".lua" then
            if contains(source(path), "secure_auth_v4") then
                v4[#v4 + 1] = path
            end
        end
    end
    pcall(scan, "/auth")
    pcall(scan, "/system")
    pcall(scan, "/sha256.lua")
    check("static.no_v4_tokens_left", #v4 == 0, table.concat(v4, ","))
end

---------------------------------------------------------------------------
-- role_policy
---------------------------------------------------------------------------

local function rolePolicyTests()
    local policy = dofile("/auth/role_policy.lua")
    check("role.normalize_root", policy.normalize("ROOT") == "root")
    check("role.normalize_trim", policy.normalize(" Admin ") == "admin")
    check("role.normalize_guest_alias", policy.normalize("guest") == "user")
    check("role.normalize_unknown", policy.normalize("wizard") == nil)
    check("role.normalize_nil", policy.normalize(nil) == nil)
    check("role.normalize_empty", policy.normalize("") == nil)
    check("role.weight_root", policy.weight("root") == 4)
    check("role.weight_admin", policy.weight("admin") == 3)
    check("role.weight_operator", policy.weight("operator") == 2)
    check("role.weight_user", policy.weight("user") == 1)
    check("role.weight_guest_is_user", policy.weight("guest") == policy.weight("user"))
    check("role.weight_unknown", policy.weight("wizard") == nil)
    check("role.allows_admin_operator", policy.allows("admin", "operator") == true)
    check("role.allows_operator_admin", policy.allows("operator", "admin") == false)
    check("role.allows_root_root", policy.allows("root", "root") == true)
    check("role.allows_guest_operator", policy.allows("guest", "operator") == false)
    check("role.allows_user_guest", policy.allows("user", "guest") == true)
    check("role.allows_nil", policy.allows(nil, "operator") == false)
    check("role.allows_unknown_required", policy.allows("root", "wizard") == false)
end

---------------------------------------------------------------------------
-- server fixtures
---------------------------------------------------------------------------

_G.SENTINEL_TEST = true

local TERMINAL_ID = "TEST-TERM-1"
local SERVER_ID = "TEST-SERVER"

local sha = dofile("/sha256.lua")
local crypto = dofile("/auth/server_crypto.lua")
local userManager = dofile("/auth/user_manager.lua")

local function prepareDatabases()
    ensureDir("/auth")
    writeFile("/auth/terminal_id.txt", TERMINAL_ID)
    writeFile("/auth/server_id", SERVER_ID)

    local terminalKeys = dofile("/auth/terminal_keys.lua")
    local key = terminalKeys.add(TERMINAL_ID)
    writeFile("/auth/psk.txt", key or "")

    if fs.exists("/auth/users.db") then fs.delete("/auth/users.db") end
    userManager.addUser("alice", "alicepw", "operator")
    userManager.addUser("ada", "adapw", "admin")
    userManager.addUser("bob", "bobpw", "guest")
    userManager.addUser("dave", "davepw", "user")

    local users = textutils.unserialize(readFile("/auth/users.db")) or {}
    local function rawUser(name, password, role)
        local salt = "0123456789abcdef"
        users[name] = {
            salt = salt,
            hash = sha.hash(password .. salt),
            role = role,
        }
    end
    rawUser("rootuser", "rootpw", "root")
    rawUser("charlie", "charliepw", "superuser")
    rawUser("norole", "norolepw", nil)
    writeFile("/auth/users.db", textutils.serialize(users))
end

local authServer = nil
local function getServer()
    if not authServer then
        authServer = dofile("/system/auth_server.lua")
        authServer.init({ server_id = SERVER_ID, modem = fakeModem })
    end
    return authServer
end

local nonceCounter = 0
local function nextNonce()
    nonceCounter = nonceCounter + 1
    return "nonce-" .. tostring(nonceCounter) .. "-" .. tostring(os.epoch("utc"))
end

local function userRecord(name)
    local users = textutils.unserialize(readFile("/auth/users.db")) or {}
    return users[name]
end

local function makeAuthRequest(username, password, nonceC, nonceS)
    local record = userRecord(username)
    -- The wire derivation uses the password actually typed, exactly like the
    -- client: hash = sha256(password .. salt), derived = sha256(hash|nonce_c|nonce_s).
    local salt = record and record.salt or "ffffffffffffffff"
    local hash = sha.hash(password .. salt)
    local derived = sha.hash(hash .. "|" .. nonceC .. "|" .. nonceS)
    local data = TERMINAL_ID .. "|" .. username .. "|" .. derived .. "|"
        .. nonceC .. "|" .. nonceS
    return {
        protocol = "secure_auth_v5",
        type = "auth_request",
        terminal_id = TERMINAL_ID,
        username = username,
        derived = derived,
        nonce_c = nonceC,
        nonce_s = nonceS,
        sig = crypto.sign(TERMINAL_ID, data),
    }
end

local function makeOpenRequest(username, nonce)
    local data = TERMINAL_ID .. "|" .. username .. "|" .. nonce
    return {
        protocol = "secure_auth_v5",
        type = "open_request",
        terminal_id = TERMINAL_ID,
        username = username,
        nonce = nonce,
        sig = crypto.sign(TERMINAL_ID, data),
    }
end

local function askServer(message, replyChannel)
    local before = #bus.sent
    getServer().handleMessage(message, replyChannel)
    local response = nil
    for i = before + 1, #bus.sent do
        local candidate = bus.sent[i].message
        if type(candidate) == "table" and candidate.type ~= nil
            and not isRequestType(candidate.type) then
            response = candidate
        end
    end
    return response
end

---------------------------------------------------------------------------
-- auth_server: role downlink
---------------------------------------------------------------------------

local function serverAuthTests()
    getServer()
    local nonceC, nonceS = nextNonce(), nextNonce()
    local response = askServer(makeAuthRequest("alice", "alicepw", nonceC, nonceS), 7001)
    check("auth.operator.success", response ~= nil and response.success == true)
    check("auth.operator.role", response ~= nil and response.role == "operator",
        response and response.role)
    local signed = SERVER_ID .. "|" .. nonceC .. "|" .. nonceS .. "|true|operator"
    check("auth.operator.signature_includes_role",
        response ~= nil and response.sig == crypto.sign(TERMINAL_ID, signed))

    nonceC, nonceS = nextNonce(), nextNonce()
    response = askServer(makeAuthRequest("bob", "bobpw", nonceC, nonceS), 7002)
    check("auth.guest.success", response ~= nil and response.success == true)
    -- The server signs the stored role verbatim ("guest"), not the alias.
    check("auth.guest.real_role", response ~= nil and response.role == "guest")

    nonceC, nonceS = nextNonce(), nextNonce()
    response = askServer(makeAuthRequest("rootuser", "rootpw", nonceC, nonceS), 7003)
    check("auth.root.role", response ~= nil and response.role == "root")

    nonceC, nonceS = nextNonce(), nextNonce()
    response = askServer(makeAuthRequest("charlie", "charliepw", nonceC, nonceS), 7004)
    check("auth.unknown_role.denied", response ~= nil and response.success == false)
    check("auth.unknown_role.no_role", response ~= nil and response.role == nil)

    nonceC, nonceS = nextNonce(), nextNonce()
    response = askServer(makeAuthRequest("norole", "norolepw", nonceC, nonceS), 7005)
    check("auth.missing_role.denied", response ~= nil and response.success == false)
    check("auth.missing_role.no_role", response ~= nil and response.role == nil)

    nonceC, nonceS = nextNonce(), nextNonce()
    response = askServer(makeAuthRequest("alice", "wrongpw", nonceC, nonceS), 7006)
    check("auth.wrong_password.denied", response ~= nil and response.success == false)

    local beforeRequests = countSentMessage("auth_response")
    local old = {
        protocol = "secure_auth_v4",
        type = "auth_request",
    }
    getServer().handleMessage(old, 7007)
    check("auth.v4_ignored", countSentMessage("auth_response") == beforeRequests)
end

---------------------------------------------------------------------------
-- auth_server: open_request actuator
---------------------------------------------------------------------------

local function serverOpenTests()
    getServer()
    clearRedstone()
    local response = askServer(makeOpenRequest("alice", nextNonce()), 7101)
    check("open.operator.granted", response ~= nil and response.ok == true
        and response.reason == "granted", response and response.reason)
    check("open.operator.pulsed_left", countPulses("left", 1) == 1
        and countPulses("left", 0) == 1)
    local nonce = response and response.nonce_c
    local signed = SERVER_ID .. "|" .. tostring(nonce) .. "|true|granted"
    check("open.operator.signature",
        response ~= nil and response.sig == crypto.sign(TERMINAL_ID, signed))

    clearRedstone()
    response = askServer(makeOpenRequest("ada", nextNonce()), 7102)
    check("open.admin.granted", response ~= nil and response.ok == true)
    check("open.admin.pulsed", countPulses("left", 1) == 1)

    clearRedstone()
    response = askServer(makeOpenRequest("rootuser", nextNonce()), 7103)
    check("open.root.granted", response ~= nil and response.ok == true)

    clearRedstone()
    response = askServer(makeOpenRequest("bob", nextNonce()), 7104)
    check("open.guest.denied", response ~= nil and response.ok == false
        and response.reason == "denied")
    check("open.guest.no_pulse", #redstoneCalls == 0)

    clearRedstone()
    response = askServer(makeOpenRequest("dave", nextNonce()), 7105)
    check("open.user.denied", response ~= nil and response.ok == false)
    check("open.user.no_pulse", #redstoneCalls == 0)

    clearRedstone()
    response = askServer(makeOpenRequest("nobody", nextNonce()), 7106)
    check("open.unknown_user.denied", response ~= nil and response.ok == false)

    local before = countSentMessage("open_response")
    local unregistered = makeOpenRequest("alice", nextNonce())
    unregistered.terminal_id = "NO-SUCH-TERMINAL"
    unregistered.sig = string.rep("0", 64)
    getServer().handleMessage(unregistered, 7107)
    check("open.unregistered.silent", countSentMessage("open_response") == before)

    local replay = makeOpenRequest("alice", nextNonce())
    response = askServer(replay, 7108)
    check("open.replay.first", response ~= nil and response.ok == true)
    local afterFirst = countSentMessage("open_response")
    getServer().handleMessage(replay, 7109)
    check("open.replay.silent", countSentMessage("open_response") == afterFirst)
end

---------------------------------------------------------------------------
-- client login against the loopback bus
---------------------------------------------------------------------------

local function useServer()
    bus.handler = getServer().handleMessage
    clearSent()
    clearQueue()
end

local function noServer()
    bus.handler = nil
    clearSent()
    clearQueue()
end

local function loginAs(username, password)
    seedHeartbeat()
    setInputs(username, password)
    local module = dofile("/auth/login.lua")
    return module.login()
end

local function loginRole(username, password)
    useServer()
    local user = loginAs(username, password)
    return user
end

local function clientLoginTests()
    local user = loginRole("alice", "alicepw")
    check("client.operator.login", user ~= nil and user.name == "alice")
    check("client.operator.role_from_server", user ~= nil and user.role == "operator")

    user = loginRole("bob", "bobpw")
    check("client.guest.login", user ~= nil and user.role == "user")

    user = loginRole("charlie", "charliepw")
    check("client.unknown_role.rejected", user == nil)

    user = loginRole("alice", "wrongpw")
    check("client.wrong_password.rejected", user == nil)

    -- The server is answering but claims success with no usable role.
    useServer()
    bus.handler = function(message, replyChannel)
        if message.type ~= "auth_request" then return end
        local signed = SERVER_ID .. "|" .. message.nonce_c .. "|"
            .. message.nonce_s .. "|true|"
        fakeModem.transmit(replyChannel, replyChannel, {
            protocol = "secure_auth_v5",
            type = "auth_response",
            server_id = SERVER_ID,
            terminal_id = TERMINAL_ID,
            nonce_c = message.nonce_c,
            nonce_s = message.nonce_s,
            success = true,
            role = nil,
            message = "OK",
            sig = crypto.sign(TERMINAL_ID, signed),
        })
    end
    user = loginAs("alice", "alicepw")
    check("client.nil_role.rejected", user == nil)

    -- Success with an unknown role must be rejected too.
    useServer()
    bus.handler = function(message, replyChannel)
        if message.type ~= "auth_request" then return end
        local role = "wizard"
        local signed = SERVER_ID .. "|" .. message.nonce_c .. "|"
            .. message.nonce_s .. "|true|" .. role
        fakeModem.transmit(replyChannel, replyChannel, {
            protocol = "secure_auth_v5",
            type = "auth_response",
            server_id = SERVER_ID,
            terminal_id = TERMINAL_ID,
            nonce_c = message.nonce_c,
            nonce_s = message.nonce_s,
            success = true,
            role = role,
            message = "OK",
            sig = crypto.sign(TERMINAL_ID, signed),
        })
    end
    user = loginAs("alice", "alicepw")
    check("client.unknown_role_response.rejected", user == nil)
end

local function offlineLoginTests()
    -- A leftover standalone switch must not change anything any more.
    writeFile("/auth/mode.lua", 'return { mode = "standalone" }')

    noServer()
    local user = loginAs("alice", "alicepw")
    check("offline.login.rejected", user == nil)

    noServer()
    local module = dofile("/auth/login.lua")
    local verified = module.verifyPassword("alice", "alicepw")
    check("offline.verify_password.rejected", verified == false)

    noServer()
    seedHeartbeat()
    user = loginAs("alice", "alicepw")
    check("offline.mode_ignored_when_server_missing", user == nil)

    local refusal = dofile("/auth/login_standalone.lua")
    local called, loginError = pcall(function() refusal.login() end)
    check("offline.standalone_module_refuses", called == false
        and contains(tostring(loginError), "Offline mode is disabled"))

    fs.delete("/auth/mode.lua")
end

---------------------------------------------------------------------------
-- client open_request
---------------------------------------------------------------------------

local function clientOpenTests()
    useServer()
    clearRedstone()
    seedHeartbeat()
    local dispatcher = dofile("/auth/login.lua")
    local ok, reason = dispatcher.requestOpen("alice")
    check("client.open.operator.ok", ok == true)
    check("client.open.operator.reason", reason == "granted", reason)
    check("client.open.operator.redstone_on_server",
        countPulses("left", 1) == 1 and countPulses("left", 0) == 1)

    useServer()
    clearRedstone()
    seedHeartbeat()
    ok, reason, code = dofile("/auth/login.lua").requestOpen("bob")
    check("client.open.guest.denied", ok == false and code == "denied", reason)
    check("client.open.guest.no_pulse", #redstoneCalls == 0)

    noServer()
    seedHeartbeat()
    ok, reason, code = dofile("/auth/login.lua").requestOpen("alice")
    check("client.open.offline.fails", ok == false and code == "timeout")

    useServer()
    bus.handler = function(message, replyChannel)
        if message.type ~= "open_request" then return end
        fakeModem.transmit(replyChannel, replyChannel, {
            protocol = "secure_auth_v5",
            type = "open_response",
            server_id = SERVER_ID,
            terminal_id = TERMINAL_ID,
            nonce_c = message.nonce,
            ok = true,
            reason = "granted",
            sig = string.rep("f", 64),
        })
    end
    seedHeartbeat()
    ok, reason, code = dofile("/auth/login.lua").requestOpen("alice")
    check("client.open.bad_signature.rejected", ok == false and code == "signature")
end

---------------------------------------------------------------------------
-- audit: terminal signing with role -> audit server verification
---------------------------------------------------------------------------

local function findQueuedEvent()
    if not fs.exists("/audit_queue") then return nil, nil end
    local newest, newestSize = nil, -1
    for _, name in ipairs(fs.list("/audit_queue")) do
        if name:sub(-4) == ".evt" then
            local size = fs.getSize("/audit_queue/" .. name) or 0
            if size > newestSize then
                newest, newestSize = name, size
            end
        end
    end
    if not newest then return nil, nil end
    local path = "/audit_queue/" .. newest
    return path, textutils.unserialize(readFile(path))
end

local function auditTests()
    local auditServer = dofile("/system/audit_server.lua")
    local booted = pcall(auditServer.boot)
    check("audit.server.boots", booted)

    local config = source("/auth/audit_config.lua")
    check("audit.config_v5", contains(config, "secure_auth_v5"))

    if fs.exists("/audit_queue") then
        for _, name in ipairs(fs.list("/audit_queue")) do
            fs.delete("/audit_queue/" .. name)
        end
    end

    local terminalAudit = dofile("/system/audit.lua")
    local logged = terminalAudit.log("alice", "operator", "OPEN_VAULT")
    check("audit.client.log_ok", logged == true)

    local path, event = findQueuedEvent()
    check("audit.client.event_queued", path ~= nil and type(event) == "table")
    if type(event) == "table" then
        check("audit.client.role_field", event.role == "operator", event.role)
        local data = TERMINAL_ID .. "|alice|operator|OPEN_VAULT|"
            .. tostring(event.timestamp) .. "|" .. tostring(event.nonce)
        check("audit.client.signature_includes_role",
            crypto.verify(TERMINAL_ID, data, event.sig) == true)

        local accepted = auditServer.handleEvent(2, event)
        check("audit.server.role_event_accepted", accepted == true)
        local logText = source("/logs/seg_0001.log")
        check("audit.server.log_has_role", contains(logText, "ROLE=operator"))

        -- A role-less event (or the old 5-field signature) is rejected.
        local timestamp = tostring(os.epoch("utc"))
        local nonce = "roleless-" .. tostring(os.epoch("utc"))
        local roleless = {
            protocol = "secure_auth_v5",
            type = "audit_event",
            terminal_id = TERMINAL_ID,
            username = "alice",
            action = "OPEN_VAULT",
            timestamp = timestamp,
            nonce = nonce,
            sig = crypto.sign(TERMINAL_ID,
                TERMINAL_ID .. "|alice|OPEN_VAULT|" .. timestamp .. "|" .. nonce),
        }
        local okRoleless = auditServer.handleEvent(2, roleless)
        check("audit.server.role_required", okRoleless == false)

        local nonce2 = "old-sig-" .. tostring(os.epoch("utc"))
        local old = {
            protocol = "secure_auth_v5",
            type = "audit_event",
            terminal_id = TERMINAL_ID,
            username = "alice",
            role = "operator",
            action = "OPEN_VAULT",
            timestamp = timestamp,
            nonce = nonce2,
            sig = crypto.sign(TERMINAL_ID,
                TERMINAL_ID .. "|alice|OPEN_VAULT|" .. timestamp .. "|" .. nonce2),
        }
        check("audit.server.old_signature_rejected",
            auditServer.handleEvent(2, old) == false)
    end
end

---------------------------------------------------------------------------
-- run
---------------------------------------------------------------------------

print("SENTINEL OFFLINE SUITE")
print("Protocol: secure_auth_v5")

ensureDir("/auth")
ensureDir("/system")

staticTests()
rolePolicyTests()
prepareDatabases()
serverAuthTests()
serverOpenTests()
clientLoginTests()
offlineLoginTests()
clientOpenTests()
auditTests()

print("OFFLINE_PASS " .. tostring(pass))
print("OFFLINE_FAIL " .. tostring(fail))
print("OFFLINE_GROUPS 9")
print("OFFLINE_RESULT pass=" .. tostring(pass) .. " fail=" .. tostring(fail))
print("TEST_DONE")
