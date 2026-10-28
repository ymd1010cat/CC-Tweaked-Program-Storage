-- params.lua - positional parameters for psh ($0, $1..$n, $#, $@, $*)
--
-- The shell keeps a LIFO stack of parameter frames. One frame is pushed for
-- every script the shell runs (run_script_file) and for every shell function
-- call, so $1 inside a function refers to the arguments of that function and
-- the caller's set is restored as soon as the function returns. $0 is the name
-- of the running script; for an interactive session it is the shell itself.
--
-- The frames are kept apart from lib/vars.lua on purpose: a positional
-- parameter cannot be overwritten with "x=1" and a name cannot start with a
-- digit, so the two namespaces never collide. read_var() in psh.lua routes
-- "$1", "$#", "$@" and friends here and everything else to vars.
local params = {}

-- $0 of the outermost frame: the shell as a POSIX login shell would report it.
local DEFAULT_ZERO = "/usr/psh.lua"

local stack = {}

local function new_frame(zero, args)
    local frame = { zero = zero or DEFAULT_ZERO, args = {} }
    for i, a in ipairs(args or {}) do
        frame.args[i] = tostring(a)
    end
    return frame
end

-- Start from the session frame: $0 is the shell, $1.. are empty and $# is 0.
stack[1] = new_frame(DEFAULT_ZERO, {})

-- Push a new frame ("script" or "function"). Returns the frame.
function params.push(zero, args)
    local frame = new_frame(zero, args)
    stack[#stack + 1] = frame
    return frame
end

-- Drop the innermost frame. The session frame is never removed, so a stray
-- call can not leave the shell without parameters at all.
function params.pop()
    if #stack <= 1 then return stack[1] end
    return table.remove(stack)
end

function params.depth()
    return #stack
end

function params.frame()
    return stack[#stack]
end

function params.zero()
    return stack[#stack].zero
end

-- Number of positional parameters of the current frame ($#).
function params.count()
    return #stack[#stack].args
end

-- All positional parameters of the current frame as a fresh array ($@).
function params.all()
    local out = {}
    for i, a in ipairs(stack[#stack].args) do out[i] = a end
    return out
end

-- One positional parameter by name:
--   "0"          -> $0 (script name)
--   "1".."9","10"-> that argument, nil when it is not set
--   "#"          -> $# as a string
--   "@" and "*"  -> the arguments joined with a single blank
function params.get(name)
    local frame = stack[#stack]
    if name == "0" then return frame.zero end
    if name == "#" then return tostring(#frame.args) end
    if name == "@" or name == "*" then return table.concat(frame.args, " ") end
    local n = tonumber(name)
    if n and n >= 1 and n % 1 == 0 then
        local v = frame.args[n]
        if v == nil then return nil end
        return tostring(v)
    end
    return nil
end

-- True when the name is a positional parameter reference handled here.
function params.is_param(name)
    if type(name) ~= "string" or name == "" then return false end
    if name == "#" or name == "@" or name == "*" then return true end
    return name:match("^%d+$") ~= nil
end

-- Replace the arguments of the current frame ($@ after "set -- a b").
function params.set(args)
    local frame = stack[#stack]
    frame.args = {}
    for i, a in ipairs(args or {}) do
        frame.args[i] = tostring(a)
    end
    return #frame.args
end

-- "shift [n]": drop the first n positional parameters (default 1). Shifting
-- past the end empties the list, exactly like POSIX shift. Returns true when
-- something was shifted.
function params.shift(n)
    n = tonumber(n) or 1
    if n ~= n or n ~= math.floor(n) or n < 0 then return false, "numeric argument required" end
    local frame = stack[#stack]
    if n == 0 then return true end
    local out = {}
    for i = n + 1, #frame.args do out[#out + 1] = frame.args[i] end
    frame.args = out
    return true
end

-- Back to the session frame (used by the self test).
function params.reset()
    stack = { new_frame(DEFAULT_ZERO, {}) }
end

return params
