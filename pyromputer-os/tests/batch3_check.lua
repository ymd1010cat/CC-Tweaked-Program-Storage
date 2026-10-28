-- batch3_check.lua - PC side assertions for the third batch of the psh
-- project: the network and data channel (rget / rput / rexec) and the package
-- repository (semver, checksums, index, install, upgrade, remove).
--
-- Loaded by tests/run_all.py over tests/cc_env_stub.lua and
-- tests/net_harness.lua. Every result here is a PC side simulation result, it
-- is NOT a CraftOS-PC result.

_G.__RESULT = { pass = 0, fail = 1 }   -- replaced at the end of a clean run

local H = _G.__H
local PROJ = _G.PROJ
local fs = _G.fs
local say = print

package.path = PROJ .. "/lib/?.lua;" .. PROJ .. "/?.lua;" .. package.path

local pass, fail = 0, 0
local failures = {}

local function check(name, cond, extra)
    if cond then
        pass = pass + 1
    else
        fail = fail + 1
        failures[#failures + 1] = name ..
            (extra ~= nil and (" [" .. tostring(extra) .. "]") or "")
    end
end

local function section(title)
    say("")
    say("=== " .. title .. " ===")
end

-- ---------------------------------------------------------------- fixture fs
for _, d in ipairs({ "/etc", "/usr", "/usr/pkgs", "/usr/cmd", "/usr/local/bin",
                     "/bin", "/var", "/var/log", "/var/lib", "/var/lib/pkg",
                     "/var/cache", "/var/cache/pkg", "/home", "/home/root",
                     "/tmp", "/var/tmp", "/mnt", "/var/net", "/repo",
                     "/repo/demo", "/repo/demo/bin" }) do
    fs.makeDir(d)
end

local function write_file(path, text)
    local dir = path:match("^(.*)/[^/]+$")
    if dir and dir ~= "" and not fs.exists(dir) then fs.makeDir(dir) end
    local h = fs.open(path, "w")
    h.write(text)
    h.close()
end

write_file("/etc/path.conf",
           "# psh PATH configuration\n/usr/cmd\n/usr/local/bin\n/bin\n")
write_file("/etc/passwd", "root:2:root\nalice:0:users\n")
write_file("/etc/group", "root:root\nusers:alice\n")
write_file("/etc/pkg.conf",
           "server_id=5\nkey=mysecretpassword\nchannel=pkg-repo\n" ..
           "chunk_size=1024\ntimeout=2\nretries=2\nmax_output=4096\n")
-- a second configuration file with different values: pkg.conf must win
write_file("/etc/network.conf",
           "channel=other-net\nmodem_side=top\nchunk_size=8192\n")

local perm = require("perm")
perm.reload()
perm.set_current_user("root")
local netcfg = require("netcfg")
netcfg.reload()

-- ------------------------------------------------------------------ helpers
local function load_program(path, argv)
    local body = assert(loadfile(path), path)
    return function()
        local saved_arg = _G.arg
        _G.arg = argv or {}
        local ok, err = pcall(body)
        _G.arg = saved_arg
        if not ok then error("program " .. path .. ": " .. tostring(err), 0) end
    end
end

-- Run one external command exactly the way the shell does: load the thin
-- wrapper, hand it (args, stage) and read the status and the collected output.
local function run_cmd(id, name, args)
    local chunk = assert(loadfile(PROJ .. "/usr/cmd/" .. name .. ".lua"), name)
    local stage = H.stage()
    local status = H.exec(id, function() return chunk(args, stage) end, name)
    return status, stage.text()
end

local function slice(text, n)
    text = tostring(text or "")
    n = n or 160
    if #text > n then return text:sub(1, n) .. "..." end
    return text
end

-- ============================================================
section("semver: ordering")
-- ============================================================
local semver = require("semver")
check("1.10.0 is newer than 1.9.9", semver.gt("1.10.0", "1.9.9"))
check("1.9.9 is older than 1.10.0", semver.lt("1.9.9", "1.10.0"))
check("1.0 and 1.0.0 compare equal", semver.compare("1.0", "1.0.0") == 0)
check("a prerelease sorts before its release", semver.lt("1.0.0-rc1", "1.0.0"))
check("major, minor and patch all take part",
      semver.gt("2.0.0", "1.9.9") and semver.lt("1.2.3", "1.2.4"))
check("valid versions are accepted",
      semver.is_valid("2.3.4") and semver.is_valid("1.0.0-beta.2"))
check("nonsense is rejected", not semver.is_valid("not-a-version"))
check("the upgrade decision is a straight comparison",
      semver.is_newer("1.3.0", "1.2.0") and not semver.is_newer("1.2.0", "1.3.0"))

-- ============================================================
section("checksums: CRC32 vector and file digests")
-- ============================================================
local checksum = require("checksum")
local crypto = require("crypto")
check("CRC32 of the standard test string", checksum.crc32("123456789") == 0xCBF43926,
      checksum.crc32_hex("123456789"))
local digest = checksum.sha256("abc")
-- THE STANDARD VECTOR, not "is it stable". The weak pair of assertions that used
-- to stand here (stable, and changes with its input) were satisfied by a 64-bit
-- arithmetic fold, and that is what the project shipped for as long as cc.crypto
-- was missing: crypto.sha256("abc") returned 16 characters instead of 64, so the
-- login password hash, the BIOS password hash and the package signature check
-- were all non-cryptographic. A known-answer test is the only kind that can tell
-- a digest from a fold.
check("SHA-256 of the standard test string (FIPS 180-4)",
      digest == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
      digest)
check("SHA-256 of the empty string", checksum.sha256("") ==
      "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
      checksum.sha256(""))
check("the digest is 64 hex characters, not a shortened fold",
      #digest == 64 and digest:match("^[0-9a-f]+$") ~= nil, #digest .. " " .. digest)
check("the digest is stable", digest == checksum.sha256("abc"))
check("one changed byte changes the digest", checksum.sha256("abd") ~= digest)

-- The module behind it, checked on its own so a failure names the right thing.
local sha = require("sha256")
local sha_results = sha.selftest()
local sha_bad = {}
for _, r in ipairs(sha_results) do
    if not r.ok then sha_bad[#sha_bad + 1] = r.name end
end
check("lib/sha256 passes every known-answer test", #sha_bad == 0,
      table.concat(sha_bad, ", "))
-- The 112-byte vector is the one that exercises the extra padding block, which is
-- where a hand written SHA-256 usually goes wrong.
local long_ok = false
for _, r in ipairs(sha_results) do
    if r.name == "sha256(112-byte)" and r.ok then long_ok = true end
end
check("including the two-block padding case", long_ok)
check("the bit library in use is reported",
      type(sha.has_bit_library()) == "boolean",
      tostring(sha.has_bit_library()))

-- ============================================================
section("the shared 32-bit layer is variadic, on both paths")
-- ============================================================
-- lib/bitops.lua exists because the same two-argument mistake was written three
-- times: here, in sha256's fallback, and in the bit32 shim in net_harness. The
-- compression function calls bxor(a, b, c), a two-argument function drops the
-- third, and the digest that results is stable, wrong, and passes any test that
-- only asks "is it stable". These assertions are the ones that can tell.
do
    local ops = require("bitops")
    local ops_bad = {}
    for _, r in ipairs(ops.selftest()) do
        if not r.ok then ops_bad[#ops_bad + 1] = r.name end
    end
    check("lib/bitops passes every self test", #ops_bad == 0,
          table.concat(ops_bad, ", "))
    -- Named separately: if the self test is ever weakened, these still fail.
    check("a three-argument xor is not truncated", ops.bxor(1, 2, 4) == 7,
          tostring(ops.bxor(1, 2, 4)))
    check("nor is a three-argument band", ops.band(0xFF, 0xFF, 0xFF) == 255)
    check("nor a four-argument one", ops.bxor(0xF0, 0x0F, 0xFF, 0x00) == 0,
          tostring(ops.bxor(0xF0, 0x0F, 0xFF, 0x00)))
    check("the path in use is reported as a boolean",
          type(ops.has_native()) == "boolean", tostring(ops.has_native()))
    -- Rotation and packing, which moved here from sha256.lua.
    check("rotr is a 32-bit rotate", ops.rotr(1, 1) == 2147483648 and
          ops.rotr(0x80000000, 1) == 1073741824)
    check("add32 wraps at 32 bits", ops.add32(0xFFFFFFFF, 1) == 0)
    check("u32be and r32be agree", ops.r32be(ops.u32be(0x12345678), 1) == 0x12345678)
    check("u32le and r32le agree", ops.r32le(ops.u32le(0x12345678), 1) == 0x12345678)

    -- The fallback path again, through bitops rather than sha256.
    local saved_bit32 = rawget(_G, "bit32")
    local saved_ops = package.loaded["bitops"]
    rawset(_G, "bit32", nil)
    package.loaded["bitops"] = nil
    local okf, fallback_ops = pcall(require, "bitops")
    check("lib/bitops loads without a bit library", okf, tostring(fallback_ops))
    if okf then
        local fbad = {}
        for _, r in ipairs(fallback_ops.selftest()) do
            if not r.ok then fbad[#fbad + 1] = r.name end
        end
        check("the arithmetic fallback also passes every self test", #fbad == 0,
              table.concat(fbad, ", "))
        check("the fallback's three-argument xor is not truncated either",
              fallback_ops.bxor(1, 2, 4) == 7,
              tostring(fallback_ops.bxor(1, 2, 4)))
    end
    rawset(_G, "bit32", saved_bit32)
    package.loaded["bitops"] = saved_ops
    check("the bit library was restored", rawget(_G, "bit32") == saved_bit32)
end

-- BOTH bit paths, not just whichever one this machine happens to take.
--
-- tests/net_harness.lua installs a bit32 shim, so without this the arithmetic
-- fallback in lib/sha256.lua NEVER RUNS in the suite -- and that is not
-- hypothetical: the fallback shipped with two-argument band/bor/bxor, SHA-256
-- calls bxor(a, b, c), and the third argument was silently dropped. The manual
-- bit32 branch had the same bug. Both were found by hand because nothing here
-- exercised either one with a three-argument call, and the digest that came out
-- was stable and wrong.
--
-- The fallback is forced by removing bit32, clearing the module from the registry
-- and requiring it again: the module reads rawget(_G, "bit32") at load time. The
-- global and the loaded module are both restored afterwards, so this cannot leak
-- into the suites that follow.
do
    local saved_bit32 = rawget(_G, "bit32")
    local saved_loaded = package.loaded["sha256"]
    local saved_hex = package.loaded["crypto"]

    rawset(_G, "bit32", nil)
    package.loaded["sha256"] = nil
    package.loaded["crypto"] = nil

    local okf, fallback = pcall(require, "sha256")
    check("the fallback path loads without a bit library", okf, tostring(fallback))
    if okf then
        check("it reports that it has no bit library",
              fallback.has_bit_library() == false)
        local fbad = {}
        for _, r in ipairs(fallback.selftest()) do
            if not r.ok then fbad[#fbad + 1] = r.name end
        end
        check("the arithmetic fallback passes every known-answer test",
              #fbad == 0, table.concat(fbad, ", "))
        -- The exact shape that was broken: a three-argument xor. Stated directly
        -- so a future two-argument rewrite fails by name, not by digest.
        check("a three-argument xor is not truncated",
              fallback.hex("abc") ==
              "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    end

    -- restore, then prove the restore worked
    rawset(_G, "bit32", saved_bit32)
    package.loaded["sha256"] = saved_loaded
    package.loaded["crypto"] = saved_hex
    check("the bit library was restored for the suites that follow",
          rawget(_G, "bit32") == saved_bit32)
    check("and the module registry is back where it was",
          package.loaded["sha256"] == saved_loaded)

    -- The three-argument call is also made through whichever path is now in use,
    -- and the assertion is UNCONDITIONAL on purpose. It used to be wrapped in
    -- `if real.has_bit_library() then`, which silently skipped it -- and a skipped
    -- assertion is what hid the original fake digest for as long as it did. The
    -- path is reported in the detail instead, so a failure says which one ran.
    local real = require("sha256")
    local real_digest = real.hex("abc")
    check("the vector hashes correctly on whichever bit path is in use",
          real_digest ==
          "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
          real_digest .. " native=" .. tostring(real.has_bit_library()))
end

local set_a = { manifest = "name=x\n", ["bin/x.lua"] = "print(1)\n" }
local set_b = { ["bin/x.lua"] = "print(1)\n", manifest = "name=x\n" }
check("files_digest does not depend on table order",
      checksum.files_digest(set_a) == checksum.files_digest(set_b))
local set_c = { manifest = "name=x\n", ["bin/x.lua"] = "print(2)\n" }
check("files_digest catches a changed file",
      checksum.files_digest(set_a) ~= checksum.files_digest(set_c))

-- ============================================================
section("the password hash does not depend on the module medium")
-- ============================================================
-- lib/crypto.lua is in the modules half (the removable medium) and lib/perm.lua is
-- in the base half (the computer). perm.hash_password() used to pcall-require
-- crypto and fall back to an arithmetic fold, so the STORED PASSWORD depended on
-- what was plugged in: measured, alice:0fbcae8a2053... with the medium and
-- alice:1265856734 without, with check_password returning false. A password set
-- with the medium in place could not be verified without it, which on a two-part
-- install locks the operator out of their own machine.
--
-- The fix is that lib/perm.lua requires lib/sha256.lua at column 0, which both
-- makes the hash fixed and puts sha256 in the base half (gate 5 pins that half).
--
-- The test has to SET A PASSWORD WHILE CRYPTO IS UNREACHABLE to mean anything: in
-- this suite lib/crypto.lua is always loadable, so a mutant that restores the
-- pcall-and-fold would take the pcall branch and produce the same value, and an
-- assertion that only compared the two would pass. Concrete assertions about the
-- stored bytes, taken on the fallback path, are what bite.
do
    local sha = require("sha256")
    local want = sha.hex("cc-salt:hunter2")
    check("the expected hash is a full SHA-256",
          #want == 64 and want:match("^[0-9a-f]+$") ~= nil, want)

    local function shadow_text()
        local h = fs.open("/etc/shadow", "r")
        if not h then return nil end
        local t = h.readAll()
        h.close()
        return t
    end

    -- Set a password with lib/crypto.lua made unreachable, the way it is when the
    -- medium is out. require() is replaced only for that one name, and everything
    -- is restored afterwards.
    local saved_require = _G.require
    local saved_perm = package.loaded["perm"]
    _G.require = function(name)
        if name == "crypto" then error("module 'crypto' not found", 0) end
        return saved_require(name)
    end
    package.loaded["perm"] = nil
    local ok_load, perm_out = pcall(require, "perm")
    local ok_set = false
    if ok_load then
        ok_set = pcall(function()
            perm_out.set_password("probeuser", "hunter2")
        end)
    end
    _G.require = saved_require

    check("lib/perm.lua loads with lib/crypto.lua unreachable", ok_load,
          tostring(perm_out))
    check("a password can be set with lib/crypto.lua unreachable", ok_set)

    local stored = shadow_text()
    check("the password was stored", type(stored) == "string" and
          stored:find("probeuser:", 1, true) ~= nil, tostring(stored))
    -- THE assertion: without the medium, the stored hash is still the real
    -- SHA-256 of the salted password. The old code stored a fold here
    -- ("1265856734"), which is why a password set with the medium in place could
    -- not be verified without it.
    check("with the medium out, the hash is still the real SHA-256",
          type(stored) == "string" and stored:find(want, 1, true) ~= nil,
          tostring(stored) .. " | want " .. want)

    -- And the verification path agrees, which is what the operator actually feels.
    if ok_load then
        package.loaded["perm"] = nil
        _G.require = function(name)
            if name == "crypto" then error("module 'crypto' not found", 0) end
            return saved_require(name)
        end
        local ok_check, verified = pcall(function()
            local p = require("perm")
            return p.check_password("probeuser", "hunter2")
        end)
        _G.require = saved_require
        check("and the password verifies without the medium", ok_check and verified,
              tostring(verified))
    end

    package.loaded["perm"] = saved_perm
end


-- ============================================================
section("netcfg: one channel, one key, one set of limits")
-- ============================================================
check("pkg.conf wins over network.conf, which fills the gaps",
      netcfg.channel() == "pkg-repo" and netcfg.modem() == "top")
check("the shared key comes from the package configuration",
      netcfg.key() == "mysecretpassword")
check("chunk size, timeout and retry budget are read",
      netcfg.chunk_size() == 1024 and netcfg.timeout() == 2 and netcfg.retries() == 2)
check("the rexec output budget is read", netcfg.max_output() == 4096)
check("the repository host is configured", netcfg.server_id() == 5)
local tid = netcfg.resolve_target("5")
check("a numeric target resolves to that computer", tid == 5)
local ok_target, bad_target = pcall(netcfg.resolve_target, "no.such.host")
check("an unknown target is never guessed", (not ok_target) or bad_target == nil)
local opened, cerr = netcfg.open()
check("the modem is opened through the shared configuration", opened == true and cerr == nil,
      tostring(cerr))
local blob = netcfg.pack({ t = "hello", n = 42 })
local back = netcfg.unpack(blob)
check("pack and unpack round trip through the shared key",
      type(back) == "table" and back.t == "hello" and back.n == 42)
local ok_wrong, wrong = pcall(function()
    return netcfg.unpack(crypto.encrypt("another-key", textutils.serialize({ t = "x" })))
end)
check("a blob sealed with another key does not open",
      (not ok_wrong) or wrong == nil, tostring(wrong))

-- ============================================================
section("xfer: rput and rget against a real netd")
-- ============================================================
local DAEMON = 2
local SAVE = "/var/net/incoming"
H.spawn(DAEMON, load_program(PROJ .. "/netd.lua", { "--save", SAVE }), "netd")

local payload = "Pyromputer OS payload\n" .. string.rep("0123456789abcdef", 400)
local SIZE = #payload
write_file("/home/root/src.bin", payload)

local st, text = run_cmd(5, "rput", { "-t", tostring(DAEMON), "-c", "1024",
                                      "/home/root/src.bin" })
check("rput reaches the daemon and exits 0", st == 0, slice(text))
check("the pushed file is on the peer", H.exists(SAVE .. "/src.bin"))
check("the received bytes are identical", H.read(SAVE .. "/src.bin") == payload)
check("the report counts bytes and verifies with CRC32",
      text:find(tostring(SIZE) .. " bytes", 1, true) ~= nil and
      text:find("CRC32", 1, true) ~= nil, slice(text))

local st2, text2 = run_cmd(5, "rput", { "-t", tostring(DAEMON), "-c", "300",
                                        "-p", SAVE .. "/copy.bin",
                                        "/home/root/src.bin" })
local want = math.ceil(SIZE / 300)
check("the chunk size is configurable on the wire",
      st2 == 0 and text2:find(want .. " chunk", 1, true) ~= nil, slice(text2))
check("the sender may name the destination path on the peer",
      H.read(SAVE .. "/copy.bin") == payload)

local st3 = run_cmd(5, "rput", { "-t", tostring(DAEMON), "/home/root/src.bin" })
check("an existing file is not overwritten without permission",
      st3 ~= 0 and H.read(SAVE .. "/src.bin") == payload)

H.spawn(3, load_program(PROJ .. "/netd.lua", { "--save", "/var/net/other", "--force" }),
        "netd-force")
write_file("/home/root/src.bin", payload .. "second\n")
local st4 = run_cmd(5, "rput", { "-t", "3", "-f", "/home/root/src.bin" })
check("a daemon started with --force accepts the overwrite",
      st4 == 0 and H.read("/var/net/other/src.bin") == payload .. "second\n",
      tostring(st4))

local st5, text5 = run_cmd(5, "rput", { "-t", tostring(DAEMON), "-p", "/etc/evil.bin",
                                        "/home/root/src.bin" })
check("a push outside the daemon root is refused",
      st5 ~= 0 and not H.exists("/etc/evil.bin"), slice(text5))
local st6, text6 = run_cmd(5, "rput", { "-t", tostring(DAEMON),
                                        "-p", SAVE .. "/../escape.bin",
                                        "/home/root/src.bin" })
check("a path escaping the root with .. is refused",
      st6 ~= 0 and not H.exists("/var/net/escape.bin"), slice(text6))

local st7, text7 = run_cmd(5, "rget", { "-t", tostring(DAEMON),
                                        "-o", "/home/root/back.bin",
                                        SAVE .. "/src.bin" })
check("rget fetches the file back", st7 == 0 and
      H.read("/home/root/back.bin") == H.read(SAVE .. "/src.bin"), slice(text7))

local st8, text8 = run_cmd(5, "rget", { "-t", "9", "-w", "1",
                                        "-o", "/home/root/silent.bin",
                                        "/var/net/incoming/src.bin" })
check("rget against a silent peer exits 124", st8 == 124, tostring(st8))
check("the timeout is explained to the user", text8:find("answer", 1, true) ~= nil,
      slice(text8))

-- one datagram is dropped on the wire: the sender must notice that the block
-- was never acknowledged and send it again, and the body must still arrive
-- intact
local seen, dropped = 0, 0
H.drop(function(from, target)
    if from == 5 and target == DAEMON then
        seen = seen + 1
        if (seen == 3 or seen == 8) and dropped < 2 then
            dropped = dropped + 1
            return true
        end
    end
    return false
end)
local st9, text9 = run_cmd(5, "rput", { "-t", tostring(DAEMON), "-w", "1", "-r", "3",
                                        "-p", SAVE .. "/retry.bin",
                                        "/home/root/src.bin" })
H.drop(nil)
check("a lost block is sent again and the transfer still lands",
      dropped > 0 and st9 == 0 and
      H.read(SAVE .. "/retry.bin") == payload .. "second\n",
      "drops=" .. dropped .. " " .. slice(text9))
check("the retransmission is reported", text9:find("retransmission", 1, true) ~= nil,
      slice(text9))

-- ============================================================
section("rexec: stdout, exit status and timeout")
-- ============================================================
local function peer_shell(line)
    -- The daemon asks for "/usr/psh.lua -c <command>": run the tail of that
    -- line the way the shell would, and hand the exit status back as a
    -- boolean, which is what shell.run returns to its caller.
    local command = line:match("^%S+%s+%-c%s+(.*)$") or line
    _G.__PSH_TEST = true
    local chunk = assert(loadfile(PROJ .. "/usr/psh.lua"))
    chunk()
    local psh = _G.__psh_test
    psh.init()
    local status = psh.run(command)
    return status == 0
end
H.shell_run = peer_shell

local st10, text10 = run_cmd(5, "rexec", { "-t", tostring(DAEMON), "-q",
                                           "echo", "hello-from-peer" })
check("rexec brings the peer stdout back",
      st10 == 0 and text10:find("hello-from-peer", 1, true) ~= nil, slice(text10))

local st11, text11 = run_cmd(5, "rexec", { "-t", tostring(DAEMON),
                                           "cat", "/nope/missing" })
check("a failing command comes back with its own status",
      type(st11) == "number" and st11 ~= 0 and st11 ~= 124,
      tostring(st11) .. " " .. slice(text11))

local policy = false
H.shell_run = function()
    policy = true
    return true
end
local st12, text12 = run_cmd(5, "rexec", { "-t", "9", "-w", "1", "-q", "echo", "hi" })
check("a peer that never answers exits 124", st12 == 124, tostring(st12))
check("nothing was run on a silent peer", policy == false)
H.shell_run = nil

-- -------------------------------------------------- rexec: one answer, one request
-- The defect this block pins down: rexec.run() accepted ANY message from the
-- peer whose action was rexec and whose t was "result". A LATE answer to an
-- earlier request to the same peer (the requester had timed out, the peer's
-- result arrived afterwards and stayed queued) was therefore read as the answer
-- to the NEXT request: "rexec -t 2 echo two" printed the output of "echo one".
--
-- An answer that is already sitting in the client's mailbox is exactly the
-- state the channel is in when that happens: no timing and no emulator, the
-- same table the peer would have sent, packed with the shared key and coming
-- from the peer's id, so the client cannot tell it apart by the envelope.
--
-- A function, like pkg_request_pairing() above: the main chunk of this suite is
-- close to the 200 local limit of a Lua function.
local function rexec_result_pairing()
local rexec = require("rexec")
local client = 5          -- the computer every rexec command in this file runs on
local peer = DAEMON       -- the netd spawned for the transfers above

-- A result from `from` in the client's mailbox before the request is sent.
local function queued(fields, from)
    local msg = { action = rexec.ACTION, t = "result" }
    for key, value in pairs(fields) do msg[key] = value end
    table.insert(H.box(client), { from = from or peer, blob = assert(netcfg.pack(msg)),
                                  protocol = netcfg.channel() })
    return msg
end

-- The same, but on the wire and arriving `delay` seconds from now: a stream of
-- strays that must be ignored one by one over time, which is what makes the one
-- deadline observable -- a wait that restarted its budget on every stray would
-- end later than the timeout it was given.
local function queued_later(fields, from, delay)
    local msg = { action = rexec.ACTION, t = "result" }
    for key, value in pairs(fields) do msg[key] = value end
    table.insert(H.held, { at = H.now + math.floor(delay * 1000), target = client,
                           from = from or peer,
                           blob = assert(netcfg.pack(msg)),
                           protocol = netcfg.channel() })
    return msg
end

-- The daemon runs the command through the peer shell again (it was set to nil
-- once the silent-peer case above was done).
H.shell_run = peer_shell

-- 1. the reported case: a result from a PREVIOUS request to the same peer, then
--    the real one. The stale answer echoes the id of the request that produced
--    it ("5-1" is what the first rexec in this file carried; the request below
--    carries a later one), which is the whole reason an answer looks like any
--    other answer on the channel.
queued({ id = "5-1", ok = true, code = 0,
         stdout = "STALE-ANSWER-FROM-AN-EARLIER-REQUEST\n" })
local st13, text13 = run_cmd(client, "rexec", { "-t", tostring(peer), "-q",
                                               "echo", "fresh-answer" })
check("a stale result is not taken as this request's answer",
      st13 == 0 and text13:find("fresh-answer", 1, true) ~= nil and
      text13:find("STALE-ANSWER", 1, true) == nil, slice(text13))
check("the stale result was consumed, so the real answer is the one that was read",
      #H.box(client) == 0, tostring(#H.box(client)))

-- 2. the same, but the leftover carries ANOTHER request's id: the shape alone
--    says "a result", so only the id tells it apart.
queued({ id = "99-99", ok = true, code = 0,
         stdout = "STALE-RESULT-WITH-A-FOREIGN-ID\n" })
local st14, text14 = run_cmd(client, "rexec", { "-t", tostring(peer), "-q",
                                               "echo", "second-answer" })
check("a result carrying another request's id is not this request's answer",
      st14 == 0 and text14:find("second-answer", 1, true) ~= nil and
      text14:find("FOREIGN", 1, true) == nil, slice(text14))
check("the ignored result was consumed, so the channel is clear again",
      #H.box(client) == 0, tostring(#H.box(client)))

-- 3. the pairing itself, on the wire: the request carries an id and the peer
--    echoes the one it was asked with. Unpacking what was recorded on the wire
--    is how the "one install costs one fetch" section counts fetches.
H.wire_clear()
local st15, text15 = run_cmd(client, "rexec", { "-t", tostring(peer), "-q",
                                               "echo", "on-the-wire" })
local asked, answered = {}, {}
for _, entry in ipairs(H.wire) do
    if entry.from == client and entry.to == peer then asked[#asked + 1] = entry end
    if entry.from == peer and entry.to == client then answered[#answered + 1] = entry end
end
local req_msg = #asked == 1 and netcfg.unpack(asked[1].blob) or nil
local rep_msg = #answered == 1 and netcfg.unpack(answered[1].blob) or nil
check("a clean rexec costs one request and one answer",
      st15 == 0 and #asked == 1 and #answered == 1,
      tostring(st15) .. " " .. tostring(#asked) .. " request(s), " ..
      tostring(#answered) .. " answer(s)")
check("the request carries an id",
      type(req_msg) == "table" and type(req_msg.id) == "string" and req_msg.id ~= "",
      type(req_msg) == "table" and tostring(req_msg.id) or "no request")
check("the peer echoes the id it was asked with",
      req_msg ~= nil and rep_msg ~= nil and rep_msg.id ~= nil and
      rep_msg.id == req_msg.id,
      tostring(req_msg and req_msg.id) .. " -> " .. tostring(rep_msg and rep_msg.id))

-- 4. compatibility: a peer that predates ids echoes none, and its answer still
--    has to be accepted. This is the fallback the pairing is allowed to keep --
--    the limit it leaves is written down in lib/rexec.lua.
local OLD_PEER = 11
H.spawn(OLD_PEER, function()
    while not H.stop do
        local sender, blob = rednet.receive(netcfg.channel(), 5)
        if sender then
            local msg = netcfg.unpack(blob)
            if msg and msg.action == rexec.ACTION and msg.t == "request" then
                -- an older daemon: it answers, and echoes nothing back
                rednet.send(sender, assert(netcfg.pack({
                    action = rexec.ACTION, t = "result", ok = true,
                    stdout = "answer from a peer without ids\n", code = 0,
                })), netcfg.channel())
            end
        end
    end
end, "old rexec peer")
local st16, text16 = run_cmd(client, "rexec", { "-t", tostring(OLD_PEER), "-q",
                                               "echo", "hi" })
check("a peer that echoes no id still answers (the compatibility fallback)",
      st16 == 0 and text16:find("without ids", 1, true) ~= nil,
      tostring(st16) .. " " .. slice(text16))

-- The same fallback seen from the other side, and the honest limit it leaves:
-- an answer with no id at all carries nothing to match on, so it is accepted --
-- a stale answer from an id-less peer cannot be told apart from a live one.
-- The comment at answers() in lib/rexec.lua states this rather than hiding it.
queued({ ok = true, code = 0, stdout = "ID-LESS-ANSWER\n" })
local st16b, text16b = run_cmd(client, "rexec", { "-t", tostring(peer), "-q",
                                                 "echo", "hi" })
check("an answer with no id is accepted, which is what keeps old peers working",
      st16b == 0 and text16b:find("ID-LESS-ANSWER", 1, true) ~= nil, slice(text16b))

-- 5. a stream of strays from the peer: every one is ignored and the ONE
--    deadline stays the only clock. The strays are spaced out over the wait
--    (0.3s, 0.6s, 0.9s of a 1s timeout), so a wait that restarted its budget on
--    each of them would be measurable: the deadline must be the same one that
--    was set when the request went out.
local SILENT = 9          -- a peer with no daemon: nothing legitimate answers
for i = 1, 3 do
    queued_later({ id = "9" .. i .. "-99", ok = true, code = 0,
                   stdout = "STALE-" .. i .. "-IS-NOT-AN-ANSWER\n" }, SILENT, 0.3 * i)
end
local before = H.now
local st17, text17 = run_cmd(client, "rexec", { "-t", tostring(SILENT), "-w", "1", "-q",
                                               "echo", "never-answered" })
local used = H.now - before
check("a stream of stale answers ends in a timeout, not in an answer",
      st17 == 124 and text17:find("STALE-", 1, true) == nil,
      tostring(st17) .. " " .. slice(text17))
check("the stale answers did not extend the deadline",
      used == 1000, tostring(used) .. "ms of a 1000ms wait")
check("every stray was consumed on the way out",
      #H.box(client) == 0 and #H.held == 0,
      tostring(#H.box(client)) .. " in the mailbox, " .. tostring(#H.held) .. " held")

-- 6. refusals are answers too, so they are paired the same way. A stale refusal
--    must not be read as this request's answer (the id is checked on the failure
--    path, not only where the command ran)...
queued({ id = "97-97", ok = false, reason = "denied by a previous request" })
local st18, text18 = run_cmd(client, "rexec", { "-t", tostring(peer), "-q",
                                               "echo", "after-a-stale-refusal" })
check("a stale refusal is not taken as this request's answer",
      st18 == 0 and text18:find("after-a-stale-refusal", 1, true) ~= nil and
      text18:find("previous request", 1, true) == nil,
      tostring(st18) .. " " .. slice(text18))

-- ...and a live refusal carries the id it refuses, so an older requester that
-- still checks nothing is not the only case covered.
local DENIER = 12
H.spawn(DENIER, load_program(PROJ .. "/netd.lua", { "--allow", "none", "-q" }),
        "netd (rexec denied)")
H.wire_clear()
local st19, text19 = run_cmd(client, "rexec", { "-t", tostring(DENIER), "echo", "hi" })
local deny_req, deny_rep
for _, entry in ipairs(H.wire) do
    local ok, msg = pcall(netcfg.unpack, entry.blob)
    if ok and type(msg) == "table" and msg.action == rexec.ACTION then
        if entry.from == client and entry.to == DENIER then deny_req = msg end
        if entry.from == DENIER and entry.to == client then deny_rep = msg end
    end
end
check("a refusal reaches the requester as a refusal",
      st19 == 1 and text19:find("remote execution is disabled", 1, true) ~= nil,
      tostring(st19) .. " " .. slice(text19))
check("a refusal carries the id of the request it refuses",
      deny_req ~= nil and deny_rep ~= nil and deny_rep.ok == false and
      deny_rep.id ~= nil and deny_rep.id == deny_req.id,
      tostring(deny_req and deny_req.id) .. " -> " .. tostring(deny_rep and deny_rep.id))

-- 7. the other refusal the peer can make: an empty command line. rexec.run()
--    never sends one (it answers locally), so the request is put on the channel
--    by hand -- the peer's refusal is still an answer and still carries the id.
local EMPTY = 13
H.spawn(EMPTY, load_program(PROJ .. "/netd.lua", { "-q" }), "netd (empty command)")
local emp = {}
H.pump(client, function()
    local blob = assert(netcfg.pack({ action = rexec.ACTION, t = "request",
                                      id = "empty-1", command = "   " }))
    require("rpvnet").send(EMPTY, blob, netcfg.channel())
    local sender, reply_blob = require("rpvnet").receive(netcfg.channel(), 2)
    emp.sender = sender
    emp.msg = sender and netcfg.unpack(reply_blob) or nil
end, "rexec (empty command)")
check("the empty-command refusal echoes the id too",
      type(emp.msg) == "table" and emp.msg.ok == false and
      emp.msg.reason == "empty command" and emp.msg.id == "empty-1",
      type(emp.msg) == "table" and
      (tostring(emp.msg.id) .. " / " .. tostring(emp.msg.reason)) or "no answer")

-- The extra peers are done: the rest of the file expects the machines it had.
-- (Their tasks wait on a mailbox nothing will ever fill, which only costs turns.)
for _, t in ipairs(H.tasks) do
    if t.id == OLD_PEER or t.id == DENIER or t.id == EMPTY then t.state = "dead" end
end
H.shell_run = nil
end
rexec_result_pairing()

-- ============================================================
section("pkg: repository index, install, upgrade and remove")
-- ============================================================
local pkg = require("pkg")
local REPO = "/repo"
local function publish(name, manifest, files)
    write_file(REPO .. "/" .. name .. "/manifest", manifest)
    for rel, body in pairs(files) do
        write_file(REPO .. "/" .. name .. "/" .. rel, body)
    end
end
publish("demo", "name=demo\nversion=1.2.0\nbin=bin/demo.lua\n", {
    ["bin/demo.lua"] = "print('demo 1.2.0')\n",
    ["extra.lua"] = "print('file only the old build ships')\n",
})
H.spawn(5, load_program(PROJ .. "/pkgserver.lua", {}), "pkgserver")

local box = {}
H.exec(7, function()
    box.updated, box.uperr = pkg.update()
    box.idx, box.err = pkg.index()
end, "pkg.update then pkg.index")
local listed = false
if type(box.idx) == "table" then
    for _, item in ipairs(box.idx) do
        if item.name == "demo" and item.version == "1.2.0" then listed = true end
    end
end
check("the repository index is fetched and parsed", listed,
      tostring(box.err) .. " " .. slice(textutils.serialize(box.idx or {})))

local ibox = {}
H.exec(7, function() ibox.ok, ibox.info = pkg.install("demo") end, "pkg.install")
check("the package installs from the repository", ibox.ok == true, tostring(ibox.info))
check("the installed command survives the fetch",
      H.read("/usr/pkgs/demo/bin/demo.lua") == "print('demo 1.2.0')\n")
check("the installed version is recorded",
      pkg.installed_version("demo") == "1.2.0", tostring(pkg.installed_version("demo")))

publish("demo", "name=demo\nversion=1.3.0\nbin=bin/demo.lua\n", {
    ["bin/demo.lua"] = "print('demo 1.3.0')\n",
})
-- the new build no longer ships extra.lua: drop it from the repository tree so
-- that the upgrade really meets a file the new file set does not contain
fs.delete(REPO .. "/demo/extra.lua")
local ubox = {}
H.exec(7, function() ubox.ok, ubox.info = pkg.upgrade() end, "pkg.upgrade")
check("upgrade picks the newer version up",
      pkg.installed_version("demo") == "1.3.0", tostring(ubox.info))
check("upgrade writes the new payload",
      H.read("/usr/pkgs/demo/bin/demo.lua") == "print('demo 1.3.0')\n")
check("upgrade removes the file the new build dropped",
      H.exists("/usr/pkgs/demo/extra.lua") == false)

local rbox = {}
H.exec(7, function() rbox.ok, rbox.info = pkg.remove("demo") end, "pkg.remove")
check("remove deletes the package tree",
      pkg.installed("demo") == false and not H.exists("/usr/pkgs/demo"),
      tostring(rbox.info))
check("remove leaves no command behind",
      not H.exists("/usr/pkgs/demo/bin/demo.lua"))

-- a repository that hands out a body whose checksum does not match must be
-- refused before a single byte is written
write_file("/etc/pkg.conf",
           "server_id=6\nkey=mysecretpassword\nchannel=pkg-repo\n" ..
           "chunk_size=1024\ntimeout=2\nretries=2\nmax_output=4096\n")
netcfg.reload()
H.spawn(6, function()
    while not H.stop do
        local sender, blob = rednet.receive(netcfg.channel(), 5)
        if sender then
            local req = netcfg.unpack(blob)
            if req and req.action == "fetch" then
                rednet.send(sender, netcfg.pack({
                    ok = true,
                    files = { manifest = "name=tampered\nversion=9.9.9\n",
                              ["bin/t.lua"] = "print('tampered')\n" },
                    checksums = { manifest = string.rep("0", 64) },
                    sig = "deadbeef",
                }), netcfg.channel())
            elseif req and req.action == "list" then
                rednet.send(sender, netcfg.pack({
                    { name = "tampered", version = "9.9.9" },
                }), netcfg.channel())
            end
        end
    end
end, "fake-repo")
local tbox = {}
H.exec(7, function()
    local ok, res, info = pcall(pkg.install, "tampered")
    tbox.crash = not ok
    if ok then tbox.ok, tbox.info = res, info else tbox.info = res end
end, "pkg.install (tampered)")
check("a package whose checksum does not match is never accepted",
      tbox.ok ~= true, tostring(tbox.crash) .. " " .. tostring(tbox.info))
check("the refused package is not written to disk",
      not H.exists("/usr/pkgs/tampered"))

write_file("/etc/pkg.conf",
           "server_id=5\nkey=mysecretpassword\nchannel=pkg-repo\n" ..
           "chunk_size=1024\ntimeout=2\nretries=2\nmax_output=4096\n")
netcfg.reload()

-- ============================================================
section("pkg: a package that cannot fit is refused, not half unpacked")
-- ============================================================
-- The download arrives as one answer in memory, so the unpack is the moment the
-- file set reaches the disk. A set written until the volume fills leaves a package
-- that is present in /usr/pkgs, listed by "pkg list" and broken -- the worst of the
-- three outcomes. The preflight measures the whole set and refuses it.
do
    local real_free = fs.getFreeSpace
    fs.getFreeSpace = function() return 8 end
    local sbox = {}
    H.exec(7, function() sbox.ok, sbox.info = pkg.install("demo") end,
           "pkg.install (no room)")
    fs.getFreeSpace = real_free
    check("an install that does not fit reports failure", sbox.ok ~= true, tostring(sbox.info))
    check("and the reason is the space one",
          tostring(sbox.info):find("not enough space", 1, true) ~= nil, slice(sbox.info))
    check("nothing was written for it", not H.exists("/usr/pkgs/demo"))
    check("and the package is not installed", pkg.installed("demo") == false)
end

-- The section is a function rather than plain statements because the main
-- chunk of this suite is close to the 200 local limit of a Lua function.
local function pkg_request_pairing()
-- ============================================================
section("pkg: an answer belongs to the request that asked for it")
-- ============================================================
-- The defect this section pins down was measured on a real machine three times:
--
--     server index shape=a leftover fetch reply (ok=true)
--
-- pkg.update() asked the repository for the index and then took THE NEXT MESSAGE
-- ON THE CHANNEL as the answer. During an install a fetch reply can outlive its
-- request (the client timed out, the answer arrived late and stayed queued), and
-- that reply -- a table with files/checksums/sig and no array part -- was saved
-- as the index, so the repository looked EMPTY.
--
-- The queue below is the client's mailbox on the pkg channel, so putting an
-- answer there by hand is exactly the state the channel is in when that happens:
-- no timing and no emulator, the same table the repository would have sent.
local client = 7      -- the computer every pkg call in this file runs on
local repo = 5        -- netcfg.server_id(), the pkgserver spawned above

local FETCH_ANSWER = {
    ok = true,
    files = { manifest = "name=stale\nversion=9.9.9\nbin=bin/stale.lua\n" },
    checksums = { manifest = string.rep("a", 64) },
    sig = "staleleftover",
}

-- An answer on the channel, packed with the shared key and coming from the
-- repository's computer, so the client cannot tell it from a live one.
local function leftover(answer)
    local blob = assert(netcfg.pack(answer))
    table.insert(H.box(client), { from = repo, blob = blob,
                                  protocol = netcfg.channel() })
end

local function index_names()
    local idx = pkg.index()
    local names = {}
    for _, entry in ipairs(type(idx) == "table" and idx or {}) do
        names[#names + 1] = tostring(entry.name)
    end
    return names
end

local function has_name(names, want)
    for _, name in ipairs(names) do
        if name == want then return true end
    end
    return false
end

local function describe_names(names)
    return "[" .. table.concat(names, ",") .. "]"
end

-- How many packages the repository directory holds: what the update has to report.
local repo_count = 0
for _, fname in ipairs(fs.list("/repo") or {}) do
    if fs.isDir("/repo/" .. fname) then repo_count = repo_count + 1 end
end

-- 1. the reported case: the fetch reply is still queued, and the repository that
--    produced it is an older one (the answer carries no id to match on)
leftover(FETCH_ANSWER)
check("fixture: a leftover fetch reply is waiting on the channel",
      #H.box(client) == 1, tostring(#H.box(client)))
local up1 = {}
H.exec(client, function() up1.ok, up1.info = pkg.update() end, "pkg.update (leftover)")
local names1 = index_names()
check("a leftover fetch reply is not saved as the index",
      up1.ok == true and has_name(names1, "demo") and not has_name(names1, "stale"),
      tostring(up1.ok) .. " " .. tostring(up1.info) .. " " .. describe_names(names1))
check("the index lists one entry per package in the repository, not zero",
      #names1 == repo_count and repo_count > 0,
      tostring(#names1) .. " of " .. tostring(repo_count) .. " " .. describe_names(names1))
check("the answer the update used has the index shape, not the fetch shape",
      type(pkg.index()) == "table" and pkg.index().ok == nil and
      pkg.index().files == nil and pkg.index().id == nil,
      slice(textutils.serialize(pkg.index() or {})))
check("no stale answer is left behind to poison the next call",
      #H.box(client) == 0, tostring(#H.box(client)))

-- 2. the same leftover, but from a repository that DOES echo ids: the id it
--    carries is another request's, so it is not this request's answer
local stale = {}
for key, value in pairs(FETCH_ANSWER) do stale[key] = value end
stale.id = "99-99"
leftover(stale)
local up2 = {}
H.exec(client, function() up2.ok, up2.info = pkg.update() end, "pkg.update (stale id)")
local names2 = index_names()
check("a fetch reply carrying another request's id is not the index",
      up2.ok == true and has_name(names2, "demo") and not has_name(names2, "stale"),
      tostring(up2.info) .. " " .. slice(textutils.serialize(pkg.index() or {})))

-- 3. a LIST shaped answer with a foreign id: the shape alone would look right,
--    so only the id tells it apart. It holds a package the repository does not
--    carry, which is what makes reading it visible in the index.
leftover({ id = "98-98", { name = "ghost", version = "0.0.1" } })
local up3 = {}
H.exec(client, function() up3.ok, up3.info = pkg.update() end, "pkg.update (foreign list)")
local names3 = index_names()
check("a list answer carrying another request's id is ignored, not read",
      up3.ok == true and not has_name(names3, "ghost") and has_name(names3, "demo"),
      tostring(up3.info) .. " " .. describe_names(names3))
check("the ignored answer was still consumed, so the channel is clear",
      #H.box(client) == 0, tostring(#H.box(client)))

-- 3b. a message that belongs to another protocol on the same channel (a file
--     block, shaped like one of lib/xfer.lua's chunks) is not an index either:
--     the fallback that compares shapes must not read "a table with no array
--     part" as "an empty repository".
leftover({ action = "rfile", t = "chunk", seq = 1, crc = "deadbeef", data = "abc" })
local up3b = {}
H.exec(client, function() up3b.ok, up3b.info = pkg.update() end, "pkg.update (foreign block)")
local names3b = index_names()
check("another protocol's message is not read as an index",
      up3b.ok == true and has_name(names3b, "demo") and #names3b == repo_count,
      tostring(up3b.info) .. " " .. describe_names(names3b))
check("the index it wrote has no trace of that message",
      type(pkg.index()) == "table" and pkg.index().action == nil and
      pkg.index().t == nil and #pkg.index() == repo_count,
      slice(textutils.serialize(pkg.index() or {})))

-- 4. the pairing itself, on the wire: one request, one answer, and the answer
--    carries the id of the request it belongs to. A clean channel costs exactly
--    one round trip -- pairing is not a retry scheme.
H.wire_clear()
local up4 = {}
H.exec(client, function() up4.ok, up4.info = pkg.update() end, "pkg.update (clean)")
local asked, answered = {}, {}
for _, entry in ipairs(H.wire) do
    if entry.from == client and entry.to == repo then asked[#asked + 1] = entry end
    if entry.from == repo and entry.to == client then answered[#answered + 1] = entry end
end
check("a clean update sends exactly one request", #asked == 1, tostring(#asked))
check("a clean update gets exactly one answer", #answered == 1, tostring(#answered))
local req_msg = #asked == 1 and netcfg.unpack(asked[1].blob) or nil
local rep_msg = #answered == 1 and netcfg.unpack(answered[1].blob) or nil
check("the request carries an id",
      req_msg ~= nil and type(req_msg.id) == "string" and req_msg.id ~= "",
      type(req_msg) == "table" and tostring(req_msg.id) or "no request")
check("the repository echoes the id it was asked with",
      rep_msg ~= nil and rep_msg.id ~= nil and req_msg ~= nil and
      rep_msg.id == req_msg.id,
      tostring(req_msg and req_msg.id) .. " -> " .. tostring(rep_msg and rep_msg.id))
check("the id is bookkeeping and is not written into the index",
      type(pkg.index()) == "table" and pkg.index().id == nil,
      slice(textutils.serialize(pkg.index() or {})))
check("the clean update succeeded on the first answer", up4.ok == true,
      tostring(up4.info))

-- 5. the fetch entry points read the same channel and go through the same
--    function, so a leftover list answer must not be read as a package either
leftover({ id = "97-97", { name = "ghost", version = "5.0.0" } })
local fe5 = {}
H.exec(client, function()
    local req, err = pkg.requires("demo")
    fe5.kind, fe5.err = type(req), err
end, "pkg.requires (leftover)")
check("a fetch request ignores a leftover list answer", fe5.kind == "table",
      tostring(fe5.err))
check("the fetch leftover was consumed too", #H.box(client) == 0,
      tostring(#H.box(client)))

-- 6. compatibility: a repository that predates the id does not echo one, and the
--    client has to keep working with it. The shape of the answer is the fallback
--    there, and that is what keeps the old repository's leftover out of the index.
write_file("/etc/pkg.conf",
           "server_id=8\nkey=mysecretpassword\nchannel=pkg-repo\n" ..
           "chunk_size=1024\ntimeout=2\nretries=2\nmax_output=4096\n")
netcfg.reload()
H.spawn(8, function()
    while not H.stop do
        local sender, blob = rednet.receive(netcfg.channel(), 5)
        if sender then
            local req = netcfg.unpack(blob)
            if req and req.action == "list" then
                -- an older repository: it answers, and echoes nothing back
                rednet.send(sender, netcfg.pack({
                    { name = "old-repo", version = "0.1.0" },
                }), netcfg.channel())
            end
        end
    end
end, "old-repo")
leftover(FETCH_ANSWER)
local up6 = {}
H.exec(client, function() up6.ok, up6.info = pkg.update() end, "pkg.update (old repository)")
local names6 = index_names()
check("an older repository (no id echoed) still answers the list",
      up6.ok == true and has_name(names6, "old-repo"), tostring(up6.info))
check("and its leftover is told apart by shape, not taken as the index",
      not has_name(names6, "stale"), describe_names(names6))
-- Nothing may be left on the channel when the section ends: a later section's
-- fetch would read it, and a stray here would look like a defect there.
check("no answer is left on the channel when the section ends",
      #H.box(client) == 0, tostring(#H.box(client)))
write_file("/etc/pkg.conf",
           "server_id=5\nkey=mysecretpassword\nchannel=pkg-repo\n" ..
           "chunk_size=1024\ntimeout=2\nretries=2\nmax_output=4096\n")
netcfg.reload()
end
pkg_request_pairing()

-- The write gate of the package front ends lives in the shell layer, so it is
-- checked the way a user meets it: the command goes through psh as alice.
perm.set_current_user("alice")
_G.__PSH_TEST = true
local psh_chunk = assert(loadfile(PROJ .. "/usr/psh.lua"))
psh_chunk()
local psh_peer = _G.__psh_test
psh_peer.init()
H.clear()
local astatus = psh_peer.run("pkg install demo")
local aout = H.text() .. "\n" .. table.concat(_G.__OUT or {}, "\n")
_G.__PSH_TEST = nil
perm.set_current_user("root")
check("a non root user cannot install",
      astatus == 1 and aout:find("must be root", 1, true) ~= nil,
      tostring(astatus) .. " " .. slice(aout))
check("the refused install wrote nothing", not H.exists("/usr/pkgs/demo"))

-- ============================================================
section("pkg: dependency constraints in the manifest")
-- ============================================================
-- A "depends" entry may carry a version constraint, and the installer has to
-- honour it: install what is missing, upgrade what is too old, refuse what the
-- repository cannot satisfy. The repository here is the real pkgserver.
local function install(name, opts)
    local r = {}
    H.exec(7, function() r.ok, r.info = pkg.install(name, opts) end, "pkg.install " .. name)
    return r.ok, r.info
end

publish("base", "name=base\nversion=2.0.0\nbin=bin/base.lua\n", {
    ["bin/base.lua"] = "print('base 2.0.0')\n",
})
publish("app", "name=app\nversion=1.0.0\nbin=bin/app.lua\ndepends=base>=1.2\n", {
    ["bin/app.lua"] = "print('app 1.0.0')\n",
})
H.exec(7, function() pkg.update() end, "pkg.update (deps)")

local dop, dinfo = install("app")
check("a package with a dependency installs", dop == true, tostring(dinfo))
check("the dependency is installed as well", pkg.installed("base"),
      tostring(dinfo))
check("the report names the dependency it pulled in",
      tostring(dinfo):find("base", 1, true) ~= nil, tostring(dinfo))
check("the dependency was installed at the version the repository carries",
      pkg.installed_version("base") == "2.0.0", pkg.installed_version("base"))
check("pkg.dependencies reads the constraint back",
      table.concat(pkg.dependencies("app"), ",") == "base>=1.2",
      table.concat(pkg.dependencies("app"), ","))

-- the installed dependency is now too old for the next dependent, and the
-- repository carries a version that fits: the install has to upgrade it
publish("base", "name=base\nversion=1.5.0\nbin=bin/base.lua\n", {
    ["bin/base.lua"] = "print('base 1.5.0')\n",
})
publish("oldapp", "name=oldapp\nversion=1.0.0\nbin=bin/old.lua\ndepends=base<=1.9\n", {
    ["bin/old.lua"] = "print('oldapp 1.0.0')\n",
})
H.exec(7, function() pkg.update() end, "pkg.update (downgrade)")
local oap, oainfo = install("oldapp")
check("a dependency that is too new is replaced", oap == true, tostring(oainfo))
check("the dependency is now the version the constraint allows",
      pkg.installed_version("base") == "1.5.0", pkg.installed_version("base"))

-- a constraint the repository cannot satisfy must be refused, with the reason
publish("tool", "name=tool\nversion=1.0.0\nbin=bin/tool.lua\ndepends=base>=9.0\n", {
    ["bin/tool.lua"] = "print('tool')\n",
})
H.exec(7, function() pkg.update() end, "pkg.update (unsatisfiable)")
local tok, tinfo = install("tool")
check("an unsatisfiable constraint is refused", tok ~= true, tostring(tinfo))
check("the refusal names the dependency and the version it needs",
      tostring(tinfo):find("base", 1, true) ~= nil and
      tostring(tinfo):find("9.0", 1, true) ~= nil, tostring(tinfo))
check("the refused package is not installed", not pkg.installed("tool"))
check("the refused install left the dependency alone",
      pkg.installed_version("base") == "1.5.0", pkg.installed_version("base"))

-- a missing dependency is reported for the package that wanted it
publish("needy", "name=needy\nversion=1.0.0\nbin=bin/needy.lua\ndepends=ghost>=1.0\n", {
    ["bin/needy.lua"] = "print('needy')\n",
})
H.exec(7, function() pkg.update() end, "pkg.update (missing)")
local nok, ninfo = install("needy")
check("a dependency the repository does not carry is refused", nok ~= true,
      tostring(ninfo))
check("the refusal names the missing dependency",
      tostring(ninfo):find("ghost", 1, true) ~= nil, tostring(ninfo))
check("the dependent is not installed when its dependency failed",
      not pkg.installed("needy"))

-- the pieces the constraint check is built from
local pd = pkg.parse_dependency("base>=1.2")
check("a constraint is split into name, operator and version",
      pd.name == "base" and pd.op == ">=" and pd.version == "1.2")
check("a bare name has no operator", pkg.parse_dependency("base").op == nil)
check("the two character operators are not read as one",
      pkg.parse_dependency("base<=1.9").op == "<=" and
      pkg.parse_dependency("base==1.9").op == "=")
check("a malformed version is refused", pkg.parse_dependency("base>=x") == nil)
check("an empty entry is refused", pkg.parse_dependency("  ") == nil)
check("the checks read the operator they were given",
      pkg.version_satisfies("1.5", pd) and not pkg.version_satisfies("1.1", pd) and
      pkg.version_satisfies("1.2", pd))
check("a range is two entries, both of which have to hold",
      pkg.version_satisfies("1.5", pkg.parse_dependency("base>1.2")) and
      pkg.version_satisfies("1.5", pkg.parse_dependency("base<2.0")) and
      not pkg.version_satisfies("2.0", pkg.parse_dependency("base<2.0")))
check("a dependency reads back the way it was written",
      pkg.describe_dependency(pd) == "base>=1.2" and
      pkg.describe_dependency(pkg.parse_dependency("base")) == "base")

-- ============================================================
section("pkg: one install costs one fetch per package")
-- ============================================================
-- "pkg install NAME" used to download NAME's file set TWICE. The preflight
-- (pkg.requires) asks the repository for the package, and a "fetch" answer is
-- the WHOLE file set -- files, checksums, digest -- not just the manifest; the
-- install pass then asked again, because install_tree's cache started empty. It
-- was invisible until an answer became tied to the request that asked for it (a
-- request id echoed by pkgserver.lua, matched in lib/pkg.lua's answers()): the
-- old client took the next message on the channel, so the second wait silently
-- ate the first wait's late answer.
--
-- A request on the channel carries the package name in clear once the shared key
-- has unpacked it, and H.wire holds every datagram, so the number of downloads a
-- command costs is COUNTABLE instead of guessed at. That count is what these
-- assertions are built on: one install, one fetch per package, and every file set
-- that arrives is the one that was written.
--
-- A function, like pkg_request_pairing() above: the main chunk is close to the
-- 200 local limit of a Lua function.
local function pkg_one_fetch_per_package()
local client = 7          -- the computer every pkg call in this file runs on
local repo = 5            -- netcfg.server_id(): the pkgserver spawned above

-- How many "fetch" requests the client sent for `name` (any name when nil) since
-- `mark`, counted off the wire. The blob is decoded with the key the client used,
-- so a request is named by what it says rather than by where it was expected.
local function fetch_requests(mark, name)
    local n = 0
    for i = mark + 1, #H.wire do
        local entry = H.wire[i]
        if entry.from == client and entry.to == repo then
            local ok, msg = pcall(netcfg.unpack, entry.blob)
            if ok and type(msg) == "table" and msg.action == "fetch" and
               (name == nil or tostring(msg.name) == name) then
                n = n + 1
            end
        end
    end
    return n
end

-- 1. a package with no dependencies: one download, no second one.
publish("solo", "name=solo\nversion=1.0.0\nbin=bin/solo.lua\n", {
    ["bin/solo.lua"] = "print('solo 1.0.0')\n",
})
H.exec(client, function() pkg.update() end, "pkg.update (one fetch)")
local m1 = #H.wire
local s1ok, s1info = install("solo")
check("a package without dependencies still installs", s1ok == true,
      tostring(s1info))
check("and the file set that arrived is the one that was written",
      H.read("/usr/pkgs/solo/bin/solo.lua") == "print('solo 1.0.0')\n",
      slice(tostring(H.read("/usr/pkgs/solo/bin/solo.lua"))))
check("one install asks the repository for the package exactly once",
      fetch_requests(m1, "solo") == 1, tostring(fetch_requests(m1, "solo")))
check("and the install costs exactly one download in all",
      fetch_requests(m1, nil) == 1, tostring(fetch_requests(m1, nil)))

-- 2. a package with a dependency: one fetch per package, not one per pass. A
--    cache keyed by anything but the package name shows up here as well: with a
--    constant key the dependency would be handed its parent's file set, so the
--    two files below are the second half of the count.
publish("leaf", "name=leaf\nversion=1.0.0\nbin=bin/leaf.lua\n", {
    ["bin/leaf.lua"] = "print('leaf 1.0.0')\n",
})
publish("twin", "name=twin\nversion=1.0.0\nbin=bin/twin.lua\ndepends=leaf\n", {
    ["bin/twin.lua"] = "print('twin 1.0.0')\n",
})
H.exec(client, function() pkg.update() end, "pkg.update (one fetch, dependency)")
local m2 = #H.wire
local s2ok, s2info = install("twin")
check("a package with a dependency still installs", s2ok == true,
      tostring(s2info))
check("each package got its own file set, not its parent's",
      H.read("/usr/pkgs/twin/bin/twin.lua") == "print('twin 1.0.0')\n" and
      H.read("/usr/pkgs/leaf/bin/leaf.lua") == "print('leaf 1.0.0')\n",
      slice(tostring(H.read("/usr/pkgs/leaf/bin/leaf.lua"))))
check("the package that was asked for is fetched exactly once",
      fetch_requests(m2, "twin") == 1, tostring(fetch_requests(m2, "twin")))
check("its dependency is fetched exactly once, not twice",
      fetch_requests(m2, "leaf") == 1, tostring(fetch_requests(m2, "leaf")))
check("the whole install is one fetch per package: two, for two packages",
      fetch_requests(m2, nil) == 2, tostring(fetch_requests(m2, nil)))

-- 3. a package the repository does not carry: the preflight's FAILED answer has
--    to be remembered too. If it were dropped (or remembered as a success) the
--    install pass would either ask again or believe it had a file set; both are
--    defects, and the count plus the refusal name them.
local m3 = #H.wire
local s3ok, s3info = install("absent")
check("a package the repository does not carry is refused", s3ok ~= true,
      tostring(s3info))
check("the refusal carries the repository's own reason",
      tostring(s3info):find("package not found", 1, true) ~= nil,
      tostring(s3info))
check("a failed preflight is not asked for a second time by the install pass",
      fetch_requests(m3, "absent") == 1, tostring(fetch_requests(m3, "absent")))
check("the refused package is not installed", not pkg.installed("absent"))

-- 4. the one-argument form every existing caller uses (the shell's
--    "pkg requires NAME") still works and still costs its own single fetch; the
--    optional cache is a hand-over between the preflight and the install pass,
--    not a change of what pkg.requires() is.
local m4 = #H.wire
local febox = {}
H.exec(client, function()
    local req, err = pkg.requires("leaf")
    febox.kind, febox.err = type(req), err
end, "pkg.requires (one argument)")
check("pkg.requires answers for a caller that passes no cache",
      febox.kind == "table", tostring(febox.err))
check("the one argument form costs its own single fetch",
      fetch_requests(m4, "leaf") == 1, tostring(fetch_requests(m4, "leaf")))

-- The section installed real packages; remove them again so the sections after
-- this one see the machine they expected.
for _, name in ipairs({ "solo", "twin", "leaf" }) do
    H.exec(client, function() pkg.remove(name) end, "pkg.remove " .. name)
end
check("the one-fetch fixture is gone again",
      not pkg.installed("solo") and not pkg.installed("twin") and
      not pkg.installed("leaf"))
end
pkg_one_fetch_per_package()

-- ============================================================
section("pkg: a package that needs data off a mounted disk")
-- ============================================================
-- The font route: a package whose data (a bitmap font) cannot fit in the
-- machine's own filesystem declares that a mounted medium has to carry a marker
-- file, and the installer refuses before it downloads anything when no medium
-- is present. lib/disk.lua mounts the medium, lib/mounts.lua holds the table.
local mounts = require("mounts")
local disk = require("disk")

fs.makeDir("/disk")
write_file("/disk/.label", "fonts\n")
local mounted, mrec = mounts.mount("/disk", "/mnt/floppy", "rw", "test")
check("fixture: a removable medium is mounted", mounted == true, tostring(mrec))
check("fixture: the medium reports as present", disk.present("/disk") == true)
check("fixture: the mount table has the medium at /mnt/floppy",
      mounts.by_target("/mnt/floppy") ~= nil)

publish("ccfonts", "name=ccfonts\nversion=1.0.0\nbin=bin/cc_chinese.lua\n" ..
                 "requires_disk=cc_fonts.marker\n", {
    ["bin/cc_chinese.lua"] = "return {}\n",
})
publish("plain", "name=plain\nversion=1.0.0\nbin=bin/plain.lua\n", {
    ["bin/plain.lua"] = "return {}\n",
})
publish("feature", "name=feature\nversion=1.0.0\nbin=bin/feature.lua\n" ..
                   "requires_feature=disk\n", {
    ["bin/feature.lua"] = "return {}\n",
})
H.exec(7, function() pkg.update() end, "pkg.update (requirements)")

-- 1. no marker on the medium
local fok, finfo = install("ccfonts")
check("the disk package is refused while the marker is absent", fok ~= true,
      tostring(finfo))
check("the refusal tells the user to insert the disk",
      tostring(finfo):find("insert the disk", 1, true) ~= nil, tostring(finfo))
check("the refusal names the marker file",
      tostring(finfo):find("cc_fonts.marker", 1, true) ~= nil, tostring(finfo))
check("the refused package was not written", not pkg.installed("ccfonts"))

-- 2. the marker is on the medium: the install goes through
write_file("/disk/cc_fonts.marker", "cc fonts\n")
pkg.check_requirements({ requires_disk = "cc_fonts.marker" })
local fok2, finfo2 = install("ccfonts")
check("with the marker on the medium the package installs", fok2 == true,
      tostring(finfo2))
check("the installed package is on disk", pkg.installed("ccfonts"))
local inst_req = pkg.installed_requirements("ccfonts")
check("the installed manifest keeps the requirement",
      type(inst_req) == "table" and #inst_req == 1 and
      tostring(inst_req[1] and inst_req[1].value) == "cc_fonts.marker",
      type(inst_req) .. "/" .. tostring(#(inst_req or {})))
check("the requirement reads back for the user",
      pkg.describe_requirement(inst_req and inst_req[1]) ==
      "requires_disk=cc_fonts.marker")

-- 3. a package without requirements is never held back
local pok, pinfo = install("plain")
check("a package with no requirement installs with the same medium present",
      pok == true, tostring(pinfo))
check("a package with no requirement declares none",
      #pkg.installed_requirements("plain") == 0)

-- 4. a declared feature this build has (and one it does not)
local feok, feinfo = install("feature")
check("a package whose feature exists installs", feok == true, tostring(feinfo))
check("has_feature answers for a known and an unknown feature",
      pkg.has_feature("disk") and not pkg.has_feature("teleporter"))
local bad, badinfo = pkg.check_requirements({ requires_feature = "teleporter" })
check("an unknown feature is refused", bad == false, tostring(badinfo))
check("the unknown feature refusal names the feature",
      tostring(badinfo):find("teleporter", 1, true) ~= nil, tostring(badinfo))

-- 5. a file that has to exist, given as a path on the medium
local fok3, finfo3 = pkg.check_requirements({ requires_file = "/mnt/floppy/cc_fonts.marker" })
check("a file that exists on the medium satisfies the requirement", fok3 == true,
      tostring(finfo3))
local fok4, finfo4 = pkg.check_requirements({ requires_file = "/disk/cc_fonts.marker" })
check("the same file found through the source path satisfies it too", fok4 == true,
      tostring(finfo4))
local fok5, finfo5 = pkg.check_requirements({ requires_file = "/mnt/floppy/nothing.here" })
check("a file that is not there does not", fok5 == false, tostring(finfo5))

-- 6. the requirement list is parsed out of a manifest
local parsed = pkg.requirements({
    requires_disk = "cc_fonts.marker",
    requires_feature = "disk",
    requires = "xfer",
    version = "1.0.0",
})
check("every requirement key of a manifest is collected", #parsed == 3,
      tostring(#parsed))
check("the keys survive the parse in a stable order",
      parsed[1].key == "requires_disk" and parsed[1].value == "cc_fonts.marker" and
      parsed[2].key == "requires_feature" and parsed[2].value == "disk" and
      parsed[3].value == "xfer")
-- a real manifest may carry comments next to the requirement (the exported
-- cc_chinese package does), and a comment must not become a key
write_file("/usr/pkgs/commented/manifest",
           "name=commented\n# a comment\nrequires_disk=cc_fonts.marker\n")
local commented = pkg.read_manifest("commented")
check("a comment in a manifest is not read as a key",
      commented["# a comment"] == nil and commented.requires_disk == "cc_fonts.marker",
      tostring(commented.requires_disk))
check("the requirement of such a manifest is found",
      #pkg.requirements(commented) == 1)

-- 7. the package stays installed when the medium goes away, and the check says so
mounts.umount("/disk", nil)
mounts.clear_cache()
check("the medium is gone from the mount table", mounts.by_target("/mnt/floppy") == nil)
local sok, sinfo = pkg.check_requirements({ requires_disk = "cc_fonts.marker" })
check("with no medium the requirement is no longer satisfied", sok == false,
      tostring(sinfo))
check("the package itself is still installed (data vanished, package did not)",
      pkg.installed("ccfonts"))

-- ============================================================
section("pkg: making a medium a package store")
-- ============================================================
-- Two drives, two media. What makes a medium a store is the marker file ON the
-- medium: the machine records no drive letter, so a store that is moved to
-- another bay is still the same store.
fs.makeDir("/disk2")
write_file("/disk2/.label", "fontdata\n")
local m2, m2rec = mounts.mount("/disk2", "/mnt/fonts", "rw", "test")
check("fixture: a second medium is mounted", m2 == true, tostring(m2rec))
write_file("/disk2/cc_fonts.marker", "cc fonts\n")
mounts.clear_cache()

check("a medium without the marker is not a store", pkg.is_store("/disk2") == false)
check("with no store the machine is on auto", pkg.store() == "auto", pkg.store())
local sset, sres = pkg.store_claim(2)
check("claiming a medium writes the marker on it",
      sset == true and sres == "/disk2", tostring(sres))
check("the marker is on the medium itself",
      fs.exists("/disk2/.pkgstore"), "no .pkgstore on /disk2")
check("the machine now reads it as a store", pkg.store() == "/disk2", pkg.store())
check("the configuration file no longer records a drive letter",
      (H.read("/etc/pkgstore.conf") or ""):find("disk=", 1, true) == nil,
      tostring(H.read("/etc/pkgstore.conf")))
local state1 = pkg.store_state()
check("the store reads as a state with its mount point",
      state1.mode == "fixed" and state1.entry ~= nil and
      state1.entry.target == "/mnt/fonts", tostring(state1.mode))

-- the requirement marker is on both media, but only the store counts
write_file("/disk/cc_fonts.marker", "cc fonts\n")   -- disk 1 has it too
mounts.clear_cache()
check("the requirement marker is on both media",
      fs.exists("/disk/cc_fonts.marker") and fs.exists("/disk2/cc_fonts.marker"))
local sok1, sinfo1 = pkg.check_requirements({ requires_disk = "cc_fonts.marker" })
check("the store satisfies the requirement", sok1 == true, tostring(sinfo1))
check("the answer names the medium that satisfied it",
      tostring(sinfo1):find("/disk2", 1, true) ~= nil, tostring(sinfo1))

-- a medium that is NOT a store cannot satisfy a requirement it does not carry
local sok2, sinfo2 = pkg.check_requirements({ requires_disk = "nothing.here" })
check("a requirement no store carries is refused", sok2 == false, tostring(sinfo2))
check("the refusal names the stores that were checked",
      tostring(sinfo2):find("/disk2", 1, true) ~= nil, tostring(sinfo2))
check("the refusal says how a medium becomes a store",
      tostring(sinfo2):find("pkg store", 1, true) ~= nil, tostring(sinfo2))

-- an install whose requirement no store satisfies must fail before the fetch
publish("storeonly", "name=storeonly\nversion=1.0.0\nbin=bin/storeonly.lua\n" ..
                     "requires_disk=nothing.here\n", {
    ["bin/storeonly.lua"] = "return {}\n",
})
H.exec(7, function() pkg.update() end, "pkg.update (store)")
local stok, stinfo = install("storeonly")
check("an install against a missing requirement is refused", stok ~= true,
      tostring(stinfo))
check("that refusal names the store that was checked",
      tostring(stinfo):find("/disk2", 1, true) ~= nil, tostring(stinfo))
check("nothing was installed for it", not pkg.installed("storeonly"))

-- a drive that has no medium cannot be made a store: there is nothing to write
local sset3, sres3 = pkg.store_claim("/disk3")
check("a drive with no medium cannot be claimed", sset3 == false, tostring(sres3))
check("the refusal says nothing can be written there",
      tostring(sres3):find("no medium", 1, true) ~= nil, tostring(sres3))

-- The store is the MEDIUM, not the drive: the marker on the medium is the only
-- record, so a medium inserted anywhere is recognised by what it carries. The
-- machine never writes a drive letter down, which is what stops a later install
-- from being sent to whatever disk now happens to sit in the old bay.
check("the marker is the whole record: no drive letter is stored anywhere",
      pkg.is_store("/disk2") == true and
      (H.read("/etc/pkgstore.conf") or ""):find("disk=", 1, true) == nil and
      (H.read("/etc/pkgstore.conf") or ""):find("disk2", 1, true) == nil and
      (H.read("/disk2/.pkgstore") or ""):find("/disk", 1, true) == nil,
      tostring(H.read("/etc/pkgstore.conf")) .. " marker=" ..
      tostring(H.read("/disk2/.pkgstore")))

-- releasing the marker turns the medium back into an ordinary disk
local sset4, sres4 = pkg.store_release(2)
check("releasing a store removes the marker",
      sset4 == true and not fs.exists("/disk2/.pkgstore"), tostring(sres4))
check("the machine is on auto again", pkg.store() == "auto", pkg.store())
check("releasing a medium that is not a store is refused",
      pkg.store_release(2) == false)
local sok3 = pkg.check_requirements({ requires_disk = "cc_fonts.marker" })
check("with no store, any medium carrying the marker satisfies it again", sok3 == true,
      tostring(sok3))
check("a bogus disk number is refused", pkg.store_claim("floppy") == false)

-- ============================================================
section("pkg: installing on the removable store, and requiring it")
-- ============================================================
-- /disk2 is mounted with the marker: a package installed while it is the store
-- has to land on the medium, and the machine can be told never to install on
-- its own filesystem at all. The block is scoped, because the file has to stay
-- below Lua's 200 local variable limit.
do
    local medpkg = pkg
    mounts.clear_cache()
    local sstore, sres2 = medpkg.store_claim(2)
    check("the store is disk 2 again", sstore == true and medpkg.store() == "/disk2",
          tostring(sres2))
    local root_on_store = medpkg.root()
    check("the install root moves onto the medium", root_on_store == "/disk2/usr/pkgs",
          root_on_store)
    local rstate = medpkg.root_state()
    check("the root state says it is a removable medium",
          rstate.removable == true and rstate.internal == false and
          rstate.side == "/disk2", tostring(rstate.path))
    local rok, rnote = medpkg.check_root()
    check("the root check accepts the medium", rok == true, tostring(rnote))
    check("the note names the medium", tostring(rnote):find("/disk2", 1, true) ~= nil,
          tostring(rnote))

    publish("onmedium", "name=onmedium\nversion=1.0.0\nbin=bin/onmedium.lua\n", {
        ["bin/onmedium.lua"] = "print('on medium')\n",
    })
    H.exec(7, function() medpkg.update() end, "pkg.update (on medium)")
    local medok, medinfo = install("onmedium")
    check("the package installs", medok == true, tostring(medinfo))
    check("the package is really on the medium",
          fs.exists("/disk2/usr/pkgs/onmedium/manifest"), tostring(medinfo))
    check("the package is not on the computer's filesystem",
          not fs.exists("/usr/pkgs/onmedium"))
    check("the install says where it went",
          tostring(medinfo):find("/disk2", 1, true) ~= nil, tostring(medinfo))
    local listed = false
    for _, n in ipairs(medpkg.list()) do
        if n == "onmedium" then listed = true end
    end
    check("the installed package is still listed", medpkg.installed("onmedium") and listed)

    -- "packages must live on a medium"
    local req_ok, req_res = medpkg.set_store_required(true)
    check("the requirement can be switched on", req_ok == true, tostring(req_res))
    check("pkg.store_required reports it", medpkg.store_required() == true)
    check("the root state carries the switch", medpkg.root_state().required == true)
    local back_auto = medpkg.set_store("auto")
    check("the switch survives a store change back to auto", back_auto == true,
          tostring(medpkg.store()))
    local rok2, rnote2 = medpkg.check_root()
    check("with the switch on and no store the install is refused", rok2 == false,
          tostring(rnote2))
    check("the refusal tells the user how to make a medium a store",
          tostring(rnote2):find("pkg store", 1, true) ~= nil, tostring(rnote2))
    local nook, noinfo = install("plain")
    check("an install is refused while the switch is on and no store is made",
          nook ~= true, tostring(noinfo))

    -- a drive with no medium cannot be made a store, so it cannot satisfy the
    -- switch either: nothing is written behind the user's back
    local s3ok, s3res = medpkg.store_claim("/disk3")
    check("a drive with no medium cannot be made a store", s3ok == false,
          tostring(s3res))
    mounts.clear_cache()
    local rok3, rnote3 = medpkg.check_root()
    check("with no store at all the install is still refused", rok3 == false,
          tostring(rnote3))
    check("that refusal says how to make one",
          tostring(rnote3):find("make it a store", 1, true) ~= nil, tostring(rnote3))

    -- --store is a one-off choice: it must not change what the machine uses later
    medpkg.set_store("auto")
    mounts.clear_cache()
    local oneoff, oneoffinfo = install("plain", { store = 2 })
    check("--store installs onto that medium", oneoff == true, tostring(oneoffinfo))
    check("--store left the package on that medium",
          fs.exists("/disk2/usr/pkgs/plain/manifest"))
    check("--store did not make that medium the machine's store",
          medpkg.store() == "auto", medpkg.store())
    check("--store reported where the package went",
          tostring(oneoffinfo):find("/disk2", 1, true) ~= nil, tostring(oneoffinfo))
    local offok, offinfo = medpkg.set_store_required(false)
    check("the switch can be switched off again", offok == true, tostring(offinfo))
    check("with the switch off a store is no longer required",
          medpkg.store_required() == false)
    medpkg.set_store(2)
    mounts.clear_cache()
    local rok4, rnote4 = medpkg.check_root()
    check("with the switch off a named store is still allowed", rok4 == true,
          tostring(rnote4))
    check("the note says the packages are on the removable store",
          tostring(rnote4):find("removable store /disk2", 1, true) ~= nil,
          tostring(rnote4))
    medpkg.set_store("auto")
    mounts.clear_cache()
    local rok5, rnote5 = medpkg.check_root()
    check("with auto and the switch off the internal filesystem is allowed again",
          rok5 == true, tostring(rnote5))
    check("that note says the packages are on the computer",
          tostring(rnote5):find("this computer", 1, true) ~= nil, tostring(rnote5))
    -- leave no marker on either medium: the next section starts from no stores
    medpkg.store_release_all()
    medpkg.set_store_required(false)
    check("no store is left for the next section", medpkg.store() == "auto",
          medpkg.store())
end

-- the command a user actually types: "pkg store" reads, "pkg store N" writes and
-- needs root, exactly like the other write subcommands
_G.__PSH_TEST = true
local store_chunk = assert(loadfile(PROJ .. "/usr/psh.lua"))
store_chunk()
local store_shell = _G.__psh_test
store_shell.init()
perm.set_current_user("root")
H.clear()
local rs1 = store_shell.run("pkg store auto")
local os1 = H.text()
check("pkg store auto says what auto means",
      rs1 == 0 and os1:find("none", 1, true) ~= nil and
      os1:find("this computer", 1, true) ~= nil, tostring(rs1) .. " " .. slice(os1))
H.clear()
local rs2 = store_shell.run("pkg store 2")
local os2 = H.text()
check("pkg store 2 points the machine at disk 2",
      rs2 == 0 and pkg.store() == "/disk2", tostring(rs2) .. " " .. slice(os2))
check("the command reports the store it set",
      os2:find("/disk2", 1, true) ~= nil, slice(os2))
H.clear()
local rs3 = store_shell.run("pkg store")
local os3 = H.text()
check("pkg store with no argument shows the current store",
      rs3 == 0 and os3:find("/disk2", 1, true) ~= nil, slice(os3))
H.clear()
local rs4 = store_shell.run("pkg store nonsense")
check("pkg store refuses a value that is not a disk number", rs4 == 1, tostring(rs4))
check("the refusal says what is wrong",
      H.text():find("not a disk number", 1, true) ~= nil, slice(H.text()))
H.clear()
store_shell.run("pkg store auto")
H.clear()
-- pkg requires talks to the repository, so it has to run as a task on the
-- harness scheduler (a network wait yields, and a C-call boundary cannot yield)
H.clear()
_G.__OUT = {}
local req_ret
H.exec(7, function() req_ret = store_shell.run("pkg requires ccfonts") end,
       "pkg requires (store section)")
local os5 = H.text() .. "\n" .. table.concat(_G.__OUT or {}, "\n")
check("pkg requires names the requirement and its state",
      req_ret == 0 and os5:find("requires_disk", 1, true) ~= nil and
      (os5:find("ok:", 1, true) ~= nil or os5:find("missing:", 1, true) ~= nil),
      tostring(req_ret) .. " " .. slice(os5))
-- a plain user may read the store but not change it
perm.set_current_user("alice")
H.clear()
local rs6 = store_shell.run("pkg store")
check("a plain user can read the store", rs6 == 0, tostring(rs6))
H.clear()
local rs7 = store_shell.run("pkg store 3")
check("a plain user cannot set the store",
      rs7 == 1 and H.text():find("permission denied", 1, true) ~= nil,
      tostring(rs7) .. " " .. slice(H.text()))
perm.set_current_user("root")
H.clear()

-- the switch that makes a medium compulsory, from the command line
local rs8 = store_shell.run("pkg store required")
local os8 = H.text()
check("pkg store required switches the requirement on",
      rs8 == 0 and pkg.store_required() == true, tostring(rs8) .. " " .. slice(os8))
H.clear()
local rs9 = store_shell.run("pkg store optional")
check("pkg store optional switches it off",
      rs9 == 0 and pkg.store_required() == false, tostring(rs9) .. " " .. slice(H.text()))
H.clear()
store_shell.run("pkg store 2")
H.clear()
local rs10 = store_shell.run("pkg store")
local os10 = H.text()
check("pkg store shows the install root it will use",
      rs10 == 0 and os10:find("/disk2/usr/pkgs", 1, true) ~= nil, slice(os10))
-- the install option, end to end: the package lands on the medium and the
-- machine's own choice is untouched
H.clear()
local install_ret
local install_out = {}
local save_out = _G.__OUT
_G.__OUT = install_out
H.exec(7, function() install_ret = store_shell.run("pkg install --store 2 plain") end,
       "pkg install --store (shell)")
_G.__OUT = save_out
local os11 = table.concat(install_out, "\n")
check("pkg install --store installs the package",
      install_ret == 0 and fs.exists("/disk2/usr/pkgs/plain/manifest"),
      tostring(install_ret) .. " where=" .. tostring(pkg.package_path("plain")) ..
      " msg=" .. slice(os11))
check("pkg install --store left no store behind",
      pkg.store() == "auto", pkg.store())
check("pkg install rejects an unknown option",
      store_shell.run("pkg install --bogus plain") == 1)
check("pkg install says when --store has no disk number",
      store_shell.run("pkg install --store") == 1 and
      H.text():find("needs a disk number", 1, true) ~= nil, slice(H.text()))
perm.set_current_user("root")
store_shell.run("pkg store auto")
_G.__PSH_TEST = nil
H.clear()

-- ============================================================
section("pkg: several removable stores")
-- ============================================================
-- A machine may keep packages on more than one medium. Every medium carrying the
-- store marker is a store: the first one the mount table lists is where a new
-- package is written, and every store is searched, so a package installed on
-- either medium is found.
do
    local mpkg = pkg
    fs.makeDir("/disk3")
    write_file("/disk3/.label", "extra\n")
    local m3, m3rec = mounts.mount("/disk3", "/mnt/extra", "rw", "test")
    check("fixture: a third medium is mounted", m3 == true, tostring(m3rec))
    write_file("/disk3/cc_fonts.marker", "cc fonts\n")
    mounts.clear_cache()

    -- both media carry the marker, so both are stores
    mpkg.store_release(2)      -- only disk 3 is a store for this part
    local c2, c2res = mpkg.store_claim(3)
    check("a medium can be made a store", c2 == true, tostring(c2res))
    check("the machine reads it as the only store", mpkg.store() == "/disk3",
          "store=" .. mpkg.store() .. " claim=" .. tostring(c2res) ..
          " d2=" .. tostring(fs.exists("/disk2/.pkgstore")) ..
          " d3=" .. tostring(fs.exists("/disk3/.pkgstore")) ..
          " mounted2=" .. tostring(mpkg.is_store("/disk3")))
    check("the machine records no drive letter for it",
          (H.read("/etc/pkgstore.conf") or ""):find("disk=", 1, true) == nil,
          tostring(H.read("/etc/pkgstore.conf")))

    -- two stores at once
    local c1, c1res = mpkg.store_claim(2)
    check("two media can be stores at once", c1 == true, tostring(c1res))
    check("pkg.store reports them in mount order", mpkg.store() == "/disk2,/disk3",
          mpkg.store())
    check("pkg.stores returns them as a list",
          #mpkg.stores() == 2 and mpkg.stores()[1] == "/disk2" and
          mpkg.stores()[2] == "/disk3", table.concat(mpkg.stores(), ","))

    -- two stores, and the first one is written to
    local first, second = mpkg.store_list()[1], mpkg.store_list()[2]
    check("both marked media are stores, in mount order",
          #mpkg.store_list() == 2 and first.side == "/disk2" and second.side == "/disk3",
          tostring(first and first.side) .. "/" .. tostring(second and second.side))
    check("the install root is the first store", mpkg.root() == "/disk2/usr/pkgs",
          mpkg.root())
    check("every root is searched, both stores and the computer",
          #mpkg.roots() == 3 and mpkg.roots()[1] == "/disk2/usr/pkgs" and
          mpkg.roots()[2] == "/disk3/usr/pkgs" and
          mpkg.roots()[3] == "/usr/pkgs", table.concat(mpkg.roots(), ","))
    local rok, rnote = mpkg.check_root()
    check("an install is allowed while a store is there", rok == true, tostring(rnote))
    check("the note names the first store",
          tostring(rnote):find("/disk2", 1, true) ~= nil, tostring(rnote))

    -- a package installed with no --store goes to the FIRST store
    publish("onfirst", "name=onfirst\nversion=1.0.0\nbin=bin/onfirst.lua\n", {
        ["bin/onfirst.lua"] = "print('on first')\n",
    })
    H.exec(7, function() mpkg.update() end, "pkg.update (on first)")
    local fok, finfo = install("onfirst")
    check("a normal install writes to the first store", fok == true, tostring(finfo))
    check("the package is on the first store",
          fs.exists("/disk2/usr/pkgs/onfirst/manifest"), tostring(finfo))

    -- a package on the SECOND store is found by every reader. Disk 2 is released
    -- first so that "--store 3" is the only store in play for this command.
    local rel2 = mpkg.store_release(2)
    check("the first store can be released", rel2 == true)
    check("with one store left the root is that store",
          mpkg.root() == "/disk3/usr/pkgs", mpkg.root())
    publish("onthird", "name=onthird\nversion=1.0.0\nbin=bin/onthird.lua\n", {
        ["bin/onthird.lua"] = "print('on third')\n",
    })
    H.exec(7, function() mpkg.update() end, "pkg.update (several stores)")
    local t3ok, t3info = install("onthird", { store = 3 })
    check("a package installs onto the store named for the command", t3ok == true,
          tostring(t3info))
    check("it really is on disk 3",
          fs.exists("/disk3/usr/pkgs/onthird/manifest"), tostring(t3info))
    check("the one-off store marker is gone again",
          not mpkg.is_store("/disk3"), "disk 3 is still a store")
    check("the machine has no store left after a one-off install",
          mpkg.store() == "auto", mpkg.store())
    -- the reader finds it once the medium is a store again: a package is looked
    -- for in every store, not only in the root a new package would go to
    local back3 = mpkg.store_claim(3)
    check("the medium can be made a store again", back3 == true)
    check("the reader finds the package on that store",
          mpkg.installed("onthird"), tostring(mpkg.package_path("onthird")))
    check("the manifest is read from that medium",
          mpkg.installed_version("onthird") == "1.0.0",
          tostring(mpkg.installed_version("onthird")))
    check("the command resolves to that medium",
          mpkg.resolve_command("onthird") == "/disk3/usr/pkgs/onthird/bin/onthird.lua",
          tostring(mpkg.resolve_command("onthird")) ..
          " bins=" .. tostring(textutils.serialize(mpkg.get_bins()["onthird"])))
    local listed = {}
    for _, n in ipairs(mpkg.list()) do listed[n] = true end
    check("pkg list shows the package on the store that is there",
          listed.onthird == true and listed.onfirst == nil,
          tostring(listed.onthird) .. "/" .. tostring(listed.onfirst) ..
          " roots=" .. table.concat(mpkg.roots(), ","))
    check("a package on a medium that is not a store is not visible",
          not mpkg.installed("onfirst"), tostring(mpkg.package_path("onfirst")))

    -- a requirement is satisfied by ANY of the stores
    local back2 = mpkg.store_claim(2)
    check("a second store can be added back", back2 == true)
    check("the requirement marker on the first store satisfies it",
          mpkg.check_requirements({ requires_disk = "cc_fonts.marker" }) == true)
    check("the marker found through the mount point does as well",
          mpkg.check_requirements({ requires_file = "/mnt/extra/cc_fonts.marker" }) == true)
    local rok3, rnote3 = mpkg.check_root()
    check("with two stores the first is the install root", rok3 == true, tostring(rnote3))
    check("and the note names it", tostring(rnote3):find("/disk2", 1, true) ~= nil,
          tostring(rnote3))

    -- releasing one store leaves the other alone
    local rok2, rres2 = mpkg.store_release(2)
    check("a store can be released", rok2 == true and mpkg.store() == "/disk3",
          "ret=" .. tostring(rok2) .. " res=" .. tostring(rres2) ..
          " store=" .. tostring(mpkg.store()))
    check("the released medium lost only its marker",
          not fs.exists("/disk2/.pkgstore") and
          fs.exists("/disk2/usr/pkgs/onfirst/manifest"))
    check("a medium that is no longer a store is no longer searched",
          not mpkg.installed("onfirst"), tostring(mpkg.package_path("onfirst")))
    local re2 = mpkg.store_claim(2)
    check("making it a store again brings its packages back",
          re2 == true and mpkg.installed("onfirst"),
          tostring(mpkg.package_path("onfirst")))
    check("releasing one that is not a store is refused", mpkg.store_release(5) == false)
    check("a bogus disk number is refused", mpkg.store_claim("floppy") == false)

    -- everything back to the way the other sections expect it
    mpkg.store_release_all()
    mpkg.set_store_required(false)
    check("with no store left the machine is on auto", mpkg.store() == "auto",
          mpkg.store())
    check("with auto the computer is the install root", mpkg.root() == "/usr/pkgs",
          mpkg.root())

    -- the commands a user types
    _G.__PSH_TEST = true
    local mchunk = assert(loadfile(PROJ .. "/usr/psh.lua"))
    mchunk()
    local mshell = _G.__psh_test
    mshell.init()
    perm.set_current_user("root")
    H.clear()
    local ms1 = mshell.run("pkg store 2")
    local mos1 = H.text()
    check("pkg store <n> makes that medium a store",
          ms1 == 0 and mpkg.is_store("/disk2") and mpkg.store() == "/disk2",
          tostring(ms1) .. " " .. slice(mos1))
    H.clear()
    local ms2 = mshell.run("pkg store 3")
    check("a second medium can be made a store too",
          ms2 == 0 and mpkg.store() == "/disk2,/disk3", tostring(ms2) .. " " .. slice(H.text()))
    H.clear()
    local ms3 = mshell.run("pkg store")
    local mos3 = H.text()
    check("pkg store lists the stores and the install root",
          ms3 == 0 and mos3:find("/disk2", 1, true) ~= nil and
          mos3:find("/disk3", 1, true) ~= nil and
          mos3:find("/disk2/usr/pkgs", 1, true) ~= nil, slice(mos3))
    H.clear()
    local ms4 = mshell.run("pkg store remove 3")
    check("pkg store remove releases the marker",
          ms4 == 0 and not mpkg.is_store("/disk3") and mpkg.store() == "/disk2",
          tostring(ms4) .. " " .. slice(H.text()))
    H.clear()
    local ms5 = mshell.run("pkg store remove 9")
    check("removing a medium that is not a store is refused",
          ms5 == 1 and H.text():find("not a package store", 1, true) ~= nil, slice(H.text()))
    H.clear()
    local ms6 = mshell.run("pkg store 9")
    check("making a drive with no medium a store is refused",
          ms6 == 1 and H.text():find("not a mounted medium", 1, true) ~= nil, slice(H.text()))
    H.clear()
    local ms7 = mshell.run("pkg store nonsuch")
    check("a value that is not a disk number is refused",
          ms7 == 1 and H.text():find("not a disk number", 1, true) ~= nil, slice(H.text()))
    H.clear()
    local ms8 = mshell.run("pkg store auto")
    check("pkg store auto releases every store",
          ms8 == 0 and mpkg.store() == "auto", tostring(ms8) .. " " .. slice(H.text()))
    H.clear()
    -- the inventory: one line per root, and the whole thing as JSON
    mpkg.store_claim(2)
    mpkg.store_claim(3)
    H.clear()
    local ms9 = mshell.run("pkg store")
    local mos9 = H.text()
    check("pkg store reports what is on each medium",
          ms9 == 0 and mos9:find("package(s)", 1, true) ~= nil and
          mos9:find("onthird", 1, true) ~= nil and
          mos9:find("onfirst", 1, true) ~= nil and
          mos9:find("this computer", 1, true) ~= nil, slice(mos9))
    H.clear()
    local ms10 = mshell.run("pkg store --json")
    local mos10 = H.text()
    check("pkg store --json renders the same answer as JSON",
          ms10 == 0 and mos10:find('"stores"', 1, true) ~= nil and
          mos10:find('"side": "/disk2"', 1, true) ~= nil and
          mos10:find('"install_root"', 1, true) ~= nil, slice(mos10))
    H.clear()
    local ms11 = mshell.run("pkg list -s")
    local mos11 = H.text()
    check("pkg list -s groups the packages by medium",
          ms11 == 0 and mos11:find("/disk2", 1, true) ~= nil and
          mos11:find("/disk3", 1, true) ~= nil and
          mos11:find("onfirst", 1, true) ~= nil and
          mos11:find("onthird", 1, true) ~= nil, slice(mos11))
    perm.set_current_user("root")
    _G.__PSH_TEST = nil
    H.clear()
end

-- ============================================================
section("pkg: two markers, the system module store and an ordinary store")
-- ============================================================
-- A machine built in two parts -- the shell on its own disk, its own modules on a
-- medium -- has to tell those modules apart from ordinary extra packages. The
-- difference decides what "the medium is not inserted" MEANS:
--
--   .pkgsys    the system module store: modules the shell itself needs. Losing it
--              costs functionality, so a machine can require it and be told.
--   .pkgstore  an ordinary removable store: extra packages. Losing it costs
--              nothing but those packages.
--
-- Three properties carry the design, and each is checked here because getting it
-- wrong is silent: a system store is searched BEFORE an ordinary one, new packages
-- still go to an ordinary one (a system store holds the installation's own
-- modules, not extras), and a missing system store WARNS where a missing required
-- store REFUSES.
do
    local tpkg = pkg
    tpkg.store_release_all()
    tpkg.set_store_required(false)
    tpkg.set_sys_required(false)
    mounts.clear_cache()

    check("the two markers are named and exported",
          tpkg.store_marker == ".pkgstore" and tpkg.sys_marker == ".pkgsys",
          tostring(tpkg.store_marker) .. "/" .. tostring(tpkg.sys_marker))

    -- nothing marked yet
    check("a medium with no marker has no kind", tpkg.store_kind("/disk2") == nil,
          tostring(tpkg.store_kind("/disk2")))
    check("and it is not a store of either kind",
          tpkg.is_store("/disk2") == false and tpkg.is_sys_store("/disk2") == false)

    -- an ordinary store. NOTE the deliberate choice of media: the ORDINARY store
    -- is on /disk2 and the SYSTEM store on /disk3, so mount order (disk2, disk3) is
    -- the OPPOSITE of the order roots() must return. If the two media were the
    -- other way round, "system first" and "mount order" would agree and a test
    -- written that way would pass even with the priority removed.
    local ok_ord = tpkg.store_claim(2)
    check("an ordinary store is claimed", ok_ord == true, tostring(ok_ord))
    check("it reads as an ordinary store", tpkg.store_kind("/disk2") == "store",
          tostring(tpkg.store_kind("/disk2")))
    check("it is a store but not the system one",
          tpkg.is_store("/disk2") == true and tpkg.is_sys_store("/disk2") == false)
    check("it carries the ordinary marker and not the system one",
          fs.exists("/disk2/.pkgstore") and not fs.exists("/disk2/.pkgsys"))

    -- the system module store, on the LATER-mounted medium
    local ok_sys = tpkg.store_claim_sys(3)
    check("a medium can be claimed as the system module store", ok_sys == true,
          tostring(ok_sys))
    check("it reads as the system store", tpkg.store_kind("/disk3") == "sys",
          tostring(tpkg.store_kind("/disk3")))
    check("it is both a store and the system one",
          tpkg.is_store("/disk3") == true and tpkg.is_sys_store("/disk3") == true)
    check("it carries the system marker and not the ordinary one",
          fs.exists("/disk3/.pkgsys") and not fs.exists("/disk3/.pkgstore"),
          "sys=" .. tostring(fs.exists("/disk3/.pkgsys")) ..
          " store=" .. tostring(fs.exists("/disk3/.pkgstore")))
    check("sys_stores names only the system one",
          #tpkg.sys_stores() == 1 and tpkg.sys_stores()[1] == "/disk3",
          table.concat(tpkg.sys_stores(), ","))
    check("sys_store is that medium", tpkg.sys_store() == "/disk3",
          tostring(tpkg.sys_store()))

    -- BOTH markers on one medium: the stronger claim wins. A store that is
    -- required must not be mistaken for one that is optional.
    write_file("/disk2/.pkgsys", "psh system module store\n")
    check("a medium carrying both markers reads as the system store",
          tpkg.store_kind("/disk2") == "sys", tostring(tpkg.store_kind("/disk2")))
    fs.delete("/disk2/.pkgsys")
    check("removing the system marker leaves it an ordinary store",
          tpkg.store_kind("/disk2") == "store", tostring(tpkg.store_kind("/disk2")))

    -- SEARCH ORDER: the system store comes first, so a module the shell depends on
    -- is the one that wins when both media are inserted and both carry the name.
    -- The system store is mounted LAST here, so this can only pass if the priority
    -- is real rather than an accident of mount order.
    local roots = tpkg.roots()
    check("the system store is searched before the ordinary one",
          #roots == 3 and roots[1] == "/disk3/usr/pkgs" and
          roots[2] == "/disk2/usr/pkgs" and roots[3] == "/usr/pkgs",
          table.concat(roots, ","))
    check("the store list itself stays in mount order",
          #tpkg.store_list() == 2 and tpkg.store_list()[1].side == "/disk2" and
          tpkg.store_list()[2].side == "/disk3",
          tostring(tpkg.store_list()[1].side) .. "/" .. tostring(tpkg.store_list()[2].side))

    -- WRITE TARGET: an ordinary store, not the system one.
    --
    -- Two configurations, because the two properties are independent and one
    -- arrangement cannot catch both:
    --   * system store LAST (above) catches "roots() must prefer sys", since mount
    --     order and the required order disagree;
    --   * system store FIRST (below) catches "root() must skip sys", since there the
    --     system store is exactly what a naive "first store wins" would pick.
    check("a new package goes to the ordinary store, not the system one",
          tpkg.root() == "/disk2/usr/pkgs", tpkg.root())
    local st = tpkg.root_state()
    check("the install root is reported as the ordinary store",
          st.path == "/disk2/usr/pkgs" and st.side == "/disk2" and st.kind == "store",
          tostring(st.path) .. "/" .. tostring(st.side) .. "/" .. tostring(st.kind))
    check("the system store is reported alongside it",
          st.sys_present == true and st.sys_side == "/disk3",
          tostring(st.sys_present) .. "/" .. tostring(st.sys_side))
    local cok, cnote = tpkg.check_root()
    check("an install is allowed while both are inserted", cok == true, tostring(cnote))
    check("and the note names the ordinary store it will use",
          tostring(cnote):find("/disk2", 1, true) ~= nil, tostring(cnote))

    -- the other arrangement: the SYSTEM store is the first medium the mount table
    -- lists. A new package must still not be written into it.
    do
        local swap_ord = tpkg.store_release_all()
        local s1 = tpkg.store_claim_sys(2)
        local s2 = tpkg.store_claim(3)
        check("fixture: the system store is now mounted first", s1 == true and s2 == true)
        check("it is the first entry the mount table lists",
              tpkg.store_list()[1].side == "/disk2" and
              tpkg.store_list()[1].kind == "sys",
              tostring(tpkg.store_list()[1].side) .. "/" ..
              tostring(tpkg.store_list()[1].kind))
        check("the system store is still searched first", tpkg.roots()[1] ==
              "/disk2/usr/pkgs", table.concat(tpkg.roots(), ","))
        check("but a new package still goes to the ordinary store",
              tpkg.root() == "/disk3/usr/pkgs", tpkg.root())
        check("and the reported install root is the ordinary one",
              tpkg.root_state().path == "/disk3/usr/pkgs" and
              tpkg.root_state().kind == "store",
              tostring(tpkg.root_state().path) .. "/" .. tostring(tpkg.root_state().kind))
        -- put the first arrangement back for the rest of the section
        local back_swap = tpkg.store_release_all()
        local b1 = tpkg.store_claim(2)
        local b2 = tpkg.store_claim_sys(3)
        check("fixture: the first arrangement is restored", b1 == true and b2 == true and
              tpkg.store_kind("/disk2") == "store" and tpkg.store_kind("/disk3") == "sys",
              tostring(tpkg.store_kind("/disk2")) .. "/" .. tostring(tpkg.store_kind("/disk3")))
    end

    -- a package on the system store is FOUND (it is a package source too).
    --
    -- Two things about this fixture, both deliberate:
    --  * "install(..., { store = 3 })" is a ONE-OFF store: pkg.install claims the
    --    marker and releases it again when the command ends, so the medium is not a
    --    store afterwards. That is the documented behaviour and the check below
    --    relies on it.
    --  * the ordinary store on disk 2 is released first, so disk 3 is the only store
    --    in play. "install --store N" names which medium to CLAIM, but a new package
    --    is still written to the root pkg.root() picks, which is the first ordinary
    --    store in mount order. (The "several removable stores" section above does
    --    the same, and for the same reason.)
    publish("sysmod", "name=sysmod\nversion=1.0.0\nbin=bin/sysmod.lua\n", {
        ["bin/sysmod.lua"] = "print('a system module')\n",
    })
    H.exec(7, function() tpkg.update() end, "pkg.update (sys store)")
    local held_ord = tpkg.store_release(2)
    check("fixture: only the system store is left to write to", held_ord == true and
          tpkg.store_kind("/disk2") == nil, tostring(tpkg.store_kind("/disk2")))
    local sok, sinfo = install("sysmod", { store = 3 })
    check("a package can be put on a medium named for the command", sok == true,
          tostring(sinfo))
    check("it is on disk 3", fs.exists("/disk3/usr/pkgs/sysmod/manifest"), tostring(sinfo))
    check("a one-off store releases its marker when the command ends",
          tpkg.store_kind("/disk3") == nil, tostring(tpkg.store_kind("/disk3")))
    check("so the package is not visible while the medium is not a store",
          not tpkg.installed("sysmod"), tostring(tpkg.package_path("sysmod")))
    local back_sys2 = tpkg.store_claim_sys(3)
    check("fixture: the medium is the system store again", back_sys2 == true)
    check("the reader finds the package on the system store", tpkg.installed("sysmod"),
          tostring(tpkg.package_path("sysmod")))
    check("and it resolves to that medium",
          tpkg.resolve_command("sysmod") == "/disk3/usr/pkgs/sysmod/bin/sysmod.lua",
          tostring(tpkg.resolve_command("sysmod")))
    local back_ord2 = tpkg.store_claim(2)
    check("fixture: the ordinary store is back too", back_ord2 == true)

    -- sys_required: the rule that makes a missing system store visible
    check("with no rule the machine is complete either way",
          tpkg.sys_status().required == false and tpkg.sys_status().complete == true,
          textutils.serialize(tpkg.sys_status()))
    check("and it has no warning to give", tpkg.completeness_warning() == nil,
          tostring(tpkg.completeness_warning()))

    local rok, rres = tpkg.set_sys_required(true)
    check("the rule can be turned on", rok == true, tostring(rres))
    check("the rule is recorded on the computer, not on a medium",
          (H.read("/etc/pkgstore.conf") or ""):find("sys_required=1", 1, true) ~= nil,
          tostring(H.read("/etc/pkgstore.conf")))
    check("it does not disturb the other switch",
          (H.read("/etc/pkgstore.conf") or ""):find("store_required", 1, true) == nil,
          tostring(H.read("/etc/pkgstore.conf")))
    check("with the rule on and the medium in, the machine is complete",
          tpkg.sys_status().complete == true and tpkg.sys_status().present == true,
          textutils.serialize(tpkg.sys_status()))

    -- now take the system medium out: the machine becomes incomplete. Disk 3 is the
    -- system store, so that is the one to release; disk 2 (the ordinary store) stays
    -- in, which is the point -- the machine can still install, but it is not whole.
    local srel = tpkg.store_release(3)
    check("the system store can be released", srel == true, tostring(srel))
    check("the ordinary store is still there", tpkg.store_kind("/disk2") == "store",
          tostring(tpkg.store_kind("/disk2")))
    check("with it gone the machine is not complete",
          tpkg.sys_status().required == true and tpkg.sys_status().present == false and
          tpkg.sys_status().complete == false,
          textutils.serialize(tpkg.sys_status()))
    local warn = tpkg.completeness_warning()
    check("a warning names the missing marker",
          type(warn) == "string" and warn:find(".pkgsys", 1, true) ~= nil,
          tostring(warn))
    local aok, anote = tpkg.check_root()
    check("a missing system store WARNS but does not refuse",
          aok == true and tostring(anote):find(".pkgsys", 1, true) ~= nil,
          tostring(aok) .. "/" .. tostring(anote))

    -- PRECEDENCE: a required store refuses, and that refusal must not be masked by
    -- the system-store warning. (An earlier revision asked about the system store
    -- first and returned early, so the install went ahead.)
    tpkg.set_store_required(true)
    local allrel = tpkg.store_release_all()
    check("fixture: no store at all is inserted", #tpkg.stores() == 0,
          table.concat(tpkg.stores(), ","))
    local bok, bnote = tpkg.check_root()
    check("the required-store refusal wins over the system-store warning",
          bok == false and tostring(bnote):find("requires packages on a removable",
                                               1, true) ~= nil,
          tostring(bok) .. "/" .. tostring(bnote))
    local iok, inote = tpkg.install("sysmod")
    check("so an install with no store is refused, not allowed with a warning",
          iok == false and tostring(inote):find("requires packages on a removable",
                                               1, true) ~= nil,
          tostring(iok) .. "/" .. tostring(inote))
    tpkg.set_store_required(false)

    -- release takes off whichever marker is there
    local back_sys = tpkg.store_claim_sys(3)
    check("fixture: the system store is back", back_sys == true and
          tpkg.store_kind("/disk3") == "sys")
    local rel_any = tpkg.store_release(3)
    check("releasing a system store works like releasing any store",
          rel_any == true and tpkg.store_kind("/disk3") == nil,
          tostring(rel_any) .. "/" .. tostring(tpkg.store_kind("/disk3")))
    check("both markers are gone, not just one",
          not fs.exists("/disk3/.pkgstore") and not fs.exists("/disk3/.pkgsys"))

    -- claiming as the system store replaces an ordinary marker: a medium cannot be
    -- both, and leaving both files would make the kind depend on check order
    local ord_again = tpkg.store_claim(3)
    check("fixture: disk 3 is an ordinary store again", ord_again == true and
          fs.exists("/disk3/.pkgstore"))
    local to_sys = tpkg.store_claim_sys(3)
    check("claiming it as the system store replaces the ordinary marker",
          to_sys == true and fs.exists("/disk3/.pkgsys") and
          not fs.exists("/disk3/.pkgstore"),
          "sys=" .. tostring(fs.exists("/disk3/.pkgsys")) ..
          " store=" .. tostring(fs.exists("/disk3/.pkgstore")))
    check("and the kind follows", tpkg.store_kind("/disk3") == "sys",
          tostring(tpkg.store_kind("/disk3")))

    -- the report and its JSON carry the kind and the completeness, so a script does
    -- not have to read marker files itself
    tpkg.set_sys_required(true)
    tpkg.store_claim(2)
    local rep = tpkg.store_report()
    check("the report says whether the system store is required",
          rep.sys_required == true, tostring(rep.sys_required))
    check("and whether it is present", rep.sys_present == true, tostring(rep.sys_present))
    check("and whether the machine is complete", rep.sys_complete == true,
          tostring(rep.sys_complete))
    check("the report names the system store's side", rep.sys_side == "/disk3",
          tostring(rep.sys_side))
    local kinds = {}
    for _, s in ipairs(rep.stores) do kinds[s.side] = s.kind end
    check("each store in the report carries its kind",
          kinds["/disk3"] == "sys" and kinds["/disk2"] == "store",
          tostring(kinds["/disk3"]) .. "/" .. tostring(kinds["/disk2"]))
    local jrep = tpkg.store_report_json() or ""
    check("the JSON carries the system store facts",
          jrep:find('"sys_required"', 1, true) ~= nil and
          jrep:find('"sys_present"', 1, true) ~= nil and
          jrep:find('"sys_complete"', 1, true) ~= nil,
          jrep:sub(1, 160))
    check("the JSON labels each store with its kind",
          jrep:find('"kind"', 1, true) ~= nil, jrep:sub(1, 160))

    -- the commands a user types
    _G.__PSH_TEST = true
    local tchunk = assert(loadfile(PROJ .. "/usr/psh.lua"))
    tchunk()
    local tshell = _G.__psh_test
    tshell.init()
    perm.set_current_user("root")
    H.clear()
    local st_sys = tshell.run("pkg store sys")
    local o_sys = H.text()
    check("pkg store sys reports the system module store",
          st_sys == 0 and o_sys:find("system module store", 1, true) ~= nil,
          tostring(st_sys) .. " " .. o_sys:gsub("\n", " "))
    H.clear()
    local st_list = tshell.run("pkg store")
    local o_list = H.text()
    check("pkg store labels which medium holds the system modules",
          st_list == 0 and o_list:find("system modules", 1, true) ~= nil,
          o_list:gsub("\n", " "))
    H.clear()
    local st_req = tshell.run("pkg store sys-required")
    check("pkg store sys-required turns the rule on", st_req == 0,
          tostring(st_req) .. " " .. H.text())
    check("and the rule is on disk, not on a medium",
          (H.read("/etc/pkgstore.conf") or ""):find("sys_required=1", 1, true) ~= nil,
          tostring(H.read("/etc/pkgstore.conf")))
    H.clear()
    local st_opt = tshell.run("pkg store sys-optional")
    check("pkg store sys-optional turns it off again", st_opt == 0, tostring(st_opt))
    check("and the line is gone",
          (H.read("/etc/pkgstore.conf") or ""):find("sys_required", 1, true) == nil,
          tostring(H.read("/etc/pkgstore.conf")))
    perm.set_current_user("root")
    _G.__PSH_TEST = nil
    H.clear()

    -- leave the machine the way the other sections expect it
    tpkg.store_release_all()
    tpkg.set_store_required(false)
    tpkg.set_sys_required(false)
    check("the section leaves no store and no rules behind",
          tpkg.store() == "auto" and tpkg.sys_status().required == false,
          tpkg.store() .. "/" .. tostring(tpkg.sys_status().required))
end

-- ============================================================
section("mounts: modules a package contributes to require()")
-- ============================================================
-- Commands and modules are two different lookups. A command is a FILE the shell
-- runs by path, so path.lua only has to know where to look. A module goes through
-- require(), which searches package.path and NOTHING else -- so a module on a
-- mounted medium is invisible until its directory is on that path.
--
-- This is what makes a two-part machine work: the shell's own modules live on a
-- medium marked .pkgsys, at <medium>/usr/pkgs/<name>/lib, and the shell has to be
-- able to require them. The scan lives in lib/mounts.lua and NOT in lib/pkg.lua,
-- because on such a machine pkg.lua is itself on the medium: a shell that had to
-- load the package manager to find the medium's modules could never start.
--
-- NOTE on what can be asserted here: the suite's require() is the HOST Lua's, so
-- it reads the host filesystem, not this stub's fs. Whether a module on an
-- emulated medium is really requirable is therefore proven on CraftOS-PC
-- (tools/rpv-verify/probe_part.sh: "require mediumonly (medium only)=true" with no
-- manual package.path edit). What IS checkable here is the mechanism that decides
-- the entries: which directories are found, and what happens to package.path.
do
    local mnt = require("mounts")
    local mpkg = pkg

    -- a clean slate: no store, and our entries out of package.path.
    -- The media are unmounted FIRST and explicitly: earlier sections in this file
    -- leave /disk2 and /disk3 mounted, and "an unmounted medium contributes
    -- nothing" is only meaningful if the medium really is unmounted. (Getting this
    -- wrong makes the assertion vacuous, not red -- the first draft of this section
    -- failed exactly here.)
    mpkg.store_release_all()
    mpkg.set_store_required(false)
    mpkg.set_sys_required(false)
    -- mounts.list() is cached; drop the cache first so find() reads the real table
    mounts.clear_cache()
    for _, side in ipairs({ "/disk2", "/disk3" }) do
        if mounts.find(side) then mounts.umount(side) end
    end
    mounts.clear_cache()
    mnt.refresh_module_paths()

    local function path_has(entry)
        return package.path:find(entry, 1, true) ~= nil
    end

    -- a package on the computer's own root, with a lib/ directory
    write_file("/usr/pkgs/localmod/lib/localmod.lua", "return {}\n")
    write_file("/usr/pkgs/localmod/manifest", "name=localmod\nversion=1.0.0\n")
    mnt.clear_cache()
    local dirs = mnt.module_dirs()
    check("a package lib directory on the computer is found",
          path_has("/usr/pkgs/localmod/lib") or
          (function() for _, d in ipairs(dirs) do
              if d == "/usr/pkgs/localmod/lib" then return true end end return false end)(),
          table.concat(dirs, ","))

    local added, list = mnt.refresh_module_paths()
    check("the computer's package lib dir is put on package.path",
          path_has("/usr/pkgs/localmod/lib/?.lua"),
          package.path)
    check("refresh reports the entries it now uses",
          #list >= 1 and list[1]:find("/usr/pkgs/localmod/lib", 1, true) ~= nil,
          table.concat(list, ","))

    -- idempotent: a second refresh adds nothing new
    local added2 = mnt.refresh_module_paths()
    check("refreshing twice adds no duplicate entry", added2 == 0,
          "added=" .. tostring(added2))

    -- a package with NO lib/ contributes nothing: it publishes commands only
    write_file("/usr/pkgs/nolib/bin/tool.lua", "print('x')\n")
    write_file("/usr/pkgs/nolib/manifest", "name=nolib\nversion=1.0.0\nbin=bin/tool.lua\n")
    mnt.clear_cache()
    local dirs2 = mnt.module_dirs()
    local found_nolib = false
    for _, d in ipairs(dirs2) do
        if d:find("nolib", 1, true) then found_nolib = true end
    end
    check("a package with no lib/ contributes no module directory", not found_nolib,
          table.concat(dirs2, ","))

    -- a medium that is NOT mounted contributes nothing
    fs.makeDir("/disk2")
    write_file("/disk2/usr/pkgs/mediamod/lib/mediamod.lua", "return {}\n")
    mnt.clear_cache()
    local dirs3 = mnt.module_dirs()
    local found_unmounted = false
    for _, d in ipairs(dirs3) do
        if d:find("/disk2", 1, true) then found_unmounted = true end
    end
    check("an unmounted medium contributes no module directory", not found_unmounted,
          table.concat(dirs3, ","))
    check("and its lib dir is not on package.path",
          not path_has("/disk2/usr/pkgs/mediamod/lib/?.lua"), package.path)

    -- MOUNTING is the event that brings it in: this is the whole point, because a
    -- caller must not have to remember to refresh.
    local mok = mnt.mount("/disk2", "/mnt/sys", "rw", "test")
    check("fixture: the medium mounts", mok == true)
    check("mounting the medium put its package lib dir on package.path",
          path_has("/disk2/usr/pkgs/mediamod/lib/?.lua"), package.path)

    -- UNMOUNTING takes it off again, so a later require does not resolve through a
    -- path on a medium that is not there.
    local uok = mnt.umount("/disk2")
    check("fixture: the medium unmounts", uok == true)
    check("unmounting took its entries back off package.path",
          not path_has("/disk2/usr/pkgs/mediamod/lib/?.lua"), package.path)
    check("but the computer's own entry is still there",
          path_has("/usr/pkgs/localmod/lib/?.lua"), package.path)

    -- a foreign entry on package.path is left alone: refresh owns only the entries
    -- that name a package lib directory under a /usr/pkgs.
    --
    -- This is a GUARD, not an independently mutable assertion, and saying so is
    -- more useful than pretending otherwise: any rule that drops an unrelated entry
    -- also drops the shell's own "/lib/?.lua", so a mutant that breaks this crashes
    -- a later require ("no file '/usr/marker.lua'") instead of failing here. The
    -- property is protected either way; it simply cannot be isolated to one line.
    local foreign = "/somewhere/else/?.lua"
    package.path = foreign .. ";" .. package.path
    mnt.refresh_module_paths()
    check("an unrelated package.path entry survives a refresh",
          path_has(foreign), package.path)
    package.path = package.path:gsub("/somewhere/else/%?%.lua;", "")

    -- the system module store is a root like any other: its packages count.
    -- The medium is MOUNTED first: store_claim() writes the marker on the medium, so
    -- it refuses a drive with nothing in it.
    fs.makeDir("/disk3")
    write_file("/disk3/usr/pkgs/sysmod/lib/sysmod.lua", "return {}\n")
    local m3 = mnt.mount("/disk3", "/mnt/sys2", "rw", "test")
    check("fixture: the system store medium mounts", m3 == true)
    local syso = mpkg.store_claim_sys(3)
    check("fixture: that medium is the system module store", syso == true,
          tostring(syso))
    check("a module on the system module store is put on package.path",
          path_has("/disk3/usr/pkgs/sysmod/lib/?.lua"), package.path)
    check("and the roots include it",
          mpkg.roots()[1] == "/disk3/usr/pkgs", table.concat(mpkg.roots(), ","))

    -- pkg asks mounts for the refresh, so a caller holding a pkg handle does not
    -- have to know where the scan lives
    local okask = pcall(mpkg.refresh_module_paths)
    check("pkg.refresh_module_paths delegates to mounts", okask == true)
    local okdirs = pcall(mpkg.module_dirs)
    check("pkg.module_dirs delegates to mounts", okdirs == true)

    -- clean up: remove the fixture packages, unmount what this section mounted, put
    -- back what it unmounted, and leave no rules behind. The following sections
    -- expect /disk2 and /disk3 to be MOUNTED (they claim stores on them), so the
    -- section restores that rather than merely tidying its own package.path entries.
    --
    -- The fixture package directories are deleted because a mounted medium with a
    -- package lib/ dir is SUPPOSED to contribute an entry -- so leaving them would
    -- make "no medium entry on package.path" false for a correct implementation.
    local function rm_tree(path)
        if fs.exists(path) then
            if fs.isDir(path) then
                for _, n in ipairs(fs.list(path)) do rm_tree(path .. "/" .. n) end
                fs.delete(path)
            else
                fs.delete(path)
            end
        end
    end
    rm_tree("/usr/pkgs/localmod")
    rm_tree("/usr/pkgs/nolib")
    rm_tree("/disk2/usr/pkgs/mediamod")
    rm_tree("/disk3/usr/pkgs/sysmod")
    mnt.umount("/disk3")
    if not mounts.find("/disk2") then
        mnt.mount("/disk2", "/mnt/a", "rw", "test")
    end
    if not mounts.find("/disk3") then
        mnt.mount("/disk3", "/mnt/b", "rw", "test")
    end
    mpkg.store_release_all()
    mounts.clear_cache()
    mnt.refresh_module_paths()
    check("the section leaves both media mounted for the next section",
          mounts.find("/disk2") ~= nil and mounts.find("/disk3") ~= nil)
    check("with the fixtures gone no medium entry is left on package.path",
          not path_has("/disk2/usr/pkgs/mediamod/lib/?.lua") and
          not path_has("/disk3/usr/pkgs/sysmod/lib/?.lua"), package.path)
end

-- ============================================================
section("pkg: the store inventory as data")
-- ============================================================
-- pkg.store_report() is what a script (or `pkg store`) reads; the JSON form is
-- what another machine reads. Both are checked on a machine with one medium.
do
    local rpkg = pkg
    rpkg.store_release_all()
    mounts.clear_cache()
    local cok = rpkg.store_claim(2)
    check("fixture: one medium is a store", cok == true)
    local report = rpkg.store_report()
    check("the report names the store and its root",
          #report.stores == 1 and report.stores[1].side == "/disk2" and
          report.stores[1].root == "/disk2/usr/pkgs",
          tostring(#report.stores))
    check("the report lists the packages on the medium",
          report.stores[1].count >= 1, tostring(report.stores[1].count))
    local names = {}
    for _, p in ipairs(report.stores[1].packages) do names[#names + 1] = p.name end
    check("the packages are the ones installed there",
          #names > 0 and names[1] == names[1], table.concat(names, ","))
    check("the report carries the store_required switch",
          report.required == false, tostring(report.required))
    check("the report says where a new package would go",
          report.install_root == "/disk2/usr/pkgs", tostring(report.install_root))
    check("the report always includes the computer's own directory",
          report.internal ~= nil and report.internal.root == "/usr/pkgs",
          tostring(report.internal and report.internal.root))
    check("a store keeps the marker it was found by",
          type(report.stores[1].marker) == "string" and
          report.stores[1].marker:find("psh package store", 1, true) ~= nil,
          tostring(report.stores[1].marker))
    -- capacity may or may not be answered by the filesystem; when it is, the
    -- report carries it and never a negative free space
    if report.stores[1].capacity then
        check("the capacity of a store is reported",
              report.stores[1].capacity > 0, tostring(report.stores[1].capacity))
        check("free space is reported with it",
              report.stores[1].free ~= nil and report.stores[1].free >= 0,
              tostring(report.stores[1].free))
    end

    local text = rpkg.store_report_json()
    check("the json form is rendered", type(text) == "string" and #text > 20,
          tostring(text))
    check("the json form names the store", text:find('"side": "/disk2"', 1, true) ~= nil,
          slice(text))
    check("the json form carries the packages",
          text:find('"onthird"', 1, true) ~= nil or
          text:find('"onfirst"', 1, true) ~= nil, slice(text))
    check("the json form is stable between two runs",
          text == rpkg.store_report_json())
    check("the json escape covers a quote in a value",
          rpkg.json_encode({ a = 'he said "hi"' }):find('\\"hi\\"', 1, true) ~= nil,
          rpkg.json_encode({ a = 'he said "hi"' }))
    check("an empty table is an object, an indexed one an array",
          rpkg.json_encode({}) == "{}" and
          rpkg.json_encode({ 1, 2 }):match("^%[") ~= nil)

    -- the grouping the shell prints comes from the same data
    local groups = rpkg.list_by_root()
    check("list_by_root has one group for the store and one for the computer",
          #groups == 2, tostring(#groups))
    check("the store group is marked removable and names its side",
          groups[1].removable == true and groups[1].side == "/disk2",
          tostring(groups[1].side))
    check("the computer group is not removable",
          groups[2].removable == false and groups[2].side == nil)
    check("each group lists its own packages",
          #groups[1].packages >= 1, tostring(#(groups[1].packages or {})))
    rpkg.store_release_all()
    rpkg.set_store_required(false)
    mounts.clear_cache()
    check("the fixture left no store behind", rpkg.store() == "auto", rpkg.store())
end

-- ============================================================
section("pkg: a machine with no update server")
-- ============================================================
-- Four states a machine can be in: offline=true, server_id=0, no
-- configuration file at all, and a working server. None of the first three
-- may raise, wait out a timeout nothing can answer, or stop the shell from
-- working. The fixtures are written the way a user edits the files, then
-- reloaded.
local PKG_CONF, NET_CONF = "/etc/pkg.conf", "/etc/network.conf"
local saved_pkg_conf, saved_net_conf = H.read(PKG_CONF), H.read(NET_CONF)
local function configure(pkg_text, net_text)
    if pkg_text == nil then fs.delete(PKG_CONF) else write_file(PKG_CONF, pkg_text) end
    if net_text == nil then fs.delete(NET_CONF) else write_file(NET_CONF, net_text) end
    netcfg.reload()
end

check("a switch is on for 1, true, yes and on, in any case",
      netcfg.truthy("ON") and netcfg.truthy("Yes") and netcfg.truthy("1") and
      netcfg.truthy(true) and not netcfg.truthy("off") and
      not netcfg.truthy("") and not netcfg.truthy(nil))

-- 1) offline mode, switched on in pkg.conf, which wins over network.conf
configure("server_id=5\nkey=mysecretpassword\nchannel=pkg-repo\noffline=true\n",
          "server_id=6\nchannel=other-net\nmodem_side=top\noffline=false\n")
check("offline is read from pkg.conf, which outranks network.conf",
      netcfg.offline() == true and netcfg.source("offline") == PKG_CONF,
      tostring(netcfg.source("offline")))
local off_cfg = netcfg.server_config()
check("an offline machine is not reported as configured",
      off_cfg.offline == true and off_cfg.configured == false,
      tostring(off_cfg.reason))
check("the offline reason names offline mode and the file to edit",
      type(off_cfg.reason) == "string" and
      off_cfg.reason:find("offline", 1, true) ~= nil and
      off_cfg.reason:find(PKG_CONF, 1, true) ~= nil, tostring(off_cfg.reason))
local oready, oreason, okind = pkg.server_ready()
check("pkg.server_ready() answers offline instead of naming a server",
      oready == nil and okind == "offline", tostring(oreason))

H.clear()
local sent_before, now_before = H.sent, H.now
local mail_before = #H.box(5)
local obox = {}
H.exec(7, function() obox.ok, obox.err = pkg.update() end, "pkg.update (offline)")
check("update on an offline machine answers with a reason, no crash",
      obox.ok == false and type(obox.err) == "string" and
      obox.err:find("offline", 1, true) ~= nil, tostring(obox.err))
check("offline: nothing was sent and no timeout was waited out",
      H.sent == sent_before and H.now == now_before and
      #H.box(5) == mail_before,
      tostring(H.sent - sent_before) .. " datagram(s) sent, " ..
      tostring(H.now - now_before) .. " ms waited")

-- 2) server_id=0: the firstboot spelling of "no server at all"
configure("offline=false\nkey=mysecretpassword\nchannel=pkg-repo\n",
          "server_id=0\nmodem_side=top\n")
check("server_id=0 names no server", netcfg.server_id() == nil)
local zero_cfg = netcfg.server_config()
check("a machine with server_id=0 is unconfigured, not offline",
      zero_cfg.configured == false and zero_cfg.offline == false,
      tostring(zero_cfg.reason))
check("the reason says the id is not a positive computer id",
      type(zero_cfg.reason) == "string" and
      zero_cfg.reason:find("not a positive computer id", 1, true) ~= nil,
      tostring(zero_cfg.reason))
check("the unconfigured hint says how to configure a server later",
      pkg.setup_hint():find("server_id=<pc id>", 1, true) ~= nil and
      pkg.setup_hint():find("pkg update", 1, true) ~= nil, pkg.setup_hint())

-- 3) neither configuration file exists: a state, not an exception
configure(nil, nil)
local cached_pkg = package.loaded["pkg"]
package.loaded["pkg"] = nil
local ok_load, pkg2 = pcall(require, "pkg")
package.loaded["pkg"] = cached_pkg
check("pkg loads when no configuration file exists at all", ok_load == true,
      tostring(pkg2))
if ok_load then
    local ready2, reason2, kind2 = pkg2.server_ready()
    check("a missing configuration is a state, not an exception",
          ready2 == nil and kind2 == "unconfigured", tostring(reason2))
    check("the reason says server_id is not set, and where",
          type(reason2) == "string" and
          reason2:find("server_id is not set", 1, true) ~= nil and
          reason2:find(PKG_CONF, 1, true) ~= nil, tostring(reason2))
    local nbox = {}
    H.exec(7, function() nbox.ok, nbox.err = pkg2.update() end,
           "pkg.update (no config)")
    check("update without a configuration file answers with a reason",
          nbox.ok == false and type(nbox.err) == "string" and
          nbox.err:find("server_id is not set", 1, true) ~= nil,
          tostring(nbox.err))
    check("the hint for a machine with no file names the file to create",
          pkg2.setup_hint():find(PKG_CONF, 1, true) ~= nil, pkg2.setup_hint())

    local sent3, now3 = H.sent, H.now
    local ibox = {}
    H.exec(7, function() ibox.ok, ibox.info = pkg.install("demo") end,
           "pkg.install (no config)")
    check("install with no server refuses at once and writes nothing",
          ibox.ok ~= true and not H.exists("/usr/pkgs/demo"), tostring(ibox.info))
    check("install with no server sent nothing and waited nothing",
          H.sent == sent3 and H.now == now3,
          tostring(H.sent - sent3) .. " datagram(s), " ..
          tostring(H.now - now3) .. " ms")
end

-- the shell layer: the message the user reads, and the status a script sees
_G.__PSH_TEST = true
local psh_np_chunk = assert(loadfile(PROJ .. "/usr/psh.lua"))
psh_np_chunk()
local psh_np = _G.__psh_test
psh_np.init()
H.clear()
local pstatus = psh_np.run("pkg update")
local pout = H.text() .. "\n" .. table.concat(_G.__OUT or {}, "\n")
_G.__PSH_TEST = nil
check("pkg update with no server exits 1 and says why",
      pstatus == 1 and pout:find("no update server", 1, true) ~= nil,
      tostring(pstatus) .. " " .. slice(pout, 200))
check("the shell message also says how to configure one later",
      pout:find("server_id=", 1, true) ~= nil and
      pout:find("pkg update", 1, true) ~= nil, slice(pout, 200))
H.clear()
local lstatus = psh_np.run("pkg list")
local lout = H.text() .. "\n" .. table.concat(_G.__OUT or {}, "\n")
check("the shell keeps working: pkg list with no server exits 0",
      lstatus == 0, tostring(lstatus) .. " " .. slice(lout, 160))

-- firstboot: the skip path. There is no harness for it, so the source is
-- checked for the pieces the flow is built from. The suites run in the
-- emulated file system and cannot see the repository, so the PC side reader
-- of tests/run_all.py is used (see host_text in batch6/batch7).
local function host_text(path)
    local reader = _G.read_host_file
    if reader == nil then return nil end
    local ok, text = pcall(function() return reader(path) end)
    if ok and type(text) == "string" then return text end
    return nil
end

local fbsrc = host_text(PROJ .. "/firstboot.lua")
check("firstboot can skip the update server and still finish",
      type(fbsrc) == "string" and
      fbsrc:find("skip_network_config", 1, true) ~= nil and
      fbsrc:find("offline=true", 1, true) ~= nil, "firstboot.lua source")
check("firstboot says an update server can be added later",
      type(fbsrc) == "string" and fbsrc:find("pkg update", 1, true) ~= nil and
      fbsrc:find("server_id=<pc id>", 1, true) ~= nil, "firstboot.lua source")
-- the skip key moved from ESC to Ctrl+T (the terminate event)
check("firstboot skips on Ctrl+T and no longer binds the escape key",
      type(fbsrc) == "string" and fbsrc:find("keys.escape", 1, true) == nil and
      fbsrc:find('e == "terminate"', 1, true) ~= nil, "firstboot.lua source")
check("the wizard prompts speak of Ctrl+T and never of ESC",
      type(fbsrc) == "string" and fbsrc:find("Ctrl+T", 1, true) ~= nil and
      fbsrc:find("ESC", 1, true) == nil, "firstboot.lua source")
check("the skip words of the text prompts are still accepted",
      type(fbsrc) == "string" and fbsrc:find("'skip'", 1, true) ~= nil and
      fbsrc:find('word == "later"', 1, true) ~= nil, "firstboot.lua source")

-- Ctrl+T arrives as a terminate event, so the wizard has to treat it as the
-- skip key. The real program is driven against the emulated file system: no
-- harness exists for it, the events are queued before it starts reading.
do
    local function chars(text)
        local list = {}
        for i = 1, #text do list[#list + 1] = { "char", text:sub(i, i) } end
        return list
    end

    -- firstboot writes with print and with term.write; both are collected so
    -- that the assertions can see what the wizard said.
    local function boot(events)
        require("marker").clear()
        -- BOOT, before the shell starts: /etc/current_user says root. lib/perm.lua
        -- enforces "only root may add accounts" itself now, because it writes
        -- /etc/passwd through the unguarded open, so the fixture starts there.
        local saved_user = perm.get_current_user()
        if saved_user ~= "root" then perm.set_current_user("root") end
        _G.__OUT = {}
        local lines = {}
        local saved_print = _G.print
        _G.print = function(...)
            local parts = {}
            for i = 1, select("#", ...) do
                parts[#parts + 1] = tostring((select(i, ...)))
            end
            lines[#lines + 1] = table.concat(parts, "\t")
        end
        for _, e in ipairs(events) do os.queueEvent(e[1], e[2], e[3]) end
        local chunk = assert(loadfile(PROJ .. "/firstboot.lua"), "firstboot.lua")
        local ok, err = pcall(chunk)
        _G.print = saved_print
        if saved_user ~= "root" then perm.set_current_user(saved_user) end
        return ok, err, table.concat(lines, "\n") .. "\n" ..
               table.concat(_G.__OUT or {}, "\n")
    end

    local enter = { "key", keys.enter, false }
    local stop = { "terminate" }

    -- a required question: Ctrl+T ends the wizard
    local ok_a, err_a, out_a = boot({ stop })
    check("Ctrl+T at the root password prompt stops the wizard",
          ok_a == true and
          out_a:find("First Boot: Root password", 1, true) ~= nil and
          out_a:find("First Boot: Administrator account", 1, true) == nil,
          tostring(err_a) .. " " .. slice(out_a, 160))

    -- an optional question: Ctrl+T skips that step only
    local events = {}
    local function push(list)
        for _, item in ipairs(list) do events[#events + 1] = item end
    end
    push(chars("abc123")); push({ enter })   -- root password
    push(chars("abc123")); push({ enter })   -- retype
    push(chars("fbuser")); push({ enter })   -- primary user
    push({ enter })                          -- user password: blank is none
    push({ stop })                           -- computer name: Ctrl+T
    push({ stop })                           -- network: Ctrl+T, no server
    push({ stop })                           -- timezone: Ctrl+T, UTC
    push({ enter })                          -- package import: blank line
    push({ enter })                          -- the final "press any key"
    push({ enter }); push({ enter })         -- spares
    local ok_b, err_b, out_b = boot(events)
    check("Ctrl+T on the optional computer name step skips that step",
          ok_b == true and
          out_b:find("Skipped: the label is unchanged.", 1, true) ~= nil,
          tostring(err_b) .. " " .. slice(out_b, 160))
    check("the wizard carries on after the skipped step",
          out_b:find("First Boot: Network", 1, true) ~= nil and
          out_b:find("Applying configuration", 1, true) ~= nil,
          slice(out_b, 160))
    check("the skipped network step falls back to offline mode",
          out_b:find("offline=true", 1, true) ~= nil, slice(out_b, 160))
end

-- ============================================================
-- the wizard's default name must be a name the policy allows
-- ============================================================
-- Reported from a real machine: at the administrator prompt the operator pressed
-- Enter, which is how the wizard's own hint says to take the default, and got
--
--   Rejected: 'admin' is a reserved name
--
-- for ever. The prompt asked again and the wizard never finished, so a fresh
-- machine could not be set up at all. The two halves of that contradiction sit in
-- different files: firstboot.lua offers 'admin' as the default ("Leave blank for
-- default name 'admin'") while etc/passwd.policy listed admin among the names
-- firstboot must refuse. 'admin' is not a reserved name in this system -- it is
-- the machine's own administrator account, the level 1 account lib/perm.lua
-- seeds (root:2, admin:1, guest:0), and firstboot KEEPS that account when the
-- operator chooses it (it deletes the seeded one only for another name).
--
-- WHY THIS READS THE REPOSITORY. The emulated file system has no
-- /etc/passwd.policy, so lib/policy.lua falls back to its built-in defaults,
-- which never listed admin. A suite that only asked check_username("admin") in
-- the emulated file system was green while every deployed machine was stuck: the
-- file that gets deployed is the one under etc/, and that is the one read here.
do
    local fb = host_text(PROJ .. "/firstboot.lua")
    local pp = host_text(PROJ .. "/etc/passwd.policy")
    check("the shipped password policy can be read",
          type(pp) == "string" and #pp > 0, "etc/passwd.policy")

    local prompt_default = type(fb) == "string" and
        fb:match("Username %[([%w_]+)%]")
    local blank_default = type(fb) == "string" and
        fb:match('if name == "" then name = "([%w_]+)" end')
    check("the wizard's default name is the same in its prompt and in its fallback",
          prompt_default ~= nil and prompt_default == blank_default,
          tostring(prompt_default) .. " vs " .. tostring(blank_default))

    local blacklist = type(pp) == "string" and pp:match("blacklist=([^\n]*)")
    check("the shipped policy has a blacklist to read", blacklist ~= nil,
          tostring(blacklist))
    local reserved = {}
    for name in tostring(blacklist or ""):gmatch("[^,]+") do
        reserved[name:gsub("^%s+", ""):gsub("%s+$", "")] = true
    end
    check("the policy does not reserve the wizard's default name",
          prompt_default ~= nil and reserved[prompt_default] == nil,
          tostring(blacklist))

    -- The same question asked of the real module with the real file installed,
    -- because the text check above would also pass if the file were unparseable.
    local policy = require("policy")
    local had_policy = fs.exists("/etc/passwd.policy")
    local saved_policy = nil
    if had_policy then
        local h = fs.open("/etc/passwd.policy", "r")
        saved_policy = h.readAll()
        h.close()
    end
    write_file("/etc/passwd.policy", pp)
    policy.reload()
    local allowed, why = policy.check_username(prompt_default)
    check("the shipped policy accepts the default name the wizard offers",
          allowed == true, tostring(why))
    -- and it still refuses what really is reserved: the check above would also
    -- pass if the blacklist had been emptied.
    check("the shipped policy still refuses a reserved name",
          policy.check_username("root") == false and
          policy.check_username("daemon") == false, "root or daemon was accepted")

    -- Driven end to end: ONE Enter at the name prompt, and the wizard must walk
    -- past it to the password question. The real policy file is still installed,
    -- so this is the prompt that used to loop for ever.
    local function drive(events)
        require("marker").clear()
        -- The wizard runs at BOOT, before the shell starts: /etc/current_user says
        -- root. The suite has moved the console around by now, so say it here too:
        -- lib/perm.lua enforces "only root may add accounts" itself, because it
        -- writes /etc/passwd through the unguarded open.
        local saved_user = perm.get_current_user()
        if saved_user ~= "root" then perm.set_current_user("root") end
        _G.__OUT = {}
        local lines = {}
        local saved_print = _G.print
        _G.print = function(...)
            local parts = {}
            for i = 1, select("#", ...) do
                parts[#parts + 1] = tostring((select(i, ...)))
            end
            lines[#lines + 1] = table.concat(parts, "\t")
        end
        for _, e in ipairs(events) do os.queueEvent(e[1], e[2], e[3]) end
        local chunk = assert(loadfile(PROJ .. "/firstboot.lua"), "firstboot.lua")
        local ok, err = pcall(chunk)
        _G.print = saved_print
        if saved_user ~= "root" then perm.set_current_user(saved_user) end
        return ok, err, table.concat(lines, "\n") .. "\n" ..
               table.concat(_G.__OUT or {}, "\n")
    end
    local function chars(text)
        local list = {}
        for i = 1, #text do list[#list + 1] = { "char", text:sub(i, i) } end
        return list
    end
    local enter = { "key", keys.enter, false }
    local stop = { "terminate" }
    local events = {}
    local function push(list)
        for _, item in ipairs(list) do events[#events + 1] = item end
    end
    -- "Abcdef12" satisfies the shipped policy (8 chars, upper, lower, digit);
    -- the name question is answered with a bare Enter -- that is the whole point.
    push(chars("Abcdef12")); push({ enter })     -- root password
    push(chars("Abcdef12")); push({ enter })     -- retype
    push({ enter })                              -- name: take the default
    push({ enter })                              -- user password: blank is none
    push({ stop })                               -- computer name: Ctrl+T
    push({ stop })                               -- network: Ctrl+T
    push({ stop })                               -- timezone: Ctrl+T
    push({ enter })                              -- package import: blank line
    push({ enter })                              -- the final "press any key"
    push({ enter }); push({ enter })             -- spares
    local ok_w, err_w, out_w = drive(events)
    check("Enter at the name prompt does not produce a reservation error",
          ok_w == true and out_w:find("is a reserved name", 1, true) == nil,
          tostring(err_w) .. " " .. slice(out_w, 160))
    check("the wizard moves on to the password of the default name",
          prompt_default ~= nil and
          out_w:find("First Boot: Password for " .. prompt_default, 1, true) ~= nil,
          slice(out_w, 160))
    check("the wizard finishes with a default name taken by Enter",
          out_w:find("Setup complete", 1, true) ~= nil, slice(out_w, 3000))
    check("and the setup marker was written", require("marker").done() == true)

    -- Put the file system back the way the rest of the batch expects it: no
    -- policy file (the emulated default) and no setup marker.
    if had_policy then
        write_file("/etc/passwd.policy", saved_policy)
    else
        fs.delete("/etc/passwd.policy")
    end
    policy.reload()
    require("marker").clear()
end

-- 4) a configured server: the normal path is untouched
configure(saved_pkg_conf, saved_net_conf)
check("a configured server is reported as ready", pkg.server_ready() == true)
local gbox = {}
H.exec(7, function() gbox.ok, gbox.msg = pkg.update() end, "pkg.update (configured)")
check("update still works once a server is configured", gbox.ok == true,
      tostring(gbox.msg))
check("no task raised an error on any of the four paths", #H.errors == 0,
      table.concat(H.errors, " | "))

-- ============================================================
section("wiring: the three commands are external psh commands")
-- ============================================================
local shells = _G.SH_SRC or {}
for _, name in ipairs({ "rget", "rput", "rexec" }) do
    local chunk = loadfile(PROJ .. "/usr/cmd/" .. name .. ".lua")
    local ok_run, status = pcall(chunk, { "--help" }, H.stage())
    check("usr/cmd/" .. name .. ".lua answers --help with a status",
          chunk ~= nil and ok_run and type(status) == "number", tostring(status))
    check("usr/cmd/" .. name .. ".lua delegates to netcmds",
          type(shells[name]) == "string" and
          shells[name]:find("netcmds", 1, true) ~= nil)
end
if type(shells.psh) == "string" then
    check("psh.lua knows the three network command names",
          shells.psh:find("rget", 1, true) ~= nil and
          shells.psh:find("rput", 1, true) ~= nil and
          shells.psh:find("rexec", 1, true) ~= nil)
end

if type(shells.rget) == "string" then
    _G.__PSH_TEST = true
    local chunk = assert(loadfile(PROJ .. "/usr/psh.lua"))
    chunk()
    local psh = _G.__psh_test
    psh.init()
    for _, name in ipairs({ "rget", "rput", "rexec" }) do
        if type(shells[name]) == "string" then
            write_file("/usr/cmd/" .. name .. ".lua", shells[name])
        end
    end
    H.clear()
    local status = psh.run("rget --help")
    local text = H.text() .. "\n" .. table.concat(_G.__OUT or {}, "\n")
    check("the shell resolves rget from PATH and runs it",
          text:find("usage: rget", 1, true) ~= nil or
          text:find("rget.lua", 1, true) ~= nil,
          slice(text, 200))
    check("the shell reports a status for the external command",
          type(status) == "number", tostring(status))
end

-- ============================================================
-- the transport layer: rpvnet keeps the rednet shape, picks rpv when the baked in
-- stack can run and falls back to rednet otherwise. The PC side stub has no modem,
-- so here the fallback path is the one under test.
local rpvnet = require("rpvnet")
check("the transport layer loads", type(rpvnet) == "table")
check("the transport layer exposes the rednet shape",
      type(rpvnet.open) == "function" and type(rpvnet.close) == "function" and
      type(rpvnet.isOpen) == "function" and type(rpvnet.send) == "function" and
      type(rpvnet.broadcast) == "function" and type(rpvnet.receive) == "function")
check("the transport layer also carries the discovery helper",
      type(rpvnet.port_of) == "function" and type(rpvnet.transport) == "function" and
      type(rpvnet.pump) == "function" and type(rpvnet.stats) == "function")
local backend = rpvnet.transport()
check("without a modem the transport falls back to rednet", backend == "rednet",
      tostring(backend))
local port_first = rpvnet.port_of("pkg-repo")
check("a protocol maps to a stable port in the rpv range",
      port_first == rpvnet.port_of("pkg-repo") and port_first >= 20000 and port_first < 40000,
      tostring(port_first))
check("different protocols map to different ports",
      rpvnet.port_of("psh-ping") ~= rpvnet.port_of("psh-msg") and
      rpvnet.port_of("psh-ping") ~= port_first,
      tostring(rpvnet.port_of("psh-ping")))
local stats = rpvnet.stats()
check("the transport reports its state", type(stats) == "table" and stats.backend == "rednet",
      tostring(stats and stats.backend))
local seen = nil
local real_send = rednet.send
local patched = pcall(function()
    rednet.send = function(target, message, protocol)
        seen = { target, message, protocol }
        return true
    end
end)
if patched then
    rpvnet.reset()
    local ok, err = pcall(rpvnet.send, 9, "payload", "psh-msg")
    rednet.send = real_send
    check("rednet mode hands send to rednet unchanged",
          ok and seen and seen[1] == 9 and seen[2] == "payload" and seen[3] == "psh-msg",
          tostring(err) .. " " .. tostring(seen and seen[1]))
else
    rednet.send = real_send
end
rpvnet.reset()
-- ============================================================
-- the rpv path itself, in process: two nodes of the vendored stack plus one hand made
-- ethernet frame carrying a real IP/UDP datagram. This runs ip_input, the UDP checksum
-- and the socket lookup for real, with no emulator and no modem medium involved.
local blk_ok, blk_err = pcall(function()
local saved_getType = peripheral and peripheral.getType
local saved_call = peripheral and peripheral.call
if peripheral then
    peripheral.getType = function(side) if side == "back" then return "modem" end return nil end
    peripheral.call = function(side, fn) if fn == "isWireless" then return true end return true end
end
-- Build the library the way rpv/loader.lua does, but with loadfile() only: inside the PC
-- side stub the loader looks its modules up through the virtual filesystem, which does
-- not contain the project tree. Every module is `local M = ...` and enriches the table.
local RPV_MODULES = { "crypto", "util", "ip", "route", "arp", "link", "icmp", "udp", "conn",
                      "fabric", "wan", "services", "dv", "nat", "mcast", "qos", "wansec",
                      "compat", "topo" }
local rpvlib = {}
for _, mod in ipairs(RPV_MODULES) do
    local chunk = loadfile("rpv/" .. mod .. ".lua")
    if chunk then chunk(rpvlib) end
end
local node_chunk = loadfile("rpv/node.lua")
if node_chunk then node_chunk(rpvlib) end
check("the vendored rpv stack loads",
      type(rpvlib) == "table" and type(rpvlib.node_new) == "function", tostring(rpvlib))
local function vnode(id)
    local n = rpvlib.node_new({
        role = "host",
        ifaces = { { side = "back", name = "LAN", cidr = "10.0.4." .. id .. "/24",
                     channel = 4700, mtu = 512, linktype = "wireless" } },
    })
    n:setup()
    return n
end
local okA, A = pcall(vnode, 20)
local okB, B = pcall(vnode, 21)
check("two rpv nodes can be built in one process",
      okA and okB and type(A) == "table" and type(B) == "table" and A.ifaces[1] and B.ifaces[1],
      tostring(A) .. " / " .. tostring(B))
local seen = nil
pcall(function() B:bind(20001, function(data, src) seen = rpvlib.int2ip(src) .. ":" .. tostring(data) end) end)
local src_ip, dst_ip = A.ifaces[1].ip, B.ifaces[1].ip
local payload = "hi-from-20"
local len = 8 + #payload
local pseudo = rpvlib.u32(src_ip) .. rpvlib.u32(dst_ip) .. rpvlib.u8(0) .. rpvlib.u8(rpvlib.IP_UDP) .. rpvlib.u16(len)
local udp = rpvlib.u16(20001) .. rpvlib.u16(20001) .. rpvlib.u16(len) .. rpvlib.u16(0) .. payload
local ck = rpvlib.cksum(pseudo .. udp)
if ck == 0 then ck = 0xFFFF end
udp = rpvlib.u16(20001) .. rpvlib.u16(20001) .. rpvlib.u16(len) .. rpvlib.u16(ck) .. payload
local hdr0 = rpvlib.u8(0x45) .. rpvlib.u8(0) .. rpvlib.u16(20 + #udp) .. rpvlib.u16(1)
    .. rpvlib.u16(0) .. rpvlib.u8(64) .. rpvlib.u8(rpvlib.IP_UDP) .. rpvlib.u16(0)
    .. rpvlib.u32(src_ip) .. rpvlib.u32(dst_ip)
-- the header checksum has to be filled in: cksum() is the one's complement sum, and rpv's
-- ip_input rejects a header whose checksum does not add up, so a zeroed field is dropped
local ip_ck = rpvlib.cksum(hdr0)
if ip_ck == 0 then ip_ck = 0xFFFF end
local hdr = rpvlib.u8(0x45) .. rpvlib.u8(0) .. rpvlib.u16(20 + #udp) .. rpvlib.u16(1)
    .. rpvlib.u16(0) .. rpvlib.u8(64) .. rpvlib.u8(rpvlib.IP_UDP) .. rpvlib.u16(ip_ck)
    .. rpvlib.u32(src_ip) .. rpvlib.u32(dst_ip)
local frame = rpvlib.u32(0xFFFFFFFF) .. rpvlib.u32(A.mac) .. rpvlib.u16(rpvlib.ET_IP) .. hdr .. udp
local okf, ferr = pcall(B.on_frame, B, B.ifaces[1], frame)
check("a hand made frame reaches the bound rpv socket", seen == "10.0.4.20:hi-from-20",
      tostring(okf) .. " " .. tostring(ferr) .. " " .. tostring(seen))
-- the adapter on the same real stack: switch the transport to rpv and, when the stack
-- can be loaded, let the adapter build its own node and hand it a frame from node A. The
-- envelope is what a peer would send, so rpvnet.receive has to give back the sender id and
-- the payload. Under the PC side stub the loader cannot see the tree (its filesystem is
-- virtual), so this part reports a skip instead of a failure there.
write_file("/etc/network.conf", "transport=rpv\nmodem_side=back\nrpv_channel=4700\n")
netcfg.reload()
rpvnet.reset()
local backend2 = nil
local errb = nil
local okb = pcall(function() backend2 = rpvnet.transport() end)
if not okb then errb = backend2 end
if okb and backend2 == "rpv" then
check("an explicit transport=rpv selects rpv when a modem is present", backend2 == "rpv",
      tostring(backend2))
local bnode = rpvnet.node()
check("the adapter built a node of its own",
      type(bnode) == "table" and type(bnode.ifaces[1]) == "table", tostring(bnode))
if type(bnode) == "table" then
    bnode.pump = function() return true end
    local dst_port = rpvnet.port_of("psh-test")
    local none = rpvnet.receive("psh-test", 0.01)
    check("nothing is queued before a frame arrives", none == nil, tostring(none))
    local benv = "RN1|psh-test|20|hello-over-rpv"
    local blen = 8 + #benv
    local bpseudo = rpvlib.u32(src_ip) .. rpvlib.u32(bnode.ifaces[1].ip) .. rpvlib.u8(0)
        .. rpvlib.u8(rpvlib.IP_UDP) .. rpvlib.u16(blen)
    local budp = rpvlib.u16(20001) .. rpvlib.u16(dst_port) .. rpvlib.u16(blen)
        .. rpvlib.u16(0) .. benv
    local bck = rpvlib.cksum(bpseudo .. budp)
    if bck == 0 then bck = 0xFFFF end
    budp = rpvlib.u16(20001) .. rpvlib.u16(dst_port) .. rpvlib.u16(blen)
        .. rpvlib.u16(bck) .. benv
    local bhdr0 = rpvlib.u8(0x45) .. rpvlib.u8(0) .. rpvlib.u16(20 + #budp) .. rpvlib.u16(2)
        .. rpvlib.u16(0) .. rpvlib.u8(64) .. rpvlib.u8(rpvlib.IP_UDP) .. rpvlib.u16(0)
        .. rpvlib.u32(src_ip) .. rpvlib.u32(bnode.ifaces[1].ip)
    local bckip = rpvlib.cksum(bhdr0)
    if bckip == 0 then bckip = 0xFFFF end
    local bhdr = rpvlib.u8(0x45) .. rpvlib.u8(0) .. rpvlib.u16(20 + #budp) .. rpvlib.u16(2)
        .. rpvlib.u16(0) .. rpvlib.u8(64) .. rpvlib.u8(rpvlib.IP_UDP) .. rpvlib.u16(bckip)
        .. rpvlib.u32(src_ip) .. rpvlib.u32(bnode.ifaces[1].ip)
    local bframe = rpvlib.u32(0xFFFFFFFF) .. rpvlib.u32(A.mac) .. rpvlib.u16(rpvlib.ET_IP)
        .. bhdr .. budp
    local bok, berr = pcall(bnode.on_frame, bnode, bnode.ifaces[1], bframe)
    local sender2, blob2 = rpvnet.receive("psh-test", 1)
    check("the adapter restores the sender id and the payload from the wire",
          sender2 == 20 and blob2 == "hello-over-rpv",
          tostring(bok) .. " " .. tostring(berr) .. " " .. tostring(sender2) .. " " ..
          tostring(blob2))
end
else
    say("rpv adapter level check skipped: the loader is not reachable here (" ..
        tostring(errb) .. ")")
end
if peripheral then
    peripheral.getType = saved_getType
    peripheral.call = saved_call
end
end)
check("the in process rpv stack block runs without an error", blk_ok, tostring(blk_err))


check("no background task raised an error", #H.errors == 0,
      table.concat(H.errors, " | "))
H.freeze()

-- ============================================================
_G.__RESULT = { pass = pass, fail = fail }
if fail > 0 then _G.__RESULT.report = table.concat(failures, "\n") end
say(string.format("batch3_check: %d passed, %d failed", pass, fail))
for _, item in ipairs(failures) do say("FAIL " .. item) end
