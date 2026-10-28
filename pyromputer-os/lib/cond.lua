-- cond.lua - the condition language of the "test" and "[" built-ins
--
-- Grammar (POSIX subset):
--   test                    -> false
--   test WORD               -> true when WORD is not empty
--   test ! WORD             -> negation, "!" may be repeated
--   test -z WORD / -n WORD  -> string tests
--   test -e/-f/-d/-x/-r/-w/-s FILE
--   test WORD1 OP WORD2     -> OP in "=", "==", "!=", -eq, -ne, -gt, -lt,
--                              -ge, -le
--
-- eval() returns (true|false, errmsg). A malformed expression returns
-- (nil, message): the caller prints the message and exits with status 2, the
-- way a real shell reports a bad test expression. File tests go through fs and
-- lib/perm.lua, so they answer the same question as an access(2) call in a
-- simulated Unix: "-w" is false on a read-only mount and on a file whose
-- permission record forbids writing.
local cond = {}

local function resolve(env, path)
    if env and env.resolve then return env.resolve(path) end
    return require("cwd").resolve(path)
end

local function is_dir(p)
    return fs.exists(p) and fs.isDir(p)
end

local function is_file(p)
    return fs.exists(p) and not fs.isDir(p)
end

local function to_int(text)
    if type(text) ~= "string" then return nil end
    local digits = text:match("^%s*(%-?%d+)%s*$")
    if not digits then return nil end
    return tonumber(digits)
end

local UNARY = {}

UNARY["-z"] = function(a) return a == "" end
UNARY["-n"] = function(a) return a ~= "" end

UNARY["-e"] = function(a, env) return fs.exists(resolve(env, a)) end
UNARY["-f"] = function(a, env) return is_file(resolve(env, a)) end
UNARY["-d"] = function(a, env) return is_dir(resolve(env, a)) end

UNARY["-s"] = function(a, env)
    local p = resolve(env, a)
    if not is_file(p) then return false end
    local f = fs.open(p, "r")
    if not f then return false end
    local data = f.readAll()
    f.close()
    return #data > 0
end

UNARY["-r"] = function(a, env)
    local p = resolve(env, a)
    if not fs.exists(p) then return false end
    return require("perm").can_read(p)
end

-- Writable means: the file exists, its mount point is not read-only and the
-- permission record allows writing for the current user.
UNARY["-w"] = function(a, env)
    local p = resolve(env, a)
    if not fs.exists(p) then return false end
    if require("mounts").is_readonly(a) then return false end
    return require("perm").can_write(p)
end

UNARY["-x"] = function(a, env)
    local p = resolve(env, a)
    if not fs.exists(p) then return false end
    return require("perm").can_exec(p)
end

local function compare(op, a, b)
    local x, y = to_int(a), to_int(b)
    if x == nil or y == nil then
        return nil, "integer expression expected"
    end
    if op == "-eq" then return x == y end
    if op == "-ne" then return x ~= y end
    if op == "-gt" then return x > y end
    if op == "-lt" then return x < y end
    if op == "-ge" then return x >= y end
    if op == "-le" then return x <= y end
    return nil, "unknown operator"
end

local BINARY = {
    ["="] = function(a, b) return a == b end,
    ["=="] = function(a, b) return a == b end,
    ["!="] = function(a, b) return a ~= b end,
    ["-eq"] = true, ["-ne"] = true, ["-gt"] = true,
    ["-lt"] = true, ["-ge"] = true, ["-le"] = true,
}

-- Evaluate one test expression. "args" is the argument list with the closing
-- "]" already removed by the caller.
function cond.eval(args, env)
    local i = 1
    local negate = false
    while args[i] == "!" do
        negate = not negate
        i = i + 1
    end

    local rest = {}
    for k = i, #args do rest[#rest + 1] = args[k] end
    local n = #rest
    local value, err

    if n == 0 then
        value = false
    elseif n == 1 then
        value = rest[1] ~= ""
    elseif n == 2 then
        local op, a = rest[1], rest[2]
        local fn = UNARY[op]
        if not fn then return nil, "unexpected operator '" .. tostring(op) .. "'" end
        value = fn(a, env)
    elseif n == 3 then
        local a, op, b = rest[1], rest[2], rest[3]
        local fn = BINARY[op]
        if fn == nil then return nil, "unexpected operator '" .. tostring(op) .. "'" end
        if fn == true then
            value, err = compare(op, a, b)
            if err then return nil, err end
        else
            value = fn(a, b)
        end
    else
        return nil, "too many arguments"
    end

    if negate then value = not value end
    return value and true or false
end

return cond
