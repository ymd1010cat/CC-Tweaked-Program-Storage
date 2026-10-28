-- gnome.apps.taskman - what is running on this desktop, and what it has done.
--
-- WHY THE APPLICATION IS ITSELF A TASK
-- The desktop schedules coroutines, and this is the window that makes them
-- visible: one row per open window, with its title, whether it has the focus and
-- how many tasks it owns. The counters are refreshed from the app's OWN task, so
-- they move while the operator does nothing at all -- which is the observable
-- form of multitasking: a window that keeps working while another one has the
-- focus. The picture is still drawn by draw(); the task only counts ticks, and
-- the count is printed, so "the desktop resumed me" is something a dump asserts.
local taskman = {}

local function row_text(desktop, win)
    local tasks = 0
    for _, t in ipairs(win.tasks or {}) do
        if t.status ~= "dead" then tasks = tasks + 1 end
    end
    local title = tostring(win.title or win.id or "?")
    local focus = (desktop.focus == win) and "*" or " "
    return string.format("%-14s %s tasks=%d", title:sub(1, 14), focus, tasks)
end

-- The task: one tick per sleep, and the count is the evidence that it ran. It
-- never draws -- drawing belongs to draw(), which the frame calls -- so a task
-- that is slow to be resumed cannot leave a half-painted window behind.
function taskman.main(api, win)
    win.state = win.state or {}
    win.state.ticks = win.state.ticks or 0
    while true do
        api.task.sleep(api.desktop.step)
        win.state.ticks = win.state.ticks + 1
    end
end

function taskman.draw(api, win)
    local d = api.desktop
    win.state = win.state or {}
    local ticks = win.state.ticks or 0
    api.write(1, 1, string.format("windows: %d", #d.windows))
    api.write(1, 2, string.format("tasks: %d   ticks: %d", #d.tasks, ticks))
    api.write(1, 3, string.format("now: %.2f", d.now))
    local row = 5
    for _, w in ipairs(d.windows) do
        if row > api.h then break end
        api.write(1, row, row_text(d, w))
        row = row + 1
    end
end

return taskman
