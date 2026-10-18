--[[- apps/advert-spoof.lua — injects bogus WAN adverts to test the M2 hardening.

Sends, from `ip` with gateway id `gw`:
  1. seq=S                     -> accepted
  2. seq=S again (1.5 s later) -> must be rejected as stale
  3. seq=S+1, hops=9           -> must be rejected by loop protection

  app=advert-spoof:172.16.0.99:99:5
]]
return function(M, node, args)
    local ip, gw, seq = args:match("^([%d%.]+):(%d+):(%d+)$")
    if not ip then
        node:log("SPOOF_BAD_ARGS args=%s", tostring(args))
        return
    end
    gw, seq = tonumber(gw), tonumber(seq)
    local side = node.cfg.wan_side or "back"
    rednet.open(side)
    node:log("SPOOF_READY side=%s ip=%s gw=%d seq=%d", side, ip, gw, seq)

    local function send(s, hops, why)
        rednet.broadcast({
            sType = "rpv-advert", ver = 1, seq = s, hops = hops,
            gw = gw, ip = ip, nets = { "10.77.0.0/24" },
        }, "rpv")
        node:log("SPOOF_ADVERT_SENT seq=%d hops=%d (%s)", s, hops, why)
    end

    node:after(2.0, function() send(seq, 1, "fresh") end)
    node:after(3.5, function() send(seq, 1, "duplicate, must be stale") end)
    node:after(5.0, function() send(seq + 1, 9, "too many hops, must be dropped") end)
    node:after(6.5, function()
        node:log("SPOOF_DONE")
        node:log("TEST_DONE")
    end)
end
