--[[- dc.crypto — 纯 Lua 的 SHA-256 / HMAC-SHA256（不需要任何外部库）

用途：给网络消息签名，防止局域网里别的程序伪装成主控/节点派任务或伪造结果，
并配合 dc.net 的序号+时间戳做防重放。**不是密码学强度的密钥管理**（密钥是明文写在
settings 里的），它防的是"同一个局域网里别的脚本乱发消息"，不是防有耐心的攻击者。

依赖 bit32（CC:Tweaked 与 CraftOS-PC 都有）。没有 bit32 时 available=false，
上层会如实提示"本机不支持签名"而不是静默降级。
]]

local M = {}

local B = rawget(_G, "bit32")
if not B and rawget(_G, "bit") then
    local bit = rawget(_G, "bit")
    B = {
        band = bit.band, bor = bit.bor, bxor = bit.bxor, bnot = bit.bnot,
        lshift = bit.lshift, rshift = bit.rshift,
    }
end
M.available = (B ~= nil and type(B.band) == "function")

local MASK = 0xFFFFFFFF

local function add(...)
    local s = 0
    for i = 1, select("#", ...) do
        local v = select(i, ...)
        if v then s = s + v end
    end
    return B.band(s, MASK)
end

local function ror(x, n)
    return B.bor(B.rshift(x, n), B.lshift(x, 32 - n))
end

local function toWord(a, b, c, d)
    return B.band(a * 0x1000000 + b * 0x10000 + c * 0x100 + d, MASK)
end

local K = {
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
    0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
    0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
    0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
    0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
    0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
}

--- SHA-256，返回 32 字节二进制摘要
function M.sha256bin(msg)
    if not M.available then return nil, "no bit32, cannot compute hash" end
    msg = tostring(msg or "")
    local h = {
        0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
        0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
    }

    -- 补位：0x80 + 若干 0，使长度 ≡ 56 (mod 64)，再接 8 字节大端比特长度
    local len = #msg
    local bits = len * 8
    local zeroPad = (55 - len) % 64
    local tail = string.char(0x80) .. string.rep("\0", zeroPad)
    local hi = math.floor(bits / 4294967296) % 4294967296
    local lo = bits % 4294967296
    for shift = 24, 0, -8 do
        tail = tail .. string.char(math.floor(hi / (2 ^ shift)) % 256)
    end
    for shift = 24, 0, -8 do
        tail = tail .. string.char(math.floor(lo / (2 ^ shift)) % 256)
    end
    local data = msg .. tail

    local w = {}
    for base = 1, #data, 64 do
        local chunk = data:sub(base, base + 63)
        for i = 0, 15 do
            local o = i * 4 + 1
            w[i + 1] = toWord(chunk:byte(o, o + 3))
        end
        for i = 17, 64 do
            local x, y = w[i - 15], w[i - 2]
            local s0 = B.bxor(ror(x, 7), ror(x, 18), B.rshift(x, 3))
            local s1 = B.bxor(ror(y, 17), ror(y, 19), B.rshift(y, 10))
            w[i] = add(w[i - 16], s0, w[i - 7], s1)
        end

        local a, b, c, d, e, f, g, hh = h[1], h[2], h[3], h[4], h[5], h[6], h[7], h[8]
        for i = 1, 64 do
            local S1 = B.bxor(ror(e, 6), ror(e, 11), ror(e, 25))
            local ch = B.bxor(B.band(e, f), B.band(B.bnot(e), g))
            local t1 = add(hh, S1, ch, K[i], w[i])
            local S0 = B.bxor(ror(a, 2), ror(a, 13), ror(a, 22))
            local maj = B.bxor(B.band(a, b), B.band(a, c), B.band(b, c))
            local t2 = add(S0, maj)
            hh, g, f = g, f, e
            e = add(d, t1)
            d, c, b = c, b, a
            a = add(t1, t2)
        end
        h[1], h[2], h[3], h[4] = add(h[1], a), add(h[2], b), add(h[3], c), add(h[4], d)
        h[5], h[6], h[7], h[8] = add(h[5], e), add(h[6], f), add(h[7], g), add(h[8], hh)
    end

    local out = {}
    for i = 1, 8 do
        out[i] = string.char(
            math.floor(h[i] / 0x1000000) % 256,
            math.floor(h[i] / 0x10000) % 256,
            math.floor(h[i] / 0x100) % 256,
            h[i] % 256)
    end
    return table.concat(out)
end

