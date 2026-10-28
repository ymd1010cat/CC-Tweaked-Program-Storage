-- netcmds.lua - command line front ends for the data channel
--
-- Three programs share the protocol code in lib/xfer.lua and lib/rexec.lua;
-- this module only parses arguments, drives them and formats the report. The
-- deployed commands (usr/cmd/rget.lua, usr/cmd/rput.lua, usr/cmd/rexec.lua)
-- are thin wrappers around netcmds.main().
--
-- Exit status, as usual for a command: 0 on success, 1 on a failure reported
-- by the peer, 2 for a bad command line and 124 when the peer never answered.

local netcfg = require("netcfg")
local xfer   = require("xfer")
local rexec  = require("rexec")

local netcmds = {}

local function emit(stage, text)
    if stage and stage._out then
        stage._out.write(text)
        stage._out.write("\n")
    else
        print(text)
    end
end

netcmds.emit = emit

local function is_flag(arg)
    return type(arg) == "string" and #arg > 1 and arg:sub(1, 1) == "-"
end

-- Shared parsing helpers: every option below takes one value.
local function take_value(args, i, name)
    local value = args[i + 1]
    if value == nil or is_flag(value) then
        return nil, i, name .. " needs a value"
    end
    return value, i + 1
end

-- ============================================================
-- rput
-- ============================================================

local RPUT_USAGE = {
    "usage: rput -t <id> [-p <path>] [-c <bytes>] [-w <sec>] [-r <n>] [-f] [-q] file...",
    "",
    "  -t, --to <id>        target computer id (or a name from /etc/hosts)",
    "  -p, --path <path>    destination on the peer (a directory when several files are sent)",
    "  -c, --chunk <bytes>  chunk size, 64..32768 (default: from /etc/pkg.conf)",
    "  -w, --timeout <sec>  wait for each acknowledgement (default: from /etc/pkg.conf)",
    "  -r, --retries <n>    retransmissions before giving up",
    "  -f, --force          overwrite a file that already exists on the peer",
    "  -q, --quiet          do not print progress",
    "",
    "The peer must be running netd (or rget --listen) to accept the file.",
    "Transfer is checked twice: per chunk, and again on the whole file.",
}

local function rput_main(args, stage)
    local opt = { quiet = false, force = false }
    local files = {}
    local i = 1
    while i <= #args do
        local a = args[i]
        if a == "-h" or a == "--help" then
            for _, line in ipairs(RPUT_USAGE) do emit(stage, line) end
            return 0
        elseif a == "-t" or a == "--to" or a == "--target" then
            local v; v, i = take_value(args, i, "rput: " .. a)
            if v == nil then emit(stage, "rput: " .. a .. " needs a value") return 2 end
            local id, iderr = netcfg.resolve_target(v)
            if not id then emit(stage, "rput: " .. iderr) return 2 end
            opt.target = id
        elseif a == "-p" or a == "--path" then
            local v; v, i = take_value(args, i, "rput: " .. a)
            if v == nil then emit(stage, "rput: " .. a .. " needs a value") return 2 end
            opt.path = v
        elseif a == "-c" or a == "--chunk" then
            local v; v, i = take_value(args, i, "rput: " .. a)
            if v == nil then emit(stage, "rput: " .. a .. " needs a value") return 2 end
            opt.chunk = tonumber(v)
            if not opt.chunk then emit(stage, "rput: invalid chunk size: " .. v) return 2 end
        elseif a == "-w" or a == "--timeout" then
            local v; v, i = take_value(args, i, "rput: " .. a)
            if v == nil then emit(stage, "rput: " .. a .. " needs a value") return 2 end
            opt.timeout = tonumber(v)
            if not opt.timeout then emit(stage, "rput: invalid timeout: " .. v) return 2 end
        elseif a == "-r" or a == "--retries" then
            local v; v, i = take_value(args, i, "rput: " .. a)
            if v == nil then emit(stage, "rput: " .. a .. " needs a value") return 2 end
            opt.retries = tonumber(v)
            if not opt.retries then emit(stage, "rput: invalid retry count: " .. v) return 2 end
        elseif a == "-f" or a == "--force" then
            opt.force = true
        elseif a == "-q" or a == "--quiet" then
            opt.quiet = true
        elseif is_flag(a) then
            emit(stage, "rput: invalid option: " .. a)
            return 2
        else
            table.insert(files, a)
        end
        i = i + 1
    end

    if opt.target == nil then
        emit(stage, "rput: no target computer given (use -t <id>)")
        return 2
    end
    if #files == 0 then
        emit(stage, "rput: no file to send")
        return 2
    end
    if opt.chunk and (opt.chunk < xfer.MIN_CHUNK or opt.chunk > xfer.MAX_CHUNK) then
        emit(stage, string.format("rput: chunk size out of range (%d..%d)",
            xfer.MIN_CHUNK, xfer.MAX_CHUNK))
        return 2
    end

    local status = 0
    for _, file in ipairs(files) do
        local remote = opt.path
        if remote and #files > 1 then
            remote = remote:gsub("/$", "") .. "/" .. xfer.basename(file)
        end

        local progress
        if not opt.quiet then
            local label = string.format("rput[%s]", xfer.basename(file))
            progress = xfer.make_progress(function(line) emit(stage, line) end, label)
        end

        local ok, info, extra = xfer.send({
            target = opt.target, path = file, remote = remote,
            chunk = opt.chunk, timeout = opt.timeout, retries = opt.retries,
            overwrite = opt.force, progress = progress,
        })
        if ok then
            emit(stage, string.format("%s -> computer %s:%s (%d bytes, %d chunk(s), CRC32 %s)",
                file, tostring(opt.target), tostring(info.remote), info.bytes,
                info.chunks, info.crc))
            if info.resends and info.resends > 0 then
                emit(stage, string.format("rput: %d retransmission(s)", info.resends))
            end
        else
            emit(stage, "rput: " .. tostring(info))
            status = (extra and extra.timeout) and 124 or 1
        end
    end
    return status
