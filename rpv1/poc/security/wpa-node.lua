--[[- WPA2-inspired security demo node.

Two computers run this program (role=ap / role=sta from wpa.txt), do the 4-way
handshake over rednet (protocol "rpv-wpa"), then exchange AEAD-protected data
frames. The station also replays a captured frame to prove replay rejection.

Config file wpa.txt:
  role=ap|sta     peer=<rednet id>    net=<network name>    psk=<passphrase>
  iters=256       messages=3          wrong_psk=0|1         replay=1
  start_delay=1
]]
local logfile = fs.open("wpa-log.txt", "w")
local function log(fmt, ...)
    local line = string.format("%.3f [%d] ", os.clock(), os.getComputerID())
        .. (select("#", ...) > 0 and string.format(fmt, ...) or fmt)
    logfile.writeLine(line)
    logfile.flush()
    print(line)
end

-- emulator glue only
if periphemu and peripheral.getType("back") ~= "modem" then periphemu.create("back", "modem") end

local cfg = {}
do
    local f = fs.open("wpa.txt", "r")
    if f then
        for line in f.readLine do
            line = line:gsub("#.*$", ""):gsub("^%s+", ""):gsub("%s+$", "")
            local k, v = line:match("^([%w_]+)=(.*)$")
            if k then cfg[k] = v end
        end
        f.close()
    end
end

local crypto = dofile("crypto.lua")
local wpa = assert(loadfile("wpa.lua"))(crypto)

local role = cfg.role or "sta"
local peer = tonumber(cfg.peer or "0")
local net = cfg.net or "rpv-lab"
local iters = tonumber(cfg.iters) or 256
local messages = tonumber(cfg.messages) or 3
local psk = cfg.psk or ""
if cfg.wrong_psk == "1" then psk = psk .. "-WRONG" end

rednet.open("back")
log("WPA_BOOT role=%s peer=%d net=%s iters=%d wrong_psk=%s", role, peer, net, iters, tostring(cfg.wrong_psk == "1"))

-- emulator/helper: open the peer computer inside the same CraftOS-PC process
if cfg.spawn and ccemux then
    for id in cfg.spawn:gmatch("%d+") do
        local ok, res = pcall(ccemux.openEmu, tonumber(id))
        log("SPAWN id=%s ok=%s res=%s", id, tostring(ok), tostring(res))
    end
end

local t0 = os.epoch and os.epoch("utc") or 0
local pmk = wpa.derive_pmk(psk, net, iters, 64)
log("WPA_PMK_READY iters=%d ms=%d hex=%s", iters,
    (os.epoch and os.epoch("utc") or 0) - t0, crypto.hex(string.sub(pmk, 1, 4)) .. "..")

local my_mac = tostring(os.getComputerID())
local peer_mac = tostring(peer)
local hs = wpa.new_handshake(role, pmk, role == "ap" and my_mac or peer_mac, role == "ap" and peer_mac or my_mac)

local function send_msg(t)
    rednet.send(peer, textutils.serialize(t), "rpv-wpa")
end
local function recv_msg(timeout)
    local sender, message = rednet.receive("rpv-wpa", timeout or 10)
    if not sender then return nil end
    return textutils.unserialize(message)
end

local result = { established = false, data_ok = 0, replay_rejected = false, mic_fail = false }

