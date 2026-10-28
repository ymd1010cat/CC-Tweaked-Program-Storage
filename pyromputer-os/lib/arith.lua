-- arith.lua - arithmetic expansion for psh: the value of "$((EXPR))"
--
-- The evaluator runs on the exact integers of lib/bignum.lua and follows the
-- 64 bit signed rules of a POSIX shell. A value is held as an unsigned 64 bit
-- number, its sign comes from the top bit, every result wraps around modulo
-- 2^64, "/" truncates towards zero and "%" takes the sign of the dividend.
--
-- Grammar, from the lowest precedence to the highest:
--
--   ?:   ||   &&   |   ^   &   == !=   < <= > >=   << >>   + -   * / %
--   ! ~ + - (unary)   ( )   NAME $NAME ${NAME}   123 0x7b 0b101
--
-- A name stands for the text of a shell variable: blanks in front are
-- skipped, a sign and a "0x" or "0b" base are understood, only the leading
-- number is read ("12abc" is 12) and an unset, empty or non numeric value
-- counts as zero.
--
-- arith.eval() returns the result as a decimal string, or nil plus a reason
-- when the expression is not valid (a division by zero, a stray character).

local B = require("bignum")

local arith = {}

local WIDTH = 64
local MASK64 = B.from_dec("18446744073709551615")   -- 2^64 - 1
local SIGN64 = B.from_dec("9223372036854775808")    -- 2^63
local ZERO, ONE = B.zero(), B.one()

-- The only way an arithmetic fault leaves the evaluator: a plain message, no
-- position and no Lua prefix, so the caller can print it as it is.
local function fault(message)
    error(message, 0)
end

-- ============================================================
-- 64 bit signed helpers
-- ============================================================

local function wrap(x)
    return B.band(x, MASK64)
end

local function negative(x)
    return B.compare(x, SIGN64) >= 0
end

-- ~x, the one's complement inside the width.
local function complement(x)
    return wrap(B.sub(MASK64, wrap(x)))
end

-- -x, which is ~x + 1 and gives x back when x is the most negative number.
local function negate(x)
    return wrap(B.add(complement(x), ONE))
end

local function from_signed(sign, magnitude)
    if sign < 0 then return negate(magnitude) end
    return wrap(magnitude)
end

local function signed_less(a, b)
    if negative(a) ~= negative(b) then return negative(a) end
    return B.compare(a, b) < 0
end

-- Decimal text of a 64 bit value with its sign.
local function signed_text(x)
    x = wrap(x)
    if negative(x) then
        return "-" .. B.to_dec(negate(x))
    end
    return B.to_dec(x)
end

-- ============================================================
-- Reader state
-- ============================================================

local src, at, n = "", 1, 0
local lookup = nil          -- name -> the value text of that name, or nil

local BLANKS = { [" "] = true, ["\t"] = true, ["\n"] = true, ["\r"] = true }

local function skip_blanks()
    while at <= n and BLANKS[src:sub(at, at)] do
        at = at + 1
    end
end

-- ============================================================
-- Numbers
-- ============================================================

local function from_binary(bits)
    local value = B.zero()
    local two = B.from_num(2)
    for i = 1, #bits do
        value = B.mul(value, two)
        if bits:sub(i, i) == "1" then value = B.add(value, ONE) end
    end
    return value
end

-- One whole token: decimal digits, "0x" hex or "0b" binary. nil when the text
-- is not a number at all.
local function number_of_token(token)
    if type(token) ~= "string" then return nil end
    local hex = token:match("^0[xX](%x+)$")
    if hex then return B.from_hex(hex) end
    local bin = token:match("^0[bB]([01]+)$")
    if bin then return from_binary(bin) end
    local dec = token:match("^%d+$")
    if dec then return B.from_dec(dec) end
    return nil
end

-- The same for a value that came out of a variable, read the lenient way.
local function number_of_text(text)
    if text == nil then return ZERO end
    local s = tostring(text)
    local i = 1
    while i <= #s and BLANKS[s:sub(i, i)] do i = i + 1 end
    local sign = 1
    local c = s:sub(i, i)
    if c == "+" then
        i = i + 1
    elseif c == "-" then
        sign = -1
        i = i + 1
    end
    local rest = s:sub(i)
    local token = rest:match("^0[xX]%x+") or rest:match("^0[bB][01]+")
        or rest:match("^%d+")
    local value = number_of_token(token)
    if value == nil then return ZERO end
    return from_signed(sign, value)
