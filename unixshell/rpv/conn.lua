--[[- rpv/conn.lua ??connection-oriented transport with AIMD congestion control.

Sits on top of the UDP sockets and gives apps a real connection:

  * 3-way handshake (SYN / SYN-ACK / ACK) with retransmission and backoff
  * cumulative ACKs, sequence numbers, in-order delivery
  * sliding window limited by  min(cwnd, rwnd)
  * AIMD congestion control: slow start (cwnd *= 2) until ssthresh, then
    congestion avoidance (cwnd += 1); RTO collapse (cwnd = 1, ssthresh = cwnd/2,
    RTO *= 2) and fast retransmit after 3 duplicate ACKs
  * RTO from RFC 6298-style SRTT/RTTVAR, with a floor of conn_rto_min
    (real Minecraft quantises to 50 ms ticks, so a sane floor matters)
  * FIN / close

Wire format (one UDP datagram per segment):
  u8 type | u32 seq | u32 ack | u16 window | u16 len | payload
  types: 1 SYN, 2 SYN-ACK, 3 DATA (len=0 means pure ACK), 4 FIN

SECURE MODE (control-plane AEAD, opt-in with node config `conn_secure=1`):
  * handshake authentication: SYN carries "C"|nonce_c|HMAC(k_ctrl, "SYN"|iss|nonce_c)
    and SYN-ACK carries "S"|nonce_s|HMAC(k_ctrl, "SYNACK"|iss|nonce_c|nonce_s), with
    k_ctrl = HKDF(psk, "", "rpv-conn-ctrl-v1"). A peer without the PSK cannot
    complete the handshake, and a secure node talking to a plaintext peer fails
    closed (CONN_SEC_PEER_PLAINTEXT + abort).
  * per-direction session keys from both nonces:
      k_c2s/m_c2s = HKDF(psk, nonce_c|nonce_s, "rpv-conn-c2s"[-mac])
      k_s2c/m_s2c = HKDF(psk, nonce_c|nonce_s, "rpv-conn-s2c"[-mac])
  * every segment is encrypt-then-MAC: hdr(13) | ChaCha20(payload, nonce_dir, counter=seq) | tag(16)
    The header stays plaintext (seq/ack/win are needed for demux and are covered
    by the tag), the payload is encrypted, and the tag is HMAC-SHA256 truncated.
    A failure is counted (CONN_SEC_AUTH_FAIL) and the segment is dropped silently.
  * replay/ordering: the existing rcv_nxt check drops old segments (counted as
    out-of-order); the tag means an attacker cannot forge a fresh sequence number.
  * PSK config: conn_psk=<hex|passphrase>, conn_psk_iter (PBKDF2 rounds for a
    passphrase), conn_sec_mac_len (tag length, default 16).
  Cost note (measured): pure-Lua ChaCha20 is ~215 KB/s, so this is for control
  flows / modest transfers ? bulk data should use link isolation instead.

Test hook: node.cfg.drop_every=N silently drops every Nth outgoing segment so
loss recovery / congestion control can be exercised deterministically.
]]
local M = ...
local u8, u16, u32, r16, r32, byte, sub, int2ip, floor = M.u8, M.u16, M.u32, M.r16, M.r32, M.byte, M.sub, M.int2ip, M.floor

local T_SYN, T_SYNACK, T_DATA, T_FIN, T_SACK = 1, 2, 3, 4, 5
local HDR = 13
M.CONN_TYPES = { SYN = T_SYN, SYNACK = T_SYNACK, DATA = T_DATA, FIN = T_FIN, SACK = T_SACK }

