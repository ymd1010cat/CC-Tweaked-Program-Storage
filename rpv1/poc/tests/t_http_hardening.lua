--[[- tests/t_http_hardening.lua - six-stage security hardening (offline).

Covers counter exhaustion, ChaCha20 block limits, PSK/passphrase policy,
session_epoch framing, token-bucket rate limiting and seed_file accounting.
]]
local T, M = ...

local HS = M.http_secure
local crypto = M
T.ok(HS ~= nil and type(crypto.hkdf_sha256) == "function", "hardening modules loaded")
if not HS then return end

local PSK = "00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff"

local function u32(v)
    v = math.floor(v)
    return string.char(
        math.floor(v / 0x1000000) % 256,
        math.floor(v / 0x10000) % 256,
        math.floor(v / 0x100) % 256,
        v % 256)
end

local function make(opts)
    local o = { crypto = crypto, psk = PSK }
    for k, v in pairs(opts or {}) do o[k] = v end
    return HS.new(o)
end

local function rejects(opts, name)
    local o = { crypto = crypto }
    for k, v in pairs(opts) do o[k] = v end
    local sec, err = HS.new(o)
    T.eq(sec, nil, name)
    T.ok(type(err) == "string" and #err > 0, name .. " has an error")
end

-- ===== stage 1: counter exhaustion =======================================
T.eq(HS.MAX_COUNTER, 0xFFFFFFFE, "highest usable counter is 2^32-2")
local client = make({ role = "client" })
T.ok(client ~= nil, "counter client created")
T.eq(client.dir.c2s.tx, 0, "fresh counter is 0")

client.dir.c2s.tx = HS.MAX_COUNTER
local env, err = client:seal_request("x")
T.eq(env, nil, "seal refuses counter 2^32-1")
T.ok(tostring(err):find("counter exhausted", 1, true) ~= nil, "counter exhaustion is explained")
T.eq(client.dir.c2s.tx, HS.MAX_COUNTER, "failed seal does not advance the counter")
T.eq(client:get_stats().tx, 0, "failed seal does not count a transmit")

client.dir.c2s.tx = HS.MAX_COUNTER - 1
env = client:seal_request("last")
T.ok(env ~= nil, "counter 2^32-2 can still be emitted")
local info = HS.parse_envelope(env, 16)
T.eq(info.counter, HS.MAX_COUNTER, "last envelope uses counter 2^32-2")
T.eq(client.dir.c2s.tx, HS.MAX_COUNTER, "successful seal commits the counter")
env, err = client:seal_request("again")
T.eq(env, nil, "the next envelope is refused")
T.ok(tostring(err):find("counter exhausted", 1, true) ~= nil, "second exhaustion is explained")

client.dir.s2c.tx = HS.MAX_COUNTER
env, err = client:seal_response("response")
T.eq(env, nil, "s2c direction also exhausts")
T.ok(tostring(err):find("counter exhausted", 1, true) ~= nil, "s2c exhaustion is explained")
T.eq(client:get_stats().tx, 1, "only the successful envelope was counted")

local edge_client = make({ role = "client" })
edge_client.dir.c2s.tx = HS.MAX_COUNTER - 2
local edge1 = edge_client:seal_request("edge1")
local edge2 = edge_client:seal_request("edge2")
T.eq(HS.parse_envelope(edge1, 16).counter, HS.MAX_COUNTER - 1, "counter MAX-1 is emitted")
T.eq(HS.parse_envelope(edge2, 16).counter, HS.MAX_COUNTER, "counter MAX is emitted last")
local edge3, edge_err = edge_client:seal_request("edge3")
T.eq(edge3, nil, "counter MAX+1 is refused")
T.ok(tostring(edge_err):find("counter exhausted", 1, true) ~= nil, "MAX+1 exhaustion is explained")

local guard_client = make({ role = "client" })
guard_client.dir.c2s.tx = -1
local guarded = guard_client:seal_request("guarded")
T.ok(guarded ~= nil, "negative tx is repaired instead of emitting counter 0")
T.eq(HS.parse_envelope(guarded, 16).counter, 1, "counter 0 is never emitted")
T.eq(guard_client.dir.c2s.tx, 1, "repaired counter is committed")

-- ===== stage 2: ChaCha20 block / message limits ==========================
T.eq(HS.MAX_CHACHA_BLOCKS, 0xFFFFFFFF, "ChaCha20 block ceiling is 32 bits")
T.eq(HS.MAX_PLAINTEXT_BYTES, 60000, "datagram plaintext cap is 60000")
T.ok(HS.MAX_PLAINTEXT_BYTES + 9 + HS.MAX_TAG_LEN <= 65507,
    "envelope fits the IPv4/UDP datagram limit")
T.ok(HS.MAX_PLAINTEXT_BYTES > 0, "plaintext cap is set")
T.ok(math.ceil(HS.MAX_PLAINTEXT_BYTES / 64) <= HS.MAX_CHACHA_BLOCKS,
    "the plaintext cap fits inside the block ceiling")

local block_client = make({ role = "client" })
local big = string.rep("x", HS.MAX_PLAINTEXT_BYTES + 1)
env, err = block_client:seal_request(big)
T.eq(env, nil, "oversized plaintext is refused")
T.ok(tostring(err):find("too large", 1, true) ~= nil, "oversized plaintext is explained")
T.eq(block_client:get_stats().tx, 0, "oversized plaintext emits nothing")

local block_server = make({ role = "server" })
local huge = "H" .. u32(0) .. u32(1) .. big .. string.rep("t", 16)
local opened, oerr = block_server:open_request(huge, "src")
T.eq(opened, nil, "oversized ciphertext is refused")
T.ok(tostring(oerr):find("too large", 1, true) ~= nil, "oversized ciphertext is explained")
T.ok(block_server:get_stats().malformed >= 1, "oversized ciphertext is counted as malformed")
local small_env = block_client:seal_request("small")
T.ok(type(small_env) == "string" and #small_env > 21, "normal plaintext still seals")

-- ===== stage 3: PSK / passphrase policy ==================================
rejects({ psk = "" }, "empty PSK")
rejects({ psk = "abcd" }, "short hex PSK")
rejects({ psk = string.rep("ab", 31) }, "62-char hex PSK")
rejects({ psk = string.rep("ab", 33) }, "66-char hex PSK")
rejects({ psk = "correct horse battery staple" }, "passphrase without allow_passphrase")
rejects({ psk = "correct horse", allow_passphrase = true, psk_iter = 4095 }, "passphrase iter 4095")
rejects({ psk = "correct horse", allow_passphrase = true, psk_iter = HS.MAX_PSK_ITER + 1 },
    "passphrase iter too large")
rejects({ psk = "correct horse", allow_passphrase = true, psk_iter = 4096.5 },
    "fractional passphrase iter")

local upper = make({ psk = PSK:upper(), role = "client" })
local lower = make({ psk = PSK, role = "client" })
T.ok(upper ~= nil and lower ~= nil, "uppercase and lowercase hex PSKs accepted")
T.eq(upper.psk_mode, "hex", "hex PSK mode is reported")
T.eq(upper.psk_iter, nil, "hex PSK has no iteration count")
T.eq(upper.dir.c2s.key, lower.dir.c2s.key, "hex PSK is case-insensitive")

local pass_client = make({ psk = "correct horse battery staple", allow_passphrase = true,
    psk_iter = 4096, role = "client" })
local pass_server = make({ psk = "correct horse battery staple", allow_passphrase = true,
    psk_iter = 4096, role = "server" })
T.ok(pass_client ~= nil and pass_server ~= nil, "passphrase PSK accepted with allow_passphrase")
T.eq(pass_client.psk_mode, "passphrase", "passphrase mode is reported")
T.eq(pass_client.psk_iter, 4096, "passphrase iteration count is reported")
T.eq(pass_server:open_request(pass_client:seal_request("pass")), "pass", "passphrase round trip")

-- ===== stage 4: session_epoch ============================================
local epoch_client = make({ role = "client", session_epoch = 7 })
local epoch_server = make({ role = "server", session_epoch = 7 })
local wrong_epoch_server = make({ role = "server", session_epoch = 8 })
T.eq(epoch_client.session_epoch, 7, "session epoch is stored")
T.eq(wrong_epoch_server.session_epoch, 8, "other epoch is stored")
T.eq(make({ session_epoch = 0 }).session_epoch, 0, "epoch 0 accepted")
T.eq(make({ session_epoch = 0xFFFFFFFF }).session_epoch, 0xFFFFFFFF, "epoch max accepted")

local e7 = epoch_client:seal_request("epoch")
T.eq(#e7, 1 + 4 + 4 + 5 + 16, "epoch is part of the envelope length")
info = HS.parse_envelope(e7, 16)
T.eq(info.epoch, 7, "envelope carries the epoch")
T.eq(epoch_server:open_request(e7), "epoch", "matching epoch opens")
T.eq(wrong_epoch_server:open_request(e7), nil, "different epoch is refused")
T.ok(wrong_epoch_server:get_stats().epoch_fail >= 1, "epoch mismatch is counted")
T.eq(wrong_epoch_server:get_stats().rx, 0, "epoch mismatch consumes no counter")

-- tag covers the epoch: rewriting it to the receiver's epoch still fails MAC
local e8 = epoch_client:seal_request("tag-epoch")
local rewritten = e8:sub(1, 1) .. u32(8) .. e8:sub(6)
T.eq(wrong_epoch_server:open_request(rewritten), nil, "rewritten epoch fails authentication")
T.ok(wrong_epoch_server:get_stats().auth_fail >= 1, "rewritten epoch is an auth failure")

for _, epoch in ipairs({ 0, 1, 2, 0xFFFF, 0xFFFFFFFF }) do
    local c = make({ role = "client", session_epoch = epoch })
    local s = make({ role = "server", session_epoch = epoch })
    local e = c:seal_request("e")
    T.eq(s:open_request(e), "e", "epoch " .. epoch .. " round trip")
    T.eq(HS.parse_envelope(e, 16).epoch, epoch, "epoch " .. epoch .. " parses")
end

for _, bad in ipairs({ -1, 1.5, 0x100000000, "not-a-number" }) do
    rejects({ session_epoch = bad }, "invalid session_epoch " .. tostring(bad))
end

for _, tag_len in ipairs({ 8, 12, 16, 24, 32 }) do
    local c = make({ role = "client", tag_len = tag_len, session_epoch = 3 })
    local s = make({ role = "server", tag_len = tag_len, session_epoch = 3 })
    T.ok(c ~= nil and s ~= nil, "tag_len " .. tag_len .. " constructors")
    local e = c:seal_request("tag")
    T.eq(#e, 1 + 4 + 4 + 3 + tag_len, "tag_len " .. tag_len .. " envelope length")
    local parsed = HS.parse_envelope(e, tag_len)
    T.eq(parsed.epoch, 3, "tag_len " .. tag_len .. " epoch")
    T.eq(parsed.counter, 1, "tag_len " .. tag_len .. " counter")
    T.eq(#parsed.tag, tag_len, "tag_len " .. tag_len .. " tag size")
    T.eq(s:open_request(e), "tag", "tag_len " .. tag_len .. " round trip")
end

-- ===== stage 5: rate limit configuration ================================
rejects({ rate_limit = { rate = 0 } }, "rate 0")
rejects({ rate_limit = { rate = -1 } }, "negative rate")
rejects({ rate_limit = { burst = 0 } }, "burst 0")
rejects({ rate_limit = { burst = HS.MAX_BURST + 1 } }, "burst too large")
rejects({ rate_limit = { idle_ttl = 0 } }, "idle_ttl 0")
rejects({ rate_limit = { max_sources = 0 } }, "max_sources 0")
rejects({ rate_limit = "bad" }, "bad rate_limit type")

local rate_default = make({ rate_limit = true })
T.ok(rate_default ~= nil and rate_default.rate ~= nil, "rate_limit=true is accepted")
T.eq(rate_default.rate.rate, HS.DEFAULT_RATE, "default rate")
T.eq(rate_default.rate.burst, HS.DEFAULT_BURST, "default burst")
local rate_number = make({ rate_limit = 5 })
T.eq(rate_number.rate.rate, 5, "numeric rate_limit sets the rate")
T.eq(rate_number.rate.burst, 5, "numeric rate_limit sets the burst")
local rate_table = make({ rate_limit = { rate = 2, burst = 3, idle_ttl = 10, max_sources = 4 } })
T.eq(rate_table.rate.rate, 2, "table rate")
T.eq(rate_table.rate.burst, 3, "table burst")
T.eq(rate_table.rate.idle_ttl, 10, "table idle_ttl")
T.eq(rate_table.rate.max_sources, 4, "table max_sources")

-- ===== stage 5: src normalisation =======================================
local src_cases = {
    { nil, "unknown" },
    { "", "unknown" },
    { "   ", "unknown" },
    { " 1.2.3.4:80 ", "1.2.3.4" },
    { "HOST.Example:443", "host.example" },
    { "[::1]:8080", "[::1]" },
    { "a b\tc", "a_b_c" },
    { string.char(233) .. "x", "_x" },
    { string.rep("a", 100), string.rep("a", 64) },
    { { ip = "1.2.3.4" }, "1.2.3.4" },
    { { host = "Host" }, "host" },
    { { id = 42 }, "42" },
    { {}, "unknown" },
    { "UPPER_lower-1.2", "upper_lower-1.2" },
    { "1.2.3.4:99999", "1.2.3.4" },
    { "[2001:db8::1]", "[2001:db8::1]" },
    { "a:b:c", "a:b:c" },
    { "  UPPER  ", "upper" },
}
for _, case in ipairs(src_cases) do
    T.eq(HS.normalize_src(case[1]), case[2], "normalize_src " .. tostring(case[1]))
end

-- ===== stage 5: token bucket ============================================
local now = 0
local function clock() return now end
local rate_server = make({ role = "server", rate_limit = { rate = 1, burst = 2 }, clock = clock })
local rate_client = make({ role = "client" })
local envs = {}
for i = 1, 12 do envs[i] = rate_client:seal_request("m" .. i) end

T.eq(rate_server:open_request(envs[1], "a"), "m1", "first token is allowed")
T.eq(rate_server:open_request(envs[2], "a"), "m2", "second token is allowed")
local limited, lerr = rate_server:open_request(envs[3], "a")
T.eq(limited, nil, "third request is limited")
T.ok(tostring(lerr):find("rate limited", 1, true) ~= nil, "rate limit is explained")
T.ok(rate_server:get_stats().rate_limited >= 1, "rate limit is counted")
T.eq(rate_server:get_stats().rate_allowed, 2, "allowed tokens are counted")
T.eq(rate_server:get_stats().rate_buckets, 1, "one bucket for one source")

-- separate sources have separate buckets
T.eq(rate_server:open_request(envs[3], "b"), "m3", "another source has its own tokens")
T.eq(rate_server:get_stats().rate_buckets, 2, "second source gets a bucket")

-- refill: one token per second, capped at burst
now = 1
T.eq(rate_server:open_request(envs[4], "a"), "m4", "one second refills one token")
T.eq(rate_server:open_request(envs[5], "a"), nil, "refill is consumed by the request")
now = 2
T.eq(rate_server:open_request(envs[5], "a"), "m5", "the next second refills again")

-- burst cap: a long idle period does not create more than burst tokens
now = 100
T.eq(rate_server:open_request(envs[6], "a"), "m6", "burst token 1")
T.eq(rate_server:open_request(envs[7], "a"), "m7", "burst token 2")
T.eq(rate_server:open_request(envs[8], "a"), nil, "burst is capped")

-- rate limiting happens before authentication
local bad_tag = envs[9]:sub(1, #envs[9] - 1)
    .. string.char((envs[9]:byte(#envs[9]) + 1) % 256)
local before_auth = rate_server:get_stats().auth_fail
local denied, derr = rate_server:open_request(bad_tag, "a")
T.eq(denied, nil, "tampered request from an exhausted source is denied")
T.ok(tostring(derr):find("rate limited", 1, true) ~= nil, "it is denied by the rate limiter")
T.eq(rate_server:get_stats().auth_fail, before_auth, "auth was not attempted before limiting")

-- fractional refill: 0.5 tokens per second
now = 0
local frac_server = make({ role = "server",
    rate_limit = { rate = 0.5, burst = 1 }, clock = clock })
local frac_client = make({ role = "client" })
local frac_env = {}
for i = 1, 4 do frac_env[i] = frac_client:seal_request("fr" .. i) end
T.eq(frac_server:open_request(frac_env[1], "x"), "fr1", "fractional rate first token")
T.eq(frac_server:open_request(frac_env[2], "x"), nil, "fractional rate starts empty")
now = 1
T.eq(frac_server:open_request(frac_env[2], "x"), nil, "half a token is not enough")
now = 2
T.eq(frac_server:open_request(frac_env[2], "x"), "fr2", "two seconds refill one token")
T.eq(frac_server:open_request(frac_env[3], "x"), nil, "refill is consumed")
now = 4
T.eq(frac_server:open_request(frac_env[3], "x"), "fr3", "fractional refill repeats")

-- ===== stage 5: make_room only recycles idle buckets =====================
now = 0
local room_server = make({ role = "server",
    rate_limit = { rate = 0.1, burst = 1, idle_ttl = 10, max_sources = 2 }, clock = clock })
local room_client = make({ role = "client" })
local room_env = {}
for i = 1, 8 do room_env[i] = room_client:seal_request("r" .. i) end

T.eq(room_server:open_request(room_env[1], "a"), "r1", "bucket a is created")
T.eq(room_server:open_request(room_env[2], "b"), "r2", "bucket b is created")
local no_room, no_err = room_server:open_request(room_env[3], "c")
T.eq(no_room, nil, "a third bucket is refused at max_sources")
T.ok(tostring(no_err):find("bucket limit", 1, true) ~= nil, "bucket limit is explained")
T.eq(room_server:make_room(), 0, "nothing is recycled while buckets are fresh")
T.eq(room_server:get_stats().rate_buckets, 2, "fresh buckets survive make_room")

now = 5
T.eq(room_server:open_request(room_env[4], "a"), nil, "bucket a is touched and stays active")
T.ok(room_server:get_stats().rate_buckets == 2, "touching does not add a bucket")

now = 14
T.eq(room_server:make_room(), 1, "only the idle bucket is recycled")
T.eq(room_server:get_stats().rate_recycled, 1, "recycled bucket is counted")
T.eq(room_server:get_stats().rate_buckets, 1, "one bucket remains")
T.ok(room_server:rate_snapshot().a ~= nil, "the active bucket remains")
T.ok(room_server:rate_snapshot().b == nil, "the idle bucket was removed")
T.eq(room_server:open_request(room_env[5], "c"), "r5", "the freed slot accepts a new source")

-- fail closed when max_sources is full of active buckets
now = 0
local full_server = make({ role = "server",
    rate_limit = { rate = 1, burst = 1, idle_ttl = 10, max_sources = 1 }, clock = clock })
local full_client = make({ role = "client" })
local full_env = {}
for i = 1, 4 do full_env[i] = full_client:seal_request("f" .. i) end
T.eq(full_server:open_request(full_env[1], "a"), "f1", "only bucket is filled")
now = 1
local full_denied, full_err = full_server:open_request(full_env[2], "b")
T.eq(full_denied, nil, "active bucket is not evicted")
T.ok(tostring(full_err):find("bucket limit", 1, true) ~= nil, "full bucket table fails closed")
T.eq(full_server:get_stats().rate_buckets, 1, "bucket count stays bounded")
T.ok(full_server:rate_snapshot().a ~= nil, "active bucket is still present")
T.ok(full_server:rate_snapshot().b == nil, "rejected source did not get a bucket")

-- ===== stage 5: src_label and fail-closed paths ==========================
now = 0
local label_server = make({ role = "server",
    rate_limit = { rate = 1, burst = 1 }, clock = clock,
    src_label = function() return "shared" end })
local label_client = make({ role = "client" })
local label_env1 = label_client:seal_request("l1")
local label_env2 = label_client:seal_request("l2")
T.eq(label_server:open_request(label_env1, "a"), "l1", "custom label allows the first source")
local label_denied = label_server:open_request(label_env2, "b")
T.eq(label_denied, nil, "custom label shares one bucket")
T.eq(label_server:get_stats().rate_buckets, 1, "custom label created one bucket")

local bad_label_server = make({ role = "server",
    rate_limit = { rate = 1, burst = 1 }, clock = clock,
    src_label = function() error("label boom") end })
local bad_label_env = label_client:seal_request("bl")
local bl_out, bl_err = bad_label_server:open_request(bad_label_env, "a")
T.eq(bl_out, nil, "src_label error fails closed")
T.ok(tostring(bl_err):find("src_label", 1, true) ~= nil, "src_label error is explained")

local non_string_label = make({ role = "server",
    rate_limit = { rate = 1, burst = 1 }, clock = clock,
    src_label = function() return 42 end })
local nsl_out, nsl_err = non_string_label:open_request(bad_label_env, "a")
T.eq(nsl_out, nil, "non-string src_label fails closed")
T.ok(tostring(nsl_err):find("src_label", 1, true) ~= nil, "non-string src_label is explained")

local missing_src = make({ role = "server", rate_limit = { rate = 1, burst = 1 }, clock = clock })
local ms_out, ms_err = missing_src:open_request(bad_label_env)
T.eq(ms_out, nil, "missing src fails closed")
T.ok(tostring(ms_err):find("missing src", 1, true) ~= nil, "missing src is explained")

local bad_clock = make({ role = "server", rate_limit = { rate = 1, burst = 1 },
    clock = function() return "later" end })
local bc_out, bc_err = bad_clock:open_request(bad_label_env, "a")
T.eq(bc_out, nil, "bad clock fails closed")
T.ok(tostring(bc_err):find("clock", 1, true) ~= nil, "bad clock is explained")

local throwing_clock = make({ role = "server", rate_limit = { rate = 1, burst = 1 },
    clock = function() error("clock boom") end })
local tc_out = throwing_clock:open_request(bad_label_env, "a")
T.eq(tc_out, nil, "throwing clock fails closed")

-- ===== stage 6: seed_file ================================================
local seeded = make({ seed_file = "tests/t_http_hardening.lua" })
T.eq(seeded.seed_loaded, true, "existing seed file is loaded")
T.eq(seeded:get_stats().seed_loaded, true, "stats report the loaded seed")
local unseeded = make({ seed_file = "tests/definitely-missing-seed.bin" })
T.eq(unseeded.seed_loaded, false, "missing seed file is not loaded")
T.eq(unseeded:get_stats().seed_loaded, false, "stats report the missing seed")
local no_seed = make()
T.eq(no_seed.seed_loaded, false, "no seed_file means seed_loaded=false")
T.eq(no_seed:get_stats().seed_loaded, false, "stats default seed_loaded=false")
T.eq(no_seed.seed_file, "seed.bin", "default seed file is seed.bin")
T.eq(make({ role_file = "configs/role.txt" }).seed_file, "configs/seed.bin",
    "default seed file follows role.txt")
T.eq(make({ role_file = "/a/b/role.txt" }).seed_file, "/a/b/seed.bin",
    "default seed file uses the role.txt directory")
T.eq(make({ seed_file = "custom.bin" }).seed_file, "custom.bin", "explicit seed_file wins")
T.eq(make({ seed_file = false }).seed_loaded, false, "seed_file=false disables loading")
T.eq(no_seed:make_room(), 0, "make_room without rate_limit is a no-op")
T.eq(no_seed:allow("src"), true, "allow without rate_limit is always true")

-- ===== stats / envelope edge cases =======================================
local stats = no_seed:get_stats()
T.eq(stats.enabled, true, "stats enabled")
T.eq(stats.strict, true, "stats strict")
T.eq(stats.tag_len, 16, "stats tag_len")
T.eq(stats.window, 64, "stats window")
T.eq(stats.session_epoch, 0, "stats session_epoch")
T.eq(stats.psk_mode, "hex", "stats psk_mode")
T.eq(stats.rate_enabled, false, "stats rate_enabled")
T.eq(stats.rate_buckets, 0, "stats rate_buckets")
T.eq(stats.epoch_fail, 0, "stats epoch_fail")

local too_short = HS.parse_envelope("H" .. u32(0), 16)
T.eq(too_short, nil, "parse_envelope rejects a short envelope")
local bad_magic = HS.parse_envelope("X" .. u32(0) .. u32(1) .. "ct" .. string.rep("t", 16), 16)
T.eq(bad_magic, nil, "parse_envelope rejects a bad marker")

local edge_server = make({ role = "server", session_epoch = 4 })
local counter_zero = "H" .. u32(4) .. u32(0) .. "ct" .. string.rep("t", 16)
local cz_out, cz_err = edge_server:open_request(counter_zero, "src")
T.eq(cz_out, nil, "counter 0 is refused")
T.ok(tostring(cz_err):find("counter 0", 1, true) ~= nil, "counter 0 is explained")
local counter_max = "H" .. u32(4) .. u32(0xFFFFFFFF) .. "ct" .. string.rep("t", 16)
local cm_out, cm_err = edge_server:open_request(counter_max, "src")
T.eq(cm_out, nil, "counter 2^32-1 is refused on open")
T.ok(tostring(cm_err):find("out of range", 1, true) ~= nil, "out-of-range counter is explained")

local bad_dir_client = make({ role = "client" })
T.eq(bad_dir_client:seal("x", "sideways"), nil, "bad direction is refused")
T.eq(bad_dir_client:seal(42), nil, "non-string plaintext is refused")
T.eq(bad_dir_client:open(42), nil, "non-string envelope is refused")

-- disabled instance still reports stats without opening
local disabled = HS.new({ crypto = crypto, strict = false })
T.eq(disabled.enabled, false, "disabled instance")
T.eq(disabled:open("H" .. u32(0) .. u32(1) .. "x" .. string.rep("t", 16), "c2s", "src"), nil,
    "disabled instance refuses open")
T.eq(disabled:get_stats().rate_enabled, false, "disabled instance has no rate limit")
