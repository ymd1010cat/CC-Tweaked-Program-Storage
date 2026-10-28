-- lib/danger.lua - the destructive-command blacklist.
--
-- WHY A BLACKLIST AND NOT MORE PERMISSIONS. The permission model already refuses a
-- non-root writer, and osguard refuses a program; neither of those stops ROOT from
-- typing `sudo rm -rf /` (or `rm -rf /*`), which does not fail, does not ask, and
-- takes the machine's own system with it. This is the one class of command the
-- machine will not run even as root: a recursive remove whose target is the
-- filesystem root or a system directory.
--
-- WHAT IT IS NOT. It is not a sandbox: a program that calls fs.delete itself is
-- osguard's subject, and a command that destroys through another tool (`cat /dev/`
-- style tricks, a script that loops) is not caught here. It is a guard against the
-- one typo/one copy-paste that cannot be undone, and the message says so.
local danger = {}

local SYSTEM = {
    "/usr", "/lib", "/etc", "/bin", "/sbin", "/opt", "/rom",
    "/startup.lua", "/firstboot.lua",
}

local function is_system(path)
    if type(path) ~= "string" or path == "" then return false end
    if path:sub(1, 1) ~= "/" then path = "/" .. path end
    for _, root in ipairs(SYSTEM) do
        if path == root or path:sub(1, #root + 1) == root .. "/" then return true end
    end
    return false
end
danger.is_system = is_system

-- Does this token contain a wildcard that would expand over a whole directory?
local function wildcard_target(path)
    local text = tostring(path)
    -- A token without a wildcard in it is not a wildcard target. This used to
    -- strip "*" from EVERY token and then ask whether what was left is a system
    -- directory, so a plain "rm -rf /usr" was refused through the wildcard
    -- branch and the "on the system directory" reason below was unreachable --
    -- the operator was told about a wildcard they never typed. Only a token that
    -- really carries "*" or "?" is judged here; a system directory is named by
    -- is_system() a few lines further down.
    if not text:find("[*?]") then return nil end
    local base = text:gsub("%*", ""):gsub("?$", "")
    if base == "/" or base == "" then return "/" end
    if is_system(base) then return base end
    return nil
end

-- check(words) -- words is the argv of the command about to run. Answers a reason
-- string when the command is refused, nil when it is allowed. `sudo` and `su -c`
-- are looked through, because `sudo rm -rf /` is exactly the command this is for.
function danger.check(words)
    if type(words) ~= "table" then return nil end
    local start = nil
    for i = 1, #words do
        if tostring(words[i]) == "rm" then start = i break end
    end
    if not start then return nil end
    local recursive, targets = false, {}
    for i = start + 1, #words do
        local a = tostring(words[i])
        if a == "--" then
            -- end of options
        elseif a:sub(1, 1) == "-" then
            if a:find("r", 1, true) or a:find("R", 1, true) then recursive = true end
        else
            targets[#targets + 1] = a
        end
    end
    if not recursive then return nil end
    for _, t in ipairs(targets) do
        if t == "/" or t == "/*" or t == "/." then
            return "refusing 'rm -r' on the filesystem root (/ or /*)"
        end
        local base = wildcard_target(t)
        if base then
            return "refusing 'rm -r' with a wildcard over '" .. base .. "'"
        end
        if is_system(t) then
            return "refusing 'rm -r' on the system directory '" .. t .. "'"
        end
    end
    return nil
end

return danger