-- SACK option payload: u8 count | (u32 left | u32 right) * count
local function sack_encode(ranges)
    local out = { u8(#ranges) }
    for _, r in ipairs(ranges) do
        out[#out + 1] = u32(r[1]) .. u32(r[2])
    end
    return table.concat(out)
end

local function sack_decode(s)
    if type(s) ~= "string" or #s < 1 then return {} end
    local n, out = byte(s, 1), {}
    for i = 0, n - 1 do
        local o = 2 + i * 8
        if #s < o + 7 then break end
        out[#out + 1] = { r32(s, o), r32(s, o + 4) }
    end
    return out
end

-- advertised receive window, optionally scaled (conn_wscale must match on both ends)
local function adv_win(c)
    local w = c.rwnd or 8192
    if (c.wscale or 0) > 0 then w = floor(w / 2 ^ c.wscale) end
    return w
end

local function seg(t, seq, ack, win, payload)
    return u8(t) .. u32(seq) .. u32(ack) .. u16(win) .. u16(#payload) .. payload
end

function M.conn_parse(data)
    if #data < HDR then return nil end
    local len = r16(data, 12)
    if #data < HDR + len then return nil end
    return {
        t = byte(data, 1), seq = r32(data, 2), ack = r32(data, 6),
        win = r16(data, 10), len = len, payload = sub(data, HDR + 1, HDR + len),
        raw = data,          -- the tag lives after the payload for secure segments
    }
end

-- ===== secure mode helpers ==================================================
local SEC_INFO_CTRL = "rpv-conn-ctrl-v1"
local SEC_INFO_NONCE = "-nonce"

local function sec_is_hex(s)
    return #s >= 32 and #s % 2 == 0 and not s:find("[^0-9a-fA-F]")
end

-- PSK -> 32-byte key. Hex of >=32 bytes is used as raw key material; anything
-- else is a passphrase stretched with PBKDF2 (yielding so CC's watchdog is happy).
function M.conn_psk_derive(node)
    local spec = node.cfg.conn_psk
    if not spec or spec == "" then return nil end
    local raw
    if sec_is_hex(spec) then
        raw = M.unhex(spec)
    else
        local iters = tonumber(node.cfg.conn_psk_iter) or 256
        raw = (iters > 0) and M.pbkdf2_sha256(spec, "rpv-conn", iters, 32, 32) or spec
    end
    return M.hkdf_sha256(raw, "", "rpv-conn-psk-v1", 32)
end

function M.conn_rand(n)
    local out = {}
    for i = 1, n do
        out[i] = string.char(math.random(0, 255))
    end
    return table.concat(out)
end

local function sec_tag(c, key, ...)
    return M.hmac_sha256(key, table.concat({ ... })):sub(1, c.sec_mac)
end

local function sec_derive(c)
    local salt = c.nonce_c .. c.nonce_s
    local a, b = M.hkdf_sha256(c.psk, salt, "rpv-conn-c2s", 32), M.hkdf_sha256(c.psk, salt, "rpv-conn-c2s-mac", 32)
    local x, y = M.hkdf_sha256(c.psk, salt, "rpv-conn-s2c", 32), M.hkdf_sha256(c.psk, salt, "rpv-conn-s2c-mac", 32)
    if c.is_client then
        c.k_tx, c.m_tx, c.k_rx, c.m_rx = a, b, x, y
    else
        c.k_tx, c.m_tx, c.k_rx, c.m_rx = x, y, a, b
    end
    c.nonce_tx = M.hkdf_sha256(c.psk, salt, "rpv-conn-c2s" .. SEC_INFO_NONCE, 12)
    c.nonce_rx = M.hkdf_sha256(c.psk, salt, "rpv-conn-s2c" .. SEC_INFO_NONCE, 12)
    if not c.is_client then
        c.nonce_tx, c.nonce_rx = c.nonce_rx, c.nonce_tx
    end
    c.sec_ready = true
    c.node:log("CONN_SEC_KEYS role=%s fp=%s", c.is_client and "client" or "server",
        M.hex(M.sha256(c.k_tx)):sub(1, 8))
end

-- header (13 B) | ciphertext | tag   (control segments: payload plaintext + tag)
local function sec_wrap(c, t, seq, ack, win, payload, encrypt)
    local body = encrypt and M.chacha20_xor(c.k_tx, c.nonce_tx, seq, payload) or payload
    local hdr = u8(t) .. u32(seq) .. u32(ack) .. u16(win) .. u16(#body)
    return hdr .. body .. sec_tag(c, c.m_tx, hdr, body)
end

local Conn = {}
Conn.__index = Conn

local function count(t)
    local n = 0
    for _ in pairs(t) do n = n + 1 end
    return n
end

function M.conn_new(node, opts)
    local c = setmetatable({
        node = node, port = opts.port, peer_ip = opts.peer_ip, peer_port = opts.peer_port or opts.port,
        state = opts.state or "CLOSED", mss = tonumber(node.cfg.conn_mss) or 200,
        snd_una = 0, snd_nxt = 0, rcv_nxt = 0,
        cwnd = 1, ssthresh = tonumber(node.cfg.conn_ssthresh) or 16,
        rwnd = tonumber(node.cfg.conn_rwnd) or 8192,
        srtt = nil, rttvar = nil,
        rto = tonumber(node.cfg.conn_rto) or 0.5,
        -- 0.2 s = 4 server ticks. Measured on a real Minecraft/CC:Tweaked server:
        -- with the old 0.05 s floor a 200 kB burst fired 12 spurious RTOs
        -- (cwnd collapsing to 1 each time) while 0.2 s produced none at the same
        -- throughput (1.5 s, ~133 kB/s). See poc/out/measurements-mc.md 2.12(d).
        rto_min = tonumber(node.cfg.conn_rto_min) or 0.2,
        rto_max = tonumber(node.cfg.conn_rto_max) or 2.0,
        tx = 0, retx = 0, bytes_tx = 0, bytes_rx = 0, dupacks = 0, dup_rx = 0,
        queue = {}, unacked = {}, closed = false, fin_sent = false, close_pending = false,
        -- secure mode (control-plane AEAD): see the header comment
        secure = false, sec_mac = tonumber(node.cfg.conn_sec_mac_len) or 16,
        sec_drops = { auth = 0, ctrl = 0, plaintext_peer = 0 },
        -- P3 transport polish: selective ACKs, window scaling, slow start, keepalive
        sack = (node.cfg.conn_sack ~= "0"),
        wscale = tonumber(node.cfg.conn_wscale) or 0,
        iw = tonumber(node.cfg.conn_iw) or 2,
        keepalive = tonumber(node.cfg.conn_keepalive) or 0,
        gmax = tonumber(node.cfg.conn_global_max_inflight) or 0,
        ooo = {}, ooo_bytes = 0, sack_rx = 0, sack_retx = 0, sack_sent = 0, ooo_buffered = 0,
        keepalives = 0, ka_miss = 0, last_activity = os.clock(),
    }, Conn)
    local id = node.id or os.getComputerID()
    c.iss = (id * 100000 + floor((os.clock() * 1000)) % 100000) % 2 ^ 31
    c.snd_una, c.snd_nxt = c.iss, c.iss
    c.cwnd = c.iw                      -- initial window (RFC 6928-style)
    c.is_client = (c.state == "SYN_SENT")
    if node.cfg.conn_secure == "1" then
        c.psk = M.conn_psk_derive(node)
        if not c.psk then
            node:log("CONN_SEC_NO_PSK (conn_secure=1 but conn_psk is empty)")
        else
            c.secure = true
            c.k_ctrl = M.hkdf_sha256(c.psk, "", SEC_INFO_CTRL, 32)
            c.nonce_c = M.conn_rand(8)
            if not c.is_client then c.nonce_s = M.conn_rand(8) end
        end
    end
    return c
end

function Conn:on_open(fn) self.open_cb = fn end
function Conn:on_data(fn) self.data_cb = fn end
function Conn:on_close(fn) self.close_cb = fn end

function Conn:_send_ctrl(t, seq, ack, payload)
    payload = payload or ""
    local frame
    if self.secure and self.sec_ready and t ~= T_SYN and t ~= T_SYNACK then
        -- control segments (pure ACK / FIN / handshake ACK) are authenticated too
        frame = sec_wrap(self, t, seq, ack, adv_win(self), payload, false)
    else
        frame = seg(t, seq, ack, adv_win(self), payload)
    end
    M.udp_send(self.node, self.peer_ip, self.port, self.peer_port, frame, 64)
    self.tx = self.tx + 1
end

function Conn:_transmit(rec)
    rec.sent = true
    rec.t0 = os.clock()
    rec.tries = (rec.tries or 0) + 1
    self.tx = self.tx + 1
    self.bytes_tx = self.bytes_tx + #rec.data
    local drop_every = tonumber(self.node.cfg.drop_every) or 0
    if drop_every > 0 and rec.tries == 1 and self.tx % drop_every == 0 then
        self.node:log("CONN_DROP_SIM seq=%d bytes=%d (drop_every=%d)", rec.seq, #rec.data, drop_every)
    else
        local frame
        if self.secure and self.sec_ready then
            frame = sec_wrap(self, T_DATA, rec.seq, self.rcv_nxt, adv_win(self), rec.data, true)
        else
            frame = seg(T_DATA, rec.seq, self.rcv_nxt, adv_win(self), rec.data)
        end
        M.udp_send(self.node, self.peer_ip, self.port, self.peer_port, frame, 64)
    end
    -- count segments, not transmits: retransmitting an existing record must not
    -- inflate the node-wide in-flight total used by the fairness cap
    if not self.unacked[rec.seq] then
        self.node.conn_inflight = (self.node.conn_inflight or 0) + 1
    end
    self.unacked[rec.seq] = rec
end

function Conn:send(data)
    if self.state ~= "ESTABLISHED" then return false end
    local i = 1
    while i <= #data do
        local chunk = sub(data, i, i + self.mss - 1)
        i = i + self.mss
        self.queue[#self.queue + 1] = { seq = self.snd_nxt, data = chunk, sent = false }
        self.snd_nxt = self.snd_nxt + #chunk
    end
    self:pump()
    return true
end

function Conn:pump()
    if self.state ~= "ESTABLISHED" then return end
    local win = math.min(self.cwnd, math.max(1, floor(self.rwnd / self.mss)))
    -- the peer tells us how much room it has (its window may be scaled)
    if self.peer_rwnd and self.peer_rwnd > 0 then
        win = math.min(win, math.max(1, floor(self.peer_rwnd / self.mss)))
    end
    local inflight = count(self.unacked)
    for _, rec in ipairs(self.queue) do
        if inflight >= win then break end
        -- fairness: a node-wide in-flight cap keeps N flows from oversubscribing.
        -- A flow with nothing in flight may always send one segment, otherwise a new
        -- flow could never get started while other flows hold the whole budget.
        if self.gmax > 0 and (self.node.conn_inflight or 0) >= self.gmax and inflight > 0 then
            self.cwnd_limited = (self.cwnd_limited or 0) + 1
            break
        end
        if not rec.sent then
            self:_transmit(rec)
            inflight = inflight + 1
        end
    end
    if self.close_pending and inflight == 0 then self:_finish_close() end
end

function Conn:_rtt(r)
    if not self.srtt then
        self.srtt, self.rttvar = r, r / 2
    else
        self.rttvar = 0.75 * self.rttvar + 0.25 * math.abs(self.srtt - r)
        self.srtt = 0.875 * self.srtt + 0.125 * r
    end
    self.rto = math.max(self.rto_min, math.min(self.rto_max or 2.0, self.srtt + 4 * self.rttvar))
end

function Conn:_on_ack(ack)
    local acked = 0
    for seq, rec in pairs(self.unacked) do
        if seq + #rec.data <= ack then
            self.unacked[seq] = nil
            self.node.conn_inflight = math.max(0, (self.node.conn_inflight or 0) - 1)
            acked = acked + 1
            if rec.tries == 1 and rec.t0 then self:_rtt(os.clock() - rec.t0) end
            for i = #self.queue, 1, -1 do
                if self.queue[i] == rec then table.remove(self.queue, i) end
            end
        end
    end
    if acked > 0 then
        self.snd_una = ack
        self.dupacks = 0
        -- AIMD
        if self.cwnd < self.ssthresh then
            -- proper slow start: +1 MSS per ACK (doubles per RTT). The legacy curve
            -- doubled per ACK, which overshoots badly on a 50 ms-tick link.
            if self.node.cfg.conn_slow_start == "1" then self.cwnd = self.cwnd + self.mss
            else self.cwnd = self.cwnd * 2 end
        else self.cwnd = self.cwnd + 1 end
        self.node:log("CONN_ACK ack=%d cwnd=%d ssthresh=%d inflight=%d rto=%.3f",
            ack, self.cwnd, self.ssthresh, count(self.unacked), self.rto)
        self:pump()
    else
        self.dupacks = self.dupacks + 1
        if self.dupacks == 3 then
            local oldest = nil
            for seq, rec in pairs(self.unacked) do
                if not oldest or seq < oldest.seq then oldest = rec end
            end
            if oldest then
                self.ssthresh = math.max(2, floor(self.cwnd / 2))
                self.cwnd = self.ssthresh
                self.retx = self.retx + 1
                self.node:log("CONN_FAST_RETX seq=%d cwnd=%d ssthresh=%d", oldest.seq, self.cwnd, self.ssthresh)
                self:_transmit(oldest)
            end
        end
    end
end

-- handshake blobs (secure mode): authenticated control segments carrying nonces
function Conn:_syn_payload()
    if not self.secure then return "" end
    local head = "C" .. self.nonce_c
    return head .. sec_tag(self, self.k_ctrl, "SYN", u32(self.iss), self.nonce_c)
end

function Conn:_synack_payload()
    if not self.secure then return "" end
    local head = "S" .. self.nonce_s
    return head .. sec_tag(self, self.k_ctrl, "SYNACK", u32(self.iss), self.nonce_c, self.nonce_s)
end

function Conn:_check_syn_payload(payload, seq)
    -- returns true when an authenticated SYN was presented (secure mode)
    if #payload ~= 1 + 8 + self.sec_mac or payload:sub(1, 1) ~= "C" then return false end
    local nc = payload:sub(2, 9)
    local expect = sec_tag(self, self.k_ctrl, "SYN", u32(seq), nc)
    if not M.equals(expect, payload:sub(10, 9 + self.sec_mac)) then return false end
    self.nonce_c = nc
    return true
end

function Conn:_check_synack_payload(payload, seq)
    -- returns "ok" | "bad" | "plaintext"
    if #payload == 0 then return "plaintext" end
    if #payload ~= 1 + 8 + self.sec_mac or payload:sub(1, 1) ~= "S" then return "bad" end
    local ns = payload:sub(2, 9)
    local expect = sec_tag(self, self.k_ctrl, "SYNACK", u32(seq), self.nonce_c, ns)
    if not M.equals(expect, payload:sub(10, 9 + self.sec_mac)) then return "bad" end
    self.nonce_s = ns
    return "ok"
end

function Conn:_on_segment(s, src, sport)
    self.peer_ip, self.peer_port = src, sport
    self.last_activity = os.clock()
    self.ka_miss = 0

    -- secure mode: verify the tag (and decrypt) before touching any state. SYN and
    -- SYN-ACK are excluded: their payloads are handshake blobs authenticated with
    -- k_ctrl (checked in the branches below), not with the session keys.
    if self.secure and self.sec_ready and s.t ~= T_SYN and s.t ~= T_SYNACK then
        local body = sub(s.raw, HDR + 1, HDR + s.len)
        local got = sub(s.raw, HDR + s.len + 1, HDR + s.len + self.sec_mac)
        local expect = sec_tag(self, self.m_rx, sub(s.raw, 1, HDR), body)
        if not M.equals(expect, got) then
            self.sec_drops.auth = self.sec_drops.auth + 1
            self.node:log("CONN_SEC_AUTH_FAIL type=%d from=%s:%d bytes=%d", s.t, int2ip(src), sport, #s.raw)
            return
        end
        if s.len > 0 then
            s.payload = M.chacha20_xor(self.k_rx, self.nonce_rx, s.seq, body)
        else
            s.payload = ""
        end
    end

    if s.t == T_SYN then
        if self.state == "SYN_RCVD" then
            self:_send_ctrl(T_SYNACK, self.iss, self.rcv_nxt, self:_synack_payload())
        end
        return
    end
    if s.t == T_SYNACK then
        if self.state == "SYN_SENT" then
            if self.secure then
                local verdict = self:_check_synack_payload(s.payload, s.seq)
                if verdict == "bad" then
                    self.sec_drops.auth = self.sec_drops.auth + 1
                    self.node:log("CONN_SEC_AUTH_FAIL type=SYNACK from=%s:%d", int2ip(src), sport)
                    return
                elseif verdict == "plaintext" then
                    self.sec_drops.plaintext_peer = self.sec_drops.plaintext_peer + 1
                    self.node:log("CONN_SEC_PEER_PLAINTEXT peer=%s:%d (aborting, fail closed)", int2ip(src), sport)
                    return self:abort("secure peer required")
                end
                sec_derive(self)
            end
            self.rcv_nxt = s.seq + 1
            -- our SYN consumed one sequence number, so data starts at iss+1
            self.snd_una, self.snd_nxt = self.iss + 1, self.iss + 1
            self.dupacks = 0
            self.state = "ESTABLISHED"
            self:_send_ctrl(T_DATA, self.snd_nxt, self.rcv_nxt, "")   -- handshake ACK
            self.node:log("CONN_ESTABLISHED peer=%s:%d", int2ip(src), sport)
            self:start_timer()
            if self.open_cb then self.open_cb(self) end
            self:pump()
        elseif self.state == "ESTABLISHED" then
            -- our ACK got lost: acknowledge the duplicate SYN-ACK again
            self:_send_ctrl(T_DATA, self.snd_nxt, self.rcv_nxt, "")
        end
        return
    end
    if s.t == T_SACK then
        -- selective ACK: mark the covered ranges and retransmit the lowest hole
        local ranges = sack_decode(s.payload)
        self.sack_rx = self.sack_rx + 1
        local covered = 0
        for _, r in ipairs(ranges) do
            for seq, rec in pairs(self.unacked) do
                if seq >= r[1] and seq + #rec.data <= r[2] then
                    rec.sacked = true
                    covered = covered + 1
                end
            end
        end
        if covered > 0 then
            local hole = nil
            for seq, rec in pairs(self.unacked) do
                if not rec.sacked and (not hole or seq < hole.seq) then hole = rec end
            end
            if hole then
                self.ssthresh = math.max(2, floor(self.cwnd / 2))
                self.cwnd = math.max(1, self.ssthresh)
                self.sack_retx = self.sack_retx + 1
                self.retx = self.retx + 1
                self.node:log("CONN_SACK_RETX seq=%d ranges=%d covered=%d cwnd=%d", hole.seq, #ranges, covered, self.cwnd)
                self:_transmit(hole)
            end
        end
        self.node:log("CONN_SACK ranges=%d covered=%d sack_rx=%d", #ranges, covered, self.sack_rx)
        -- an empty SACK doubles as a keepalive probe: answer so the peer knows we live
        if #ranges == 0 then self:_send_ctrl(T_DATA, self.snd_nxt, self.rcv_nxt, "") end
        self:_on_ack(s.ack)
        return
    end
    if s.t == T_FIN then
        self.rcv_nxt = s.seq + 1
        self:_send_ctrl(T_DATA, self.snd_nxt, self.rcv_nxt, "")
        self.state = "CLOSED"
        self.closed = true
        self.node:log("CONN_FIN from=%s bytes_rx=%d", int2ip(src), self.bytes_rx)
        if self.close_cb then self.close_cb(self) end
        return
    end
    if s.t == T_DATA then
        -- peer's advertised window (may be scaled; conn_wscale must match on both ends)
        if s.win then
            self.peer_rwnd = s.win * 2 ^ (self.wscale or 0)
        end
        if s.len > 0 then
            if s.seq == self.rcv_nxt then
                self.rcv_nxt = self.rcv_nxt + s.len
                self.bytes_rx = self.bytes_rx + s.len
                if self.data_cb then self.data_cb(self, s.payload) end
                -- drain anything we buffered while this hole was open
                local progress = true
                while progress do
                    progress = false
                    local buffered = self.ooo[self.rcv_nxt]
                    if buffered then
                        self.ooo[self.rcv_nxt] = nil
                        self.rcv_nxt = self.rcv_nxt + #buffered
                        self.bytes_rx = self.bytes_rx + #buffered
                        if self.data_cb then self.data_cb(self, buffered) end
                        progress = true
                    end
                end
            elseif s.seq > self.rcv_nxt then
                -- out of order: buffer it (selective ACK) and report what we have
                if self.sack and not self.ooo[s.seq] then
                    self.ooo[s.seq] = s.payload
                    self.ooo_bytes = self.ooo_bytes + #s.payload
                    self.ooo_buffered = self.ooo_buffered + 1
                end
                self.dup_rx = self.dup_rx + 1
                self.node:log("CONN_OOO_SEG seq=%d expected=%d buffered=%d (dup ack)", s.seq, self.rcv_nxt, self.ooo_buffered)
                if self.sack then self:_send_sack() end
            else
                self.dup_rx = self.dup_rx + 1
                self.node:log("CONN_OOO_SEG seq=%d expected=%d (old duplicate)", s.seq, self.rcv_nxt)
            end
            self:_send_ctrl(T_DATA, self.snd_nxt, self.rcv_nxt, "")
        end
        -- handshake completion is signalled by the peer's first ACK, which may
        -- be a pure ACK (no payload) or arrive piggybacked on data
        if self.state == "SYN_RCVD" and s.ack and s.ack >= self.snd_nxt then
            self.state = "ESTABLISHED"
            self.node:log("CONN_ACCEPTED peer=%s:%d", int2ip(src), sport)
            if self.listener and self.listener.on_accept then self.listener.on_accept(self) end
            if self.open_cb then self.open_cb(self) end
        end
        self:_on_ack(s.ack)
    end
end

-- report the contiguous blocks we hold out of order so the sender retransmits only
-- the hole (selective ACK)
function Conn:_send_sack()
    local seqs = {}
    for seq in pairs(self.ooo) do seqs[#seqs + 1] = seq end
    table.sort(seqs)
    local ranges = {}
    for _, seq in ipairs(seqs) do
        local right = seq + #self.ooo[seq]
        local last = ranges[#ranges]
        if last and seq <= last[2] then
            if right > last[2] then last[2] = right end
        else
            ranges[#ranges + 1] = { seq, right }
        end
    end
    self.sack_sent = self.sack_sent + 1
    self.node:log("CONN_SACK_SENT ranges=%d rcv_nxt=%d buffered=%d", #ranges, self.rcv_nxt, self.ooo_buffered)
    return self:_send_ctrl(T_SACK, self.snd_nxt, self.rcv_nxt, sack_encode(ranges))
end

function Conn:_finish_close()
    self.fin_sent = true
    self:_send_ctrl(T_FIN, self.snd_nxt, self.rcv_nxt, "")
    self.node:log("CONN_FIN_SENT bytes_tx=%d tx=%d retx=%d", self.bytes_tx, self.tx, self.retx)
end

function Conn:close()
    if self.state == "ESTABLISHED" then
        self.close_pending = true
        self:pump()
    elseif self.state == "SYN_SENT" then
        self.closed = true
    end
end

function Conn:abort(why)
    -- give the in-flight segments of this connection back to the node-wide counter
    self.node.conn_inflight = math.max(0, (self.node.conn_inflight or 0) - count(self.unacked))
    self.unacked = {}
    self.state = "CLOSED"
    self.closed = true
    self.node:log("CONN_ABORT %s", tostring(why))
    if self.close_cb then self.close_cb(self) end
end

function Conn:log_stats(tag)
    self.node:log("CONN_STATS %s cwnd=%d ssthresh=%d srtt=%s rto=%.3f tx=%d retx=%d dupacks=%d out_of_order=%d bytes_tx=%d bytes_rx=%d secure=%s sec_auth_fail=%d sec_ctrl=%d sec_plaintext=%d",
        tostring(tag), self.cwnd, self.ssthresh,
        self.srtt and string.format("%.3f", self.srtt) or "?", self.rto,
        self.tx, self.retx, self.dupacks, self.dup_rx, self.bytes_tx, self.bytes_rx,
        tostring(self.secure), self.sec_drops.auth, self.sec_drops.ctrl, self.sec_drops.plaintext_peer)
    self.node:log("CONN_P3 sack_rx=%d sack_sent=%d sack_retx=%d ooo_buffered=%d ooo_bytes=%d keepalives=%d rwnd=%d wscale=%d peer_rwnd=%s gmax=%d",
        self.sack_rx, self.sack_sent, self.sack_retx, self.ooo_buffered, self.ooo_bytes,
        self.keepalives, self.rwnd, self.wscale, tostring(self.peer_rwnd), self.gmax)
end

function Conn:start_timer()
    if self.closed then return end
    self.node:after(0.05, function() self:_tick() end)
end

function Conn:_tick()
    if self.closed or self.state == "CLOSED" then return end
    local now = os.clock()
    -- control segments (SYN / SYN-ACK) retransmission
    if self.state == "SYN_SENT" or self.state == "SYN_RCVD" then
        self.syn_tries = (self.syn_tries or 1)
        if not self.syn_t0 then self.syn_t0 = now end
        if now - self.syn_t0 >= self.rto then
            if self.syn_tries >= 6 then
                return self:abort("handshake timeout")
            end
            self.syn_tries = self.syn_tries + 1
            self.syn_t0 = now
            self.rto = math.min(self.rto * 2, self.rto_max or 2.0)
            local t = (self.state == "SYN_SENT") and T_SYN or T_SYNACK
            local payload = (t == T_SYN) and self:_syn_payload() or self:_synack_payload()
            self:_send_ctrl(t, self.iss, self.rcv_nxt, payload)
            self.node:log("CONN_HANDSHAKE_RETX type=%d try=%d rto=%.3f", t, self.syn_tries, self.rto)
        end
    end
    -- keepalive: probe when idle, give up after 3 unanswered probes
    if self.keepalive > 0 and self.state == "ESTABLISHED" then
        local idle = now - (self.last_activity or now)
        if idle >= self.keepalive then
            self.keepalives = self.keepalives + 1
            self.ka_miss = (self.ka_miss or 0) + 1
            self.last_activity = now
            if self.ka_miss > 3 then
                self.node:log("CONN_KEEPALIVE_TIMEOUT misses=%d probes=%d", self.ka_miss, self.keepalives)
                return self:abort("keepalive timeout")
            end
            self.node:log("CONN_KEEPALIVE probe=%d idle=%.2fs miss=%d", self.keepalives, idle, self.ka_miss)
            self:_send_ctrl(T_SACK, self.snd_nxt, self.rcv_nxt, u8(0))
        end
    end
    -- data retransmission (RTO with AIMD collapse)
    for seq, rec in pairs(self.unacked) do
        if rec.t0 and now - rec.t0 >= self.rto then
            if rec.tries >= 6 then return self:abort("data timeout seq=" .. tostring(seq)) end
            self.ssthresh = math.max(2, floor(self.cwnd / 2))
            self.cwnd = 1
            self.retx = self.retx + 1
            self.rto = math.min(self.rto * 2, self.rto_max or 2.0)
            self.node:log("CONN_RTO seq=%d rto=%.3f cwnd=1 ssthresh=%d retx=%d", seq, self.rto, self.ssthresh, self.retx)
            self:_transmit(rec)
            self:pump()
            break
        end
    end
    self:start_timer()
end

function M.conn_connect(node, ip, port, opts)
    opts = opts or {}
    local c = M.conn_new(node, {
        port = opts.sport or port, peer_ip = ip, peer_port = port, state = "SYN_SENT",
    })
    c:_send_ctrl(T_SYN, c.iss, 0, c:_syn_payload())
    c.snd_nxt = c.iss + 1              -- the SYN itself consumes one sequence number
    c.syn_tries, c.syn_t0 = 1, os.clock()
    c:_bind()
    c:start_timer()
    node:log("CONN_SYN_SENT peer=%s:%d iss=%d secure=%s", int2ip(ip), port, c.iss, tostring(c.secure))
    return c
end

function Conn:_bind()
    self.sk = self.node:bind(self.port, function(data, src, sport)
        local s = M.conn_parse(data)
        if not s then
            self.node:log("CONN_BAD_SEG from=%s bytes=%d", int2ip(src), #data)
            return
        end
        self:_on_segment(s, src, sport)
    end)
end

function M.conn_listen(node, port, on_accept)
    local l = { node = node, port = port, on_accept = on_accept, conns = {} }
    l.sk = node:bind(port, function(data, src, sport)
        local s = M.conn_parse(data)
        if not s then
            node:log("CONN_BAD_SEG from=%s bytes=%d", int2ip(src), #data)
            return
        end
        local key = src .. ":" .. sport
        local c = l.conns[key]
        if not c and s.t == T_SYN then
            c = M.conn_new(node, { port = port, peer_ip = src, peer_port = sport, state = "SYN_RCVD" })
            if c.secure and not c:_check_syn_payload(s.payload, s.seq) then
                c.sec_drops.ctrl = c.sec_drops.ctrl + 1
                node:log("CONN_SEC_SYN_REJECT from=%s:%d (unauthenticated SYN)", int2ip(src), sport)
                return
            end
            c.listener = l
            l.conns[key] = c
            c.rcv_nxt = s.seq + 1
            c:_send_ctrl(T_SYNACK, c.iss, c.rcv_nxt, c:_synack_payload())
            c.snd_nxt = c.iss + 1          -- SYN-ACK consumed one sequence number
            if c.secure then sec_derive(c) end
            c.syn_tries, c.syn_t0 = 1, os.clock()
            c:start_timer()
            node:log("CONN_SYN_RCVD from=%s:%d iss=%d secure=%s", int2ip(src), sport, c.iss, tostring(c.secure))
        elseif c then
            c:_on_segment(s, src, sport)
        else
            node:log("CONN_NO_SYN type=%d from=%s:%d", s.t, int2ip(src), sport)
        end
    end)
    return l
end

return M
