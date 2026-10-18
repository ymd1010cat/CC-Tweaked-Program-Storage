-- pkgserver.lua - encrypted package repository server

-- ------------------------------------------------------------------
-- Module search paths: /lib/?.lua and /usr/?.lua so that
-- require("perm"), require("cwd"), ... resolve on CC:Tweaked.
-- ------------------------------------------------------------------
local EXTRA_PATHS = { "/lib/?.lua", "/usr/?.lua" }
for _, entry in ipairs(EXTRA_PATHS) do
    if not package.path:find(entry, 1, true) then
        package.path = entry .. ";" .. package.path
    end
end

local crypto = require("crypto")
local rpvnet  = require("rpvnet")
local checksum = require("checksum")

-- Channel, key, modem side and repository directory. /etc/pkg.conf, read
-- through lib/netcfg.lua, wins whenever it is present, so the server speaks
-- exactly the transport the clients use; the table below is the fallback of a
-- repository that runs without a configuration file.
local FALLBACK = {
    channel = "pkg-repo",
    key = "mysecretpassword",
    repo_dir = "/repo",
    modem = "back",
}

local CONFIG = {
    channel = FALLBACK.channel,
    key = FALLBACK.key,
    repo_dir = FALLBACK.repo_dir,
    modem = FALLBACK.modem,
}

local netcfg = nil
do
    local loaded, module = pcall(require, "netcfg")
    if loaded and module then
        netcfg = module
        CONFIG.channel = netcfg.channel()
        CONFIG.key = netcfg.key() or CONFIG.key
        CONFIG.repo_dir = netcfg.get("repo_dir", FALLBACK.repo_dir)
        CONFIG.modem = netcfg.modem()
    end
end

-- Wrap and unwrap a message the way the clients do: through netcfg when it is
-- there (same key and same format), through lib/crypto.lua directly otherwise.
local function pack(message)
    if netcfg then return netcfg.pack(message) end
    return crypto.encrypt(CONFIG.key, textutils.serialize(message))
end

local function unpack(blob)
    if netcfg then return netcfg.unpack(blob) end
    local plain = crypto.decrypt(CONFIG.key, blob)
    if plain then return textutils.unserialize(plain) end
    return nil
end

-- Version a package publishes. The manifest in the repository directory is the
-- same file the client installs, so "version=1.2.0" there is what the index
-- reports and what "pkg upgrade" compares: a repository that bumps the
-- manifest needs no other bookkeeping. A package without a manifest, or with
-- no version line, falls back to the old "1.0".
local function manifest_version(dir)
    local path = dir .. "/manifest"
    if fs.exists(path) then
        local f = fs.open(path, "r")
        if f then
            while true do
                local line = f.readLine()
                if line == nil then break end
                local value = line:match("^%s*version%s*=%s*(.-)%s*$")
                if value and value ~= "" then
                    f.close()
                    return value
                end
            end
            f.close()
        end
    end
    return "1.0"
end

local function list_packages()
    local idx = {}
    if not fs.exists(CONFIG.repo_dir) then return idx end
    for _, name in ipairs(fs.list(CONFIG.repo_dir)) do
        local dir = CONFIG.repo_dir .. "/" .. name
        if fs.isDir(dir) then
            table.insert(idx, { name = name, version = manifest_version(dir) })
        end
    end
    return idx
end

-- Read a package out of the repository directory into a "path -> content"
-- table. Subdirectories are walked: a package that installs commands publishes
-- them under bin/, and a flat listing would silently drop every command of the
-- installed package.
local function collect_files(root, prefix, files)
    for _, fname in ipairs(fs.list(root)) do
        local full = root .. "/" .. fname
        local rel = prefix and (prefix .. "/" .. fname) or fname
        if fs.isDir(full) then
            collect_files(full, rel, files)
        else
            local f = fs.open(full, "r")
            if f then
                files[rel] = f.readAll()
                f.close()
            end
        end
    end
    return files
end

local function fetch_package(name)
    local dir = CONFIG.repo_dir .. "/" .. name
    if not fs.exists(dir) then
        return { ok = false, error = "package not found" }
    end
    local files = collect_files(dir, nil, {})

    -- What the client checks before it writes a single byte: a SHA-256 per
    -- file, and the canonical digest of the whole file set as the signature.
    -- Both sides compute those with lib/checksum.lua, so a package altered on
    -- the wire or in the repository is refused instead of installed, and a
    -- client with pkg_sig_required=1 accepts this repository.
    local sums = {}
    for fname, body in pairs(files) do
        sums[fname] = checksum.sha256(body)
    end

    return {
        ok = true, files = files,
        checksums = sums, sig = checksum.files_digest(files),
    }
end

rpvnet.open(CONFIG.modem)
print("pkg-server on channel '" .. CONFIG.channel .. "' serving " .. CONFIG.repo_dir)

while true do
    local sender, message = rpvnet.receive(CONFIG.channel)
    if sender and message then
        local req = unpack(message)
        if req then
            local reply
            if req.action == "list" then reply = list_packages()
            elseif req.action == "fetch" then reply = fetch_package(req.name)
            else reply = { ok = false, error = "unknown action" } end

            -- Echo the request id, so the client can match this answer to the
            -- request that asked for it and ignore anything an earlier command
            -- left on the channel. A request without an id (an older client) is
            -- answered exactly as before: the field is simply absent from the reply.
            if req.id ~= nil and type(reply) == "table" then reply.id = req.id end

            local blob = pack(reply)
            if blob then rpvnet.send(sender, blob, CONFIG.channel) end
        end
    end
end
