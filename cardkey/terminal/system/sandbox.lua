-- CardKey terminal sandbox: block Ctrl+T and remove the ways back to CraftOS.
-- Deploy path: /system/sandbox.lua
-- /startup.lua calls lockEvents(); /system/kernel.lua calls init(). restore() is
-- kept for symmetry (nothing on a real terminal calls it).
-- Pure module: all state is local, no globals are created.

local M = {}

local saved = nil      -- original globals captured before we touch anything
local locked = false   -- lockEvents() already applied to the event APIs
local hardened = false -- init() already removed the exit hatches

local function captureOriginals()
    if saved ~= nil then
        return
    end
    saved = {
        pullEvent = os.pullEvent,
        pullEventRaw = os.pullEventRaw,
        shell = rawget(_G, "shell"),
        commands = rawget(_G, "commands"),
        fsDelete = fs.delete,
        fsMove = fs.move,
        osShutdown = os.shutdown,
        osReboot = os.reboot,
    }
end

-- Wrap the raw event call so a "terminate" event is dropped instead of reaching
-- the caller. The wrapper always calls the function captured at lock time, so
-- restore() can put the platform originals back.
local function makeFilteredEvents(originalRaw)
    return function(filter)
        while true do
            local name, a, b, c, d = originalRaw(filter)
            if name ~= "terminate" then
                return name, a, b, c, d
            end
        end
    end
end

-- Install the event lock. Safe to call more than once.
function M.lockEvents()
    captureOriginals()
    if locked then
        return true
    end
    local filtered = makeFilteredEvents(saved.pullEventRaw)
    os.pullEventRaw = filtered
    os.pullEvent = filtered
    locked = true
    return true
end

-- Remove shell/commands and the shutdown/reboot/filesystem-delete hatches.
-- Safe to call more than once.
function M.init()
    captureOriginals()
    if hardened then
        return true
    end
    _G.shell = nil
    _G.commands = nil
    fs.delete = nil
    fs.move = nil
    os.shutdown = nil
    os.reboot = nil
    hardened = true
    return true
end

-- Put every global captured above back in place. Safe to call more than once.
function M.restore()
    captureOriginals()
    os.pullEvent = saved.pullEvent
    os.pullEventRaw = saved.pullEventRaw
    _G.shell = saved.shell
    _G.commands = saved.commands
    fs.delete = saved.fsDelete
    fs.move = saved.fsMove
    os.shutdown = saved.osShutdown
    os.reboot = saved.osReboot
    locked = false
    hardened = false
    return true
end

return M
