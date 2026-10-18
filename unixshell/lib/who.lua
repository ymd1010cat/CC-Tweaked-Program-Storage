-- who.lua - shared report code for the 'who' and 'w' external commands
--
-- usr/cmd/who.lua and usr/cmd/w.lua both load this module; "w" only adds an
-- uptime header line above the same table. The data comes from
-- lib/sessionlog.lua, which keeps one live session record per console in
-- /var/lib/sessions.

local who = {}

local sessionlog = require("sessionlog")

local USAGE = "usage: who [-H] [-q] [am i]"

local function emit(stage, text)
    if stage and stage._out then
        stage._out.write(text)
        stage._out.write("\n")
    else
        print(text)
    end
end

-- Format a Unix timestamp with the timezone configured in /etc/timezone.conf.
local function fmt_epoch(epoch)
    local ok, tz = pcall(require, "time")
    if ok and tz and tz.get_offset then
        local offset = tz.get_offset() or 0
        local label = tz.get_label and tz.get_label() or ""
        local text = os.date("%Y-%m-%d %H:%M:%S", math.floor(epoch + offset * 3600))
        if label ~= "" then return text .. " " .. label end
        return text
    end
    return os.date("%Y-%m-%d %H:%M:%S", math.floor(epoch))
end

who.fmt_epoch = fmt_epoch

local function parse_args(args)
    local opt = { header = false, quiet = false, am_i = false }
    local words = {}
    for _, a in ipairs(args) do
        if a == "-H" then opt.header = true
        elseif a == "-q" or a == "--count" then opt.quiet = true
        elseif a:sub(1, 1) == "-" then
            return nil, "invalid option: " .. a
        else
            table.insert(words, a)
        end
    end
    if #words >= 2 and words[1] == "am" and (words[2] == "i" or words[2] == "I") then
        opt.am_i = true
    elseif #words > 0 then
        return nil, "extra operand: " .. words[1]
    end
    return opt
end

-- opts.title: "who" (default) or "w"
function who.main(args, stage, opts)
    opts = opts or {}
    local opt, err = parse_args(args)
    if not opt then
        emit(stage, "who: " .. tostring(err))
        emit(stage, USAGE)
        return
    end

    local sessions
    if opt.am_i then
        local rec = sessionlog.current()
        sessions = rec and { rec } or {}
    else
        sessions = sessionlog.online()
    end

    if opts.title == "w" then
        -- Uptime line, the same fields are printed by the uptime builtin.
        local now = os.date("%H:%M:%S")
        emit(stage, string.format("%s up %d seconds, %d user(s), load average: n/a",
            now, math.floor(os.clock()), #sessions))
        emit(stage, string.format("%-8s %-8s %-19s %-6s %s",
            "USER", "TTY", "LOGIN", "IDLE", "WHAT"))
        for _, rec in ipairs(sessions) do
            emit(stage, string.format("%-8s %-8s %-19s %-6s %s",
                rec.user, rec.tty, fmt_epoch(rec.since or 0), "-", rec.note or "-"))
        end
        return
    end

    if opt.quiet then
        if #sessions == 0 then return end
        local names = {}
        for _, rec in ipairs(sessions) do names[#names + 1] = rec.user end
        emit(stage, table.concat(names, " "))
        emit(stage, "# users=" .. tostring(#sessions))
        return
    end

    if opt.am_i and #sessions == 0 then
        emit(stage, "who: no session record for " .. sessionlog.tty())
        return
    end

    if opt.header then
        emit(stage, string.format("%-8s %-8s %s", "USER", "TTY", "LOGIN"))
    end
    for _, rec in ipairs(sessions) do
        emit(stage, string.format("%-8s %-8s %s",
            rec.user, rec.tty, fmt_epoch(rec.since or 0)))
    end
end

return who
