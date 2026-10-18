-- vars.lua - shell variables and exported environment for ush
-- A plain name -> value table plus an "exported" flag per name, mirroring the
-- POSIX environment. USER/HOME/SHELL/PATH/PWD are exported by default, "?" and
-- "$" are read-only specials ($? = last exit status, $$ = computer ID).

local vars = {}

local SPECIAL = { ["?"] = true, ["$"] = true }

local store = {}
local exported = {}

function vars.init(opts)
    opts = opts or {}
    store = {}
    exported = {}
    vars.set("USER", opts.user or "guest")
    vars.set("HOME", opts.home or "/")
    vars.set("SHELL", opts.shell or "/usr/ush.lua")
    vars.set("PATH", opts.path or "")
    vars.set("PWD", opts.pwd or "/")
    store["?"] = "0"
    store["$"] = tostring(opts.computer_id or 0)
    vars.export("USER")
    vars.export("HOME")
    vars.export("SHELL")
    vars.export("PATH")
    vars.export("PWD")
    return true
end

function vars.get(name)
    return store[name]
end

function vars.set(name, value)
    if type(name) ~= "string" or name == "" then return false end
    store[name] = tostring(value)
    return true
end

function vars.unset(name)
    local had = store[name] ~= nil
    if not SPECIAL[name] then
        store[name] = nil
        exported[name] = nil
    end
    return had
end

function vars.export(name)
    if type(name) ~= "string" or name == "" then return nil end
    if SPECIAL[name] then return store[name] end
    if store[name] == nil then store[name] = "" end
    exported[name] = true
    return store[name]
end

function vars.is_exported(name)
    return exported[name] == true
end

function vars.set_exported(name, flag)
    if SPECIAL[name] then return false end
    if flag then
        exported[name] = true
    else
        exported[name] = nil
    end
    return true
end

function vars.special(name)
    return SPECIAL[name] == true
end

-- Sorted list of user visible variable names.
function vars.names()
    local out = {}
    for name in pairs(store) do
        if not SPECIAL[name] then out[#out + 1] = name end
    end
    table.sort(out)
    return out
end

-- Sorted list of exported pairs, as printed by "env" and "export".
function vars.env()
    local out = {}
    for name in pairs(store) do
        if exported[name] and not SPECIAL[name] then
            out[#out + 1] = { name = name, value = store[name] }
        end
    end
    table.sort(out, function(a, b) return a.name < b.name end)
    return out
end

function vars.status()
    return tonumber(store["?"]) or 0
end

function vars.set_status(code)
    store["?"] = tostring(math.floor(tonumber(code) or 0))
    return store["?"]
end

function vars.reset()
    store = {}
    exported = {}
    return true
end

return vars