if role == "ap" then
    os.sleep(tonumber(cfg.start_delay) or 1)
    local m1 = wpa.hs_start(hs)
    send_msg(m1)
    log("WPA_M1_SENT anonce=%s", crypto.hex(string.sub(m1.anonce, 1, 4)) .. "..")

    local m2 = recv_msg(15)
    if not m2 then
        log("WPA_FAIL no M2")
    else
        log("WPA_M2_RECV snonce=%s mic=%s", crypto.hex(string.sub(m2.snonce or "", 1, 4)) .. "..", crypto.hex(string.sub(m2.mic or "", 1, 4)) .. "..")
        local m3, err = wpa.hs_rx_m2(hs, m2)
        if not m3 then
            log("WPA_HANDSHAKE_FAIL stage=M2 reason=%s", tostring(err))
            result.mic_fail = true
            send_msg({ t = "ABORT" })
        else
            log("WPA_M2_MIC_OK")
            send_msg(m3)
            log("WPA_M3_SENT gtk_wrapped_bytes=%d", #m3.gtk_ct)
            local m4 = recv_msg(15)
            if not m4 then
                log("WPA_FAIL no M4")
            else
                local ok, err = wpa.hs_rx_m4(hs, m4)
                if not ok then
                    log("WPA_HANDSHAKE_FAIL stage=M4 reason=%s", tostring(err))
                    result.mic_fail = true
                else
                    log("WPA_M4_MIC_OK")
                    result.established = true
                    log("WPA_ESTABLISHED role=ap")
                end
            end
        end
    end
end

if role == "sta" then
    local m1 = recv_msg(20)
    if not m1 then
        log("WPA_FAIL no M1")
    elseif m1.t == "M1" then
        local m2 = wpa.hs_rx_m1(hs, m1)
        send_msg(m2)
        log("WPA_M2_SENT snonce=%s mic=%s", crypto.hex(string.sub(m2.snonce, 1, 4)) .. "..", crypto.hex(string.sub(m2.mic, 1, 4)) .. "..")
        local m3 = recv_msg(15)
        if not m3 then
            log("WPA_FAIL no M3")
        else
            local m4, err = wpa.hs_rx_m3(hs, m3)
            if not m4 then
                log("WPA_HANDSHAKE_FAIL stage=M3 reason=%s", tostring(err))
                result.mic_fail = true
            else
                log("WPA_M3_GTK_UNWRAP_OK gtk=%s", crypto.hex(string.sub(hs.gtk, 1, 4)) .. "..")
                send_msg(m4)
                log("WPA_M4_SENT")
                result.established = true
                log("WPA_ESTABLISHED role=sta")
            end
        end
    else
        log("WPA_ABORT_RECV reason=%s", tostring(m1.reason or m1.t))
        log("WPA_HANDSHAKE_FAIL remote=authentication rejected")
        result.mic_fail = true
    end
end

-- data plane keys (both roles), derived once the handshake has finished
local keys, rx, tx_pn = nil, wpa.new_rx(), 0
if hs.state == "established" then
    keys = {
        tx = wpa.data_keys(hs.ptk.tk, role == "ap" and "ap2sta" or "sta2ap"),
        rx = wpa.data_keys(hs.ptk.tk, role == "ap" and "sta2ap" or "ap2sta"),
    }
    log("WPA_KEYS_READY tx_enc=%s rx_mac=%s",
        crypto.hex(string.sub(keys.tx.enc, 1, 4)) .. "..", crypto.hex(string.sub(keys.rx.mac, 1, 4)) .. "..")
end

-- station sends sealed frames (and one replay); AP opens them
if result.established and keys then
    if role == "sta" then
        local first_frame = nil
        for i = 1, messages do
            tx_pn = tx_pn + 1
            local frame = wpa.seal(keys.tx, tx_pn, "secure data #" .. i)
            if i == 1 then first_frame = frame end
            rednet.send(peer, frame, "rpv-data")
            log("WPA_DATA_TX pn=%d bytes=%d", tx_pn, #frame)
        end
        if cfg.replay == "1" then
            os.sleep(1)
            rednet.send(peer, first_frame, "rpv-data")   -- identical bytes: must be rejected
            log("WPA_REPLAY_SENT pn=1 (same bytes as the first frame)")
        end
        os.sleep(3)
        local summary = result.established and not result.mic_fail
        log("WPA_RESULT established=%s data_sent=%d replay_sent=%s", tostring(result.established), messages, tostring(cfg.replay == "1"))
        log("TEST_DONE ok=%s", tostring(summary))
    else
        -- AP: open incoming frames until timeout
        local deadline = os.clock() + 12
        while os.clock() < deadline do
            local sender, message = rednet.receive("rpv-data", 1)
            if message then
                if type(message) ~= "string" then
                    log("WPA_DATA_BAD type=%s", type(message))
                else
                    local plain, err, got_pn = wpa.open(keys.rx, message)
                    if not plain then
                        log("WPA_DATA_REJECT reason=%s sender=%s", tostring(err), tostring(sender))
                        if tostring(err) == "tag mismatch" then result.tag_fail = true end
                    elseif not wpa.replay_check(rx, got_pn) then
                        result.replay_rejected = true
                        log("WPA_REPLAY_REJECTED pn=%d sender=%s", got_pn, tostring(sender))
                    else
                        result.data_ok = result.data_ok + 1
                        log("WPA_DATA_RX pn=%d plaintext=%s", got_pn, plain)
                    end
                end
            elseif os.clock() > deadline - 0.5 then
                break
            end
        end
        log("WPA_RESULT established=true data_ok=%d replay_rejected=%s", result.data_ok, tostring(result.replay_rejected))
        log("AP_DONE")
    end
else
    log("WPA_RESULT established=%s handshake_failed=true", tostring(result.established))
    if role == "sta" then log("TEST_DONE ok=false") end
end

os.sleep(0.5)
logfile.close()
os.shutdown()
