local PROTO_CTRL = "dccomp"
local PROTO_PUSH = "dcpush"
local DEST = "/dccomp/worker.lua"

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
    printError("没有找到调制解调器：请在有线调制解调器上接好网络线缆。")
    return
end
rednet.open(modemName)
print(string.format("[bootstrap] 使用 %s（%s），本机 ID #%d",
    modemName, wireless and "无线" or "有线", os.getComputerID()))

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
    printError("没有找到主控：请确认主控已在同一条有线网络上运行（master.lua）。")
    return
end
print("[bootstrap] 找到主控 #" .. target)

math.randomseed(os.getComputerID() * 7919 + (os.epoch and os.epoch("utc") or 0) % 100000)
local xid = string.format("boot-%d-%d", os.getComputerID(), math.random(10000, 99999))
rednet.send(target, { t = "fetch", ver = 1, xid = xid, what = "worker" }, PROTO_PUSH)
print("[bootstrap] 正在接收 worker.lua …")

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
                print(string.format("[bootstrap] 已写入 %s（%d 字节），启动节点…", DEST, #data))
                shell.run(DEST)
                return

            else
                print(string.format("[bootstrap] 缺 %d 块，请求重传", #miss))
                rednet.send(sender, { t = "putmiss", ver = 1, xid = xid, miss = miss }, PROTO_PUSH)
            end

        elseif msg.t == "referr" then
            printError("[bootstrap] 主控无法分发代码：" .. tostring(msg.err))
            return
        end
    end
end
printError("[bootstrap] 拉取超时。可以先用软盘把 dist/worker.lua 拷到 " .. DEST)
