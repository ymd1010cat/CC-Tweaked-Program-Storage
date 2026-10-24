-- bsod.lua - 基于 window 的 Windows 10 风格蓝屏模块
-- 使用 window API 创建全屏窗口，文字居中显示，调用后直接 error() 退出

local bsod = {}

-- 默认配置
local DEFAULTS = {
    error = "UNKNOWN_ERROR",
    file  = "unknown.sys",
    code  = "0x00000000",
    title = "Your PC ran into a problem and needs to restart.",
    extra = "We're just collecting some error info, and then we'll restart for you."
}

-- 辅助：在窗口内居中写入多行文本（自动换行）
local function centerWrite(window, text, y, maxWidth)
    maxWidth = maxWidth or window.getSize()
    local winW, _ = window.getSize()
    for line in text:gmatch("[^\n]+") do
        if #line > maxWidth then line = line:sub(1, maxWidth) end
        local x = math.floor((winW - #line) / 2) + 1
        window.setCursorPos(x, y)
        window.write(line)
        y = y + 1
    end
    return y
end

-- 显示蓝屏并抛出错误（不返回）
function bsod.show(options)
    options = options or {}
    local errorMsg = options.error or DEFAULTS.error
    local file     = options.file  or DEFAULTS.file
    local code     = options.code  or DEFAULTS.code
    local title    = options.title or DEFAULTS.title
    local extra    = options.extra or DEFAULTS.extra

    -- 获取终端尺寸并创建全屏窗口
    local parent = term.current()
    local w, h = parent.getSize()
    local win = window.create(parent, 1, 1, w, h)

    -- 设置蓝屏主题
    win.setBackgroundColor(colors.blue)
    win.setTextColor(colors.white)
    win.clear()

    local y = 1

    -- 1. 哭脸（居中）
    local face = ":("
    win.setCursorPos(math.floor((w - #face) / 2) + 1, y)
    win.write(face)
    y = y + 2

    -- 2. 主标题
    y = centerWrite(win, title, y, w - 4) + 1

    -- 3. 错误详情
    local details = {
        "What failed: " .. file,
        "Error code: " .. code
    }
    for _, line in ipairs(details) do
        y = centerWrite(win, line, y, w - 4) + 1
    end
    y = y + 1

    -- 4. 额外说明（支持多行）
    if extra and extra ~= "" then
        for line in extra:gmatch("[^\n]+") do
            y = centerWrite(win, line, y, w - 4) + 1
        end
    end

    -- 5. 底部提示（占用倒数第二行，最后一行留空给 error 输出）
    local footer = "Your system needs to be restarted."
    win.setCursorPos(math.floor((w - #footer) / 2) + 1, h - 1)
    win.write(footer)

    -- 6. 将父终端光标移到屏幕外（行号远超屏幕高度），然后调用 error
    parent.setCursorPos(1, h + 10)   -- 移出可视区域
    error("", 0)   -- 错误信息将输出到光标位置，因在屏幕外而不可见
end

return bsod