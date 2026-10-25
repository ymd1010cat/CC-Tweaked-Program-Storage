--[[- tests/t_http_secure.lua - envelope, direction keys and replay window (offline).]]
local T, M = ...

local HS = M.http_secure
local crypto = M
T.ok(HS ~= nil and type(crypto.hkdf_sha256) == "function", "http_secure and crypto modules loaded")
if not HS or not crypto then return end

local PSK = "00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff"

local function make(role, opts)
    local o = { psk = PSK, crypto = crypto, salt = "unit-test", role = role }
    for k, v in pairs(opts or {}) do o[k] = v end
    return HS.new(o)
end

local client, cerr = make("client")
local server, serr = make("server")
T.ok(client ~= nil and server ~= nil, "client and server instances are created")
T.eq(cerr, nil, "client constructor has no error")
T.eq(serr, nil, "server constructor has no error")
T.ok(client.enabled, "client is enabled with a PSK")
T.ok(server.enabled, "server is enabled with a PSK")
T.eq(client.tag_len, 16, "default tag length")
T.eq(client.window, 64, "default replay window")
T.eq(client.session_epoch, 0, "default session epoch")
T.eq(client.send_dir, "c2s", "client sends client-to-server")
T.eq(client.recv_dir, "s2c", "client receives server-to-client")
T.eq(server.send_dir, "s2c", "server sends server-to-client")
T.eq(server.recv_dir, "c2s", "server receives client-to-server")

-- both ends derive the same per-direction keys, and the directions differ
T.eq(client.dir.c2s.key, server.dir.c2s.key, "c2s key matches on both ends")
T.eq(client.dir.s2c.key, server.dir.s2c.key, "s2c key matches on both ends")
T.ok(client.dir.c2s.key ~= client.dir.s2c.key, "c2s and s2c keys differ")
T.ok(client.dir.c2s.mac ~= client.dir.s2c.mac, "c2s and s2c MAC keys differ")
T.ok(client.dir.c2s.nonce ~= client.dir.s2c.nonce, "c2s and s2c nonces differ")

