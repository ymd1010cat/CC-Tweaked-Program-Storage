--[[- recovery/bootstrap.lua -- push receiver for a file set (EDL alternative).

The publisher sends one META packet and then the chunks; this receiver needs no
request channel, which is why it stays small enough to retype onto a bricked
machine. Same transaction as recovery/flash.lua because it reuses
recovery/proto.lua: stage -> prove -> apply, and a failed run leaves the old
system untouched.

    PYROET-FLASH/2 PUSH meta version=.. manifest_sha=.. files=..
    <relpath> <size> <sha256>                     (one per file)
    PYROET-FLASH/2 PUSH DATA <relpath> idx=<i> sha256=<64 hex> <hex payload>

Chunks may arrive in any order: the provider waits for the window it needs and
buffers the rest. A chunk with a wrong window is kept (the publisher may resend
it later); a chunk with a wrong digest or size is dropped and counts as a miss,
so a publisher retransmission is picked up instead of failing the file.

    BOOTSTRAP_OK files=.. written=.. skipped=.. bytes=.. version=.. manifest_sha=.. journal=..
    BOOTSTRAP_FAIL stage=<prepare|meta|stage|backup|apply> err=..

No rpv, no slot: only the ROM globals (fs/term/os/rednet), target is always
<root>/system. No non-ASCII bytes in this file.
]]

local P = dofile("/recovery/proto.lua")
local M = {}

function M.recv(net, protocol, timeout)
    local ok, sender, msg = pcall(net.receive, protocol, timeout)
    if not ok then return nil, "receive" end
    if sender == nil then return nil, "timeout" end
    return { sender = sender, msg = msg }
end

function M.main(opts)
    local o = opts or {}
    local fs = o.fs or rawget(_G, "fs")
    local out = o.print or print
    local function fail(stage, err) return P.fail(out, "BOOTSTRAP", stage, err) end
    if type(fs) ~= "table" then return fail("prepare", "fs") end
    local net = o.rednet or rawget(_G, "rednet")
    if type(net) ~= "table" or type(net.receive) ~= "function" then
        return fail("prepare", "rednet")
    end
    local sha = o.sha or P.sha(o)
    if type(sha) ~= "function" then return fail("prepare", "sha256") end
    local protocol = o.protocol or P.PROTOCOL
    local tries = o.max_tries or P.MAX_TRIES
    local timeout = o.timeout or P.TIMEOUT
    local root = o.root or ""

    local target, twhy, tpath = P.target(fs, root)
    out("BOOTSTRAP_TARGET path=" .. tostring(tpath) .. " state="
        .. tostring(target and "present" or twhy))

    local meta, why_parse, why_recv
    for _ = 1, tries do
        local packet, perr = M.recv(net, protocol, timeout)
        if packet then
            local parsed, why = P.meta(packet.msg, sha)
            if parsed then
                meta = parsed
                break
            end
            why_parse = why
        else
            why_recv = perr
        end
    end
    -- a META that arrived but did not parse says more than the timeouts after it
    if not meta then return fail("meta", why_parse or why_recv or "timeout") end
    out("BOOTSTRAP_META version=" .. meta.version .. " files=" .. tostring(#meta.files)
        .. " manifest_sha=" .. meta.manifest_sha)

    local buffer = {}
    local function take(relpath, index)
        for i = 1, #buffer do
            local chunk = buffer[i]
            if chunk.relpath == relpath and chunk.idx == index then
                table.remove(buffer, i)
                return chunk
            end
        end
        return nil
    end

    local function provider(relpath, offset, want)
        local index = math.floor(offset / P.MAX_DATA)
        local misses, err = 0, "timeout"
        while misses < tries do
            local chunk = take(relpath, index)
            if chunk then
                if #chunk.data ~= want then
                    misses, err = misses + 1, "size"
                elseif not P.check(sha, chunk.data, chunk.sha256) then
                    misses, err = misses + 1, "digest"
                else
                    return chunk.data
                end
            else
                local packet, perr = M.recv(net, protocol, timeout)
                if not packet then
                    misses, err = misses + 1, perr or "timeout"
                else
                    local data = P.data(packet.msg)
                    -- a re-sent META or a foreign packet is simply not a chunk
                    if data then buffer[#buffer + 1] = data end
                end
            end
        end
        return nil, err
    end

    local r1, r2, r3 = P.write_file_set(fs, root, meta, provider, sha, o)
    if not r1 then return fail(r2, r3) end
    local stats = r2
    out("BOOTSTRAP_OK files=" .. tostring(stats.files) .. " written=" .. tostring(stats.written)
        .. " skipped=" .. tostring(stats.skipped) .. " bytes=" .. tostring(stats.bytes)
        .. " version=" .. tostring(stats.version)
        .. " manifest_sha=" .. tostring(stats.manifest_sha)
        .. " journal=" .. tostring(stats.journal or "none"))
    return true
end

local direct = (select("#", ...) > 0) or (type(arg) == "table" and arg[0] ~= nil)
if direct and not rawget(_G, "PYROET_BOOTSTRAP_TEST") then M.main() end
return M