end

local function lookup_number(name)
    return number_of_text(lookup(name))
end

local function lookup_length(name)
    local text = lookup(name)
    if text == nil then return ZERO end
    return B.from_num(#tostring(text))
end

-- ============================================================
-- Grammar
-- ============================================================

local parse_ternary
local parse_reference
local parse_expression

function parse_expression()

    skip_blanks()
    local c = src:sub(at, at)

    -- A parenthesised expression, any level inside.
    if c == "(" then
        at = at + 1
        local value = parse_ternary()
        skip_blanks()
        if src:sub(at, at) ~= ")" then
            fault("syntax error: missing )")
        end
        at = at + 1
        return value
    end

    -- $NAME, ${NAME}, $1, $#, ${#NAME}: every reference the shell knows.
    if c == "$" then
        at = at + 1
        return parse_reference()
    end

    -- A literal number.
    if c:match("%d") then
        local token = src:match("^0[xX]%x+", at) or src:match("^0[bB][01]+", at)
            or src:match("^%d+", at)
        at = at + #token
        return wrap(number_of_token(token))
    end

    -- A bare name, the same value a $NAME would give.
    if c:match("[%a_]") then
        local name = src:match("^[%a_][%w_]*", at)
        at = at + #name
        return lookup_number(name)
    end

    fault("syntax error near '" .. (c == "" and "the end" or c) .. "'")
end

function parse_reference()
    local c = src:sub(at, at)
    if c == "{" then
        local close = src:find("}", at + 1, true)
        if close == nil then
            fault("syntax error: missing }")
        end
        local name = src:sub(at + 1, close - 1)
        at = close + 1
        if #name > 1 and name:sub(1, 1) == "#" then
            return lookup_length(name:sub(2))
        end
        return lookup_number(name)
    end
    local digits = src:match("^%d+", at)
    if digits then
        at = at + #digits
        return lookup_number(digits)
    end
    local name = src:match("^[%a_][%w_]*", at)
    if name then
        at = at + #name
        return lookup_number(name)
    end
    if c:match("[%?#@%*%$!]") then
        at = at + 1
        return lookup_number(c)
    end
    fault("syntax error: bad reference")
end

local function parse_unary()
    skip_blanks()
    local c = src:sub(at, at)
    if c == "!" then
        at = at + 1
        return B.is_zero(parse_unary()) and ONE or ZERO
    end
    if c == "~" then
        at = at + 1
        return complement(parse_unary())
    end
    if c == "-" then
        at = at + 1
        return negate(parse_unary())
    end
    if c == "+" then
        at = at + 1
        return wrap(parse_unary())
    end
    return parse_expression()
end

-- The binary levels, lowest precedence first. "|", "&", "<" and ">" are the
-- first half of a longer operator ("||", "&&", "<<", ">>"), which
-- match_operator() keeps them from eating.
local LEVELS = {
    { "||" },
    { "&&" },
    { "|" },
    { "^" },
    { "&" },
    { "==", "!=" },
    { "<=", ">=", "<", ">" },
    { "<<", ">>" },
    { "+", "-" },
    { "*", "/", "%" },
}

local DOUBLED = { ["|"] = true, ["&"] = true, ["<"] = true, [">"] = true }

local function match_operator(ops)
    for _, op in ipairs(ops) do
        if src:sub(at, at + #op - 1) == op then
            if #op == 1 and DOUBLED[op] and src:sub(at + 1, at + 1) == op then
                return nil
            end
            return op
        end
    end
    return nil
end

-- A shift count has to be small to mean anything; a count with more than 53
-- bits set is past the width and is reported as one.
local function shift_count(amount)
    if negative(amount) then
        fault("shift count out of range")
    end
    if B.bitlen(amount) > 53 then return WIDTH end
    local k = tonumber(B.to_dec(amount))
    if k == nil then return WIDTH end
    return k
end

local function shift_left(a, amount)
    local k = shift_count(amount)
    if k >= WIDTH then return ZERO end
    return wrap(B.shl(a, k))
end

local function shift_right(a, amount)
    local k = shift_count(amount)
    if k >= WIDTH then
        return negative(a) and complement(ZERO) or ZERO
    end
    local value = B.shr(a, k)
    if negative(a) and k > 0 then
        -- an arithmetic shift: the ones come in from the left
        value = B.bor(value, B.shl(complement(ZERO), WIDTH - k))
    end
    return wrap(value)
end

local function quotient(a, b, modulo)
    if B.is_zero(b) then
        if modulo then
            fault("division by zero in modulo")
        end
        fault("division by zero")
    end
    local q, r = B.divmod(negative(a) and negate(a) or a,
        negative(b) and negate(b) or b)
    if modulo then
        return negative(a) and negate(r) or wrap(r)
    end
    if negative(a) ~= negative(b) then return negate(q) end
    return wrap(q)
end

local function apply(op, a, b)
    a, b = wrap(a), wrap(b)
    if op == "||" then
        return (not B.is_zero(a) or not B.is_zero(b)) and ONE or ZERO
    elseif op == "&&" then
        return (not B.is_zero(a) and not B.is_zero(b)) and ONE or ZERO
    elseif op == "|" then
        return B.bor(a, b)
    elseif op == "^" then
        return B.bxor(a, b)
    elseif op == "&" then
        return B.band(a, b)
    elseif op == "==" then
        return B.compare(a, b) == 0 and ONE or ZERO
    elseif op == "!=" then
        return B.compare(a, b) ~= 0 and ONE or ZERO
    elseif op == "<" then
        return signed_less(a, b) and ONE or ZERO
    elseif op == "<=" then
        return (signed_less(a, b) or B.compare(a, b) == 0) and ONE or ZERO
    elseif op == ">" then
        return signed_less(b, a) and ONE or ZERO
    elseif op == ">=" then
        return (signed_less(b, a) or B.compare(a, b) == 0) and ONE or ZERO
    elseif op == "<<" then
        return shift_left(a, b)
    elseif op == ">>" then
        return shift_right(a, b)
    elseif op == "+" then
        return wrap(B.add(a, b))
    elseif op == "-" then
        return wrap(B.add(a, negate(b)))
    elseif op == "*" then
        return wrap(B.mul(a, b))
    elseif op == "/" then
        return quotient(a, b, false)
    elseif op == "%" then
        return quotient(a, b, true)
    end
    fault("syntax error: unknown operator " .. tostring(op))
end

local function parse_binary(level)
    if level > #LEVELS then
        return parse_unary()
    end
    local left = parse_binary(level + 1)
    while true do
        skip_blanks()
        local op = match_operator(LEVELS[level])
        if op == nil then return left end
        at = at + #op
        skip_blanks()
        left = apply(op, left, parse_binary(level + 1))
    end
end

function parse_ternary()
    local condition = parse_binary(1)
    skip_blanks()
    if src:sub(at, at) ~= "?" then return condition end
    at = at + 1
    local yes = parse_ternary()
    skip_blanks()
    if src:sub(at, at) ~= ":" then
        fault("syntax error: missing : of a ?: expression")
    end
    at = at + 1
    local no = parse_ternary()
    if B.is_zero(condition) then return no end
    return yes
end

-- ============================================================
-- Entry point
-- ============================================================

-- Value of EXPR as a decimal string. LOOKUP maps a name to the text of that
-- name (nil when it is not set, which counts as zero). Returns the text, or
-- nil plus a reason when the expression cannot be evaluated.
function arith.eval(text, lookup_fn)
    local saved_src, saved_at, saved_n, saved_lookup = src, at, n, lookup
    src, at, n = tostring(text or ""), 1, #tostring(text or "")
    lookup = lookup_fn or function() return nil end
    local ok, result = pcall(function()
        skip_blanks()
        if at > n then return ZERO end      -- "$(( ))" is zero
        local value = parse_ternary()
        skip_blanks()
        if at <= n then
            fault("syntax error near '" .. src:sub(at) .. "'")
        end
        return value
    end)
    src, at, n, lookup = saved_src, saved_at, saved_n, saved_lookup
    if not ok then
        return nil, tostring(result)
    end
    return signed_text(result)
end

-- The same value as a Lua number when it fits one, for callers that only need
-- a count (a shift, a repeat, a test). nil when the value is too large.
function arith.eval_number(text, lookup_fn)
    local value, why = arith.eval(text, lookup_fn)
    if value == nil then return nil, why end
    local num = tonumber(value)
    if num == nil then return nil, "value out of range" end
    return num
end

return arith
