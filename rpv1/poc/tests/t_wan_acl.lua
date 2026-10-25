--[[- tests/t_wan_acl.lua - apps/wan_acl.lua: default 200..299 band, fail-closed
checks, dynamic allow/deny and whitelist loading (offline).]]
local T, M = ...

local W = M.wan_acl
T.ok(W ~= nil, "wan_acl module loaded")
if not W then return end

local CFG = "t_wan_acl.txt"
local BAD = "t_wan_acl_bad.txt"
local function write(path, text)
    local f = fs.open(path, "w")
    if not f then return false end
    f.write(text)
    f.close()
    return true
end
if fs.exists(CFG) then pcall(fs.delete, CFG) end
if fs.exists(BAD) then pcall(fs.delete, BAD) end

T.eq(W.MIN_CHANNEL, 0, "lowest channel is 0")
T.eq(W.MAX_CHANNEL, 65535, "highest channel is 65535")
T.eq(W.DEFAULT_BAND[1], 200, "default band starts at 200")
T.eq(W.DEFAULT_BAND[2], 299, "default band ends at 299")

T.ok(W.is_channel(0), "0 is a channel")
T.ok(W.is_channel(65535), "65535 is a channel")
T.ok(not W.is_channel(-1), "-1 is not a channel")
T.ok(not W.is_channel(65536), "65536 is not a channel")
T.ok(not W.is_channel(2.5), "2.5 is not a channel")
T.ok(not W.is_channel("200"), "the string \"200\" is not a channel")
T.ok(not W.is_channel(0 / 0), "NaN is not a channel")

-- ===== default band is fail-closed ========================================
local acl = W.new()
T.ok(acl ~= nil, "new() returns an acl")
T.eq(acl:check(200), true, "lower band edge allowed")
T.eq(acl:check(250), true, "channel inside the band allowed")
T.eq(acl:check(299), true, "upper band edge allowed")
T.eq(acl:check(199), false, "channel below the band denied")
T.eq(acl:check(300), false, "channel above the band denied")
T.eq(acl:check(0), false, "channel 0 denied")
T.eq(acl:check(65535), false, "channel 65535 denied")

-- ===== invalid channels are always denied ==================================
T.eq(acl:check(nil), false, "nil channel denied")
T.eq(acl:check("250"), false, "string channel denied")
T.eq(acl:check(250.5), false, "fractional channel denied")
T.eq(acl:check(-1), false, "negative channel denied")
T.eq(acl:check(65536), false, "out-of-range channel denied")
T.eq(acl:check(0 / 0), false, "NaN channel denied")
T.eq(acl:check(true), false, "boolean channel denied")
T.eq(acl:check({}), false, "table channel denied")

local st = acl:stats()
T.eq(st.checked, 15, "stats count every check")
T.eq(st.allowed, 3, "stats count allows")
T.eq(st.denied, 12, "stats count denies")

-- ===== an empty whitelist denies everything ================================
local none = W.new({ band = false })
T.ok(none ~= nil, "band=false builds an empty acl")
T.eq(none:check(250), false, "empty whitelist denies a band channel")
T.eq(none:check(299), false, "empty whitelist denies the upper edge")
T.eq(none:check(0), false, "empty whitelist denies channel 0")

-- ===== dynamic allow =======================================================
local dyn = W.new()
T.eq(dyn:check(4700), false, "4700 denied before allow")
T.eq(dyn:allow(4700), true, "allow accepts a valid channel")
T.eq(dyn:check(4700), true, "allowed channel passes")
T.eq(dyn:allow(250), true, "allow is idempotent for a band channel")
T.eq(dyn:check(250), true, "band channel still passes")
T.eq(dyn:allow(nil), nil, "allow rejects nil")
T.eq(dyn:allow("4701"), nil, "allow rejects a string")
T.eq(dyn:allow(70000), nil, "allow rejects an out-of-range channel")
T.eq(dyn:check(4701), false, "rejected allow does not whitelist")
T.eq(dyn:allow_range(500, 510), true, "allow_range accepts a band")
T.eq(dyn:check(505), true, "channel inside the added range passes")
T.eq(dyn:allow_range(510, 500), nil, "inverted range rejected")
T.eq(dyn:allow_range(500, 70000), nil, "out-of-range band rejected")

