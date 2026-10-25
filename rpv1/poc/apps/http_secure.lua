--[[- apps/http_secure.lua - PSK envelope with the six-stage hardening pass.

Wire format (binary, one message per envelope):

    "H" | epoch(u32 BE) | counter(u32 BE) | ciphertext | tag

  * keys are derived with HKDF-SHA256 from a pre-shared key:
        master  = HKDF(psk, salt, "rpv-http-psk-v1", 32)
  * key     = HKDF(master, salt, "rpv-http-<dir>-key-v1", 32)
  * mac     = HKDF(master, salt, "rpv-http-<dir>-mac-v1", 32)
  * nonce   = HKDF(master, salt, "rpv-http-<dir>-nonce-v1", 12)
  * <dir> is c2s (client to server) or s2c (server to client), so the two
    directions never share key material.
  * ciphertext = ChaCha20(key, nonce[1..8] .. u32(counter), block 1, plaintext).
    The counter is bound into the nonce, and the ChaCha20 block counter restarts
    at 1 for each message, so no two messages share a keystream block.
  * tag = HMAC-SHA256(mac, "H" | epoch | counter | ciphertext)[1..tag_len].

Hardening stages:
  1. counter exhaustion: counters are per direction; the highest usable value is
     2^32-2 (0xFFFFFFFE). When the next counter would be 2^32-1 (0xFFFFFFFF),
     seal() returns nil,"counter exhausted" and emits no ciphertext. The counter
     is only committed after the cipher and MAC succeeded.
  2. ChaCha20 blocks: block 1..ceil(#plaintext/64) are used. Plaintext and
     ciphertext are capped at MAX_PLAINTEXT_BYTES = 60000 because one envelope is
     carried as one rpv UDP datagram (IPv4/UDP max data is 65507); the block
     count is also checked against MAX_CHACHA_BLOCKS. A conn/streaming transport
     would need to raise this cap explicitly.
  3. PSK: the default is exactly 64 hex characters (32 bytes). A passphrase is
     accepted only with allow_passphrase=true, and then PBKDF2-HMAC-SHA256 with
     psk_iter >= 4096 (default 4096) turns it into the 32-byte key material.
  4. session_epoch: the envelope carries a u32 epoch; it is part of the MAC and
     must equal the receiver's opts.session_epoch (default 0). It separates
     sessions only: it is not re-keying and not identity/authentication. Changing
     it is a breaking wire format, so both ends must be upgraded together.
  5. rate_limit: optional per-source token bucket checked BEFORE any unwrap work.
     opts.rate_limit is true/number/{rate,burst,idle_ttl,max_sources}; src_label
     is the sibling opts.src_label(src, base). Sources are normalised, buckets are
     bounded, and make_room() only recycles buckets idle for idle_ttl seconds.
     Fail-closed: missing src, a bad clock/label, or a full max_sources table
     rejects the request. Malformed/non-ASCII src normalises to "_" or "unknown",
     so several bad sources can share a bucket and be mis-accounted.
  6. seed_file: opts.seed_file defaults to seed.bin in the directory of
     opts.role_file (role.txt by default). It is passed to
     crypto.load_seed_file(); a missing file leaves seed_loaded=false and never
     blocks construction. stats.seed_loaded reports the result. The current code
     only strengthens the crypto DRBG: it does not change HKDF keys or the
     counter start (counter begins at 1).

Replay protection is per direction: a counter must be positive, and the receiver
keeps a sliding window (default 64 entries). strict=true (default) also requires
counters to increase, because HTTP is an ordered transport; strict=false accepts
out-of-order envelopes inside the window (datagram-like transports), while
duplicates and entries older than the window are still rejected.

strict=true fails closed: a missing/short PSK is a construction error, malformed
envelopes are rejected, and a disabled instance refuses to seal or open. With
strict=false a missing PSK returns a disabled instance instead of an error.

This module uses the primitives of rpv/crypto.lua and adds no cryptography: the
only code here is framing, key derivation calls, the replay window and the
token bucket.
]]
local M = {}

M.MAGIC = "H"
M.DEFAULT_TAG_LEN = 16
M.MIN_TAG_LEN = 8
M.MAX_TAG_LEN = 32
M.DEFAULT_WINDOW = 64
M.MAX_WINDOW = 1024

M.MAX_COUNTER = 0xFFFFFFFE          -- highest usable per-direction counter
M.MAX_CHACHA_BLOCKS = 0xFFFFFFFF    -- 32-bit ChaCha20 block counter ceiling
-- This app layer carries one envelope per rpv UDP datagram (http_server's
-- transport callback is datagram shaped; conn.lua streaming is not used here).
-- IPv4/UDP tops out at 65507 bytes of UDP data (65535 - 20 IP - 8 UDP), so
-- 60000 leaves room for magic + epoch + counter + tag. A future conn/streaming
-- secure transport can raise this with its own limit.
M.MAX_PLAINTEXT_BYTES = 60000

M.PSK_HEX_LEN = 64
M.DEFAULT_PSK_ITER = 4096
M.MIN_PSK_ITER = 4096
M.MAX_PSK_ITER = 1000000
M.PASSPHRASE_SALT = "rpv-http-passphrase-v1"

M.MAX_SRC_LEN = 64
M.DEFAULT_RATE = 50
M.DEFAULT_BURST = 100
M.DEFAULT_IDLE_TTL = 300
M.DEFAULT_MAX_SOURCES = 1024
M.MAX_BURST = 1000000
M.MAX_SOURCES = 1000000

local U32_MAX = 0xFFFFFFFF

local cached_crypto
local function get_crypto()
    if cached_crypto then return cached_crypto end
    for _, path in ipairs({ "rpv/crypto.lua", "crypto.lua", "apps/crypto.lua" }) do
        local chunk = loadfile(path)
        if chunk then
            local ok, mod = pcall(chunk, {})
            if ok and type(mod) == "table" and type(mod.hkdf_sha256) == "function" then
                cached_crypto = mod
                return mod
            end
        end
    end
    return nil
end

local function u32be(v)
    v = math.floor(v)
    return string.char(
        math.floor(v / 0x1000000) % 256,
        math.floor(v / 0x10000) % 256,
        math.floor(v / 0x100) % 256,
        v % 256)
end

local function r32be(s, i)
    return s:byte(i) * 0x1000000 + s:byte(i + 1) * 0x10000 + s:byte(i + 2) * 0x100 + s:byte(i + 3)
end

local function block_count(n)
    return math.ceil(n / 64)
end

-- ===== source labels ======================================================
-- Normalise a peer address into a bounded ASCII bucket label. Tables can carry
-- ip/host/label/id, strings may include a port, and everything else is folded
-- into a safe ASCII form. An absent source becomes "unknown"; callers that want
-- fail-closed behaviour reject a nil source before calling this.
function M.normalize_src(src)
    local label
    if type(src) == "table" then
        label = src.ip or src.host or src.label or src.id
    else
        label = src
    end
    if label == nil then return "unknown" end
    label = tostring(label)
    label = (label:gsub("^%s+", ""):gsub("%s+$", ""))

    local host = label:match("^([%w%.%-]+):%d+$")
    if host then
        label = host
    elseif label:sub(1, 1) == "[" then
        local close = label:find("]", 1, true)
        if close and label:sub(close + 1):match("^:%d+$") then
            label = label:sub(1, close)
        end
    end

    local out = {}
    for i = 1, #label do
        local b = label:byte(i)
        local keep = (b >= 48 and b <= 57) or (b >= 97 and b <= 122)
            or b == 46 or b == 95 or b == 58 or b == 45 or b == 91 or b == 93
        if b >= 65 and b <= 90 then
            b = b + 32
            keep = true
        end
        out[i] = keep and string.char(b) or "_"
    end
    label = table.concat(out)
    if label == "" then label = "unknown" end
    if #label > M.MAX_SRC_LEN then label = label:sub(1, M.MAX_SRC_LEN) end
    return label
end

-- ===== rate-limit configuration ==========================================
local function parse_rate_limit(spec)
    if spec == nil or spec == false then return nil, nil end
    local cfg
    if spec == true then
        cfg = {}
    elseif type(spec) == "number" then
        cfg = { rate = spec, burst = math.max(1, math.floor(spec)) }
    elseif type(spec) == "table" then
        cfg = spec
    else
        return nil, "rate_limit must be true, a number or a table"
    end

    local rate = tonumber(cfg.rate) or M.DEFAULT_RATE
    local burst = tonumber(cfg.burst) or M.DEFAULT_BURST
    local idle = tonumber(cfg.idle_ttl) or M.DEFAULT_IDLE_TTL
    local max_sources = tonumber(cfg.max_sources) or M.DEFAULT_MAX_SOURCES

    if rate <= 0 then return nil, "rate_limit.rate must be > 0" end
    if burst < 1 or burst > M.MAX_BURST then return nil, "rate_limit.burst out of range" end
    if idle <= 0 then return nil, "rate_limit.idle_ttl must be > 0" end
    if max_sources < 1 or max_sources > M.MAX_SOURCES then
        return nil, "rate_limit.max_sources out of range"
    end
    return {
        rate = rate,
        burst = math.floor(burst),
        idle_ttl = idle,
        max_sources = math.floor(max_sources),
        buckets = {},
        count = 0,
    }, nil
end

local function default_clock()
    if os and os.epoch then
        local ok, ms = pcall(os.epoch, "utc")
        if ok and type(ms) == "number" then return ms / 1000 end
    end
    return os.clock()
end

-- ===== PSK ================================================================
local function resolve_psk(opts, crypto)
    local psk = opts.psk
    if type(psk) ~= "string" or psk == "" then return nil, nil, nil, "empty PSK" end

    if #psk == M.PSK_HEX_LEN and psk:match("^[0-9a-fA-F]+$") then
        return crypto.unhex(psk), "hex", nil, nil
    end

    if opts.allow_passphrase ~= true then
        return nil, nil, nil,
            "PSK must be 64 hex chars (set allow_passphrase=true for a passphrase)"
    end
    local iter = tonumber(opts.psk_iter) or M.DEFAULT_PSK_ITER
    if iter < M.MIN_PSK_ITER then return nil, nil, nil, "psk_iter must be >= 4096" end
    if iter > M.MAX_PSK_ITER then return nil, nil, nil, "psk_iter is too large" end
    if iter ~= math.floor(iter) then return nil, nil, nil, "psk_iter must be an integer" end

    local salt = M.PASSPHRASE_SALT .. "|" .. tostring(opts.salt or "")
    local ok, raw = pcall(crypto.pbkdf2_sha256, psk, salt, iter, 32, 64)
    if not ok then return nil, nil, nil, "pbkdf2: " .. tostring(raw) end
    return raw, "passphrase", iter, nil
end

local function derive_dir(crypto, master, salt, dir, tag_len, window)
    return {
        dir = dir,
        key = crypto.hkdf_sha256(master, salt, "rpv-http-" .. dir .. "-key-v1", 32),
        mac = crypto.hkdf_sha256(master, salt, "rpv-http-" .. dir .. "-mac-v1", 32),
        nonce = crypto.hkdf_sha256(master, salt, "rpv-http-" .. dir .. "-nonce-v1", 12),
        tag_len = tag_len,
        window = window,
        tx = 0,
        rx_top = 0,
        seen = {},
        rx = 0,
        auth_fail = 0,
        replay = 0,
        malformed = 0,
    }
end

local Secure = {}
Secure.__index = Secure

local function direction_of(self, dir)
    if dir == "c2s" or dir == "s2c" then return self.dir[dir] end
    return nil
end

local function window_check(self, state, counter)
    if counter < 1 then return false, "counter 0" end
    if state.rx_top == 0 then
        state.rx_top = counter
        state.seen[counter] = true
        return true
    end
    if counter > state.rx_top then
        state.rx_top = counter
        state.seen[counter] = true
        local cutoff = state.rx_top - state.window
        for c in pairs(state.seen) do
            if c <= cutoff then state.seen[c] = nil end
        end
        return true
    end
    -- strict mode follows the ordered transport and never accepts a rewind
    if self.strict then return false, "replayed counter" end
    if counter <= state.rx_top - state.window then return false, "stale counter" end
    if state.seen[counter] then return false, "replayed counter" end
    state.seen[counter] = true
    return true
end

-- ===== rate limit =========================================================
function Secure:_now()
    local ok, value = pcall(self.clock)
    if not ok or type(value) ~= "number" or value ~= value or value < 0 then
        return nil, "rate clock unavailable"
    end
    return value
end

function Secure:label_for(src)
    if src == nil then return nil, "missing src" end
    local base = M.normalize_src(src)
    local fn = self.src_label_fn
    if type(fn) == "function" then
        local ok, value = pcall(fn, src, base)
        if not ok then return nil, "src_label failed" end
        if type(value) ~= "string" then return nil, "src_label must return a string" end
        base = M.normalize_src(value)
    end
    return base
end

function Secure:make_room(now)
    if not self.rate then return 0 end
    if now == nil then
        local value = self:_now()
        if value == nil then return 0 end
        now = value
    end
    local freed = 0
    for label, bucket in pairs(self.rate.buckets) do
        if now - bucket.last >= self.rate.idle_ttl then
            self.rate.buckets[label] = nil
            self.rate.count = self.rate.count - 1
            freed = freed + 1
        end
    end
    self.stats.rate_recycled = self.stats.rate_recycled + freed
    return freed
end

-- Returns true, or false + reason (+ retry_after seconds). Called before any
-- envelope parsing/authentication; see Secure:open.
function Secure:allow(src)
    if not self.rate then return true end
    local now = self:_now()
    if now == nil then return false, "rate clock unavailable" end

    local label, lerr = self:label_for(src)
    if not label then return false, lerr end

    local bucket = self.rate.buckets[label]
    if not bucket then
        if self.rate.count >= self.rate.max_sources then
            self:make_room(now)
            if self.rate.count >= self.rate.max_sources then
                self.stats.rate_limited = self.stats.rate_limited + 1
                return false, "rate bucket limit"
            end
        end
        bucket = { tokens = self.rate.burst, last = now }
        self.rate.buckets[label] = bucket
        self.rate.count = self.rate.count + 1
    end

    local elapsed = now - bucket.last
    if elapsed < 0 then elapsed = 0 end
    bucket.tokens = math.min(self.rate.burst, bucket.tokens + elapsed * self.rate.rate)
    bucket.last = now

    if bucket.tokens + 1e-9 >= 1 then
        bucket.tokens = bucket.tokens - 1
        self.stats.rate_allowed = self.stats.rate_allowed + 1
        return true
    end

    self.stats.rate_limited = self.stats.rate_limited + 1
    return false, "rate limited", (1 - bucket.tokens) / self.rate.rate
end

function Secure:rate_snapshot()
    local out = {}
    if not self.rate then return out end
    for label, bucket in pairs(self.rate.buckets) do
        out[label] = { tokens = bucket.tokens, last = bucket.last }
    end
    return out
end

-- ===== seal / open ========================================================
function Secure:seal(plaintext, dir)
    if not self.enabled then return nil, "secure transport disabled" end
    if type(plaintext) ~= "string" then return nil, "plaintext must be a string" end
    local state = direction_of(self, dir or self.send_dir)
    if not state then return nil, "bad direction" end

    if #plaintext > M.MAX_PLAINTEXT_BYTES then
        return nil, "plaintext too large"
    end
    if block_count(#plaintext) > M.MAX_CHACHA_BLOCKS then
        return nil, "chacha block count overflow"
    end
    if state.tx >= M.MAX_COUNTER then
        return nil, "counter exhausted"
    end

    local counter = state.tx + 1
    -- the counter starts at 1 (derive_dir initialises tx to 0); clamp a
    -- corrupted/negative tx instead of ever emitting counter 0
    if counter < 1 then counter = 1 end
    local nonce = state.nonce:sub(1, 8) .. u32be(counter)
    local ok, ct = pcall(self.crypto.chacha20_xor, state.key, nonce, 1, plaintext)
    if not ok then return nil, "cipher: " .. tostring(ct) end
    local body = M.MAGIC .. u32be(self.session_epoch) .. u32be(counter) .. ct
    local hok, tag = pcall(self.crypto.hmac_sha256, state.mac, body)
    if not hok then return nil, "mac: " .. tostring(tag) end
    tag = tag:sub(1, state.tag_len)

    state.tx = counter
    self.stats.tx = self.stats.tx + 1
    return body .. tag
end

function Secure:open(envelope, dir, src)
    if not self.enabled then return nil, "secure transport disabled" end
    if type(envelope) ~= "string" then return nil, "envelope must be a string" end
    local state = direction_of(self, dir or self.recv_dir)
    if not state then return nil, "bad direction" end

    -- stage 5: the bucket is consulted before length/magic/MAC/decrypt work
    if self.rate then
        local allowed, why = self:allow(src)
        if not allowed then return nil, "rate limited: " .. tostring(why) end
    end

    local min_len = 9 + state.tag_len
    if #envelope < min_len then
        state.malformed = state.malformed + 1
        self.stats.malformed = self.stats.malformed + 1
        return nil, "envelope too short"
    end
    if envelope:sub(1, 1) ~= M.MAGIC then
        state.malformed = state.malformed + 1
        self.stats.malformed = self.stats.malformed + 1
        return nil, "bad magic"
    end

    local epoch = r32be(envelope, 2)
    local counter = r32be(envelope, 6)
    if epoch ~= self.session_epoch then
        state.malformed = state.malformed + 1
        self.stats.malformed = self.stats.malformed + 1
        self.stats.epoch_fail = self.stats.epoch_fail + 1
        return nil, "session epoch mismatch"
    end
    if counter == 0 then
        state.malformed = state.malformed + 1
        self.stats.malformed = self.stats.malformed + 1
        return nil, "counter 0"
    end
    if counter > M.MAX_COUNTER then
        state.malformed = state.malformed + 1
        self.stats.malformed = self.stats.malformed + 1
        return nil, "counter out of range"
    end

    local tag_at = #envelope - state.tag_len + 1
    local ct = envelope:sub(10, tag_at - 1)
    local tag = envelope:sub(tag_at)
    if #ct > M.MAX_PLAINTEXT_BYTES then
        state.malformed = state.malformed + 1
        self.stats.malformed = self.stats.malformed + 1
        return nil, "ciphertext too large"
    end
    if block_count(#ct) > M.MAX_CHACHA_BLOCKS then
        state.malformed = state.malformed + 1
        self.stats.malformed = self.stats.malformed + 1
        return nil, "chacha block count overflow"
    end

    local body = M.MAGIC .. u32be(epoch) .. u32be(counter) .. ct
    local hok, expect = pcall(self.crypto.hmac_sha256, state.mac, body)
    if not hok then return nil, "mac: " .. tostring(expect) end
    expect = expect:sub(1, state.tag_len)
    if not self.crypto.equals(expect, tag) then
        state.auth_fail = state.auth_fail + 1
        self.stats.auth_fail = self.stats.auth_fail + 1
        return nil, "authentication failed"
    end

    local accepted, why = window_check(self, state, counter)
    if not accepted then
        state.replay = state.replay + 1
        self.stats.replay = self.stats.replay + 1
        return nil, why
    end

    local nonce = state.nonce:sub(1, 8) .. u32be(counter)
    local ok, plain = pcall(self.crypto.chacha20_xor, state.key, nonce, 1, ct)
    if not ok then return nil, "cipher: " .. tostring(plain) end

    state.rx = state.rx + 1
    self.stats.rx = self.stats.rx + 1
    return plain
end

function Secure:seal_request(plaintext)
    return self:seal(plaintext, "c2s")
end

function Secure:open_request(envelope, src)
    return self:open(envelope, "c2s", src)
end

function Secure:seal_response(plaintext)
    return self:seal(plaintext, "s2c")
end

function Secure:open_response(envelope, src)
    return self:open(envelope, "s2c", src)
end

function Secure:get_stats()
    local dirs = {}
    for name, state in pairs(self.dir) do
        dirs[name] = {
            tx = state.tx,
            rx = state.rx,
            rx_top = state.rx_top,
            auth_fail = state.auth_fail,
            replay = state.replay,
            malformed = state.malformed,
        }
    end
    return {
        enabled = self.enabled,
        strict = self.strict,
        tag_len = self.tag_len,
        window = self.window,
        salt = self.salt,
        session_epoch = self.session_epoch,
        psk_mode = self.psk_mode,
        psk_iter = self.psk_iter,
        seed_loaded = self.seed_loaded,
        rate_enabled = self.rate ~= nil,
        rate_limited = self.stats.rate_limited,
        rate_allowed = self.stats.rate_allowed,
        rate_recycled = self.stats.rate_recycled,
        rate_buckets = self.rate and self.rate.count or 0,
        tx = self.stats.tx,
        rx = self.stats.rx,
        auth_fail = self.stats.auth_fail,
        replay = self.stats.replay,
        malformed = self.stats.malformed,
        epoch_fail = self.stats.epoch_fail,
        dirs = dirs,
    }
end

function M.parse_envelope(envelope, tag_len)
    if type(envelope) ~= "string" then return nil, "envelope must be a string" end
    tag_len = tonumber(tag_len) or M.DEFAULT_TAG_LEN
    if #envelope < 9 + tag_len then return nil, "envelope too short" end
    if envelope:sub(1, 1) ~= M.MAGIC then return nil, "bad magic" end
    local epoch = r32be(envelope, 2)
    local counter = r32be(envelope, 6)
    local tag_at = #envelope - tag_len + 1
    return {
        epoch = epoch,
        counter = counter,
        ciphertext = envelope:sub(10, tag_at - 1),
        tag = envelope:sub(tag_at),
    }
end

function M.new(opts)
    local opts = opts or {}
    local crypto = opts.crypto or get_crypto()
    if not crypto then return nil, "crypto module not found" end

    local strict = opts.strict ~= false
    local role = opts.role or "client"
    if role ~= "client" and role ~= "server" then return nil, "bad role" end

    local tag_len = tonumber(opts.tag_len) or M.DEFAULT_TAG_LEN
    if tag_len < M.MIN_TAG_LEN or tag_len > M.MAX_TAG_LEN then
        return nil, "tag_len must be between 8 and 32"
    end
    local window = tonumber(opts.window) or M.DEFAULT_WINDOW
    if window < 1 or window > M.MAX_WINDOW then return nil, "bad replay window" end
    local salt = tostring(opts.salt or "")

    local epoch = opts.session_epoch
    if epoch == nil then
        epoch = 0
    else
        epoch = tonumber(epoch)
    end
    if not epoch or epoch < 0 or epoch > U32_MAX or epoch ~= math.floor(epoch) then
        return nil, "session_epoch must be an integer in 0..2^32-1"
    end

    local rate, rerr = parse_rate_limit(opts.rate_limit)
    if rerr then return nil, rerr end

    local seed_loaded = false
    local role_file = tostring(opts.role_file or "role.txt")
    local seed_dir = role_file:match("^(.*[/\\])") or ""
    local seed_file = opts.seed_file
    if seed_file == nil or seed_file == "" then seed_file = seed_dir .. "seed.bin" end
    if seed_file ~= false then
        local ok, loaded = pcall(crypto.load_seed_file, seed_file)
        seed_loaded = ok and loaded == true
    end

    local self = setmetatable({
        crypto = crypto,
        strict = strict,
        role = role,
        tag_len = tag_len,
        window = window,
        salt = salt,
        session_epoch = epoch,
        send_dir = (role == "server") and "s2c" or "c2s",
        recv_dir = (role == "server") and "c2s" or "s2c",
        dir = {},
        rate = rate,
        clock = opts.clock or default_clock,
        src_label_fn = opts.src_label,
        seed_file = seed_file,
        seed_loaded = seed_loaded,
        stats = {
            tx = 0, rx = 0, auth_fail = 0, replay = 0, malformed = 0,
            epoch_fail = 0, rate_limited = 0, rate_allowed = 0, rate_recycled = 0,
        },
        enabled = false,
    }, Secure)
    self.stats.seed_loaded = seed_loaded

    if opts.psk == nil or opts.psk == "" then
        if strict then return nil, "PSK is required in strict mode" end
        self:_log(opts, "disabled without a PSK (strict=false)")
        return self
    end

    local raw, mode, iter, perr = resolve_psk(opts, crypto)
    if not raw then return nil, perr end
    self.psk_mode = mode
    self.psk_iter = iter

    local master = crypto.hkdf_sha256(raw, salt, "rpv-http-psk-v1", 32)
    self.dir.c2s = derive_dir(crypto, master, salt, "c2s", tag_len, window)
    self.dir.s2c = derive_dir(crypto, master, salt, "s2c", tag_len, window)
    self.enabled = true
    self:_log(opts, "enabled role=" .. role .. " epoch=" .. tostring(epoch)
        .. " tag=" .. tag_len .. " window=" .. window)
    return self
end

function Secure:_log(opts, message)
    if type(opts.log) == "function" then pcall(opts.log, message) end
end

return M
