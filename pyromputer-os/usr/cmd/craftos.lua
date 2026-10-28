-- craftos.lua - open the ROM shell in a new multishell tab (root only).
--
-- This is an external command, not a built-in, so a deployment can leave it out
-- with "tools/deploy.py --without-craftos". The tab runs
-- /rom/programs/shell.lua, so psh and its jobs keep running and the machine
-- stays under this installation's boot/exit rules.

local args, stage = ...

local function say(text)
    local s = tostring(text)
    if stage and type(stage.write) == "function" then
        stage.write(s .. "\n")
    else
        print(s)
    end
end

local perm = require("perm")
local audit = require("audit")
local actor = perm.get_current_user()

if actor ~= "root" then
    pcall(audit.log, { actor = actor, action = "craftos", target = "rom",
                       result = "denied", note = "not root" })
    say("craftos: must be root")
    return 1
end

if type(shell) ~= "table" or type(shell.openTab) ~= "function" then
    say("craftos: multishell is not available on this machine")
    return 1
end

local ok, id = pcall(shell.openTab, "/rom/programs/shell.lua")
if not ok or not id then
    say("craftos: cannot open a tab: " .. tostring(id))
    return 1
end

if type(multishell) == "table" then
    if multishell.setTitle then pcall(multishell.setTitle, id, "CraftOS") end
    if multishell.setFocus then pcall(multishell.setFocus, id) end
end

pcall(audit.log, { actor = actor, action = "craftos", target = "rom",
                   result = "granted" })
return 0
