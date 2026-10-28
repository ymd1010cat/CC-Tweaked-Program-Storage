--[[- dc.panel — monitor 大屏状态面板

主控挂上显示器（monitor）后，可以把它当集群仪表盘：

    ┌──────────────────────────────────────────┐
    │ dcnet 主控 #2            12:03:41        │  标题（时间）
    │ 节点 3/3 在线  并发 1/2  队列 1          │  集群概况
    │ #1 primes    ############-------  57%    │  正在跑的作业（最多 4 行）
    │   46/80 失败 0  用时 12.4s               │
    │ #3:42% #4:闲 #5:63%  云:1飞              │  节点矩阵（紧凑）
    └──────────────────────────────────────────┘

设计上把 **生成文本行**（lines）和 **画到屏幕**（redraw）分开：
lines 是纯函数、可单元测试；redraw 只负责清屏 + 逐行写 + 上色。
尺寸自适应：w<20 或 h<4 时退化成一两行的极简模式，任何尺寸都不会崩。
]]

local util = dc_require("dc.util")

local M = {}

local C = util.colours or {}
local function col(name, fb) return (C and C[name]) or fb end

M.DEFAULT_SCALE = 0.5      -- 0.5 让分辨率翻倍，字小但能塞下更多信息

-- ── 外设名解析（本地 + 有线网络） ───────────────────────────────────────
-- CC 会把"贴着有线调制解调器的显示器"按网络名暴露出来（monitor_0 之类），
-- 但不同版本/接法下 getNames() 不一定都列出远端外设，所以这里再主动问一遍
-- modem.getNamesRemote()。这样主控既能用自己侧面贴的显示器，也能直接用
-- 网络另一头的显示器（不用另开一台屏幕电脑）。

