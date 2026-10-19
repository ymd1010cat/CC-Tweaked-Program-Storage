-- 多实例探测 A：当服务端 + 广播
print("MULTI A id=" .. tostring(os.getComputerID()))
print("MULTI A periph=" .. table.concat(peripheral.getNames(), ","))
local side
for _, name in ipairs(peripheral.getNames()) do
    local ty = peripheral.getType(name)
    if ty == "modem" then side = name end
    if type(ty) == "table" then
        for _, t in ipairs(ty) do if t == "modem" then side = name end end
    end
end
print("MULTI A modem=" .. tostring(side))
if side then
    local ok, err = pcall(rednet.open, side)
    print("MULTI A open=" .. tostring(ok) .. " " .. tostring(err))
    rednet.broadcast("hello-from-A", "dcprobe")
    print("MULTI A 已广播 hello-from-A，等待应答…")
    local sender, msg, proto = rednet.receive(nil, 20)
    print("MULTI A 收到 sender=" .. tostring(sender) .. " msg=" .. tostring(msg) ..
        " proto=" .. tostring(proto))
end
print("MULTI A 结束")
os.shutdown()
