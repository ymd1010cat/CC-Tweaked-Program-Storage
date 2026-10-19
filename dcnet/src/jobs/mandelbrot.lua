--[[ dcnet 内置作业：曼德博集合（ASCII 渲染）

每个任务渲染若干行，把行文本回传，主控端按行号拼成整幅图。
这是"结果不是数字而是数据块"的作业范例。

参数：
  width=48        图像宽度（字符列）
  height=14       图像高度（字符行）
  rows=2          每个任务渲染几行
  maxIter=32      最大迭代次数
  xmin=-2.1 xmax=0.7 ymin=-1.1 ymax=1.1   复平面范围

提示：把 width 设成终端宽度、height 设成 12~16，看起来最舒服。
]]

local SHADES = " .:-=+*#%@"

return {
    name    = "mandelbrot",
    summary = "并行渲染曼德博集合（演示数据块型作业）",
    -- 它的 reduce 是按行号拼接，不满足结合律，所以明确拒绝两级汇总
    twoLevel = false,
    params  = {
        { name = "width",   type = "number", default = 48,   help = "图像宽度" },
        { name = "height",  type = "number", default = 14,   help = "图像高度" },
        { name = "rows",    type = "number", default = 2,    help = "每个任务渲染的行数" },
        { name = "maxIter", type = "number", default = 32,   help = "最大迭代次数" },
        { name = "xmin",    type = "number", default = -2.1 },
        { name = "xmax",    type = "number", default = 0.7 },
        { name = "ymin",    type = "number", default = -1.1 },
        { name = "ymax",    type = "number", default = 1.1 },
    },

    split = function(a)
        local tasks = {}
        local h = math.max(1, math.floor(a.height))
        local per = math.max(1, math.floor(a.rows))
        local y = 0
        while y < h do
            tasks[#tasks + 1] = {
                y0 = y, y1 = math.min(y + per, h) - 1,
                width = math.floor(a.width), height = h,
                maxIter = math.floor(a.maxIter),
                xmin = a.xmin, xmax = a.xmax, ymin = a.ymin, ymax = a.ymax,
            }
            y = y + per
        end
        return tasks
    end,

    map = function(task, ctx)
        local w, maxIter = task.width, task.maxIter
        local lines = {}
        local total = task.y1 - task.y0 + 1
        for y = task.y0, task.y1 do
            local cy = task.ymin + (task.ymax - task.ymin) * (y / math.max(1, task.height - 1))
            local row = {}
            for x = 0, w - 1 do
                local cx = task.xmin + (task.xmax - task.xmin) * (x / math.max(1, w - 1))
                local zx, zy, i = 0, 0, 0
                while zx * zx + zy * zy <= 4 and i < maxIter do
                    zx, zy = zx * zx - zy * zy + cx, 2 * zx * zy + cy
                    i = i + 1
                end
                local idx
                if i >= maxIter then
                    idx = #SHADES
                else
                    idx = 1 + math.floor((i / maxIter) * (#SHADES - 1))
                end
                row[#row + 1] = SHADES:sub(idx, idx)
            end
            lines[#lines + 1] = table.concat(row)
            ctx.progress((y - task.y0 + 1) / total, string.format("行 %d", y))
            ctx.tick()
            if ctx.canceled() then break end
        end
        return { y0 = task.y0, lines = lines }
    end,

    reduce = function(results)
        local byRow = {}
        local maxRow = 0
        for _, r in ipairs(results) do
            for i, line in ipairs(r.lines or {}) do
                local y = (r.y0 or 0) + i - 1
                byRow[y] = line
                if y > maxRow then maxRow = y end
            end
        end
        local out = {}
        for y = 0, maxRow do out[#out + 1] = byRow[y] or "" end
        return { art = table.concat(out, "\n"), rows = maxRow + 1 }
    end,

    format = function(res)
        return res.art
    end,
}