local function typesOf(ty)
    local out = {}
    if type(ty) == "string" then
        out[1] = ty
    elseif type(ty) == "table" then
        for _, t in ipairs(ty) do out[#out + 1] = t end
    end
    return out
end

local function isMonitorType(ty)
    for _, t in ipairs(typesOf(ty)) do
        if t == "monitor" then return true end
    end
    return false
end

--- 取外设类型；远端外设（有线网络）用 modem.getTypeRemote 兜底。
function M.typeOf(name, modems)
    local ok, ty = pcall(peripheral.getType, name)
    if ok and ty ~= nil then return ty end
    for _, md in ipairs(modems or {}) do
        if type(md.getTypeRemote) == "function" then
            local ok2, t = pcall(md.getTypeRemote, name)
            if ok2 and t ~= nil then return t end
        end
    end
end

--- 扫描所有 monitor 外设（含有线网络上的远端显示器）。
-- 返回 { {name=, periph=, net=bool}, ... }；本地显示器排在网络显示器前面。
function M.findMonitors()
    local order, remote, modems, seen = {}, {}, {}, {}

    local function add(name, isRemote)
        name = tostring(name)
        if seen[name] then
            if isRemote then remote[name] = true end
            return
        end
        seen[name] = true
        order[#order + 1] = name
        if isRemote then remote[name] = true end
    end

    local names = {}
    for _, name in ipairs(peripheral.getNames()) do
        names[#names + 1] = name
        add(name, false)
    end

    -- 有线网络上的远端外设（有些版本会出现在 getNames 里，有些不会）
    for _, name in ipairs(names) do
        for _, t in ipairs(typesOf(M.typeOf(name))) do
            if t == "modem" then
                local ok, dev = pcall(peripheral.wrap, name)
                if ok and dev and type(dev.getNamesRemote) == "function" then
                    modems[#modems + 1] = dev
                    local ok2, list = pcall(dev.getNamesRemote)
                    if ok2 and type(list) == "table" then
                        for _, rn in ipairs(list) do add(rn, true) end
                    end
                end
                break
            end
        end
    end

    local found = {}
    for _, name in ipairs(order) do
        if isMonitorType(M.typeOf(name, modems)) then
            local ok, dev = pcall(peripheral.wrap, name)
            found[#found + 1] = { name = name, periph = ok and dev or nil, net = remote[name] or false }
        end
    end
    table.sort(found, function(a, b)
        if a.net ~= b.net then return not a.net end     -- 本地优先
        return a.name < b.name
    end)
    return found
end

local Panel = {}
M.Panel = Panel

--- opts: { log = function(text, colour), scale = number, cfg = table }
function M.new(opts)
    opts = opts or {}
    local self = setmetatable({}, { __index = Panel })
    self.log = opts.log or function() end
    self.scale = opts.scale or M.DEFAULT_SCALE
    self.name, self.periph = nil, nil
    self.w, self.h = 0, 0
    self.lastDraw = 0
    return self
end

function Panel:attached()
    return self.periph ~= nil
end

--- 绑定一个显示器：可以传外设名（"right"），也可以直接传一个可用的对象（测试用）
function Panel:attach(target)
    if type(target) == "table" then
        self.periph, self.name = target, (target.__name or "fake")
    elseif type(target) == "string" and target ~= "" then
        if not isMonitorType(M.typeOf(target)) then
            return nil, "not a monitor peripheral: " .. target
        end
        local ok, dev = pcall(peripheral.wrap, target)
        if not ok or not dev then return nil, "cannot open monitor: " .. target end
        self.periph, self.name = dev, target
    else
        return nil, "no monitor specified"
    end
    pcall(function() self.periph.setTextScale(self.scale) end)
    local ok2, w, h = pcall(function() return self.periph.getSize() end)
    if ok2 and w then
        self.w, self.h = w, h
    else
        self.w, self.h = 51, 19
    end
    return true
end

function Panel:detach()
    local old = self.name
    self.periph, self.name, self.w, self.h = nil, nil, 0, 0
    return old
end

--- 自动找一台显示器挂上
function Panel:attachAuto()
    local list = M.findMonitors()
    if #list == 0 then return nil, "no monitor detected" end
    local ok, err = self:attach(list[1].name)
    if not ok then return nil, err end
    return self.name
end

function Panel:refreshSize()
    if not self.periph then return end
    local ok, w, h = pcall(function() return self.periph.getSize() end)
    if ok and w then self.w, self.h = w, h end
end

-- ── 文本生成（纯函数，便于测试） ────────────────────────────────────────

--- 生成面板内容。w/h 缺省用本地面板的当前尺寸；网络屏幕按自己的尺寸调用。
-- 返回 { { text =, colour = }, ... }
function M.linesFor(sched, cloud, w, h)
    local out = {}
    w = math.max(1, tonumber(w) or 51)
    h = math.max(1, tonumber(h) or 19)

    local function add(text, colour)
        -- 面板固定是 6x9 像素的字符网格（一个汉字要 6x4 格），所以面板永远是
        -- 英文：不经过 util.tr，也就不会在 zh 模式里出现撒豆子一样的乱码。
        out[#out + 1] = { text = util.trunc(tostring(text), w), colour = colour }
    end

    add(string.format("dcnet master #%d   %s", os.getComputerID(), os.date("%H:%M:%S")),
        col("lime", 32))

    -- 极简模式：显示器太小就只报集群概况
    if w < 20 or h < 4 then
        add(string.format("Workers %d/%d jobs %d", sched:onlineCount(), sched:workerCount(),
            sched:runningCount()), col("white", 1))
        return out
    end

    local queued = 0
    for _, j in pairs(sched.jobs) do
        if j.state == "queued" then queued = queued + 1 end
    end
    add(string.format("Workers %d/%d online   parallel %d/%d   queue %d%s",
        sched:onlineCount(), sched:workerCount(), sched:runningCount(),
        math.max(1, sched.cfg.maxParallel or 1), queued,
        sched.paused and "  [paused]" or ""), col("white", 1))

    -- 正在跑的作业（最多 4 个）
    local jobs = sched:runningJobs()
    for i = 1, math.min(#jobs, 4) do
        local job = jobs[i]
        local pct = sched:progress(job)
        add(string.format("#%d %s %s %3d%%", job.id, util.trunc(job.name, 12),
            util.bar(pct, 12), math.floor(pct * 100)),
            job.state == "running" and col("lightBlue", 512) or col("lightGray", 1024))
        add(string.format("    %d/%d done  failed %d  elapsed %s",
            job.counts.done + job.counts.failed, job.total, job.counts.failed,
            util.duration(util.now() - (job.submittedAt or util.now()))),
            col("lightGray", 1024))
    end

    -- 节点矩阵（紧凑，按宽度折行）
    local cells = {}
    for _, wk in ipairs(sched:workerList()) do
        local cell
        if wk.virtual then
            cell = string.format("%s:%d run", util.trunc(wk.name or "cloud", 6),
                cloud and cloud:countInflight(wk) or 0)
        elseif wk.state == "offline" then
            cell = "#" .. wk.id .. ":offline"
        elseif wk.state == "busy" then
            cell = string.format("#%d:%d%%", wk.id, math.floor((wk.progress or 0) * 100))
        else
            cell = "#" .. wk.id .. ":idle"
        end
        cells[#cells + 1] = cell
    end
    if #cells > 0 then
        add(table.concat(cells, " "), col("yellow", 256))
    end

    -- 云端与统计
    if cloud and cloud.ok and #cloud.endpoints > 0 then
        add(string.format("Cloud %d endpoints, %d in flight, ok %d / failed %d",
            #cloud.endpoints, cloud:totalInflight(), cloud.okCount, cloud.failCount),
            col("lightGray", 1024))
    end
    add(string.format("Total tasks %d failed %d retries %d redundant %d",
        sched.stats.done, sched.stats.failed, sched.stats.retries, sched.stats.redundant or 0),
        col("gray", 128))

    return out
end

--- 本地面板：按自己挂载的显示器尺寸生成
function Panel:lines(sched, cloud)
    return M.linesFor(sched, cloud, self.w, self.h)
end

--- 把 {text=,colour=} 行画到任意屏幕（本地 monitor / 网络屏幕）上。
-- 只依赖 CC monitor 的 setBackgroundColour/clear/setCursorPos/setTextColour/write。
function M.draw(dev, lines, h)
    if not dev or type(lines) ~= "table" then return false end
    h = math.max(1, tonumber(h) or 19)
    pcall(function() dev.setBackgroundColour(col("black", 32768)) end)
    pcall(function() dev.clear() end)
    local all = true
    for i = 1, math.min(#lines, h) do
        local line = lines[i] or {}
        local ok = pcall(function()
            dev.setCursorPos(1, i)
            dev.setTextColour(line.colour or col("white", 1))
            dev.write(tostring(line.text or ""))
        end)
        if not ok then all = false end
    end
    pcall(function() dev.setCursorPos(1, 1) end)
    return all
end

--- 画一帧（受最小间隔限制；force 可强制）
function Panel:redraw(sched, cloud, force)
    if not self:attached() then return false end
    local now = util.mono()
    if not force and (now - (self.lastDraw or 0)) < 0.9 then return false end
    self.lastDraw = now
    self:refreshSize()

    local ok, lines = pcall(self.lines, self, sched, cloud)
    if not ok then
        self.log("Panel draw failed: " .. tostring(lines), 16384)
        return false
    end

    local drawn = M.draw(self.periph, lines, self.h)
    if not drawn then
        self.log("Panel write to monitor failed (size " .. tostring(self.w) .. "x" .. tostring(self.h) .. ")", 16384)
    end
    return drawn
end

return M
