-- base64.lua - standard base64 (RFC 4648) for the base64 builtin
--
-- The standard alphabet with "+" and "/" and "=" padding, one line of output and
-- no line breaking: this machine has no mail reader that would want the 76 column
-- form, and a wrapped line is one more thing a script has to undo before it can
-- decode.
--
-- The decoder is deliberately strict about what it accepts, because a decoder
-- that skips a character it does not know turns a corrupted file into a shorter
-- file with no error. Whitespace is the one thing it ignores -- a base64 blob
-- pasted out of a file arrives with newlines in it -- and anything else that is
-- not in the alphabet is a reason to stop.

local base64 = {}

local ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

-- The reverse map, built once: the answer for a character is its position in the
-- alphabet less one, which is the six bit value it stands for.
local VALUE = {}
for i = 1, #ALPHABET do
    VALUE[ALPHABET:sub(i, i)] = i - 1
end

-- The character of one six bit value.
local function sextet(value)
    return ALPHABET:sub(value + 1, value + 1)
end

-- Encode DATA. The result is one line with no break.
function base64.encode(data)
    local out = {}
    local n = #data
    local i = 1
    -- Whole groups of three bytes become four characters. The three bytes are
    -- packed into one number and the six bit fields are cut back out of it, so
    -- no bit library is needed for either half of this file.
    while i + 2 <= n do
        local a, b, c = data:byte(i, i + 2)
        local block = a * 65536 + b * 256 + c
        out[#out + 1] = sextet(math.floor(block / 262144) % 64)
        out[#out + 1] = sextet(math.floor(block / 4096) % 64)
        out[#out + 1] = sextet(math.floor(block / 64) % 64)
        out[#out + 1] = sextet(block % 64)
        i = i + 3
    end
    -- One byte left gives two characters and two "=", two bytes give three
    -- characters and one "=", no byte gives nothing at all.
    local left = n - i + 1
    if left == 1 then
        local block = data:byte(i) * 65536
        out[#out + 1] = sextet(math.floor(block / 262144) % 64)
        out[#out + 1] = sextet(math.floor(block / 4096) % 64)
        out[#out + 1] = "=="
    elseif left == 2 then
        local a, b = data:byte(i, i + 1)
        local block = a * 65536 + b * 256
        out[#out + 1] = sextet(math.floor(block / 262144) % 64)
        out[#out + 1] = sextet(math.floor(block / 4096) % 64)
        out[#out + 1] = sextet(math.floor(block / 64) % 64)
        out[#out + 1] = "="
    end
    return table.concat(out)
end

-- Decode TEXT. Returns the bytes, or nil plus a reason when TEXT is not base64.
function base64.decode(text)
    text = tostring(text)
    -- Whitespace carries no data: a blob copied out of a file is full of the
    -- newlines the encoder never wrote.
    local compact = text:gsub("[ \t\r\n]", "")

    -- Padding is only legal at the end, and there are at most two of them.
    local pad = 0
    local first_pad = compact:find("=", 1, true)
    if first_pad then
        pad = #compact - first_pad + 1
        if pad > 2 or compact:sub(first_pad):find("[^=]") then
            return nil, "invalid padding"
        end
        compact = compact:sub(1, first_pad - 1)
    end

    -- A base64 group is four characters, so a lone leftover character can never
    -- be the start of a byte.
    if #compact % 4 == 1 then
        return nil, "invalid length"
    end

    local out = {}
    local acc, bits = 0, 0
    for i = 1, #compact do
        local c = compact:sub(i, i)
        local value = VALUE[c]
        if value == nil then
            return nil, "invalid character '" .. c .. "'"
        end
        acc = acc * 64 + value
        bits = bits + 6
        if bits >= 8 then
            bits = bits - 8
            local divisor = 2 ^ bits
            out[#out + 1] = string.char(math.floor(acc / divisor) % 256)
            acc = acc % divisor
        end
    end
    return table.concat(out)
end

-- The nine vectors of RFC 4648 plus the round trip of every one of them. The
-- decode of an unknown character is checked as well: a decoder that quietly
-- dropped it would pass the round trip and lose data on a corrupt file.
function base64.selftest()
    local vectors = {
        { "", "" },
        { "f", "Zg==" },
        { "fo", "Zm8=" },
        { "foo", "Zm9v" },
        { "foob", "Zm9vYg==" },
        { "fooba", "Zm9vYmE=" },
        { "foobar", "Zm9vYmFy" },
    }
    local out = {}
    for _, pair in ipairs(vectors) do
        local encoded = base64.encode(pair[1])
        local decoded = base64.decode(pair[2])
        out[#out + 1] = {
            name = "encode(" .. pair[1] .. ")",
            ok = encoded == pair[2],
            got = encoded,
            want = pair[2],
        }
        out[#out + 1] = {
            name = "decode(" .. pair[2] .. ")",
            ok = decoded == pair[1],
            got = tostring(decoded),
            want = pair[1],
        }
    end
    local bad, reason = base64.decode("Zm9!")
    out[#out + 1] = {
        name = "decode refuses a character outside the alphabet",
        ok = (bad == nil and reason == "invalid character '!'"),
        got = tostring(bad) .. " / " .. tostring(reason),
        want = "nil and the offending character",
    }
    -- Padding that is not at the end is a different fault and must not be read
    -- as data either.
    local padded, why = base64.decode("Z=9v")
    out[#out + 1] = {
        name = "decode refuses padding in the middle",
        ok = (padded == nil and type(why) == "string"),
        got = tostring(padded) .. " / " .. tostring(why),
        want = "nil and a reason",
    }
    return out
end

return base64
