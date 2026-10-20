-- Sentinel terminal sandbox: keeps a running session from escaping to a shell.
-- Deploy: /system/sandbox.lua
--
-- Three switches, all idempotent:
--   lockEvents() : os.pullEvent becomes os.pullEventRaw so Ctrl+T (a
--                  "terminate" event) cannot kill the session.
--   init()       : removes the escape hatches (shell, commands, fs.delete,
--                  fs.move, os.shutdown, os.reboot).
--   restore()    : puts every captured value back where it came from.

local M = {}

-- Captured once at load time, before anything is disabled. The handles are
-- kept together with the table they belong to so restore() can be exact.
local saved = {
    pullEvent = os.pullEvent,
    shell = shell,
    commands = commands,
    fsDelete = fs.delete,
    fsMove = fs.move,
    shutdown = os.shutdown,
    reboot = os.reboot,
}

local eventsLocked = false
local initialized = false

function M.lockEvents()
    if eventsLocked then return end
    os.pullEvent = os.pullEventRaw
    eventsLocked = true
end

function M.init()
    if initialized then return end
    shell = nil
    commands = nil
    fs.delete = nil
    fs.move = nil
    os.shutdown = nil
    os.reboot = nil
    initialized = true
end

function M.restore()
    if initialized then
        shell = saved.shell
        commands = saved.commands
        fs.delete = saved.fsDelete
        fs.move = saved.fsMove
        os.shutdown = saved.shutdown
        os.reboot = saved.reboot
        initialized = false
    end
    if eventsLocked then
        os.pullEvent = saved.pullEvent
        eventsLocked = false
    end
end

return M
