-- 多实例探测 B：连到服务端 + 等广播并回一条
print("MULTI B id=" .. tostring(os.getComputerID()))
print("MULTI B periph=" .. table.concat(peripheral.getNames(), ","))
local side
for _, name in ipairs(peripheral.getNames()) do
    local ty = peripheral.getType(name)
    if ty == "modem" then side = name end
    if type(ty) == "table" then
        for _, t in ipairs(ty) do if t == "modem" then side = name end end
    end
end
print("MULTI B modem=" .. tostring(side))
if side then
    local ok, err = pcall(rednet.open, side)
    print("MULTI B open=" .. tostring(ok) .. " " .. tostring(err))
    local sender, msg, proto = rednet.receive(nil, 15)
    print("MULTI B 收到 sender=" .. tostring(sender) .. " msg=" .. tostring(msg) ..
        " proto=" .. tostring(proto))
    if sender then
        rednet.send(sender, "hello-back-from-B", "dcprobe")
        print("MULTI B 已回包给 " .. tostring(sender))
    end
end
print("MULTI B 结束")
os.shutdown()
