--[[- dc.screen — 网络屏幕（屏幕节点）

另一台电脑接上显示器、运行 screen.lua，就会成为主控的"网络屏幕"：
主控每秒把面板内容（文字行 + 颜色）通过 rednet 推过来，这里只负责画。

为什么需要它：
  * CC 的有线网络会把"贴着有线调制解调器的显示器"暴露成外设（monitor_0），
    那种屏幕主控用 `mon monitor_0` 直接就能挂上；
  * 但**贴在别的电脑侧面**的显示器不是网络外设，主控看不到。屏幕节点就是
    这种显示器的转发器——它不参与计算，只接收 `disp` 帧并绘制。

协议（见 docs/PROTOCOL.md）：
    屏幕 ── screen {name,w,h} ──▶ 主控     （上线登记 + 心跳，缺省每 3 秒）
    屏幕 ◀── disp {lines,w,h} ─── 主控     （一帧面板内容，缺省每 1 秒）
    屏幕 ◀── screenoff {why} ─── 主控     （推送关闭 / 屏幕数满 / 被踢）

集群设了共享密钥（dcnet.key）时，屏幕端也要设同一个密钥，否则消息会被丢弃。
]]

local util  = dc_require("dc.util")
local proto = dc_require("dc.protocol")
local net   = dc_require("dc.net")
local panel = dc_require("dc.panel")

local M = {}

M.DEFAULTS = {
    monitor  = "",    -- 显示器外设名（""=自动找第一台）
    scale    = 0.5,   -- 字号缩放（0.5=分辨率翻倍）
    name     = "",    -- 屏幕名（缺省用电脑标签，再缺省 screen-<ID>）
    interval = 3,     -- 秒：向主控报到的间隔（同时是心跳）
    timeout  = 15,    -- 秒：多久没收到画面就当主控离线
}

local C = util.colours or {}
local function col(name, fb) return (C and C[name]) or fb end

local function clampScale(v)
    v = tonumber(v) or M.DEFAULTS.scale
    if v < 0.5 then v = 0.5 end
    if v > 5 then v = 5 end
    return v
end

