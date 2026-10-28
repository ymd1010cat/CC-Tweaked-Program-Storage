--[[- dc.console — 简易三区终端界面（状态行 / 日志区 / 输入行）

  ┌────────────────────────────────────────────┐  第 1 行：状态栏
  │ 主控 #2 | 节点 3/3 | primes 42% [####----] │
  ├────────────────────────────────────────────┤
  │ [12:03:41] 节点 #5 已连接                  │  第 2..h-1 行：滚动日志
  │ dccomp> run primes to=1000000              │  第 h 行：输入行（read）
  └────────────────────────────────────────────┘

注意：CC 的 parallel 会把同一个事件分发给所有 filter 匹配的协程，因此本模块的
所有方法在返回前都会把 term.redirect 复位到输入窗口，避免后台协程刷日志时
把 read() 正在回显的字符写进日志窗口。
]]

local util = dc_require("dc.util")

local M = {}

local Console = {}
M.Console = Console

local BLACK = (util.colours and util.colours.black) or 32768
local WHITE = (util.colours and util.colours.white) or 1
local BLUE  = (util.colours and util.colours.blue) or 8

--- opts: { title=, hasPrompt=true, statusColour=, statusTextColour=, maxWidth= }
function M.new(opts)
    opts = opts or {}
    local self = setmetatable({}, { __index = Console })
    self.history   = {}
    self.title     = opts.title or "dccomp"
    self.hasPrompt = opts.hasPrompt ~= false
    self.bg        = opts.statusColour or BLUE
    self.fg        = opts.statusTextColour or WHITE
    self.statusText = ""
    term.clear()
    term.setCursorPos(1, 1)
    self:build()
    return self
end

function Console:build()
    local w, h = term.getSize()
    self.parent = term.current()
    self.w, self.h = w, h
    self.statusWin = window.create(self.parent, 1, 1, w, 1, true)
    if self.hasPrompt then
        self.logWin    = window.create(self.parent, 1, 2, w, math.max(1, h - 2), true)
        self.promptWin = window.create(self.parent, 1, h, w, 1, true)
    else
        self.logWin    = window.create(self.parent, 1, 2, w, math.max(1, h - 1), true)
        self.promptWin = nil
    end
    self:redrawStatus()
    term.redirect(self.hasPrompt and self.promptWin or self.logWin)
end

--- 终端尺寸变化或显示错乱时重建界面（会清屏）
function Console:rebuild()
    term.redirect(self.parent)
    term.clear()
    term.setCursorPos(1, 1)
    self:build()
end

function Console:redrawStatus()
    local win = self.statusWin
    win.setBackgroundColour(self.bg)
    win.setTextColour(self.fg)
    win.clearLine()
    win.setCursorPos(1, 1)
    win.write(util.trunc(" " .. tostring(self.statusText), self.w))
    win.setBackgroundColour(BLACK)
    win.setTextColour(WHITE)
    win.setCursorPos(1, 1)
end

--- 更新状态栏文字
function Console:setStatus(text)
    self.statusText = text
    self:redrawStatus()
end

--- 往日志区追加一行（界面语言在输出边界翻译，调用点不用关心）
-- 翻译后的中文是 UTF-8 多字节，原版 CC 字体没有汉字字形。主控启动时若找到
-- 了 CJK 字体介质，会把逐字形的渲染器挂到 _G.DCNET_DRAW（见 master.lua）：
-- 它返回 true 表示这一行已经画完（字形块），false 表示纯 ASCII 没画，照常
-- print 即可。这样英文日志仍然是一行、和以前完全一样。
function Console:log(text, colour)
    text = util.tr(tostring(text))
    term.redirect(self.logWin)
    if colour then term.setTextColour(colour) end
    local draw = rawget(_G, "DCNET_DRAW")
    local drawn = false
    if type(draw) == "function" then
        local ok, res = pcall(draw, text, colour)
        drawn = (ok and res == true)
    end
    if not drawn then print(tostring(text)) end
    if colour then term.setTextColour(WHITE) end
    term.redirect(self.hasPrompt and self.promptWin or self.logWin)
end

--- 往日志区追加多行
function Console:logLines(lines, colour)
    for _, l in ipairs(lines or {}) do self:log(l, colour) end
end

--- 清空日志区
function Console:clearLog()
    self.logWin.clear()
    self.logWin.setCursorPos(1, 1)
end

--- 读取一行输入。prefix 是提示符，completeFn(text) 返回补全候选。
--
-- 注意 CC 的 read 签名是 read(replaceChar, history, completeFn, default)
-- （见 rom/bios.lua），参数顺序写错会在调用瞬间抛 bad argument。
-- completeFn 的返回值会被 read 直接**追加**到当前行尾，所以它必须返回
-- "后缀"而不是完整单词（见 master.lua 里的 suffixes 辅助函数）。
function Console:prompt(prefix, completeFn)
    if not self.hasPrompt then return nil end
    local win = self.promptWin
    win.setCursorPos(1, 1)
    win.clearLine()
    win.setTextColour(WHITE)
    win.write(util.trunc(prefix or "> ", self.w))
    term.redirect(win)
    local line = read(nil, self.history, completeFn, nil)
    if line and util.trim(line) ~= "" then self.history[#self.history + 1] = line end
    term.redirect(win)
    return line
end

--- 结束使用，把终端还原
function Console:close()
    term.redirect(self.parent)
    term.setBackgroundColour(BLACK)
    term.setTextColour(WHITE)
    term.setCursorPos(1, self.h)
    term.clearLine()
end

-- ── headless 控制台 ────────────────────────────────────────────────────
-- 与 Console 同一套方法，但不碰 term：日志追加到文件，prompt 只让出时间片。
-- Pyromputer OS 包里 `dcnet master --headless` / `dcnet worker --headless` 用它。
local Null = {}
Null.__index = Null

function M.null(opts)
    opts = opts or {}
    local self = setmetatable({}, Null)
    self.logFile = opts.logFile
    self.title = opts.title
    self.statusText = ""
    if self.logFile then
        local dir = self.logFile:match("^(.*)/[^/]*$")
        if dir and dir ~= "" then util.ensureDir(dir) end
    end
    return self
end

function Null:setStatus(text) self.statusText = text end
--- headless 没有屏幕，不挂 CJK 渲染（日志文件里存的是翻译后的 UTF-8 文本，
-- 由读日志的那一端决定怎么显示）
function Null:log(text)
    text = util.tr(tostring(text))
    if self.logFile then util.appendLog(self.logFile, util.logLine(text)) end
end
function Null:logLines(lines)
    for _, line in ipairs(lines or {}) do self:log(line) end
end
function Null:clearLog() end
function Null:prompt() sleep(1) return nil end
function Null:rebuild() end
function Null:close() end

return M
