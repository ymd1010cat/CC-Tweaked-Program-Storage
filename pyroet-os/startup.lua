--[[- /startup.lua -- the only file CraftOS runs at boot.

Pyroet OS keeps its whole image in one tree, `/system/`. This stub stays in the
computer root and is deliberately not part of the update set: it is small enough
that a partial update cannot corrupt it, and its only job is to load
`/system/startup.lua` and call it. When that fails it says so in ASCII and leaves
the ROM shell in charge instead of booting into nothing (a reboot loop cannot
repair a broken byte; see DECISIONS.md 13).

No non-ASCII bytes in this file.
]]

local PATH = "/system/startup.lua"
local HINT = "shell only. Run recovery/flash.lua to reflash /system."

local function say(line)
    print("Pyroet OS: " .. tostring(line))
end

local ok, chunk, err = pcall(loadfile, PATH)
if not ok or type(chunk) ~= "function" then
    say("cannot load " .. PATH)
    say(tostring(err or chunk):gsub("[\r\n]+", " "):sub(1, 60))
    say(HINT)
    return
end

local ran, why = pcall(chunk)
if not ran then
    say("startup failed")
    say(tostring(why):gsub("[\r\n]+", " "):sub(1, 60))
    say(HINT)
end
