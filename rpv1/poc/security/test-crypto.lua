-- Known-answer tests + benchmarks for poc/security/crypto.lua.
-- Writes crypto-report.txt into the computer's own directory.
local ok, crypto = pcall(dofile, "crypto.lua")
local f = fs.open("crypto-report.txt", "w")
local function w(...)
    local parts = {}
    for i = 1, select("#", ...) do parts[i] = tostring(select(i, ...)) end
    local line = table.concat(parts, " ")
    f.writeLine(line)
    f.flush()
    print(line)
end

if not ok then
    w("LOAD_FAIL " .. tostring(crypto))
    f.close()
    os.shutdown()
    return
end

local function ms()
    return os.epoch and os.epoch("utc") or math.floor(os.clock() * 1000)
end

w("VERSION=rpv-crypto-1")
w("COMPUTER=" .. tostring(os.getComputerID()))

-- 1. known-answer tests
local fails = 0
for _, t in ipairs(crypto.selftest()) do
    w("KAT " .. t.name .. " ok=" .. tostring(t.ok) .. (t.ok and "" or (" got=" .. tostring(t.got) .. " want=" .. tostring(t.want))))
    if not t.ok then fails = fails + 1 end
end

-- 2. benchmarks
local function bench(label, n, fn, bytes)
    local t0 = ms()
    for _ = 1, n do fn() end
    local dt = ms() - t0
    local per = dt / n
    local extra = ""
    if bytes then extra = string.format(" throughput=%s B/s", tostring(math.floor(bytes * n / math.max(dt / 1000, 0.001)))) end
    w(string.format("BENCH %s n=%d total_ms=%d per_op_ms=%.3f%s", label, n, dt, per, extra))
    return per
end

w("--- benchmarks (os.epoch ms) ---")
bench("sha256_64B", 200, function() crypto.sha256(string.rep("A", 64)) end, 64)
bench("sha256_1KB", 50, function() crypto.sha256(string.rep("A", 1024)) end, 1024)
bench("sha256_16KB", 5, function() crypto.sha256(string.rep("A", 16384)) end, 16384)
bench("hmac_sha256_64B", 100, function() crypto.hmac_sha256(string.rep("K", 32), string.rep("M", 64)) end)
bench("chacha20_1KB", 50, function()
    crypto.chacha20_xor(string.rep("K", 32), string.rep("N", 12), 1, string.rep("A", 1024))
end, 1024)
bench("chacha20_16KB", 5, function()
    crypto.chacha20_xor(string.rep("K", 32), string.rep("N", 12), 1, string.rep("A", 16384))
end, 16384)

local pbkdf2_1 = bench("pbkdf2_iters1", 1, function() crypto.pbkdf2_sha256("passphrase", "rpv-network", 1, 32) end)
local pbkdf2_64 = bench("pbkdf2_iters64", 1, function() crypto.pbkdf2_sha256("passphrase", "rpv-network", 64, 32) end)
w(string.format("PBKDF2 per_iteration_ms=%.4f", (pbkdf2_64 - pbkdf2_1) / 63))
for _, iters in ipairs({ 256, 1024, 4096 }) do
    w(string.format("PBKDF2 estimate iters=%d ~ms=%.0f", iters, pbkdf2_1 + (pbkdf2_64 - pbkdf2_1) / 63 * (iters - 1)))
end

-- 3. what one protected frame costs (encrypt-then-MAC over a 128 byte payload)
local key, nonce = crypto.random_bytes(32), crypto.random_bytes(12)
local mac_key = crypto.random_bytes(32)
local payload = string.rep("P", 128)
local per_frame = bench("aead_etm_frame_128B", 20, function()
    local ct = crypto.chacha20_xor(key, nonce, 1, payload)
    crypto.hmac_sha256(mac_key, ct)
end)

-- 4. what a 4-way handshake / key derivation costs
local per_hkdf = bench("hkdf_expand_64B", 10, function() crypto.hkdf_sha256(string.rep("I", 32), string.rep("S", 32), "rpv", 64) end)
w(string.format("ESTIMATE handshake_ms=%.0f (pbkdf2(1024)+4*hmac+2*hkdf)", pbkdf2_1 + (pbkdf2_64 - pbkdf2_1) / 63 * 1023 + 4 * 1 + 2 * per_hkdf))
w(string.format("ESTIMATE frames_per_second=%.0f", 1000 / math.max(per_frame, 0.001)))

w("SELFTEST_FAILS=" .. tostring(fails))
w("DONE")
f.close()
os.shutdown()