-- ===== explicit deny wins ==================================================
local denied = W.new()
T.eq(denied:deny(250), true, "deny accepts a band channel")
T.eq(denied:check(250), false, "denied channel is rejected even inside the band")
T.eq(denied:allow(250), true, "allow after deny is accepted")
T.eq(denied:check(250), false, "deny keeps winning over allow")
T.eq(denied:deny(nil), nil, "deny rejects nil")

-- ===== whitelist file ======================================================
T.ok(write(CFG, "# wan channels\n200-299\n4700\n"), "whitelist fixture written")
local from_file = W.new({ band = false, path = CFG })
T.ok(from_file ~= nil, "acl with a whitelist file built")
T.eq(from_file.config_error, nil, "whitelist file loaded without error")
T.eq(from_file:check(250), true, "config band entry allowed")
T.eq(from_file:check(299), true, "config band upper edge allowed")
T.eq(from_file:check(4700), true, "config single channel allowed")
T.eq(from_file:check(4800), false, "channel outside the config denied")

local latest = W.new({ band = false })
T.eq(latest:check(4700), false, "fresh acl starts empty")
local lr = latest:load(CFG)
T.eq(lr and lr.ok, true, "load returns ok")
T.eq(lr and lr.ranges, 1, "load reports one range")
T.eq(lr and lr.channels, 1, "load reports one channel")
T.eq(latest:check(4700), true, "load applied the channel")
T.eq(latest:check(250), true, "load applied the range")

-- a malformed file changes nothing
T.ok(write(BAD, "200-299\nnot-a-channel\n"), "bad whitelist fixture written")
local bad_load, bad_err = latest:load(BAD)
T.eq(bad_load, nil, "malformed whitelist is rejected")
T.ok(type(bad_err) == "string", "malformed whitelist returns an error")
T.eq(latest:check(4700), true, "failed load keeps the old policy")
T.eq(latest:check(250), true, "failed load keeps the old range")

local missing, missing_err = latest:load("t_wan_acl_nope.txt")
T.eq(missing, nil, "missing whitelist is rejected")
T.ok(type(missing_err) == "string", "missing whitelist returns an error")
T.eq(latest:check(4700), true, "missing whitelist keeps the old policy")

local trav, trav_err = latest:load("../wan_acl.txt")
T.eq(trav, nil, "whitelist path traversal rejected")
T.ok(tostring(trav_err):find("traversal") ~= nil, "traversal error names the reason")

local broken = W.new({ band = false, path = "t_wan_acl_nope.txt" })
T.ok(broken ~= nil, "acl with a missing whitelist still builds")
T.ok(type(broken.config_error) == "string", "missing whitelist recorded in config_error")
T.eq(broken:check(250), false, "missing whitelist leaves the policy fail-closed")