--- SHA-256，返回十六进制字符串
function M.sha256(msg)
    local bin, err = M.sha256bin(msg)
    if not bin then return nil, err end
    return (bin:gsub(".", function(c) return string.format("%02x", c:byte()) end))
end

--- HMAC-SHA256，返回 32 字节二进制
function M.hmacSha256bin(key, msg)
    if not M.available then return nil, "no bit32, cannot compute HMAC" end
    key = tostring(key or "")
    msg = tostring(msg or "")
    if #key > 64 then
        local k = M.sha256bin(key)
        if not k then return nil, "key hash failed" end
        key = k
    end
    key = key .. string.rep("\0", 64 - #key)
    local ipad, opad = {}, {}
    for i = 1, 64 do
        local b = key:byte(i)
        ipad[i] = string.char(B.bxor(b, 0x36))
        opad[i] = string.char(B.bxor(b, 0x5c))
    end
    local inner = M.sha256bin(table.concat(ipad) .. msg)
    if not inner then return nil, "inner hash failed" end
    return M.sha256bin(table.concat(opad) .. inner)
end

--- HMAC-SHA256，返回十六进制字符串
function M.hmacSha256(key, msg)
    local bin, err = M.hmacSha256bin(key, msg)
    if not bin then return nil, err end
    return (bin:gsub(".", function(c) return string.format("%02x", c:byte()) end))
end

--- 定长比较（避免按字节提前返回；这里消息量很小，够用）
function M.equal(a, b)
    a, b = tostring(a or ""), tostring(b or "")
    if #a ~= #b then return false end
    local diff = 0
    for i = 1, #a do
        if a:byte(i) ~= b:byte(i) then diff = diff + 1 end
    end
    return diff == 0
end

--- 把任意值序列化成**稳定**字符串（键名排序），用于签名。
-- textutils.serialize 不保证键顺序，所以必须自己来。
function M.canonical(value, seen)
    local t = type(value)
    if t == "number" then
        return string.format("%.17g", value)
    elseif t == "string" then
        return string.format("%q", value)
    elseif t == "boolean" then
        return value and "true" or "false"
    elseif t == "nil" then
        return "nil"
    elseif t ~= "table" then
        return t
    end
    seen = seen or {}
    if seen[value] then return "<cycle>" end
    seen[value] = true
    local keys = {}
    for k in pairs(value) do keys[#keys + 1] = k end
    table.sort(keys, function(x, y) return tostring(x) < tostring(y) end)
    local parts = { "{" }
    for _, k in ipairs(keys) do
        parts[#parts + 1] = M.canonical(tostring(k), seen)
        parts[#parts + 1] = "="
        parts[#parts + 1] = M.canonical(value[k], seen)
        parts[#parts + 1] = ","
    end
    parts[#parts + 1] = "}"
    seen[value] = nil
    return table.concat(parts)
end

--- 生成随机十六进制串（用于会话 ID）。不追求密码学随机：
-- 拿 os.epoch + os.clock + 电脑 ID + 计数器混合后哈希。
-- 注意：这里刻意不用 string.format("%d", ...)——Lua 5.2 的 %d 对浮点数会直接报错。
local counter = 0
function M.randomHex(bytes)
    bytes = bytes or 8
    counter = counter + 1
    local id = (os.getComputerID and os.getComputerID()) or 0
    local epoch = os.epoch and os.epoch("utc") or 0
    local seed = tostring(id) .. "|" .. tostring(counter) .. "|"
        .. tostring(math.floor(epoch)) .. "|"
        .. tostring(math.floor((os.clock() or 0) * 1000000)) .. "|"
        .. tostring(math.random(1, 2147483646))
    local h = M.sha256(seed) or string.rep("0", 64)
    return h:sub(1, bytes * 2)
end

--- 自检：用公开测试向量验证实现是否正确（真机测试里会调用）
function M.selftest()
    local out = {}
    local function expect(what, got, want)
        out[#out + 1] = { name = what, ok = (got == want), got = got, want = want }
    end
    expect("sha256(\"\")",
        M.sha256(""),
        "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    expect("sha256(\"abc\")",
        M.sha256("abc"),
        "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    expect("sha256(long string)",
        M.sha256("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq"),
        "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1")
    -- RFC 4231 Test Case 1
    expect("hmac-sha256(RFC4231 #1)",
        M.hmacSha256(string.rep("\11", 20), "Hi There"),
        "b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7")
    -- RFC 4231 Test Case 2
    expect("hmac-sha256(RFC4231 #2)",
        M.hmacSha256("Jefe", "what do ya want for nothing?"),
        "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843")
    return out
end

return M
