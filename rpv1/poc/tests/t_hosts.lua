--[[- tests/t_hosts.lua - apps/hosts.lua: validation, load/resolve, atomic save,
update protocol with timeout/retry (offline, no sockets).]]
local T, M = ...

local H = M.hosts
T.ok(H ~= nil, "hosts module loaded")
if not H then return end

-- ===== helpers =============================================================
local function write(path, text)
    local f = fs.open(path, "w")
    if not f then return false end
    f.write(text)
    f.close()
    return true
end

local function read(path)
    local f = fs.open(path, "r")
    if not f then return nil end
    local s = f.readAll()
    f.close()
    return s
end

local function clean(path)
    if fs.exists and fs.exists(path) then pcall(fs.delete, path) end
end

local function n_of(t)
    local n = 0
    for _ in pairs(t) do n = n + 1 end
    return n
end

local BASE = "t_hosts_base.txt"
local SAVE = "t_hosts_save.txt"
local SAVE2 = "t_hosts_save2.txt"
local UPD = "t_hosts_upd.txt"
for _, p in ipairs({ BASE, SAVE, SAVE2, UPD }) do
    clean(p)
    clean(p .. ".tmp")
    clean(p .. ".bak")
end

-- ===== hostname / ip validation ============================================
T.eq(H.validate_name("router"), true, "plain name is valid")
T.eq(H.validate_name("a"), true, "single-character name is valid")
T.eq(H.validate_name("a.b-c_1"), true, "dots, dashes and underscores are valid")
T.ok(not H.validate_name(nil), "nil hostname rejected")
T.ok(not H.validate_name(""), "empty hostname rejected")
T.ok(not H.validate_name("-bad"), "hostname cannot start with a dash")
T.ok(not H.validate_name("bad-"), "hostname cannot end with a dash")
T.ok(not H.validate_name("bad..name"), "empty label rejected")
T.ok(not H.validate_name("bad name"), "embedded space rejected")
T.ok(not H.validate_name(string.rep("a", H.MAX_NAME + 1)), "over-long hostname rejected")
T.ok(not H.validate_name(string.char(195) .. "router"), "non-ASCII hostname rejected")

T.eq(H.validate_ip("10.0.1.1"), true, "dotted quad is valid")
T.eq(H.validate_ip("0.0.0.0"), true, "0.0.0.0 is a valid quad")
T.eq(H.validate_ip("255.255.255.255"), true, "255.255.255.255 is a valid quad")
T.ok(not H.validate_ip("999.1.1.1"), "octet above 255 rejected")
T.ok(not H.validate_ip("10.0.1"), "three-octet ip rejected")
T.ok(not H.validate_ip("10.0.1.1.1"), "five-octet ip rejected")
T.ok(not H.validate_ip("010.0.0.1"), "leading zero rejected")
T.ok(not H.validate_ip("a.b.c.d"), "non-numeric ip rejected")
T.ok(not H.validate_ip(42), "non-string ip rejected")

T.eq(H.ip_to_int("10.0.1.1"), 10 * 16777216 + 0 * 65536 + 1 * 256 + 1, "ip_to_int")
T.eq(H.ip_to_int("nope"), nil, "ip_to_int rejects bad input")

-- ===== parse ===============================================================
local parsed = H.parse("# comment\n\nrouter 10.0.1.1\nprinter 10.0.1.2\n# tail\n")
T.ok(parsed ~= nil, "valid payload parses")
T.eq(parsed and parsed.router, "10.0.1.1", "first entry")
T.eq(parsed and parsed.printer, "10.0.1.2", "second entry")
T.eq(parsed and n_of(parsed), 2, "comments and blanks ignored")

local crlf = H.parse("router 10.0.1.1\r\n")
T.eq(crlf and crlf.router, "10.0.1.1", "CRLF line endings accepted")

local empty = H.parse("")
T.eq(empty and n_of(empty), 0, "empty payload is an empty table")

local dup = H.parse("router 10.0.1.1\nrouter 10.0.1.2\n")
T.ok(not dup, "duplicate hostname rejected")

local bad_payloads = {
    "router 10.0.1\n",
    "router 10.0.1.1.1\n",
    "router 10.0.0.256\n",
    "-router 10.0.1.1\n",
    "router\n",
    "router 10.0.1.1 extra\n",
    "rou ter 10.0.1.1\n",
    "router 010.0.1.1\n",
    string.rep("a", H.MAX_NAME + 1) .. " 10.0.1.1\n",
}
for i = 1, #bad_payloads do
    local t = H.parse(bad_payloads[i], "case" .. i)
    T.ok(not t, "malformed payload " .. i .. " rejected")
end
T.ok(not H.parse(42), "non-string payload rejected")

-- ===== load / resolve / path traversal =====================================
T.ok(write(BASE, "router 10.0.1.1\nprinter 10.0.1.2\n"), "fixture written")
local load_res = H.load(BASE)
T.eq(load_res and load_res.ok, true, "load ok")
T.eq(load_res and load_res.n, 2, "load counts two entries")
T.eq(load_res and load_res.path, BASE, "load remembers the path")

