-- netd.lua - data channel daemon: file transfer and remote execution server
--
-- Run this on a computer that should accept pushes (rput), serve pulls (rget)
-- and answer rexec requests. It speaks the same protocol name and the same
-- shared key as the package manager, both read from /etc/pkg.conf.
--
--   netd                       listen, store pushes in /var/net/incoming
--   netd --save /home/me       store pushes elsewhere
--   netd --allow ls,cat,df     only those commands may be run by rexec
--   netd --allow none          refuse every rexec request
--   netd --once                handle a single request and exit
--
-- Every served request is written to the audit log (/var/log/auth.log).

local netcfg = require("netcfg")
local rpvnet  = require("rpvnet")
local xfer   = require("xfer")
local rexec  = require("rexec")

local DEFAULT_SAVE = "/var/net/incoming"

local USAGE = {
    "usage: netd [options]",
    "  -s, --save <dir>      directory for incoming files (/var/net/incoming)",
    "  -a, --allow <list>    commands rexec may run: all, none, or a comma list",
    "  -r, --root <dir>      writes must stay inside this directory (the save dir)",
    "  -f, --force           allow overwriting a file that already exists",
    "  -t, --timeout <sec>   per message timeout",
    "  -T, --budget <sec>    time budget reported for a rexec command",
    "  -o, --once            handle one request and exit",
    "  -q, --quiet           only report errors",
    "  -h, --help            show this message",
}

local function parse_args(argv)
    local opts = {
        save = DEFAULT_SAVE,
        allow = "all",
        timeout = nil,
        budget = rexec.DEFAULT_BUDGET,
        once = false,
        quiet = false,
    }
    local i = 1
    while i <= #argv do
        local a = argv[i]
        if a == "-h" or a == "--help" then
            opts.help = true
        elseif a == "-s" or a == "--save" then
            opts.save = argv[i + 1]; i = i + 1
        elseif a == "-a" or a == "--allow" then
            opts.allow = rexec.parse_allow(argv[i + 1]); i = i + 1
        elseif a == "-r" or a == "--root" then
            opts.root = argv[i + 1]; i = i + 1
        elseif a == "-f" or a == "--force" then
            opts.overwrite = true
        elseif a == "-t" or a == "--timeout" then
            opts.timeout = tonumber(argv[i + 1]); i = i + 1
        elseif a == "-T" or a == "--budget" then
            opts.budget = tonumber(argv[i + 1]); i = i + 1
        elseif a == "-o" or a == "--once" then
            opts.once = true
        elseif a == "-q" or a == "--quiet" then
            opts.quiet = true
        else
            return nil, "netd: unknown option " .. tostring(a)
        end
        i = i + 1
    end
    if opts.save == nil or opts.save == "" then return nil, "netd: --save needs a directory" end
    -- A push may only be written inside the root directory, which defaults to
    -- the directory incoming files are stored in: a daemon never writes outside
    -- what it was told to manage. "--root /" opts back into the permissive
    -- behaviour of an early build.
    if opts.root == nil or opts.root == "" then opts.root = opts.save end
    return opts
end

local function describe_policy(allow)
    if allow == "all" then return "all commands" end
    if allow == "none" then return "none (rexec disabled)" end
    return table.concat(allow, ",")
end

local function handle(opts, sender, blob)
    local msg = netcfg.unpack(blob)
    if not msg then
        if not opts.quiet then
            print(string.format("netd: ignored a message from %s that did not decrypt",
                tostring(sender)))
        end
        return
    end

    if msg.action == xfer.ACTION then
        local serve_opts = {
            save_dir = opts.save,
            root = opts.root,
            overwrite = opts.overwrite,
            timeout = opts.timeout,
            budget = opts.budget,
            report = function(line) if not opts.quiet then print("netd: " .. line) end end,
        }
        local ok, info = xfer.serve(sender, msg, serve_opts)
        if not opts.quiet then
            if ok then
                print(string.format("netd: %s %s (%d bytes, %d chunk(s)) for %s",
                    info.direction == "put" and "stored" or "sent", tostring(info.path),
                    info.bytes or 0, info.chunks or 0, tostring(sender)))
            else
                print(string.format("netd: transfer with %s failed: %s",
                    tostring(sender), tostring(info)))
            end
        end
        -- A requester that asked while this transfer was running was queued rather than
        -- dropped; serve it now, before going back to waiting for the next message.
        local queued = xfer.serve_pending(serve_opts)
        if queued > 0 and not opts.quiet then
            print(string.format("netd: served %d request(s) that arrived during the transfer",
                queued))
        end
    elseif msg.action == rexec.ACTION then
        local ok, info = rexec.serve(sender, msg, {
            allow = opts.allow,
            budget = opts.budget,
            max_output = opts.max_output,
        })
        if not opts.quiet then
            if ok then
                print(string.format("netd: ran for %s (exit %s): %s",
                    tostring(sender), tostring(info.code), tostring(msg.command)))
            else
                print(string.format("netd: refused a command for %s: %s",
                    tostring(sender), tostring(info)))
            end
        end
    elseif not opts.quiet then
        print(string.format("netd: ignored an unsupported request from %s", tostring(sender)))
    end
end

local function main(argv)
    local opts, err = parse_args(argv)
    if not opts then
        print(err)
        return 1
    end
    if opts.help then
        for _, line in ipairs(USAGE) do print(line) end
        return 0
    end

    local opened, oerr = netcfg.open()
    if not opened then
        print("netd: " .. tostring(oerr))
        return 1
    end

    if not fs.exists(opts.save) then fs.makeDir(opts.save) end

    local channel = netcfg.channel()
    print(string.format("netd: computer %d listening on protocol '%s' (save: %s)",
        os.getComputerID(), channel, opts.save))
    print("netd: rexec policy: " .. describe_policy(opts.allow))

    while true do
        local sender, blob = rpvnet.receive(channel)
        if sender ~= nil then
            handle(opts, sender, blob)
            if opts.once then return 0 end
        end
    end
end

local argv = { }
if type(arg) == "table" then
    for index = 1, #arg do argv[index] = arg[index] end
end

return main(argv)
