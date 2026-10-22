--[[- dcnet bootstrap — 让一台新电脑从主控拉取 worker.lua 并立刻开工

这是唯一需要"弄到新机器上"的小脚本（约 60 行），之后所有代码都由主控
通过有线网络分发，不必再插软盘。

用法（在全新电脑的 shell 里）：
    bootstrap.lua            自动广播寻找主控
    bootstrap.lua <主控ID>    直接指定主控

也可以直接把本文件贴进 CC 的终端（Ctrl+V）后回车运行。
]]

local PROTO_CTRL = "dccomp"
local PROTO_PUSH = "dcpush"
local DEST = "/dccomp/worker.lua"

-- ── 1. 找调制解调器并打开 rednet ────────────────────────────────────────
local modemName, wireless
for _, n in ipairs(peripheral.getNames()) do
    if peripheral.getType(n) == "modem" then
        local w = true
        local ok, dev = pcall(peripheral.wrap, n)
        if ok and dev and dev.isWireless then
            local ok2, v = pcall(dev.isWireless, dev)
            if ok2 then w = v and true or false end
        end
        if not w then
            modemName, wireless = n, false
            break
        end
        if not modemName then modemName, wireless = n, w end
    end
end
if not modemName then
    printError("no modem found: connect the network cable to a wired modem.")
    return
end
rednet.open(modemName)
print(string.format("[bootstrap] using %s (%s), computer ID #%d",
    modemName, wireless and "wireless" or "wired", os.getComputerID()))

-- ── 2. 找主控 ───────────────────────────────────────────────────────────
local target = tonumber(({...})[1])
if not target then
    for _ = 1, 5 do
        rednet.broadcast({ t = "who", ver = 1 }, PROTO_CTRL)
        local sender, msg = rednet.receive(PROTO_CTRL, 1.5)
        if type(msg) == "table" and msg.t == "iam" then
            target = tonumber(msg.master) or sender
            break
        end
    end
end
if not target then
    printError("no master found: make sure master.lua is running on the same wired network.")
    return
end
print("[bootstrap] found master #" .. target)

-- ── 3. 拉取 worker.lua ──────────────────────────────────────────────────
math.randomseed(os.getComputerID() * 7919 + (os.epoch and os.epoch("utc") or 0) % 100000)
local xid = string.format("boot-%d-%d", os.getComputerID(), math.random(10000, 99999))
rednet.send(target, { t = "fetch", ver = 1, xid = xid, what = "worker" }, PROTO_PUSH)
print("[bootstrap] receiving worker.lua ...")

local parts, want = {}, nil
local deadline = os.clock() + 40
while os.clock() < deadline do
    local sender, msg = rednet.receive(PROTO_PUSH, 2)
    if type(msg) == "table" and msg.xid == xid then
        if msg.t == "put" then
            parts[msg.i] = msg.d
            want = tonumber(msg.n) or want
            rednet.send(sender, { t = "putack", ver = 1, xid = xid, i = msg.i }, PROTO_PUSH)

        elseif msg.t == "putdone" then
            want = tonumber(msg.n) or want
            local miss = {}
            for i = 1, (want or 0) do
                if not parts[i] then miss[#miss + 1] = i end
            end
            if #miss == 0 then
                local buf = {}
                for i = 1, want do buf[i] = parts[i] end
                local data = table.concat(buf)
                if not fs.exists("/dccomp") then fs.makeDir("/dccomp") end
                local f = fs.open(DEST, "w")
                f.write(data)
                f.close()
                rednet.send(sender, { t = "putok", ver = 1, xid = xid }, PROTO_PUSH)
                print(string.format("[bootstrap] wrote %s (%d bytes), starting worker...", DEST, #data))
                shell.run(DEST)
                return

            else
                print(string.format("[bootstrap] missing %d chunks, requesting retransmit", #miss))
                rednet.send(sender, { t = "putmiss", ver = 1, xid = xid, miss = miss }, PROTO_PUSH)
            end

        elseif msg.t == "referr" then
            printError("[bootstrap] master cannot distribute code: " .. tostring(msg.err))
            return
        end
    end
end
printError("[bootstrap] fetch timeout. Copy dist/worker.lua to " .. DEST .. " using a floppy.")
