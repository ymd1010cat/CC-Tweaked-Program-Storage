--[[- wan-sniffer ? standalone WAN eavesdropper / replayer (no rpv library).

Runs AS startup.lua on a throwaway computer, like the bridge attacker. It opens the
rednet broadcast channel plus the WAN peers' ID channels, so it sees everything the
routers exchange over rednet:

    sniff.txt keys:
        sniff_ids=21,22          rednet ids to listen on (their unicast channels)
        sniff_mode=log|replay    replay re-transmits the first captured "S" frame
        sniff_replay_at=6        seconds before the replay
        sniff_secs=30            total runtime
        sniff_marker=RPVSECRET   marker that must NOT be visible when the tunnel is
                                 encrypted (the harness greps this log for it)

Output: sniff-log.txt with SNIFF lines, SNIFF_MARKER_SEEN when the marker is found in
cleartext, SNIFF_REPLAY_SENT for the replay, and SNIFF_DONE at the end.
]]
local function cfg(name, default)
    if not fs.exists("sniff.txt") then return default end
    local f = fs.open("sniff.txt", "r")
    local out = default
    for line in f.readLine do
        local k, v = line:match("^([%w_]+)%s*=%s*(.-)%s*$")
        if k == name then out = v end
    end
    f.close()
    return out
end

local ids = {}
for id in tostring(cfg("sniff_ids", "21,22")):gmatch("%d+") do ids[#ids + 1] = tonumber(id) end
local mode = cfg("sniff_mode", "log")
local replayAt = tonumber(cfg("sniff_replay_at", "6")) or 6
local secs = tonumber(cfg("sniff_secs", "30")) or 30
local marker = cfg("sniff_marker", "RPVSECRET")

local log = fs.open("sniff-log.txt", "w")
local t0 = os.clock()
local function w(fmt, ...)
    log.writeLine(string.format("%.3f " .. fmt, os.clock() - t0, ...))
    log.flush()
end

local side = nil
for _, s in ipairs({ "left", "right", "back", "front", "top", "bottom" }) do
    if peripheral.getType(s) == "modem" then side = s break end
end
if not side and periphemu and periphemu.create then
    -- CraftOS-PC: a plain computer has no peripherals, so make ourselves a modem
    pcall(periphemu.create, "left", "modem")
    if peripheral.getType("left") == "modem" then side = "left" end
end
if not side then
    w("SNIFF_NO_MODEM")
    log.close()
    return
end
peripheral.call(side, "open", 65535)          -- rednet broadcast
for _, id in ipairs(ids) do peripheral.call(side, "open", id) end
w("SNIFF_START side=%s ids=%s mode=%s marker=%s secs=%d", side, table.concat(ids, ","), mode, marker, secs)

local captured, capturedCh, capturedReply = nil, nil, nil
local markerSeen, frames = 0, 0
local envDumped = false
local stopAt = t0 + secs
local replayDone = false

while os.clock() < stopAt do
    local timer = os.startTimer(0.5)
    local ev, p1, p2, p3, p4 = os.pullEvent()
    if ev == "modem_message" then
        -- p1 side, p2 channel, p3 replyChannel (= rednet sender id), p4 message
        local ch, reply, env = p2, p3, p4
        if type(env) ~= "table" then env = nil end
        if env then
            if not envDumped then
                envDumped = true
                local keys = {}
                for k, v in pairs(env) do keys[#keys + 1] = tostring(k) .. ":" .. type(v) end
                w("SNIFF_ENV keys=%s", table.concat(keys, ","))
            end
            -- rednet envelope: the real payload is element 1 (some builds use a field)
            local inner = env[1]
            if inner == nil then inner = env.message or env.msg end
            if type(inner) == "string" then
                frames = frames + 1
                local hasMarker = inner:find(marker, 1, true) ~= nil
                if hasMarker then markerSeen = markerSeen + 1 end
                if hasMarker or frames <= 5 then
                    w("SNIFF ch=%s from=%s len=%d marker=%s first=%q", tostring(ch), tostring(reply), #inner,
                        tostring(hasMarker), inner:sub(1, 24))
                end
                if hasMarker then w("SNIFF_MARKER_SEEN ch=%s from=%s len=%d", tostring(ch), tostring(reply), #inner) end
                if mode == "replay" and not captured and inner:sub(1, 1) == "S" and #inner > 24 then
                    captured, capturedCh, capturedReply = inner, ch, reply
                    w("SNIFF_CAPTURED ch=%s from=%s len=%d (encrypted frame)", tostring(ch), tostring(reply), #inner)
                end
            elseif type(inner) == "table" then
                w("SNIFF_TABLE ch=%s from=%s sType=%s nonce=%s", tostring(ch), tostring(reply),
                    tostring(inner.sType), tostring(inner.nonce and "yes" or "-"))
            else
                w("SNIFF_OTHER ch=%s from=%s inner=%s", tostring(ch), tostring(reply), type(inner))
            end
        end
    elseif ev == "timer" then
        -- NB: do NOT compare p1 against the timer started in this iteration -- with a
        -- steady stream of modem messages the timer event is delivered one iteration
        -- later and the id never matches, so the replay branch would never run.
        if mode == "replay" and captured and not replayDone and (os.clock() - t0) >= replayAt then
            -- verbatim re-send with a FRESH rednet message id and the original sender's
            -- id in the reply channel: the receiver sees a genuine frame from that peer,
            -- so this exercises our own replay window rather than rednet's dedupe
            local freshId = (os.epoch("utc") % 2000000000) + 1
            -- this CC build's rednet envelope uses named fields (dumped at runtime)
            local envelope = { message = captured, nMessageID = freshId, nRecipient = capturedCh,
                               nSender = capturedReply, sProtocol = "rpv" }
            local ok, err = pcall(peripheral.call, side, "transmit", capturedCh, capturedReply or 1, envelope)
            replayDone = true
            w("SNIFF_REPLAY_SENT ch=%s spoofed_from=%s msgid=%d len=%d ok=%s err=%s", tostring(capturedCh),
                tostring(capturedReply), freshId, #captured, tostring(ok), tostring(err))
        end
    end
end

w("SNIFF_RESULT frames=%d marker_seen=%d captured=%s replayed=%s", frames, markerSeen,
    tostring(captured ~= nil), tostring(replayDone))
w("SNIFF_DONE")
log.close()