end

-- ============================================================
-- rget
-- ============================================================

local RGET_USAGE = {
    "usage: rget -t <id> [-o <local>] [-c <bytes>] [-w <sec>] [-r <n>] [-f] [-q] remote...",
    "       rget --listen [-s <dir>] [--as <path>] [-W <sec>] [-c <bytes>] [-f] [-q]",
    "",
    "  -t, --to <id>        computer to fetch from (id or a name from /etc/hosts)",
    "  -o, --out <path>     local destination (a directory when several files are fetched)",
    "  -c, --chunk <bytes>  chunk size, 64..32768 (default: from /etc/pkg.conf)",
    "  -w, --timeout <sec>  wait for each chunk (default: from /etc/pkg.conf)",
    "  -r, --retries <n>    requests for a missing chunk before giving up",
    "  -f, --force          overwrite an existing local file",
    "  -q, --quiet          do not print progress",
    "",
    "  -l, --listen         wait for one incoming push instead of fetching",
    "  -s, --save <dir>     directory for a pushed file (default: current directory)",
    "      --as <path>      exact local path for a pushed file",
    "  -W, --wait <sec>     how long --listen waits for a request (default 60)",
    "",
    "Every chunk and the assembled file are both checksummed before the file",
    "is written, so a damaged transfer never replaces a good file.",
}

local function rget_listen(opt, stage)
    local progress
    if not opt.quiet then
        progress = xfer.make_progress(function(line) emit(stage, line) end, "rget[listen]")
    end
    emit(stage, string.format("rget: waiting up to %ds for an incoming file",
        opt.wait or 60))
    local ok, info = xfer.listen({
        save_dir = opt.save, as = opt.as_path, wait = opt.wait,
        chunk = opt.chunk, timeout = opt.timeout, overwrite = opt.force,
        progress = progress,
    })
    if not ok then
        emit(stage, "rget: " .. tostring(info))
        return 1
    end
    emit(stage, string.format("received %s from computer %s (%d bytes, %d chunk(s), CRC32 %s)",
        tostring(info.path), tostring(info.sender), info.bytes, info.chunks, info.crc))
    return 0
end