--- 启动网络屏幕。返回 true / false（失败时已经打印了原因）
function M.run(opts)
    opts = opts or {}
    local scale = clampScale(opts.scale)

    -- ── 网络 ─────────────────────────────────────────────────────────
    local modems, failed = net.openAll()
    if #modems == 0 then
        printError("[dcnet] 网络屏幕：没有检测到调制解调器（modem）")
        print("[dcnet] 屏幕电脑也要接在有线网络（或同一无线网络）里。")
        return false
    end
    for _, e in ipairs(failed or {}) do
        print("[dcnet] 网络屏幕：打开 modem 失败：" .. tostring(e))
    end

    local key = opts.key
    if key == nil or key == "" then
        key = rawget(_G, "DCNET_KEY") or (settings and settings.get("dcnet.key")) or ""
    end
    key = tostring(key)
    if key ~= "" then
        local ok, err = net.setKey(key)
        if not ok then
            print("[dcnet] 网络屏幕：启用消息签名失败：" .. tostring(err))
        else
            print("[dcnet] 网络屏幕：消息签名已启用（指纹 " ..
                tostring(net.fingerprint()) .. "）")
        end
    end

    -- ── 显示器 ───────────────────────────────────────────────────────
    local monitors = panel.findMonitors()
    if #monitors == 0 then
        printError("[dcnet] 网络屏幕：这台电脑上没有显示器（monitor）")
        print("[dcnet] 把显示器贴在电脑侧面，或用 screen.lua <外设名> 指定。")
        return false
    end
    local want = tostring(opts.monitor or "")
    local pick
    for _, m in ipairs(monitors) do
        if want == "" or m.name == want then pick = m break end
    end
    if not pick then
        local names = {}
        for _, m in ipairs(monitors) do names[#names + 1] = m.name end
        printError("[dcnet] 网络屏幕：找不到显示器 " .. want ..
            "；可用：" .. table.concat(names, ", "))
        return false
    end
    if not pick.periph then
        printError("[dcnet] 网络屏幕：无法打开显示器 " .. pick.name)
        return false
    end

    local dev, monName = pick.periph, pick.name
    local w, h = 51, 19
    local function resize()
        pcall(function() dev.setTextScale(scale) end)
        local ok, nw, nh = pcall(function() return dev.getSize() end)
        if ok and nw then w, h = nw, nh end
    end
    resize()

    local name = tostring(opts.name or "")
    if name == "" then
        local ok, label = pcall(function() return os.getComputerLabel() end)
        if ok and label and label ~= "" then name = label end
    end
    if name == "" then name = "screen-" .. tostring(os.getComputerID()) end

    local interval = math.max(1, tonumber(opts.interval) or M.DEFAULTS.interval)
    local timeout = math.max(3, tonumber(opts.timeout) or M.DEFAULTS.timeout)

    -- ── 画面 ─────────────────────────────────────────────────────────
    local masterId, masterSeen = nil, 0
    local frames, lastHello, lastStatus, lastBad = 0, -interval, 0, 0
    local offWhy = nil

    local function statusLines()
        local out = {}
        out[#out + 1] = { text = string.format("dcnet 网络屏幕 #%d", os.getComputerID()),
            colour = col("lime", 32) }
        out[#out + 1] = { text = string.format("显示器 %s  %dx%d", monName, w, h),
            colour = col("lightGray", 1024) }
        if masterId and util.mono() - masterSeen <= timeout then
            out[#out + 1] = { text = string.format("已连接主控 #%d", masterId),
                colour = col("lime", 32) }
            out[#out + 1] = { text = string.format("已收到 %d 帧面板", frames),
                colour = col("white", 1) }
        elseif offWhy == "off" then
            out[#out + 1] = { text = "主控已关闭网络屏幕推送", colour = col("orange", 2) }
            out[#out + 1] = { text = "在主控上执行 mon net on 重新开启",
                colour = col("lightGray", 1024) }
        elseif offWhy == "full" then
            out[#out + 1] = { text = "主控的网络屏幕数量已满", colour = col("orange", 2) }
            out[#out + 1] = { text = "在主控上 mon net 看列表 / 踢掉不用的屏幕",
                colour = col("lightGray", 1024) }
        elseif offWhy == "ver" then
            out[#out + 1] = { text = "协议版本不兼容", colour = col("red", 16384) }
            out[#out + 1] = { text = "请把 screen.lua 更新到与主控相同的版本",
                colour = col("lightGray", 1024) }
        elseif offWhy == "kick" then
            out[#out + 1] = { text = "已被主控断开", colour = col("orange", 2) }
            out[#out + 1] = { text = "下次心跳会自动重连", colour = col("lightGray", 1024) }
        else
            out[#out + 1] = { text = "正在寻找主控…", colour = col("yellow", 256) }
            out[#out + 1] = { text = "在主控上输入 mon 查看网络屏幕",
                colour = col("lightGray", 1024) }
        end
        out[#out + 1] = { text = os.date("%H:%M:%S"), colour = col("gray", 128) }
        return out
    end

    local function redrawStatus()
        local now = util.mono()
        if now - lastStatus < 2 then return end
        lastStatus = now
        panel.draw(dev, statusLines(), h)
    end

    panel.draw(dev, statusLines(), h)
    print(string.format("[dcnet] 网络屏幕 %s 已启动：显示器 %s（%dx%d），等待主控…",
        name, monName, w, h))

    -- ── 主循环 ───────────────────────────────────────────────────────
    while true do
        local now = util.mono()

        -- 显示器可能被重新拼接：尺寸变了就重新应用缩放，并立刻报到
        local ok, nw, nh = pcall(function() return dev.getSize() end)
        if ok and nw and (nw ~= w or nh ~= h) then
            w, h = nw, nh
            resize()
            lastHello = now - interval
        end

        if now - lastHello >= interval then
            lastHello = now
            net.broadcast(proto.msg(proto.SCREEN, {
                name = name, w = w, h = h, scale = scale,
            }), util.PROTO_CTRL)
        end

        local sender, msg = net.receive(util.PROTO_CTRL, 0.5)
        local gotFrame = false
        if msg and proto.valid(msg) then
            local vok, why = net.verify(sender, msg)
            if not vok then
                if now - lastBad > 10 then
                    lastBad = now
                    print("[dcnet] 网络屏幕：丢弃一条消息（" .. tostring(why) .. "）")
                end
            elseif msg.t == proto.DISP and type(msg.lines) == "string" then
                local parsed, lines = pcall(textutils.unserialize, msg.lines)
                if parsed and type(lines) == "table" then
                    masterId, masterSeen = sender, util.mono()
                    frames, offWhy = frames + 1, nil
                    panel.draw(dev, lines, msg.h or h)
                    gotFrame = true
                end
            elseif msg.t == proto.SCREENOFF then
                masterId, offWhy = nil, tostring(msg.why or "off")
                redrawStatus()
            end
        end

        if not gotFrame and util.mono() - masterSeen > timeout then
            redrawStatus()
        end
    end
    return true
end

return M
