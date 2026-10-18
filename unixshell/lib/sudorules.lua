-- sudorules.lua - fine-grained sudo policy read from /etc/sudo.conf
--
-- Rule syntax (one rule per line, '#' starts a comment):
--
--   <user> <host>=(<runas>) <command>[, <command>...]
--
-- Examples:
--   guest  ALL=(ALL) /bin/ls
--   guest  ALL=(root) /usr/cmd/*, /bin/cat
--   helper ALL=(ALL) ALL
--
--   * <user>    user the rule applies to
--   * <host>    kept for compatibility; only ALL is meaningful on a single
--               computer and the field is not enforced
--   * <runas>   comma separated target users, or ALL
--   * <command> absolute path of the command (as resolved through PATH) with
--               '*' as wildcard, "ALL", or a bare command name for shell
--               builtins and for anything found in PATH. A command file may be
--               named with or without its ".lua" extension in the rule, so
--               both "/bin/ls" and "/bin/ls.lua" match the same command.
--
-- Lines that do not look like a rule (for example "timeout=300") are ignored,
-- so the file stays compatible with lib/sudocache.lua.
--
-- sudorules.check() is a three state answer used by the sudo builtin:
--   true  - allowed by a rule
--   false - explicitly denied (there are rules for the user, none matches)
--   nil   - no rule for the user at all, the caller falls back to
--           /etc/sudoers membership

local sudorules = {}

local FILE = "/etc/sudo.conf"

local cached = nil

local function strip(text)
    return (text:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function split_list(text)
    local out = {}
    for item in (text or ""):gmatch("[^,]+") do
        item = strip(item)
        if item ~= "" then out[#out + 1] = item end
    end
    return out
end

-- '*' becomes '.*', everything else is matched literally.
local function pattern_to_lua(pattern)
    local escaped = pattern:gsub("([%^%$%(%)%%%.%[%]%+%-%?])", "%%%1")
    escaped = escaped:gsub("%*", ".*")
    return "^" .. escaped .. "$"
end

sudorules.pattern_to_lua = pattern_to_lua

local function parse(text)
    local data = { rules = {}, by_user = {} }
    for line in (text or ""):gmatch("[^\r\n]+") do
        line = strip(line)
        if line ~= "" and line:sub(1, 1) ~= "#" then
            local user, host, runas, commands =
                line:match("^(%S+)%s+(%S+)%s*=%s*%(%s*([^)]*)%s*%)%s*(.+)$")
            if user then
                local rule = {
                    user     = user,
                    host     = host,
                    runas    = split_list(runas),
                    commands = split_list(commands),
                    text     = line,
                }
                if #rule.commands > 0 then
                    table.insert(data.rules, rule)
                    if not data.by_user[user] then data.by_user[user] = {} end
                    table.insert(data.by_user[user], rule)
                end
            end
        end
    end
    return data
end

local function load()
    if cached then return cached end
    cached = { rules = {}, by_user = {} }
    if fs.exists(FILE) then
        local f = fs.open(FILE, "r")
        if f then
            local text = f.readAll()
            f.close()
            cached = parse(text)
        end
    end
    return cached
end

-- Force a re-read of /etc/sudo.conf on the next check.
function sudorules.reload()
    cached = nil
end

function sudorules.rules()
    return load().rules
end

-- Rule text of every rule that applies to a user, for "sudo -l".
function sudorules.for_user(user)
    local list = {}
    for _, rule in ipairs(load().by_user[user] or {}) do
        table.insert(list, rule.text)
    end
    return list
end

local function match_runas(list, target)
    for _, item in ipairs(list) do
        if item == "ALL" or item == target then return true end
        local user = item:match("^([^:]+)")
        if user == "ALL" or user == target then return true end
    end
    return false
end

-- Absolute path of a command, with the trailing ".lua" of the deployed
-- command file removed. Rules are written the way the user sees the command
-- ("/bin/ls", "/usr/cmd/chmod"), so the extension must not get in the way.
local function bare_path(path)
    local stripped = path:gsub("%.lua$", "")
    if stripped ~= path then return stripped end
    return nil
end

local function match_command(pattern, path, name, is_builtin)
    if pattern == "ALL" then return true end
    if pattern:find("/", 1, true) then
        -- Path pattern: shell builtins have no path and cannot match.
        if is_builtin or not path then return false end
        local lua = pattern_to_lua(pattern)
        if path:match(lua) then return true end
        local bare = bare_path(path)
        return bare ~= nil and bare:match(lua) ~= nil
    end
    return name ~= nil and name:match(pattern_to_lua(pattern)) ~= nil
end

-- Check one command against the rules of a user.
-- path may be nil when the command could not be resolved.
function sudorules.check(user, runas, path, name, is_builtin)
    if user == "root" then return true, "root" end

    local rules = load().by_user[user]
    if not rules or #rules == 0 then
        return nil, "no rule for " .. tostring(user) .. " in " .. FILE
    end

    for _, rule in ipairs(rules) do
        if match_runas(rule.runas, runas) then
            for _, pattern in ipairs(rule.commands) do
                if match_command(pattern, path, name, is_builtin) then
                    return true, rule.text
                end
            end
        end
    end
    return false, "command not permitted by " .. FILE
end

return sudorules
