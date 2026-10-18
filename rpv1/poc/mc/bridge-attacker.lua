--[[- bridge-attacker ? hostile third party on the bridge LINK channel (test tool).

Standalone test program (own config `attack.txt`, no rpv imports). It sits on the
same channel the two bridges use and tries everything an off-path adversary could:

  1. FORGE   - send "S"-framed payloads with random counters and bogus tags
  2. HELLO   - send unauthenticated pairing requests (must not pair / not flap)
  3. REPLAY  - capture real authenticated frames off the link and re-send them
               verbatim (valid tags, but the counters are stale -> replay window)
  4. OVERSIZE- send a frame larger than the bridge's max relayed size
  5. POLICY  - send a correctly-sized, random-tag frame so only the tag can reject it

Every attempt is counted; the bridge under test must show matching drop counters
(`unauth`, `replay`, `size`, `bad`) and must never relay any of it into the LAN.

  attack.txt keys:
      attack_side=right        -- side of the modem on the link channel
      attack_channel=4999      -- the bridge link channel
      attack_secs=30
      attack_id=rpv1           -- bridge_id the bridges use
      attack_forge=20          -- forged "S" frames
      attack_hellos=8          -- unauthenticated HELLOs
      attack_oversize=4096     -- size for the oversize attempt
]]
local function cfg(key, default)
    local f = fs.open("attack.txt", "r")
    if not f then return default end
    local v = default
    for line in f.readLine do
        local k, val = line:match("^([%w_]+)=(.*)$")
        if k == key then v = val end
    end
    f.close()
    return v
end

local side = cfg("attack_side", "right")
local chan = tonumber(cfg("attack_channel", "4999"))
local secs = tonumber(cfg("attack_secs", "30"))
local bridgeId = cfg("attack_id", "rpv1")
local nForge = tonumber(cfg("attack_forge", "20"))
local nHello = tonumber(cfg("attack_hellos", "8"))
local oversize = tonumber(cfg("attack_oversize", "4096"))
local atForge = tonumber(cfg("attack_forge_at", "2"))
local atHello = tonumber(cfg("attack_hello_at", "4"))
local atReplay = tonumber(cfg("attack_replay_at", "10"))
local atOversize = tonumber(cfg("attack_oversize_at", "13"))
local atBadTag = tonumber(cfg("attack_badtag_at", "15"))

local log = fs.open("attack-log.txt", "w")
local function w(fmt, ...)
    log.writeLine(string.format("%.3f attacker " .. fmt, os.clock(), ...))
    log.flush()
end

local function u32be(v)
    v = math.floor(v)
    return string.char(math.floor(v / 0x1000000) % 256, math.floor(v / 0x10000) % 256,
        math.floor(v / 0x100) % 256, v % 256)
end
local function rnd(n)
    local out = {}
    for i = 1, n do out[i] = string.char(math.random(0, 255)) end
    return table.concat(out)
end
local function tx(payload)
    return (pcall(function() peripheral.call(side, "transmit", chan, chan, payload) end))
end

math.randomseed((os.epoch and os.epoch("utc") or os.time()) * 7 + 13)
for _ = 1, 8 do math.random() end
if periphemu and peripheral.getType(side) ~= "modem" then periphemu.create(side, "modem") end
pcall(function() peripheral.call(side, "open", chan) end)
w("START side=%s chan=%d secs=%d target_id=%s", side, chan, secs, bridgeId)

local captured, replayed = {}, 0
local sentForge, sentHello, sentOversize, sentBadTag = 0, 0, 0, 0

-- a LAN-shaped frame (dstMAC|srcMAC|ethertype|body) so policy checks see something real
local function lanish(payloadBytes)
    return u32be(0x0A000002) .. u32be(0x00000001) .. string.char(0x08, 0x00) .. rnd(payloadBytes)
end

local t0 = os.clock()
local phase = 1
os.startTimer(0.25)

-- trap: a headless computer only shows errors on its screen, which a test can
-- never see, so failures must land in the log
local function loop()
while os.clock() - t0 < secs do
    local ev, a, b, c, d = os.pullEvent()
    if ev == "modem_message" then
        -- harvest real frames for replay (a captured tag is valid; only the
        -- counter is stale, which is exactly what the replay window must catch)
        local msg = d
        if type(msg) == "string" and msg:sub(1, 1) == "S" and #captured < 16 then
            captured[#captured + 1] = msg
        end
    elseif ev == "timer" then
        os.startTimer(0.25)
        local now = os.clock() - t0
        if phase == 1 and now > atForge then
            phase = 2
            for i = 1, nForge do
                if tx("S" .. u32be(i) .. lanish(60) .. rnd(16)) then sentForge = sentForge + 1 end
            end
            w("FORGE sent=%d (random tags)", sentForge)
        elseif phase == 2 and now > atHello then
            phase = 3
            for i = 1, nHello do
                if tx("Q" .. bridgeId .. rnd(8) .. rnd(16)) then sentHello = sentHello + 1 end
            end
            w("HELLO sent=%d (unauthenticated)", sentHello)
        elseif phase == 3 and now > atReplay then
            phase = 4
            for _, frame in ipairs(captured) do
                if tx(frame) then replayed = replayed + 1 end
            end
            w("REPLAY captured=%d replayed=%d", #captured, replayed)
        elseif phase == 4 and now > atOversize then
            phase = 5
            if tx("S" .. u32be(999999) .. lanish(oversize) .. rnd(16)) then sentOversize = 1 end
            w("OVERSIZE bytes=%d", oversize + 26)
        elseif phase == 5 and now > atBadTag then
            phase = 6
            for i = 1, 5 do
                if tx("S" .. u32be(100000 + i) .. lanish(200) .. rnd(16)) then sentBadTag = sentBadTag + 1 end
            end
            w("BADTAG sent=%d", sentBadTag)
        end
    end
end

w("ATTACK_RESULT forge=%d hello=%d replay_captured=%d replay_sent=%d oversize=%d badtag=%d",
    sentForge, sentHello, #captured, replayed, sentOversize, sentBadTag)
w("TEST_DONE")
end

local ok, err = pcall(loop)
if not ok then
    w("ATTACK_ERROR %s", tostring(err))
    w("ATTACK_RESULT forge=%d hello=%d replay_captured=%d replay_sent=%d oversize=%d badtag=%d",
        sentForge, sentHello, #captured, replayed, sentOversize, sentBadTag)
    w("TEST_DONE")
end
log.close()