-- ===== a whitelist that does not fit is never applied partially ===========
-- Regression: load() applied the file's bands one by one, so a policy close to
-- MAX_RANGES got the leading bands of the file and then nil ("too many channel
-- ranges") -- a failed load that still changed the policy. The capacity check
-- must happen before the first apply (fail-closed).
local NARROW = "t_wan_acl_narrow.txt"
local OVER = "t_wan_acl_over.txt"
local EXACT = "t_wan_acl_exact.txt"
T.ok(write(NARROW, "100-101\n102-103\n"), "narrow whitelist fixture written")

local function band_file(path, count, base)
    local lines = {}
    for i = 0, count - 1 do
        local lo = base + i * 2
        lines[#lines + 1] = lo .. "-" .. (lo + 1)
    end
    return write(path, table.concat(lines, "\n") .. "\n")
end

local function fill(acl, first, last)
    for i = first, last do
        local ok = acl:allow_range(2000 + i * 2, 2001 + i * 2)
        if not ok then return false end
    end
    return true
end

local near = W.new()                              -- default band = 1 range
T.eq(fill(near, 2, W.MAX_RANGES - 1), true, "near-full acl built")
local near_before = near:stats()
T.eq(near_before.ranges, W.MAX_RANGES - 1, "near-full acl sits one range below the limit")
local nok, nerr = near:load(NARROW)
T.eq(nok, nil, "load rejected when the file does not fit the remaining ranges")
T.eq(nerr, "too many channel ranges", "rejection names the range limit")
local near_after = near:stats()
T.eq(near_after.ranges, near_before.ranges, "failed load kept the range count")
T.eq(near_after.channels, near_before.channels, "failed load kept the channel count")
T.eq(near_after.config_error, near_before.config_error, "failed load kept config_error")
T.eq(near:check(100), false, "failed load did not apply the first file range")
T.eq(near:check(102), false, "failed load did not apply the second file range")
T.eq(near:check(250), true, "the default band still applies after the failed load")
T.eq(near:check(2004), true, "ranges added before the failed load still apply")
local near_probe = near:stats()
T.eq(near_probe.checked, near_after.checked + 4, "probes after the failed load are counted")
T.eq(near_probe.denied, near_after.denied + 2, "both file bands are still denied")
T.eq(near_probe.allowed, near_after.allowed + 2, "both pre-existing ranges still allow")

-- a file with more bands than the whole capacity is refused with no change
T.ok(band_file(OVER, W.MAX_RANGES + 1, 4000), "oversized whitelist fixture written")
local roomy = W.new({ band = false })
local roomy_before = roomy:stats()
local ook, oerr = roomy:load(OVER)
T.eq(ook, nil, "oversized whitelist is rejected")
T.eq(oerr, "too many channel ranges", "oversized whitelist names the range limit")
local roomy_after = roomy:stats()
T.eq(roomy_after.ranges, roomy_before.ranges, "oversized whitelist added no range")
T.eq(roomy_after.channels, roomy_before.channels, "oversized whitelist added no channel")
T.eq(roomy:check(4000), false, "oversized whitelist applied none of its leading bands")

-- the boundary itself still loads: 1 band + (MAX_RANGES - 1) file bands
T.ok(band_file(EXACT, W.MAX_RANGES - 1, 5000), "boundary whitelist fixture written")
local fits = W.new()                              -- default band = 1 range
local fit_load = fits:load(EXACT)
T.eq(fit_load and fit_load.ok, true, "a whitelist that exactly fits still loads")
T.eq(fit_load and fit_load.ranges, W.MAX_RANGES - 1, "boundary load reports every range")
T.eq(fits:stats().ranges, W.MAX_RANGES, "boundary load fills the range list to the limit")
T.eq(fits:check(5252), true, "the last fitted range applies")
T.eq(fits:check(200), true, "the default band still applies")
local full_ok, full_err = fits:load(NARROW)
T.eq(full_ok, nil, "an acl already at MAX_RANGES refuses another file")
T.eq(full_err, "too many channel ranges", "full acl names the range limit")
T.eq(fits:stats().ranges, W.MAX_RANGES, "full acl was not mutated by the refused load")
T.eq(fits:check(100), false, "full acl did not apply the refused file's range")

-- ===== bad constructor arguments ==========================================
T.eq(W.new({ band = { 300, 200 } }), nil, "inverted default band rejected")
T.eq(W.new({ band = "200-299" }), nil, "non-table band rejected")
T.eq(W.new({ allow = "4700" }), nil, "non-table allow list rejected")
T.eq(W.new({ allow = { 70000 } }), nil, "out-of-range allow entry rejected")
T.eq(W.new({ deny = { "250" } }), nil, "non-numeric deny entry rejected")

-- ===== logger sees only the event word, never a payload ===================
local events = {}
local logged = W.new({ log = function(line) events[#events + 1] = line end })
T.eq(logged:check(300), false, "logged acl denies 300")
T.eq(#events, 1, "one deny event logged")
T.eq(events[1], "WAN_ACL_DENY", "logger receives only the event word")
T.eq(logged:check(250), true, "logged acl allows 250")
T.eq(#events, 1, "allows are not logged")
T.eq(logged.denied, 1, "denied counter")
T.eq(logged.allowed, 1, "allowed counter")

-- a logger that throws must not break policy
local boom = W.new({ log = function() error("logger failed") end })
T.eq(boom:check(300), false, "throwing logger cannot open the acl")
T.eq(boom.denied, 1, "throwing logger still counted the deny")
