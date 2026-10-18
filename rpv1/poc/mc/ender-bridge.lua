--[[- ender-bridge ? standalone ender-modem bridge (client/server pair), SECURED.

DESIGN CONSTRAINT (deliberate, security-driven): the ender modem (CC's
`wireless_modem_advanced`: unlimited range + cross-dimension) is used ONLY as a
bridge transport. This program is intentionally NOT part of the rpv stack:

  * it lives in `poc/mc/` (harness tooling), not in `poc/apps/`
  * the harness installs it AS `startup.lua` on the bridge computers, so it never
    goes through `node2/startup.lua` -- and those computers carry NO rpv files at
    all (proved by the endbridge scenario)
  * it owns its config (`bridge.txt`) and its log (`bridge-log.txt`)
  * it does not `require`/`dofile` anything; the crypto it needs is embedded below
  * no other script in this project knows ender modems exist

WHY the isolation matters: this program sits on an unauthenticated radio channel
and relays frames into a LAN. Its privilege must therefore be *only* "relay
authenticated bytes" -- it holds no routing state, no rpv secrets, no rpv code.

SECURITY MODEL (link layer, fail-closed by default):
  1. A pre-shared key (`bridge_psk`) is REQUIRED by default. Without it the bridge
     relays nothing at all.
  2. Pairing is authenticated: HELLO(nonce_c) -> ACK(nonce_c,nonce_s,HMAC); the
     ACK's HMAC is verified, so a wrong/absent PSK never pairs.
  3. Direction keys are derived per session with HKDF-SHA256 from the PSK and both
     nonces: k_c2s / k_s2c. Every relayed frame carries
         "S" | counter(4, big endian) | payload | tag(16)
     with tag = HMAC(k_dir, "S"|counter|payload). A frame that fails its tag is
     dropped and counted.
  4. Replay protection: per-direction monotonic counter with a 64-frame window
     (plus a "too far in the future" guard).
  5. Policy: only allowed ethertypes are bridged (default IPv4 + ARP), an optional
     source-MAC allowlist, an optional per-second broadcast limit, and a maximum
     relayed frame size (checked BEFORE the HMAC so junk cannot burn CPU).
  6. Every drop reason is counted; the SHA-256 KAT runs at boot and the bridge
     refuses to relay if the primitive is broken.

  bridge.txt keys (one instance per side):
      bridge_role=server|client     -- one of each per link
      bridge_id=rpv1                -- must match on both sides
      bridge_local=left             -- side of the modem facing the local LAN
      bridge_ender=right            -- side of the ender modem
      bridge_lan_channel=4300       -- channel used on the local segment
      bridge_link_channel=4999      -- channel used between the two bridges
      bridge_secs=45                -- run this long, then write TEST_DONE
      bridge_psk=<hex|passphrase>   -- REQUIRED unless bridge_require_auth=0
      bridge_psk_iter=256           -- PBKDF2 rounds when bridge_psk is a passphrase
      bridge_require_auth=1         -- 0 => insecure plaintext mode (A/B testing)
      bridge_allow_ethertypes=0800,0806
      bridge_allow_srcmacs=          -- decimal MACs, empty = any (auth still required)
      bridge_broadcast_per_sec=200   -- 0 = unlimited
      bridge_max_frame=4096          -- 0 = unlimited (crypto cost grows with size)
]]
local function cfg(key, default)
    local f = fs.open("bridge.txt", "r")
    if not f then return default end
    local v = default
    for line in f.readLine do
        local k, val = line:match("^([%w_]+)=(.*)$")
        if k == key then v = val end
    end
    f.close()
    return v
end

local role = cfg("bridge_role", "server")
local id = cfg("bridge_id", "rpv1")
local localSide = cfg("bridge_local", "left")
local enderSide = cfg("bridge_ender", "right")
local lanCh = tonumber(cfg("bridge_lan_channel", "4300"))
local linkCh = tonumber(cfg("bridge_link_channel", "4999"))
local secs = tonumber(cfg("bridge_secs", "45"))
local pskSpec = cfg("bridge_psk", "")
local pskIter = tonumber(cfg("bridge_psk_iter", "256"))
local requireAuth = cfg("bridge_require_auth", "1") ~= "0"
local allowEtypes = cfg("bridge_allow_ethertypes", "0800,0806")
local allowMacs = cfg("bridge_allow_srcmacs", "")
local bcastPerSec = tonumber(cfg("bridge_broadcast_per_sec", "200"))
local maxFrame = tonumber(cfg("bridge_max_frame", "4096"))