local function rget_main(args, stage)
    local opt = { quiet = false, force = false, listen = false }
    local remotes = {}
    local i = 1
    while i <= #args do
        local a = args[i]
        if a == "-h" or a == "--help" then
            for _, line in ipairs(RGET_USAGE) do emit(stage, line) end
            return 0
        elseif a == "-t" or a == "--to" or a == "--target" then
            local v; v, i = take_value(args, i, "rget: " .. a)
            if v == nil then emit(stage, "rget: " .. a .. " needs a value") return 2 end
            local id, iderr = netcfg.resolve_target(v)
            if not id then emit(stage, "rget: " .. iderr) return 2 end
            opt.target = id
        elseif a == "-o" or a == "--out" then
            local v; v, i = take_value(args, i, "rget: " .. a)
            if v == nil then emit(stage, "rget: " .. a .. " needs a value") return 2 end
            opt.out = v
        elseif a == "-c" or a == "--chunk" then
            local v; v, i = take_value(args, i, "rget: " .. a)
            if v == nil then emit(stage, "rget: " .. a .. " needs a value") return 2 end
            opt.chunk = tonumber(v)
            if not opt.chunk then emit(stage, "rget: invalid chunk size: " .. v) return 2 end
        elseif a == "-w" or a == "--timeout" then
            local v; v, i = take_value(args, i, "rget: " .. a)
            if v == nil then emit(stage, "rget: " .. a .. " needs a value") return 2 end
            opt.timeout = tonumber(v)
            if not opt.timeout then emit(stage, "rget: invalid timeout: " .. v) return 2 end
        elseif a == "-r" or a == "--retries" then
            local v; v, i = take_value(args, i, "rget: " .. a)
            if v == nil then emit(stage, "rget: " .. a .. " needs a value") return 2 end
            opt.retries = tonumber(v)
            if not opt.retries then emit(stage, "rget: invalid retry count: " .. v) return 2 end
        elseif a == "-W" or a == "--wait" then
            local v; v, i = take_value(args, i, "rget: " .. a)
            if v == nil then emit(stage, "rget: " .. a .. " needs a value") return 2 end
            opt.wait = tonumber(v)
            if not opt.wait then emit(stage, "rget: invalid wait time: " .. v) return 2 end
        elseif a == "-s" or a == "--save" then
            local v; v, i = take_value(args, i, "rget: " .. a)
            if v == nil then emit(stage, "rget: " .. a .. " needs a value") return 2 end
            opt.save = v
        elseif a == "--as" then
            local v; v, i = take_value(args, i, "rget: --as")
            if v == nil then emit(stage, "rget: --as needs a value") return 2 end
            opt.as_path = v
        elseif a == "-l" or a == "--listen" then
            opt.listen = true
        elseif a == "-f" or a == "--force" then
            opt.force = true
        elseif a == "-q" or a == "--quiet" then
            opt.quiet = true
        elseif is_flag(a) then
            emit(stage, "rget: invalid option: " .. a)
            return 2
        else
            table.insert(remotes, a)
        end
        i = i + 1
    end

    if opt.chunk and (opt.chunk < xfer.MIN_CHUNK or opt.chunk > xfer.MAX_CHUNK) then
        emit(stage, string.format("rget: chunk size out of range (%d..%d)",
            xfer.MIN_CHUNK, xfer.MAX_CHUNK))
        return 2
    end

    if opt.listen then
        if #remotes > 0 then
            emit(stage, "rget: --listen takes no remote path")
            return 2
        end
        return rget_listen(opt, stage)
    end

    if opt.target == nil then
        emit(stage, "rget: no target computer given (use -t <id>)")
        return 2
    end
    if #remotes == 0 then
        emit(stage, "rget: no remote path given")
        return 2
    end

    local status = 0
    for _, remote in ipairs(remotes) do
        local dest = opt.out
        if dest and #remotes > 1 then
            dest = dest:gsub("/$", "") .. "/" .. xfer.basename(remote)
        end

        local progress
        if not opt.quiet then
            local label = string.format("rget[%s]", xfer.basename(remote))
            progress = xfer.make_progress(function(line) emit(stage, line) end, label)
        end

        local ok, info, extra = xfer.pull({
            target = opt.target, remote = remote, path = dest,
            chunk = opt.chunk, timeout = opt.timeout, retries = opt.retries,
            overwrite = opt.force, progress = progress,
        })
        if ok then
            emit(stage, string.format("computer %s:%s -> %s (%d bytes, %d chunk(s), CRC32 %s)",
                tostring(opt.target), remote, tostring(info.path),
                info.bytes, info.chunks, info.crc))
            if info.resends and info.resends > 0 then
                emit(stage, string.format("rget: %d chunk request(s)", info.resends))
            end
        else
            emit(stage, "rget: " .. tostring(info))
            status = (extra and extra.timeout) and 124 or 1
        end
    end
    return status