-- ===== envelope shape and round trip ======================================
local pt = "GET /status HTTP/1.1\r\nHost: box\r\n\r\n"
local env = client:seal_request(pt)
T.ok(type(env) == "string", "seal_request returns a string")
T.eq(env:sub(1, 1), "H", "envelope starts with the H marker")
T.eq(#env, 1 + 4 + 4 + #pt + 16, "envelope is marker + epoch + counter + ct + tag")
T.ok(env:sub(2, 5) == string.char(0, 0, 0, 0), "default epoch is u32 BE 0")
T.ok(env:sub(6, 9) == string.char(0, 0, 0, 1), "first counter is u32 BE 1")
T.ok(not env:find("GET", 1, true), "plaintext is not visible")
T.ok(not env:find("Host", 1, true), "headers are not visible")

local info = HS.parse_envelope(env, 16)
T.ok(info ~= nil, "envelope parses")
T.eq(info.epoch, 0, "parsed epoch")
T.eq(info.counter, 1, "parsed counter")
T.eq(#info.ciphertext, #pt, "ciphertext length matches plaintext")
T.eq(#info.tag, 16, "tag length matches tag_len")

local plain = server:open_request(env)
T.eq(plain, pt, "server opens the client request")
T.eq(server:get_stats().rx, 1, "receive counter increments")

local env2 = client:seal_request("second")
info = HS.parse_envelope(env2, 16)
T.eq(info.counter, 2, "counter increments per envelope")
T.eq(server:open_request(env2), "second", "second request opens")

-- ===== replay / tamper / direction ========================================
T.eq(server:open_request(env), nil, "replayed envelope rejected")
T.ok(server:get_stats().replay >= 1, "replay is counted")

local env3 = client:seal_request("tamper-target")
local bad_tag = env3:sub(1, #env3 - 1) .. string.char((env3:byte(#env3) + 1) % 256)
T.eq(server:open_request(bad_tag), nil, "tampered tag rejected")
T.ok(server:get_stats().auth_fail >= 1, "authentication failure is counted")

local bad_ct = env3:sub(1, 9) .. string.char((env3:byte(10) + 1) % 256) .. env3:sub(11)
T.eq(server:open_request(bad_ct), nil, "tampered ciphertext rejected")

T.eq(server:open_response(env3), nil, "c2s envelope is not valid as s2c")
T.ok(server:get_stats().auth_fail >= 2, "direction mismatch is an auth failure")

local resp = server:seal_response("HTTP/1.1 200 OK\r\n\r\n")
T.eq(resp:sub(1, 1), "H", "sealed response has the marker")
T.eq(client:open_response(resp), "HTTP/1.1 200 OK\r\n\r\n", "client opens the response")
T.eq(client:open_request(resp), nil, "s2c envelope is not valid as c2s")

-- ===== strict ordering vs sliding window =================================
local strict_client = make("client", { strict = true })
local strict_server = make("server", { strict = true })
local s1 = strict_client:seal_request("one")
local s2 = strict_client:seal_request("two")
T.eq(strict_server:open_request(s2), "two", "strict mode accepts the next counter")
T.eq(strict_server:open_request(s1), nil, "strict mode rejects a rewind")
T.ok(strict_server:get_stats().replay >= 1, "strict rewind is counted as replay")

local loose_client = make("client", { strict = false })
local loose_server = make("server", { strict = false })
local l1 = loose_client:seal_request("one")
local l2 = loose_client:seal_request("two")
T.eq(loose_server:open_request(l2), "two", "non-strict accepts a forward jump")
T.eq(loose_server:open_request(l1), "one", "non-strict accepts an in-window reorder")
T.eq(loose_server:open_request(l1), nil, "non-strict still rejects duplicates")

-- counters older than the window are stale even in non-strict mode
local old = {}
for i = 1, 66 do old[i] = loose_client:seal_request("m" .. i) end
local stale_server = make("server", { strict = false })
T.eq(stale_server:open_request(old[66]), "m66", "window test opens the newest counter")
T.eq(stale_server:open_request(old[1]), nil, "counter older than the window is stale")
T.eq(stale_server:open_request(old[2]), nil, "window boundary (top-window) is stale")
T.eq(stale_server:open_request(old[3]), "m3", "counter just inside the window is accepted")

-- ===== PSK / option handling ==============================================
local missing, missing_err = HS.new({ crypto = crypto, strict = true })
T.eq(missing, nil, "strict mode without a PSK is an error")
T.ok(missing_err ~= nil, "missing PSK has an error message")

local disabled = HS.new({ crypto = crypto, strict = false })
T.ok(disabled ~= nil, "non-strict mode without a PSK returns an instance")
T.eq(disabled.enabled, false, "missing PSK disables the instance")
T.eq(disabled:seal("x"), nil, "disabled instance cannot seal")
T.eq(disabled:open("Hxxxx"), nil, "disabled instance cannot open")

local bad_tag_len = HS.new({ psk = PSK, crypto = crypto, tag_len = 4 })
T.eq(bad_tag_len, nil, "short tag length rejected")
bad_tag_len = HS.new({ psk = PSK, crypto = crypto, tag_len = 64 })
T.eq(bad_tag_len, nil, "long tag length rejected")

local bad_role = HS.new({ psk = PSK, crypto = crypto, role = "peer" })
T.eq(bad_role, nil, "invalid role rejected")

-- a literal passphrase works too, and a different PSK/salt fails closed
local pass_client = HS.new({ psk = "correct horse battery staple", allow_passphrase = true,
    psk_iter = 4096, crypto = crypto, role = "client" })
local pass_server = HS.new({ psk = "correct horse battery staple", allow_passphrase = true,
    psk_iter = 4096, crypto = crypto, role = "server" })
T.eq(pass_server:open_request(pass_client:seal_request("pass")), "pass", "literal PSK round trip")

local other_server = make("server", { psk = string.rep("ab", 32) })
T.eq(other_server:open_request(env2), nil, "wrong PSK fails authentication")

local salt_server = make("server", { salt = "other-salt" })
T.eq(salt_server:open_request(env2), nil, "different salt fails authentication")

-- custom tag length changes the envelope length and still round trips
local short_client = make("client", { tag_len = 8 })
local short_server = make("server", { tag_len = 8 })
local short = short_client:seal_request("short")
T.eq(#short, 1 + 4 + 4 + 5 + 8, "tag_len is applied to the envelope")
T.eq(short_server:open_request(short), "short", "custom tag length round trip")