-- STP-lite (loop protection) + duplicate suppression + failure simulation
local stpOn = cfg("bridge_stp", "0") == "1"
local myBridgeId = tonumber(cfg("bridge_id_num", "")) or os.getComputerID()
local claimInterval = tonumber(cfg("bridge_claim_interval", "2"))
local stpTimeout = tonumber(cfg("bridge_stp_timeout", "6"))
local selfStopAt = tonumber(cfg("bridge_selfstop_at", "0"))
local dupWindow = tonumber(cfg("bridge_dup_window", "64"))
local dupTTL = tonumber(cfg("bridge_dup_ttl", "0.5"))

-- bridge control ethertype: bridge claims are control plane and always pass the
-- ethertype policy check (they are never user traffic)
local ET_CLAIM = 0x88B6

local log = fs.open("bridge-log.txt", "w")
local function w(fmt, ...)
    log.writeLine(string.format("%.3f %s " .. fmt, os.clock(), role, ...))
    log.flush()
end

-- ===========================================================================
-- embedded crypto (copied verbatim from poc/security/crypto.lua, which is
-- KAT-verified; kept inline on purpose so this program has zero file deps)
-- ===========================================================================
local band, bor, bxor, bnot, rshift, lshift = bit32.band, bit32.bor, bit32.bxor, bit32.bnot, bit32.rshift, bit32.lshift
local floor, char, byte, sub, rep, format, concat = math.floor, string.char, string.byte, string.sub, string.rep, string.format, table.concat

local function rotr(x, n) return band(bor(rshift(x, n), lshift(x, 32 - n)), 0xFFFFFFFF) end
local function add32(...)
    local s = 0
    for i = 1, select("#", ...) do s = s + select(i, ...) end
    return band(s, 0xFFFFFFFF)
end
local function u32be(v)
    v = floor(v)
    return char(floor(v / 0x1000000) % 256, floor(v / 0x10000) % 256, floor(v / 0x100) % 256, v % 256)
end
local function r32be(s, i) return byte(s, i) * 0x1000000 + byte(s, i + 1) * 0x10000 + byte(s, i + 2) * 0x100 + byte(s, i + 3) end

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
local H0 = { 0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19 }

local function sha256_compress(h, block)
    local w = {}
    for i = 0, 15 do
        local o = i * 4
        w[i] = byte(block, o + 1) * 0x1000000 + byte(block, o + 2) * 0x10000 + byte(block, o + 3) * 0x100 + byte(block, o + 4)
    end
    for i = 16, 63 do
        local x, y = w[i - 15], w[i - 2]
        local s0 = bxor(rotr(x, 7), rotr(x, 18), rshift(x, 3))
        local s1 = bxor(rotr(y, 17), rotr(y, 19), rshift(y, 10))
        w[i] = add32(w[i - 16], s0, w[i - 7], s1)
    end
    local a, b, c, d, e, f, g, hh = h[1], h[2], h[3], h[4], h[5], h[6], h[7], h[8]
    for i = 0, 63 do
        local S1 = bxor(rotr(e, 6), rotr(e, 11), rotr(e, 25))
        local ch = bxor(band(e, f), band(bnot(e), g))
        local t1 = add32(hh, S1, ch, K[i + 1], w[i])
        local S0 = bxor(rotr(a, 2), rotr(a, 13), rotr(a, 22))
        local maj = bxor(band(a, b), band(a, c), band(b, c))
        local t2 = add32(S0, maj)
        hh, g, f, e, d, c, b, a = g, f, e, add32(d, t1), c, b, a, add32(t1, t2)
    end
    h[1], h[2], h[3], h[4] = add32(h[1], a), add32(h[2], b), add32(h[3], c), add32(h[4], d)
    h[5], h[6], h[7], h[8] = add32(h[5], e), add32(h[6], f), add32(h[7], g), add32(h[8], hh)
