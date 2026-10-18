--[[- rpv/compat.lua — runtime API self-check and version reporting.

CC:Tweaked and CraftOS-PC differ in small ways (emulator-only globals, rednet
availability, bit32 vs native bit operators), so every node reports what it found
at boot. A missing *required* API is loud; missing optional ones are listed.

    COMPAT ok=true os=CraftOS-PC 2.8.3 missing=- optional=periphemu,settings

Required: peripheral, fs, os.clock, os.getComputerID, string.format, table.concat,
          bit32 (or the native bit operators, which LuaJIT/5.2+ provide).
Optional: rednet (only needed for the WAN), periphemu (emulator-only modem creation),
          settings, colours/multishell (none used by the library).
]]
local M = ...

local REQUIRED = { "peripheral", "fs", "os", "string", "table" }
local OPTIONAL = { "rednet", "periphemu", "settings", "commands", "shell" }

function M.compat_check()
    local missing, optional = {}, {}
    for _, name in ipairs(REQUIRED) do
        if _G[name] == nil then missing[#missing + 1] = name end
    end
    if not (bit32 or _G.bit) then missing[#missing + 1] = "bit32" end
    if not (os and os.clock and os.getComputerID) then missing[#missing + 1] = "os.clock/getComputerID" end
    if not (fs and fs.open and fs.exists and fs.list) then missing[#missing + 1] = "fs.open/exists/list" end
    for _, name in ipairs(OPTIONAL) do
        if _G[name] == nil then optional[#optional + 1] = name end
    end
    return #missing == 0, missing, optional
end

function M.compat_setup(node)
    local ok, missing, optional = M.compat_check()
    local ver = "unknown"
    local got, v = pcall(function() return os.version and os.version() end)
    if got and type(v) == "string" then ver = v end
    node.compat = { ok = ok, missing = missing, optional = optional, version = ver }
    node:log("COMPAT ok=%s os=%s missing=%s optional=%s", tostring(ok), ver,
        #missing > 0 and table.concat(missing, ",") or "-",
        #optional > 0 and table.concat(optional, ",") or "-")
    if not ok then
        node:log("COMPAT_UNSUPPORTED the host is missing required APIs: %s", table.concat(missing, ","))
    end
    return ok
end

return M
