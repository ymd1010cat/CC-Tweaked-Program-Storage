-- alias.lua - shell alias store for ush
-- Keeps name -> replacement text. The token level expansion (so that
-- "ll -a" really re-parses as "ls -l -a") lives in usr/ush.lua, which owns the
-- tokenizer; this module only validates and stores definitions.

local alias = {}

local table_store = {}

function alias.valid_name(name)
    return type(name) == "string" and name:match("^[%w_%.%-]+$") ~= nil
end

function alias.define(name, value)
    if not alias.valid_name(name) then
        return nil, "alias: invalid name: " .. tostring(name)
    end
    table_store[name] = value or ""
    return true
end

function alias.get(name)
    return table_store[name]
end

function alias.exists(name)
    return table_store[name] ~= nil
end

function alias.remove(name)
    if table_store[name] == nil then return nil end
    table_store[name] = nil
    return true
end

function alias.remove_all()
    local n = 0
    for _ in pairs(table_store) do n = n + 1 end
    table_store = {}
    return n
end

function alias.names()
    local out = {}
    for name in pairs(table_store) do out[#out + 1] = name end
    table.sort(out)
    return out
end

function alias.reset()
    table_store = {}
    return true
end

return alias
