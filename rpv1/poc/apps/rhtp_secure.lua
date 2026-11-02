--[[- pyroet-os/net/rhtp_secure.lua -- PSK-sealed RHTP response envelope.

RHTP is the project's stateless datagram HTTP-alike (rpv1 apps/rhtp_server.lua
is the reference server): one request datagram in, one response datagram out,
no connection, no persistent counter between messages. This module reuses the
exact design of rpv1's http_secure (HKDF key tree over a pre-shared key,
ChaCha20 for secrecy, HMAC-SHA256 truncated to 16 bytes for integrity) but
adapts it to RHTP's stateless single-request/single-response shape.

The deliberate deviation from http_secure is documented here because it is
load-bearing: http_secure binds a *monotonic per-direction counter* into the
nonce and keeps a replay window on the receiver. RHTP has no session to hang a
counter on -- a request and its response are one exchange and nothing about the
client or server identity survives to the next request. Instead of a counter,
the integrity envelope is bound to a *per-request random 8-byte nonce* that the
client generates, hands to the server, and the server echoes back. Replay of a
stale response therefore fails the MAC (the echoed nonce no longer matches the
request), and there is no counter state to exhaust or drift between the two
ends. The price is that the request AND the response each carry the nonce (16
hex chars), so an eavesdropper sees it -- but a nonce is not a secret, and the
confidentiality still comes entirely from ChaCha20 under the PSK-derived key.

Key tree (TLS-style HKDF, all with salt = "", matching http_secure):

    master     = HKDF(psk, "", "rhtp-psk-v1", 32)
    key        = HKDF(master, "", "rhtp-s2c-key-v1", 32)
    mac        = HKDF(master, "", "rhtp-s2c-mac-v1", 32)
    nonce_base = HKDF(master, "", "rhtp-s2c-nonce-v1", 12)

Wrapping the pair [key, nonce_base] with the 8-byte per-request nonce gives a
12-byte ChaCha20 nonce: nonce_input = nonce_base[1..4] .. bin_nonce. The
ChaCha20 block counter restarts at 1 for every message, and reverse
engineering / forward secrecy is the same as http_secure: nothing here adds new
cryptography, only framing + HKDF calls.

Note on the nonce size: the spec's literal `nonce_base[1..8] .. bin_nonce`
would be 16 bytes, but ChaCha20 accepts exactly 12. We keep the FULL 8-byte
per-request nonce in the cipher nonce (it is what makes every message unique)
and take only the first 4 bytes of the derived base as PSK-domain separation,
so the 12-byte requirement is satisfied without discarding per-request entropy.

Server envelope, written into the response body (never the status block):

    ct       = ChaCha20(key, nonce_input, 1, body)      body may be ""
    status   = "RHTP/1.0 <code> <reason>"                the literal first line
    auth     = bin_nonce .. ct .. status                 bound into the tag
    tag      = HMAC-SHA256(mac, auth)[1..16]
    response = "RHTP/1.0 <code> <reason>\r\nRhtp-Seal: v1 <nonce16> 16 <tag32>\r\n\r\n" .. ct

`S:seal(code, reason, body, bin_nonce)` returns that whole text. The auth
binding includes bin_nonce AND the status line, so neither a swapped nonce nor
an edited status (e.g. "200 OK" turned into "404") survives the MAC.

`S:open(text, bin_nonce)`:

    * no "Rhtp-Seal" header  -> nil, "plain"    (not a sealed response at all)
    * echoed nonce != bin_nonce, or MAC mismatch -> nil, "seal bad" (fail closed)
    * otherwise -> code, decrypted_body        (ct may be "", so body may be "")

`S.new{psk_hex=, crypto=, nonce_base=}`: psk_hex must be exactly 64 hex chars
(32 bytes) else nil, "bad psk". `crypto` is injected (any table exposing the
rpv subset: hkdf_sha256 / chacha20_xor / hmac_sha256 / hex / unhex / equals);
when absent it is loaded lazily from /system/rpv/crypto.lua. `nonce_base` lets a
test pin the derived nonce base; when absent it is derived from the PSK. The
module is pure: it performs no IO at construction, and the crypto loader is the
only file access anywhere.

No non-ASCII bytes in this file.
]]

local S = {}
S.VERSION = "1.0"
S.DEFAULT_CRYPTO_PATH = "/system/rpv/crypto.lua"
S.CRYPTO_FALLBACKS = { "/system/rpv/crypto.lua", "system/rpv/crypto.lua", "rpv/crypto.lua" }
S.PSK_HEX_LEN = 64
S.NONCE_LEN = 8
S.TAG_LEN = 16
S.SEAL_HEADER = "Rhtp-Seal"
S.SEAL_PREFIX = "v1"

local function is_hex64(s)
    return type(s) == "string"
        and #s == S.PSK_HEX_LEN
        and s:match("^[0-9a-fA-F]+$") ~= nil
end

-- load the rpv crypto subset lazily; never throws
local cached_crypto
local function get_crypto()
    if cached_crypto then return cached_crypto end
    for i = 1, #S.CRYPTO_FALLBACKS do
        local path = S.CRYPTO_FALLBACKS[i]
        local loaded, chunk = pcall(loadfile, path)
        if loaded and type(chunk) == "function" then
            local ok, mod = pcall(chunk, {})
            if ok and type(mod) == "table" and type(mod.hkdf_sha256) == "function" then
                cached_crypto = mod
                return mod
            end
        end
    end
    return nil
