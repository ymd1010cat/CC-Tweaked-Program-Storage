-- dcnet-tabs.lua - first multishell tab launcher.
--
-- /startup.lua queues "lua /usr/dcnet-tabs.lua" as typed input, so this runs in
-- the shell whose environment carries multishell. It opens the resident dcnet
-- role in tab 1 and the ush command console in tab 2, then focuses dcnet.
-- The first (shell) tab is left behind as an emergency prompt.

local bin = rawget(_G, "DCNET_BIN") or "/usr/pkgs/dcnet/bin/dcnet.lua"
local role = rawget(_G, "DCNET_BOOT_ROLE") or "master"

if type(fs) == "table" and not fs.exists(bin) then
    local okp, pkg = pcall(require, "pkg")
    if okp and type(pkg) == "table" and type(pkg.resolve_command) == "function" then
        bin = pkg.resolve_command("dcnet") or bin
    end
end

if type(shell) ~= "table" or type(shell.openTab) ~= "function" then
    print("[dcnet] multishell is not available; keeping the shell")
    return
end

local dc = shell.openTab(bin, role)
if dc and multishell and multishell.setTitle then
    multishell.setTitle(dc, "dcnet " .. tostring(role))
end

local ui = shell.openTab("/usr/ush.lua")
if ui and multishell and multishell.setTitle then
    multishell.setTitle(ui, "ush")
end

if dc and multishell and multishell.setFocus then
    multishell.setFocus(dc)
end