end

-- ============================================================
-- rexec
-- ============================================================

local REXEC_USAGE = {
    "usage: rexec -t <id> [-w <sec>] [-T <sec>] command...",
    "",
    "  -t, --to <id>        computer to run the command on",
    "  -w, --timeout <sec>  how long to wait for the answer (default 30)",
    "  -T, --budget <sec>   expected duration, reported when exceeded (default 60)",
    "  -n, --no-output      do not print the command output",
    "  -q, --quiet          print only the exit code line",
    "  -h, --help           show this message",
    "",
    "The command runs in a shell on the peer; stdout, stderr and the exit code",
    "come back together. Exit status 124 means the peer did not answer in time.",
}

local function rexec_main(args, stage)
    local opt = { timeout = rexec.DEFAULT_WAIT, budget = rexec.DEFAULT_BUDGET }
    local words = {}
    local i = 1
    while i <= #args do
        local a = args[i]
        if a == "-h" or a == "--help" then
            for _, line in ipairs(REXEC_USAGE) do emit(stage, line) end
            return 0
        elseif a == "-t" or a == "--to" or a == "--target" then
            local v; v, i = take_value(args, i, "rexec: " .. a)
            if v == nil then emit(stage, "rexec: " .. a .. " needs a value") return 2 end
            local id, iderr = netcfg.resolve_target(v)
            if not id then emit(stage, "rexec: " .. iderr) return 2 end
            opt.target = id
        elseif a == "-w" or a == "--timeout" then
            local v; v, i = take_value(args, i, "rexec: " .. a)
            if v == nil then emit(stage, "rexec: " .. a .. " needs a value") return 2 end
            opt.timeout = tonumber(v)
            if not opt.timeout then emit(stage, "rexec: invalid timeout: " .. v) return 2 end
        elseif a == "-T" or a == "--budget" then
            local v; v, i = take_value(args, i, "rexec: " .. a)
            if v == nil then emit(stage, "rexec: " .. a .. " needs a value") return 2 end
            opt.budget = tonumber(v)
            if not opt.budget then emit(stage, "rexec: invalid budget: " .. v) return 2 end
        elseif a == "-n" or a == "--no-output" then
            opt.no_output = true
        elseif a == "-q" or a == "--quiet" then
            opt.quiet = true
        elseif is_flag(a) and #words == 0 then
            emit(stage, "rexec: invalid option: " .. a)
            return 2
        else
            table.insert(words, a)
        end
        i = i + 1
    end

    if opt.target == nil then
        emit(stage, "rexec: no target computer given (use -t <id>)")
        return 2
    end
    if #words == 0 then
        emit(stage, "rexec: no command given")
        return 2
    end

    local command = table.concat(words, " ")
    local ok, info, extra = rexec.run({
        target = opt.target, command = command,
        timeout = opt.timeout, budget = opt.budget,
    })
    if not ok then
        emit(stage, "rexec: " .. tostring(info))
        if extra and extra.timeout then return 124 end
        return 1
    end

    if not opt.no_output then
        if info.stdout ~= "" then
            if stage and stage._out then
                stage._out.write(info.stdout)
                if info.stdout:sub(-1) ~= "\n" then stage._out.write("\n") end
            else
                print(info.stdout)
            end
        end
        if info.stderr ~= "" then
            emit(stage, info.stderr)
        end
        if info.truncated then
            emit(stage, "rexec: output was truncated (limit " ..
                tostring(netcfg.max_output()) .. " bytes)")
        end
        if info.note then
            emit(stage, "rexec: " .. info.note)
        end
    end

    if not opt.quiet then
        emit(stage, string.format("rexec: exit %d in %.2fs on computer %s",
            info.code, info.elapsed, tostring(opt.target)))
    end
    return info.code
end

-- ============================================================
-- Dispatch
-- ============================================================

-- opts.title: "rget", "rput" or "rexec"
function netcmds.main(args, stage, opts)
    opts = opts or {}
    local title = opts.title or "rget"
    if title == "rput" then return rput_main(args or {}, stage) end
    if title == "rexec" then return rexec_main(args or {}, stage) end
    return rget_main(args or {}, stage)
end

netcmds.rget = rget_main
netcmds.rput = rput_main
netcmds.rexec = rexec_main

return netcmds
