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

--- 扫描所有 monitor 外设。返回 { {name=, periph=}, ... }
function M.findMonitors()
    local found = {}
    for _, name in ipairs(peripheral.getNames()) do
        local ty = peripheral.getType(name)
        local isMonitor = (ty == "monitor")
        if not isMonitor and type(ty) == "table" then
            for _, t in ipairs(ty) do
                if t == "monitor" then isMonitor = true end
            end
        end
        if isMonitor then
            local ok, dev = pcall(peripheral.wrap, name)
            found[#found + 1] = { name = name, periph = ok and dev or nil }
        end
    end
    table.sort(found, function(a, b) return a.name < b.name end)
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
        if peripheral.getType(target) ~= "monitor" then
            return nil, "不是显示器外设: " .. target
        end
        local ok, dev = pcall(peripheral.wrap, target)
        if not ok or not dev then return nil, "无法打开显示器: " .. target end
        self.periph, self.name = dev, target
    else
        return nil, "没有指定显示器"
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
    if #list == 0 then return nil, "没有检测到显示器" end
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

--- 生成面板内容。返回 { { text =, colour = }, ... }
function Panel:lines(sched, cloud)
    local out = {}
    local w = self.w or 51

    local function add(text, colour)
        out[#out + 1] = { text = util.trunc(text, w), colour = colour }
    end

    add(string.format("dcnet 主控 #%d   %s", os.getComputerID(), os.date("%H:%M:%S")),
        col("lime", 32))

    -- 极简模式：显示器太小就只报集群概况
    if w < 20 or (self.h or 19) < 4 then
        add(string.format("节点 %d/%d 作业 %d", sched:onlineCount(), sched:workerCount(),
            sched:runningCount()), col("white", 1))
        return out
    end

    local queued = 0
    for _, j in pairs(sched.jobs) do
        if j.state == "queued" then queued = queued + 1 end
    end
    add(string.format("节点 %d/%d 在线   并发 %d/%d   队列 %d%s",
        sched:onlineCount(), sched:workerCount(), sched:runningCount(),
        math.max(1, sched.cfg.maxParallel or 1), queued,
        sched.paused and "  [已暂停]" or ""), col("white", 1))

    -- 正在跑的作业（最多 4 个）
    local jobs = sched:runningJobs()
    for i = 1, math.min(#jobs, 4) do
        local job = jobs[i]
        local pct = sched:progress(job)
        add(string.format("#%d %s %s %3d%%", job.id, util.trunc(job.name, 12),
            util.bar(pct, 12), math.floor(pct * 100)),
            job.state == "running" and col("lightBlue", 512) or col("lightGray", 1024))
        add(string.format("    %d/%d 完成  失败 %d  用时 %s",
            job.counts.done + job.counts.failed, job.total, job.counts.failed,
            util.duration(util.now() - (job.submittedAt or util.now()))),
            col("lightGray", 1024))
    end

    -- 节点矩阵（紧凑，按宽度折行）
    local cells = {}
    for _, wk in ipairs(sched:workerList()) do
        local cell
        if wk.virtual then
            cell = string.format("%s:%d飞", util.trunc(wk.name or "cloud", 6),
                cloud and cloud:countInflight(wk) or 0)
        elseif wk.state == "offline" then
            cell = "#" .. wk.id .. ":离线"
        elseif wk.state == "busy" then
            cell = string.format("#%d:%d%%", wk.id, math.floor((wk.progress or 0) * 100))
        else
            cell = "#" .. wk.id .. ":闲"
        end
        cells[#cells + 1] = cell
    end
    if #cells > 0 then
        add(table.concat(cells, " "), col("yellow", 256))
    end

    -- 云端与统计
    if cloud and cloud.ok and #cloud.endpoints > 0 then
        add(string.format("云端 %d 端点，在飞 %d，成功 %d / 失败 %d",
            #cloud.endpoints, cloud:totalInflight(), cloud.okCount, cloud.failCount),
            col("lightGray", 1024))
    end
    add(string.format("累计任务 %d 失败 %d 重试 %d 冗余 %d",
        sched.stats.done, sched.stats.failed, sched.stats.retries, sched.stats.redundant or 0),
        col("gray", 128))

    return out
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
        self.log("面板绘制失败：" .. tostring(lines), 16384)
        return false
    end

    local mon = self.periph
    pcall(function() mon.setBackgroundColour(col("black", 32768)) end)
    pcall(function() mon.clear() end)
    for i, line in ipairs(lines) do
        if i > (self.h or 19) then break end
        pcall(function()
            mon.setCursorPos(1, i)
            mon.setTextColour(line.colour or col("white", 1))
            mon.write(line.text)
        end)
    end
    pcall(function() mon.setCursorPos(1, 1) end)
    return true
end

return M