local q = H.resolve("router")
T.eq(q and q.ok, true, "resolve ok")
T.eq(q and q.ip, "10.0.1.1", "resolve returns the dotted quad")
T.eq(q and q.int, H.ip_to_int("10.0.1.1"), "resolve returns the integer form")
T.eq(H.get("printer"), "10.0.1.2", "get returns a plain string")

local miss, merr = H.resolve("missing")
T.eq(miss, nil, "resolve miss returns nil")
T.ok(type(merr) == "string" and #merr > 0, "resolve miss returns an error")
T.eq(H.get("missing"), nil, "get miss returns nil")

local badname, nerr = H.resolve("bad name")
T.eq(badname, nil, "resolve rejects a malformed name")
T.ok(type(nerr) == "string", "resolve malformed name has an error")

local nope, nerr2 = H.load("t_hosts_does_not_exist.txt")
T.eq(nope, nil, "missing file does not load")
T.ok(type(nerr2) == "string", "missing file returns an error")
T.eq(H.get("router"), "10.0.1.1", "failed load keeps the old table")

local trav, terr = H.load("../escape.txt")
T.eq(trav, nil, "path traversal is rejected")
T.ok(tostring(terr):find("traversal") ~= nil, "traversal error names the reason")
T.eq(H.load("a/../../b"), nil, "nested traversal is rejected")
T.eq(H.load("..\\evil.txt"), nil, "backslash traversal is rejected")
T.eq(H.load(""), nil, "empty path is rejected")
T.eq(H.load("dir/"), nil, "directory-like path is rejected")
T.eq(H.load(42), nil, "non-string path is rejected without throwing")
T.eq(H.save("../evil.txt"), nil, "save rejects traversal")

-- ===== set + atomic save ===================================================
T.ok(write(SAVE, "old 10.0.0.9\n"), "save fixture written")
T.ok(H.load(SAVE) ~= nil, "save fixture loaded")
T.eq(H.set("router", "10.0.1.1") and true, true, "set adds an entry")
T.eq(H.set("bad name", "10.0.0.1"), nil, "set rejects a bad hostname")
T.eq(H.set("new", "999.0.0.1"), nil, "set rejects a bad ip")

local saved = H.save(SAVE)
T.eq(saved and saved.ok, true, "save ok")
T.eq(saved and saved.n, 2, "save counts both entries")
T.eq(read(SAVE), "old 10.0.0.9\nrouter 10.0.1.1\n", "save writes sorted lines")
T.ok(not fs.exists(SAVE .. ".tmp"), "temp file is gone after save")
T.ok(not fs.exists(SAVE .. ".bak"), "backup file is gone after save")

-- a failing rename must not destroy the old file or leave the temp behind
T.ok(write(SAVE2, "keep 10.0.0.7\n"), "failure fixture written")
T.ok(H.load(SAVE2) ~= nil, "failure fixture loaded")
T.eq(H.set("new", "10.0.0.8") and true, true, "set before failing save")
local fsaved, fserr = H.save(SAVE2, { rename = function() return false, "simulated rename failure" end })
T.eq(fsaved, nil, "save reports the rename failure")
T.ok(type(fserr) == "string" and tostring(fserr):find("simulated") ~= nil, "failure reason propagated")
T.eq(read(SAVE2), "keep 10.0.0.7\n", "old file intact after a failed save")
T.ok(not fs.exists(SAVE2 .. ".tmp"), "temp file cleaned after a failed save")
T.eq(H.get("keep"), "10.0.0.7", "in-memory table intact after a failed save")

-- ===== update: fake node over the rpv socket API ==========================
local function fake_node(script, src_override)
    local n = { binds = 0, sends = 0, closes = 0, port = nil }
    function n:bind(port, cb)
        self.binds = self.binds + 1
        self.port = port
        local sk = { port = port }
        function sk:sendto(dst, dport, data)
            n.sends = n.sends + 1
            local reply = script(n.sends, dst, dport, data)
            if reply then cb(reply, src_override or dst, dport) end
            return true
        end
        function sk:close() n.closes = n.closes + 1 end
        return sk
    end
    return n
end

local function reset_update_fixture()
    T.ok(write(UPD, "old 10.0.0.9\n"), "update fixture written")
    T.ok(H.load(UPD) ~= nil, "update fixture loaded")
end

reset_update_fixture()
local logs = {}
local node1 = fake_node(function(nr)
    if nr == 2 then return "HOSTS1 16\nrouter 10.0.1.1\n" end
    return nil
end)
local up1 = H.update(node1, "10.0.9.9", {
    timeout = 0.2, retries = 2, wait = function() end, path = UPD,
    log = function(line) logs[#logs + 1] = line end,
})
T.eq(up1 and up1.ok, true, "update succeeds on the second attempt")
T.eq(up1 and up1.attempts, 2, "update reports the attempt that worked")
T.eq(up1 and up1.changed, true, "update reports a changed table")
T.eq(node1.sends, 2, "one query per attempt")
T.eq(node1.closes, 1, "socket closed after a successful update")
T.eq(H.get("router"), "10.0.1.1", "update replaced the table")
T.eq(H.get("old"), nil, "update dropped the stale entry")
T.eq(read(UPD), "router 10.0.1.1\n", "update saved the new table")
T.ok(not fs.exists(UPD .. ".tmp"), "update leaves no temp file")
T.ok(#logs >= 1, "update logged a retry")

local node2 = fake_node(function() return "HOSTS1 16\nrouter 10.0.1.1\n" end)
local up2 = H.update(node2, "10.0.9.9", { timeout = 0.2, wait = function() end, path = UPD })
T.eq(up2 and up2.ok, true, "unchanged update is ok")
T.eq(up2 and up2.changed, false, "unchanged update reports no change")
T.eq(node2.sends, 1, "unchanged update stops after one attempt")

reset_update_fixture()
local node3 = fake_node(function() return nil end)
local up3, uerr3 = H.update(node3, "10.0.9.9", { timeout = 0.2, retries = 1, wait = function() end, path = UPD })
T.eq(up3, nil, "timeout returns nil")
T.eq(uerr3, "timeout", "timeout reason")
T.eq(node3.sends, 2, "timeout retried once (two attempts)")
T.eq(node3.closes, 1, "socket closed after a timeout")
T.eq(H.get("old"), "10.0.0.9", "failed update keeps the old table")
T.eq(read(UPD), "old 10.0.0.9\n", "failed update keeps the old file")

reset_update_fixture()
local node4 = fake_node(function() return "HOSTS1 16\nrouter 10.0.1.1\n" end, 0x01020304)
local up4 = H.update(node4, "10.0.9.9", { timeout = 0.2, retries = 1, wait = function() end, path = UPD })
T.eq(up4, nil, "reply from a different src is ignored")
T.eq(H.get("old"), "10.0.0.9", "spoofed reply does not change the table")

local node5 = fake_node(function() return "HOSTS1 99\nrouter 10.0.1.1\n" end)
local up5 = H.update(node5, "10.0.9.9", { timeout = 0.2, retries = 1, wait = function() end, path = UPD })
T.eq(up5, nil, "truncated reply is rejected")
T.eq(H.get("old"), "10.0.0.9", "truncated reply keeps the old table")

local node6 = fake_node(function() return "HOSTS1 19\nbad..name 10.0.1.1\n" end)
local up6 = H.update(node6, "10.0.9.9", { timeout = 0.2, retries = 0, wait = function() end, path = UPD })
T.eq(up6, nil, "invalid body is rejected")
T.eq(H.get("old"), "10.0.0.9", "invalid body keeps the old table")

local node7 = fake_node(function() return "not a hosts reply" end)
local up7 = H.update(node7, "10.0.9.9", { timeout = 0.2, retries = 0, wait = function() end, path = UPD })
T.eq(up7, nil, "reply without a header is rejected")

local node8 = fake_node(function() return string.rep("x", H.MAX_REPLY_BYTES + 1) end)
local up8 = H.update(node8, "10.0.9.9", { timeout = 0.2, retries = 0, wait = function() end, path = UPD })
T.eq(up8, nil, "oversized reply is rejected")

local node9 = fake_node(function() return "HOSTS1 0\n" end)
local up9 = H.update(node9, "10.0.9.9", { timeout = 0.2, retries = 0, wait = function() end, path = UPD })
T.eq(up9, nil, "empty update is rejected by default")
T.eq(H.get("old"), "10.0.0.9", "empty update keeps the old table")

-- ===== update: argument validation ========================================
local node10 = fake_node(function() return nil end)
T.eq(H.update(node10, "999.1.1.1", {}), nil, "bad server ip rejected")
T.eq(H.update(node10, "10.0.9.9", { path = "../evil.txt" }), nil, "update rejects traversal")
T.eq(H.update(node10, "10.0.9.9", { port = 70000 }), nil, "update rejects an out-of-range port")
T.eq(H.update(node10, "10.0.9.9", { local_port = -1 }), nil, "update rejects an out-of-range local port")
T.eq(H.update(nil, "10.0.9.9", {}), nil, "update without a node is rejected")
T.eq(node10.binds, 0, "validation failures do not bind a socket")

-- allow_empty is the explicit opt-in for wiping the table on purpose
reset_update_fixture()
local node11 = fake_node(function() return "HOSTS1 0\n" end)
local up11 = H.update(node11, "10.0.9.9", { timeout = 0.2, wait = function() end, path = UPD, allow_empty = true })
T.eq(up11 and up11.ok, true, "allow_empty accepts an empty update")
T.eq(up11 and up11.n, 0, "allow_empty table has no entries")
T.eq(read(UPD), "", "allow_empty saved an empty file")