end

function S.new(o)
    local opts = o or {}
    local crypto = opts.crypto
    if not crypto then
        if type(get_crypto) == "function" then crypto = get_crypto() end
    end
    if type(crypto) ~= "table" or type(crypto.hkdf_sha256) ~= "function" then
        return nil, "no crypto"
    end
    local psk_hex = tostring(opts.psk_hex or "")
    if not is_hex64(psk_hex) then return nil, "bad psk" end
    local psk = crypto.unhex(psk_hex:lower())
    local master = crypto.hkdf_sha256(psk, "", "rhtp-psk-v1", 32)
    local self = setmetatable({}, { __index = S })
    self.crypto = crypto
    self.key = crypto.hkdf_sha256(master, "", "rhtp-s2c-key-v1", 32)
    self.mac = crypto.hkdf_sha256(master, "", "rhtp-s2c-mac-v1", 32)
    self.nonce_base = opts.nonce_base
        or crypto.hkdf_sha256(master, "", "rhtp-s2c-nonce-v1", 12)
    return self
end

-- the per-message ChaCha20 nonce: 4 bytes of the derived base (PSK domain
-- separation) plus the caller's full 8-byte single-request nonce -> 12 bytes
function S:nonce_of(bin_nonce)
    return self.nonce_base:sub(1, 4) .. tostring(bin_nonce or "")
end

-- Server -> client. Returns the full sealed response text (status line +
-- Rhtp-Seal header + ciphertext body). body may be "".
function S:seal(code, reason, body, bin_nonce)
    local plain = type(body) == "string" and body or ""
    local status_line = "RHTP/1.0 " .. tostring(code) .. " " .. tostring(reason)
    local bn = tostring(bin_nonce or "")
    if #bn ~= S.NONCE_LEN then return nil, "bad nonce" end
    local nonce = self:nonce_of(bn)
    local ok, ct = pcall(self.crypto.chacha20_xor, self.key, nonce, 1, plain)
    if not ok then return nil, "cipher: " .. tostring(ct) end
    local auth = bn .. ct .. status_line
    local hok, tag = pcall(self.crypto.hmac_sha256, self.mac, auth)
    if not hok then return nil, "mac: " .. tostring(tag) end
    tag = tag:sub(1, S.TAG_LEN)
    return status_line
        .. "\r\n" .. S.SEAL_HEADER .. ": " .. S.SEAL_PREFIX .. " "
        .. self.crypto.hex(bn) .. " " .. tostring(S.TAG_LEN) .. " "
        .. self.crypto.hex(tag)
        .. "\r\n\r\n" .. ct
end

-- Client <- server. Given the response text and the same request nonce the
-- server echoed, return code, decrypted_body; or nil, reason on any failure
-- (fail closed). `plain` for unscaled responses and `seal bad` on a mismatch.
function S:open(text, bin_nonce)
    if type(text) ~= "string" then return nil, "bad response" end
    local head, body = text:match("^(.-)\r?\n\r?\n(.*)$")
    if head == nil then return nil, "bad response" end
    local first = head:match("^([^\r\n]*)") or ""
    local version, code = first:match("^RHTP/(%d+%.%d+) (%d%d%d)")
    if not version or version ~= "1.0" then return nil, "bad response" end
    local bn = tostring(bin_nonce or "")
    if #bn ~= S.NONCE_LEN then return nil, "seal bad" end
    -- find the Rhtp-Seal header across the whole head block (case-insensitive)
    local seal_value = nil
    for line in (head .. "\n"):gmatch("([^\n]*)\n") do
        if line ~= first then
            local key, value = line:match("^([%w%-]+):[ \t]*(.*)$")
            if key and key:lower() == S.SEAL_HEADER:lower() then seal_value = value end
        end
    end
    if seal_value == nil then return nil, "plain" end
    local prefix, nonce_hex, tag_len, tag_hex = seal_value:match("^%s*(%S+)%s+(%x+)%s+(%d+)%s+(%x+)%s*$")
    if prefix ~= S.SEAL_PREFIX then return nil, "seal bad" end
    if tostring(nonce_hex):lower() ~= self.crypto.hex(bn) then return nil, "seal bad" end
    if tonumber(tag_len) ~= S.TAG_LEN then return nil, "seal bad" end
    local expect = self.crypto.unhex(tag_hex:lower())
    if #expect ~= S.TAG_LEN then return nil, "seal bad" end
    local ct = tostring(body or "")
    local auth = bn .. ct .. first
    local hok, tag = pcall(self.crypto.hmac_sha256, self.mac, auth)
    if not hok then return nil, "seal bad" end
    tag = tag:sub(1, S.TAG_LEN)
    if not self.crypto.equals(tag, expect) then return nil, "seal bad" end
    local nonce = self:nonce_of(bn)
    local dok, plain = pcall(self.crypto.chacha20_xor, self.key, nonce, 1, ct)
    if not dok then return nil, "seal bad" end
    return tonumber(code), plain
end

return S