end

local function sha256(msg)
    msg = tostring(msg)
    local h = { H0[1], H0[2], H0[3], H0[4], H0[5], H0[6], H0[7], H0[8] }
    local bits = #msg * 8
    local padded = msg .. "\128" .. rep("\0", (55 - #msg) % 64)
        .. u32be(floor(bits / 4294967296)) .. u32be(bits % 4294967296)
    for i = 1, #padded, 64 do sha256_compress(h, sub(padded, i, i + 63)) end
    local out = {}
    for i = 1, 8 do out[i] = u32be(h[i]) end
    return concat(out)
end

local function hmac_sha256(key, msg)
    if #key > 64 then key = sha256(key) end
    key = key .. rep("\0", 64 - #key)
    local ipad, opad = {}, {}
    for i = 1, 64 do
        local k = byte(key, i)
        ipad[i] = char(bxor(k, 0x36))
        opad[i] = char(bxor(k, 0x5c))
    end
    return sha256(concat(opad) .. sha256(concat(ipad) .. msg))
end

local function hkdf(ikm, salt, info, length)
    salt = (salt == nil or salt == "") and rep("\0", 32) or salt
    local prk = hmac_sha256(salt, ikm)
    local out, t, n = {}, "", 0
    while #concat(out) < length do
        n = n + 1
        t = hmac_sha256(prk, t .. info .. char(n))
        out[#out + 1] = t
    end
    return sub(concat(out), 1, length)
end

local function pbkdf2(pass, salt, iters, dklen)
    local out, block = {}, 0
    while #concat(out) < dklen do
        block = block + 1
        local u = hmac_sha256(pass, salt .. u32be(block))
        local t = u
        for i = 2, iters do
            u = hmac_sha256(pass, u)
            local x = {}
            for j = 1, #t do x[j] = char(bxor(byte(t, j), byte(u, j))) end
            t = concat(x)
            if i % 32 == 0 then os.sleep(0) end     -- keep CC's watchdog happy
        end
        out[#out + 1] = t
    end
    return sub(concat(out), 1, dklen)
end

local function unhex(s)
    local out = {}
    for i = 1, #s, 2 do out[#out + 1] = char(tonumber(sub(s, i, i + 1), 16)) end
    return concat(out)
end
local function hex(s)
    local out = {}
    for i = 1, #s do out[i] = format("%02x", byte(s, i)) end
    return concat(out)
end
local function rand_bytes(n)
    local out = {}
    for i = 1, n do out[i] = char(math.random(0, 255)) end
    return concat(out)
end
local function equals(a, b)
    if #a ~= #b then return false end
    local diff = 0
    for i = 1, #a do diff = bor(diff, bxor(byte(a, i), byte(b, i))) end
    return diff == 0
end

-- ===========================================================================
-- main
-- ===========================================================================
local function main()
    local TAG_SEC, TAG_HELLO, TAG_ACK, TAG_LAN = "S", "Q", "A", "F"
    local TAG_LEN, CTR_LEN = 16, 4

    local function open(side, ch)
        local ok, err = pcall(function() peripheral.call(side, "open", ch) end)
        if not ok then w("OPEN_FAIL side=%s ch=%d err=%s", side, ch, tostring(err)) end
    end
    local function tx(side, chan, reply, payload)
        return (pcall(function() peripheral.call(side, "transmit", chan, reply, payload) end))
    end

    -- CraftOS-PC starts a computer without modems; creating them keeps this
    -- program self-sufficient on the emulator. CC:Tweaked has no `periphemu`, so
    -- on a real server this is a no-op (the harness places the modems).
    local function ensure_modem(side)
        if periphemu and peripheral.getType(side) ~= "modem" then
            local ok, err = periphemu.create(side, "modem")
            w("MODEM_CREATE side=%s ok=%s err=%s", side, tostring(ok), tostring(err))
        end
    end
    ensure_modem(localSide)
    ensure_modem(enderSide)

    open(localSide, lanCh)
    open(enderSide, linkCh)

    -- ---- crypto self-test: refuse to relay on a broken primitive ----------
    math.randomseed((os.epoch and os.epoch("utc") or os.time()) + os.getComputerID())
    for _ = 1, 8 do math.random() end
    local KAT_OK = (sha256("abc") == unhex("ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"))
    w("START id=%s role=%s local=%s/%d ender=%s/%d secs=%d auth=%s kat=%s maxframe=%d",
        id, role, localSide, lanCh, enderSide, linkCh, secs, requireAuth and "psk" or "none", tostring(KAT_OK), maxFrame)
    if not KAT_OK then
        w("BRIDGE_FAIL_CLOSED sha256_kat_broken")
        w("BRIDGE_RESULT auth=none paired=false relayed=0 fail_closed=kat_broken")
        w("TEST_DONE")
        return
    end

    -- ---- PSK -> 32-byte key ----------------------------------------------
    local pskKey = nil
    if pskSpec ~= "" then
        local raw, kind
        if #pskSpec >= 32 and #pskSpec % 2 == 0 and not pskSpec:find("[^0-9a-fA-F]") then
            raw, kind = unhex(pskSpec), "hex"
        else
            kind = "passphrase(pbkdf2=" .. pskIter .. ")"
            raw = (pskIter > 0) and pbkdf2(pskSpec, "rpv-bridge", pskIter, 32) or pskSpec
        end
        pskKey = hkdf(raw, "", "rpv-bridge-psk-v1", 32)
        w("PSK_LOADED kind=%s fingerprint=%s", kind, hex(sha256(pskKey)):sub(1, 8))
    end

    if requireAuth and not pskKey then
        w("BRIDGE_FAIL_CLOSED no_psk (set bridge_psk in bridge.txt)")
        w("BRIDGE_RESULT auth=none paired=false relayed=0 fail_closed=no_psk")
        w("TEST_DONE")
        return
    end
    if not requireAuth then w("WARN insecure plaintext mode (bridge_require_auth=0)") end

    -- ---- policy tables ---------------------------------------------------
    local etypeOK = {}
    for e in allowEtypes:gmatch("%x%x%x%x") do etypeOK[tonumber(e, 16)] = true end
    local macOK = nil
    if allowMacs ~= "" then
        macOK = {}
        for m in allowMacs:gmatch("%d+") do macOK[tonumber(m)] = true end
    end

    -- ---- session state ----------------------------------------------------
    -- secure mode: nobody is "paired" until a *verified* handshake happened (the
    -- server included -- it only becomes paired when an authenticated HELLO
    -- arrives, so a wrong-PSK peer leaves it unpaired and fail-closed).
    -- plaintext mode keeps the old behaviour (server is up immediately).
    local paired = (role == "server") and not requireAuth
    local authed = not requireAuth
    local nonceC, nonceS, kTx, kRx = nil, nil, nil, nil
    local kHello = pskKey and hkdf(pskKey, "", "rpv-bridge-hello-v1", 32) or nil
    local txCounter, rxMax, rxSeen = 0, -1, {}
    local lastHello = -1

    local relayed, lanToLink = 0, 0
    local dropUnauth, dropReplay, dropPolicy, dropRate, dropSize, dropFuture, dropBad = 0, 0, 0, 0, 0, 0, 0
    local bcastCount, bcastAt = 0, 0

    local function derive_pair_keys()
        local salt = nonceC .. nonceS
        local c2s = hkdf(pskKey, salt, "rpv-bridge-c2s", 32)
        local s2c = hkdf(pskKey, salt, "rpv-bridge-s2c", 32)
        if role == "server" then kTx, kRx = s2c, c2s else kTx, kRx = c2s, s2c end
    end

    local function seal(payload)
        txCounter = txCounter + 1
        local hdr = TAG_SEC .. u32be(txCounter)
        return hdr .. payload .. hmac_sha256(kTx, hdr .. payload):sub(1, TAG_LEN)
    end

    -- replay window: accept counters in (rxMax-64, rxMax], reject older/future
    local function window_check(counter)
        if counter > rxMax then
            if rxMax >= 0 and counter - rxMax > 4096 then return false, "future" end
            return true
        end
        if rxMax - counter >= 64 then return false, "old" end
        if rxSeen[counter] then return false, "seen" end
        return true
    end
    local function window_accept(counter)
        if counter > rxMax then
            for c in pairs(rxSeen) do if c <= counter - 64 then rxSeen[c] = nil end end
            rxMax = counter
        end
        rxSeen[counter] = true
    end

    -- policy on an authenticated LAN frame: dstMAC(4)|srcMAC(4)|ethertype(2)|body
    local function policy_ok(frame, now)
        if #frame < 10 then return false, "short" end
        local dst, src = r32be(frame, 1), r32be(frame, 5)
        local etype = byte(frame, 9) * 256 + byte(frame, 10)
        if etype ~= ET_CLAIM and not etypeOK[etype] then return false, "etype" end
        if macOK and not macOK[src] then return false, "srcmac" end
        if dst == 0xFFFFFFFF and bcastPerSec > 0 then
            if now - bcastAt >= 1 then bcastAt, bcastCount = now, 0 end
            bcastCount = bcastCount + 1
            if bcastCount > bcastPerSec then return false, "rate" end
        end
        return true
    end

    local function unseal(msg, now)
        if #msg < 1 + CTR_LEN + TAG_LEN then return nil, "short" end
        local payload = sub(msg, 1 + CTR_LEN + 1, #msg - TAG_LEN)
        if maxFrame > 0 and #payload > maxFrame then return nil, "size" end
        local counter = r32be(msg, 2)
        local ok, why = window_check(counter)
        if not ok then return nil, (why == "future") and "future" or "replay" end
        local expect = hmac_sha256(kRx, sub(msg, 1, 1 + CTR_LEN) .. payload):sub(1, TAG_LEN)
        if not equals(expect, sub(msg, #msg - TAG_LEN + 1)) then return nil, "auth" end
        local pok, pwhy = policy_ok(payload, now)
        if not pok then return nil, "policy:" .. pwhy end
        window_accept(counter)
        return payload
    end

    -- ---- STP-lite: active/standby bridges, duplicate suppression ------------
    -- Each bridge periodically announces itself on BOTH sides (plain claim on the
    -- LAN, sealed claim on the link). The lowest bridge id on a segment becomes the
    -- active (root) bridge; every other bridge blocks forwarding, so a loop of
    -- bridges relays each frame exactly once. If the root stops claiming for
    -- stpTimeout seconds the standby takes over: that is the redundancy story.
    local function u16be(v) return string.char(math.floor(v / 256) % 256, v % 256) end
    local function u8be(v) return string.char(v % 256) end
    local claimSeq, peers, rootId, lanBlocked = 0, {}, myBridgeId, false
    local claimsSent, claimsRx, stpChanges = 0, 0, 0
    local linkPeerAt, linkWithdrawn, linkPeerLan = -999, false, 0
    local dupSeen, dupDrop, blockedDrop, stopped = {}, 0, 0, false

    local function claim_frame()
        -- the pair signature (my LAN channel + the LAN channel my link peer serves) is
        -- what tells a redundant path from a chained one: two bridges on the same LAN
        -- are redundant only when they connect the SAME two LANs
        return string.char(255, 255, 255, 255) .. u32be(myBridgeId) .. u16be(ET_CLAIM)
            .. u32be(rootId) .. u32be(myBridgeId) .. u32be(claimSeq)
            .. u32be(lanCh) .. u32be(linkPeerLan)
    end

    local function is_claim(frame)
        if #frame < 30 then return false end
        if byte(frame, 1) * 0x1000000 + byte(frame, 2) * 0x10000 + byte(frame, 3) * 0x100 + byte(frame, 4) ~= 0xFFFFFFFF then return false end
        return (byte(frame, 9) * 256 + byte(frame, 10)) == ET_CLAIM
    end

    local function handle_claim(frame, side)
        local rid = r32be(frame, 11)
        local bid = r32be(frame, 15)
        if bid == myBridgeId then return end          -- our own echo
        claimsRx = claimsRx + 1
        local info = peers[bid]
        if not info or info.side ~= side then
            w("STP_CLAIM from=%d root=%d side=%s", bid, rid, tostring(side))
        end
        local pl = r32be(frame, 23)
        local ppl = r32be(frame, 27)
        peers[bid] = { at = os.clock(), root = rid, side = side, lanCh = pl, peerLan = ppl }
        if side == "link" then
            linkPeerAt = os.clock()
            linkPeerLan = pl                       -- the LAN our link peer serves
        end
    end

    -- STP-lite rule: for every LAN segment there is exactly one designated bridge,
    -- the one with the lowest id that is heard on that segment. A bridge that hears
    -- a lower id on its LAN side stops relaying in BOTH directions for that segment
    -- (its link side keeps running so claims still flow and it can take over).
    -- Link sides are point-to-point and never blocked, which is what keeps a chained
    -- (non-looped) multi-hop topology working.
    local function stp_tick(now)
        if not stpOn then return end
        local bestLan = myBridgeId
        for bid, info in pairs(peers) do
            if now - info.at > stpTimeout then
                peers[bid] = nil
                w("STP_PEER_TIMEOUT id=%d", bid)
            elseif info.side == "lan" and bid < myBridgeId then
                -- redundant only if that bridge connects the same pair of LANs we do
                local redundant = linkPeerLan ~= 0 and info.peerLan ~= 0 and (
                    (info.lanCh == lanCh and info.peerLan == linkPeerLan) or
                    (info.lanCh == linkPeerLan and info.peerLan == lanCh))
                if redundant and bid < bestLan then bestLan = bid end
            end
        end
        local shouldBlock = (bestLan ~= myBridgeId)
        if bestLan ~= rootId then
            rootId = bestLan
            stpChanges = stpChanges + 1
        end
        if shouldBlock ~= lanBlocked then
            lanBlocked = shouldBlock
            stpChanges = stpChanges + 1
            if lanBlocked then
                w("STP_BLOCK side=lan id=%d superior=%d (standby path)", myBridgeId, bestLan)
            else
                w("STP_UNBLOCK side=lan id=%d", myBridgeId)
                w("STP_ROOT side=lan id=%d (designated bridge)", myBridgeId)
            end
        end
    end

    local function dup_check(frame, now, side)
        -- key on (ingress side, frame): a frame coming back around the loop arrives on
        -- the same side within milliseconds, while a host ARP/ICMP retransmission is
        -- byte-identical but half a second or more later -- so a short window with the
        -- side in the key catches loop echos without eating legitimate retries
        if not stpOn then return true end
        local key = tostring(side) .. ":" .. sha256(frame):sub(1, 10)
        local seen = dupSeen[key]
        if seen and now - seen <= dupTTL then
            dupDrop = dupDrop + 1
            return false
        end
        dupSeen[key] = now
        local n = 0
        for k in pairs(dupSeen) do
            n = n + 1
            if dupSeen[k] + dupTTL * 2 < now then dupSeen[k] = nil end
        end
        return true
    end

    local function relay_gate(frame, now, side)
        if stopped then blockedDrop = blockedDrop + 1 return false end
        if stpOn and lanBlocked then blockedDrop = blockedDrop + 1 return false end
        return dup_check(frame, now, side)
    end

    local function relay_to_link(frame)
        if stpOn and is_claim(frame) then return false end        -- claims never relay
        if not relay_gate(frame, os.clock(), "lan") then return false end
        if requireAuth then
            if not authed then return false end
            local ok = tx(enderSide, linkCh, linkCh, seal(frame))
            if ok then lanToLink = lanToLink + 1 end
            return ok
        end
        if not paired then return false end
        local ok = tx(enderSide, linkCh, linkCh, TAG_LAN .. frame)
        if ok then lanToLink = lanToLink + 1 end
        return ok
    end

    local function relay_to_lan(frame)
        -- a sealed payload from the link side: if it is a claim, it came from our link
        -- peer (side="link"), which must NOT count as a superior bridge on our LAN
        if stpOn and is_claim(frame) then handle_claim(frame, "link") return false end
        if not relay_gate(frame, os.clock(), "link") then return false end
        local ok = tx(localSide, lanCh, lanCh, frame)
        if ok then relayed = relayed + 1 end
        return ok
    end

    local function hello_frame(nc)
        local head = TAG_HELLO .. id .. nc
        return head .. hmac_sha256(kHello, head):sub(1, TAG_LEN)
    end

    local function handle_hello(msg)
        -- the HELLO itself is authenticated with a PSK-derived key: an unauthenticated
        -- peer can neither pair with us nor make us flap between peers
        if #msg ~= 1 + #id + 8 + TAG_LEN then dropBad = dropBad + 1 return end
        local idIn, nc = msg:sub(2, 1 + #id), msg:sub(2 + #id, 9 + #id)
        local head = TAG_HELLO .. id .. nc
        if idIn ~= id or not equals(hmac_sha256(kHello, head):sub(1, TAG_LEN), msg:sub(10 + #id, 9 + #id + TAG_LEN)) then
            dropUnauth = dropUnauth + 1
            w("AUTH_FAIL bad hello")
            return
        end
        nonceC, nonceS = nc, rand_bytes(8)
        local body = TAG_ACK .. id .. nonceC .. nonceS
        local tag = hmac_sha256(hkdf(pskKey, nonceC, "rpv-bridge-auth", 32), body):sub(1, TAG_LEN)
        tx(enderSide, linkCh, linkCh, body .. tag)
        derive_pair_keys()
        paired, authed = true, true
        w("PAIRED_BY_CLIENT id=%s", id)
    end

    local function handle_ack(msg)
        if authed then return end
        local idIn = msg:sub(2, 1 + #id)
        local off = 2 + #id
        if idIn ~= id or #msg < off - 1 + 8 + 8 + TAG_LEN then dropBad = dropBad + 1 return end
        local nc, ns = msg:sub(off, off + 7), msg:sub(off + 8, off + 15)
        nonceC = nonceC or nc
        if nc ~= nonceC then dropBad = dropBad + 1 w("AUTH_FAIL stale nonce") return end
        nonceS = ns
        local body = TAG_ACK .. id .. nonceC .. nonceS
        local expect = hmac_sha256(hkdf(pskKey, nonceC, "rpv-bridge-auth", 32), body):sub(1, TAG_LEN)
        if not equals(expect, msg:sub(off + 16, off + 15 + TAG_LEN)) then
            dropUnauth = dropUnauth + 1
            w("AUTH_FAIL bad hmac (wrong psk?)")
            return
        end
        derive_pair_keys()
        paired, authed = true, true
        w("PAIRED id=%s", id)
    end

    -- ---- main loop --------------------------------------------------------
    local t0 = os.clock()
    local statAt, nextHello, claimAt = 0, 0, -999
    os.startTimer(0.25)          -- periodic wakeup: stats + pairing retries must not
                                 -- depend on traffic arriving (idle = no events)
    while os.clock() - t0 < secs do
        local ev, a, b, c, d = os.pullEvent()
        if ev == "modem_message" then
            local side, chan, msg = a, b, d
            if side == localSide and chan == lanCh then
                if type(msg) == "string" and msg:sub(1, 1) ~= TAG_LAN then
                    if stpOn and is_claim(msg) then handle_claim(msg, "lan") else relay_to_link(msg) end
                end
            elseif side == enderSide and chan == linkCh and type(msg) == "string" then
                local tag = msg:sub(1, 1)
                if tag == TAG_HELLO then
                    if requireAuth then handle_hello(msg) end
                elseif tag == TAG_ACK then
                    if requireAuth then handle_ack(msg) end
                elseif tag == TAG_SEC then
                    if authed then
                        local payload, why = unseal(msg, os.clock())
                        if payload then relay_to_lan(payload)
                        elseif why == "auth" then dropUnauth = dropUnauth + 1
                        elseif why == "replay" then dropReplay = dropReplay + 1
                        elseif why == "future" then dropFuture = dropFuture + 1
                        elseif why == "size" then dropSize = dropSize + 1
                        elseif why and why:sub(1, 7) == "policy:" then
                            if why == "policy:rate" then dropRate = dropRate + 1 else dropPolicy = dropPolicy + 1 end
                        else dropBad = dropBad + 1 end
                    else
                        dropUnauth = dropUnauth + 1         -- secure frame before pairing
                    end
                elseif tag == TAG_LAN then
                    if requireAuth then
                        dropUnauth = dropUnauth + 1         -- plaintext never accepted
                    else
                        local payload = msg:sub(2)
                        if payload ~= "" and paired then relay_to_lan(payload) end
                    end
                else
                    dropBad = dropBad + 1
                end
            end
        elseif ev == "timer" then
            os.startTimer(0.25)
        end

        local now = os.clock()
        if requireAuth and role == "client" and not authed and now - nextHello >= 0.5 then
            nextHello = now
            nonceC = nonceC or rand_bytes(8)
            tx(enderSide, linkCh, linkCh, hello_frame(nonceC))
        end
        -- STP-lite periodic work: announce ourselves on both sides, recompute the
        -- designated-bridge decision, and honour the failure-simulation hook
        if selfStopAt > 0 and not stopped and now - t0 >= selfStopAt then
            stopped = true
            w("BRIDGE_SELFSTOP at=%.1f (simulating a dead bridge)", now - t0)
        end
        if stpOn then
            -- A bridge whose link peer has gone silent is useless: withdraw its LAN
            -- claim so the LAN side can hand the designated-bridge role to the other
            -- pair (this is what makes the standby path take over end to end).
            local linkAlive = (now - linkPeerAt) <= stpTimeout
            if not linkAlive and not linkWithdrawn then
                linkWithdrawn = true
                w("STP_WITHDRAW side=lan (no live link peer)")
            elseif linkAlive and linkWithdrawn then
                linkWithdrawn = false
                w("STP_RECLAIM side=lan (link peer is back)")
            end
            if not stopped and now - claimAt >= claimInterval then
                claimAt = now
                claimSeq = claimSeq + 1
                local cf = claim_frame()
                if linkAlive then tx(localSide, lanCh, lanCh, cf) end         -- plain on the LAN
                if authed then tx(enderSide, linkCh, linkCh, seal(cf)) end    -- sealed on the link
                claimsSent = claimsSent + 1
            end
            stp_tick(now)
        end
        if now - statAt >= 5 then
            statAt = now
            -- both direction names are present here too: harnesses read the last
            -- STATS line when the run ends before BRIDGE_RESULT
            w("STATS auth=%s paired=%s relayed=%d lan_to_link=%d link_to_lan=%d unauth=%d replay=%d policy=%d rate=%d size=%d future=%d bad=%d stp=%s id=%d root=%d fwd=%s claims_tx=%d claims_rx=%d dup_drop=%d blocked=%d",
                requireAuth and "psk" or "none", tostring(paired), relayed, lanToLink, relayed,
                dropUnauth, dropReplay, dropPolicy, dropRate, dropSize, dropFuture, dropBad,
                stpOn and "on" or "off", myBridgeId, rootId, tostring(forwarding), claimsSent, claimsRx, dupDrop, blockedDrop)
        end
    end

    local dropped = dropUnauth + dropReplay + dropPolicy + dropRate + dropSize + dropFuture + dropBad
    -- `relayed` is the link->LAN direction; both names are printed because the
    -- harnesses (and the docs) parse lan_to_link / link_to_lan
    w("BRIDGE_RESULT auth=%s paired=%s relayed=%d lan_to_link=%d link_to_lan=%d dropped=%d unauth=%d replay=%d policy=%d rate=%d size=%d future=%d bad=%d stp=%s id=%d root=%d fwd=%s claims_tx=%d claims_rx=%d dup_drop=%d blocked=%d",
        requireAuth and "psk" or "none", tostring(paired), relayed, lanToLink, relayed, dropped,
        dropUnauth, dropReplay, dropPolicy, dropRate, dropSize, dropFuture, dropBad,
        stpOn and "on" or "off", myBridgeId, rootId, tostring(forwarding), claimsSent, claimsRx, dupDrop, blockedDrop)
    w("TEST_DONE")
end

local ok, err = pcall(main)
if not ok then
    w("BRIDGE_ERROR %s", tostring(err))
    log.close()
    error(err)
end
log.close()
