--[[- recovery/flash.lua -- EDL-style reflash of the single /system tree. ASCII.

Pulls a complete file set from a floppy image or over rednet, hands it to
recovery/proto.lua (stage -> prove -> apply) and reports one line per decision.

Floppy image, laid out by relpath under one directory:

    meta.txt      version=<tok> manifest_sha=<64 hex> files=<n>, then one
                  `<relpath> <size> <sha256>` line per file -- the same text a
                  rednet publisher sends, just without the packet prefix
    <relpath>     the file itself

    flash --disk=/disk/firmware          from the floppy
    flash --host=12                      over rednet (protocol pyroet-flash)

No rpv and no slot: only the ROM globals (fs/term/os/rednet), and the target is
always <root>/system -- a machine whose /system is missing is exactly what this
tool is for. A failed run leaves the old system untouched (staging and proving
happen before anything is replaced) and a run interrupted in the apply phase
undoes itself by hash. Re-running the same set is a no-op: a file already at the
wanted sha256 is skipped.

On success the set is described to boot.lua as an `applied` update journal, so
the freshly flashed image is trial-booted and falls back to /update.backup if it
never reaches its first frame.

    FLASH_OK files=.. written=.. skipped=.. bytes=.. version=.. manifest_sha=.. journal=..
    FLASH_FAIL stage=<prepare|source|meta|stage|backup|apply> err=..

No non-ASCII bytes in this file.
]]

local P = dofile("/recovery/proto.lua")
local M = {}

function M.args(argv)
    local o, i = {}, 1
    local list = argv or {}
    while i <= #list do
        local w = tostring(list[i])
        local k, v = w:match("^%-%-([%w%-]+)=(.*)$")
        if k then
            o[k] = v
            i = i + 1
        elseif w:match("^%-%-[%w%-]+$") then
            o[w:sub(3)] = list[i + 1]
            i = i + 2
        else
            i = i + 1
        end
    end
    return o
end

-- meta.txt is a META body, so wrapping it gives the exact packet the rednet
-- source sends and one parser covers both sources
function M.disk(fs, dir, sha)
    local text = P.read(fs, dir .. "/meta.txt")
    if text == nil then return nil, "meta" end
    text = text:gsub("^%s+", "")
    local meta, merr = P.meta(P.PREFIX .. " META " .. text, sha)
    if not meta then return nil, merr end
    local function provider(relpath, offset, want)
        local body = P.read(fs, dir .. "/" .. relpath)
        if body == nil then return nil, "missing" end
        return body:sub(offset + 1, offset + want)
    end
    return meta, nil, provider
end

-- one chunk over rednet: GET <relpath> <index> -> DATA <relpath> idx=<index> ..
function M.request(net, host, relpath, offset, want, sha, opts)
    local index = math.floor(offset / P.MAX_DATA)
    return P.fetch(net, host,
        function() return P.PREFIX .. " GET " .. relpath .. " " .. tostring(index) end,
        function(msg)
            local chunk, derr = P.data(msg)
            if not chunk then return nil, derr end
            if chunk.relpath ~= relpath then return nil, "relpath" end
            if chunk.idx ~= index then return nil, "idx" end
            if #chunk.data ~= want then return nil, "size" end
            if not P.check(sha, chunk.data, chunk.sha256) then return nil, "digest" end
            return chunk.data
        end, opts)
end

function M.main(argv, opts)
    local o = opts or {}
    local fs = o.fs or rawget(_G, "fs")
    local out = o.print or print
    local a = M.args(argv or {})
    if type(fs) ~= "table" then return P.fail(out, "FLASH", "prepare", "fs") end
    local sha = o.sha or P.sha(o)
    if type(sha) ~= "function" then return P.fail(out, "FLASH", "prepare", "sha256") end

    local root = o.root or ""
    local target, twhy, tpath = P.target(fs, root)
    out("FLASH_TARGET path=" .. tostring(tpath) .. " state="
        .. tostring(target and "present" or twhy))

    local dir = o.disk or a.disk or "/disk/firmware"
    local meta, provider, merr
    if fs.exists(dir .. "/meta.txt") then
        out("FLASH_SOURCE kind=disk path=" .. tostring(dir))
        meta, merr, provider = M.disk(fs, dir, sha)
    else
        local host = tonumber(a.host or o.host)
        if not host then return P.fail(out, "FLASH", "source", "host") end
        local net = o.rednet or rawget(_G, "rednet")
        out("FLASH_SOURCE kind=rednet host=" .. tostring(host))
        meta, merr = P.fetch(net, host,
            function() return P.PREFIX .. " GET meta" end,
            function(msg) return P.meta(msg, sha) end, o)
        provider = function(relpath, offset, want)
            return M.request(net, host, relpath, offset, want, sha, o)
        end
    end
    if not meta then return P.fail(out, "FLASH", "meta", merr) end
    out("FLASH_META version=" .. meta.version .. " files=" .. tostring(#meta.files)
        .. " manifest_sha=" .. meta.manifest_sha)

    local r1, r2, r3 = P.write_file_set(fs, root, meta, provider, sha, o)
    if not r1 then return P.fail(out, "FLASH", r2, r3) end
    local stats = r2
    out("FLASH_OK files=" .. tostring(stats.files) .. " written=" .. tostring(stats.written)
        .. " skipped=" .. tostring(stats.skipped) .. " bytes=" .. tostring(stats.bytes)
        .. " version=" .. tostring(stats.version)
        .. " manifest_sha=" .. tostring(stats.manifest_sha)
        .. " journal=" .. tostring(stats.journal or "none"))
    return true
end

local argv = { ... }
if (select("#", ...) > 0) or (type(arg) == "table" and arg[0] ~= nil) then
    M.main(type(arg) == "table" and #arg > 0 and arg or argv)
end
return M
