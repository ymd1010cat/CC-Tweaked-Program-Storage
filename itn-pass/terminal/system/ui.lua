-- ITN-Pass terminal menu: the only action is "Write Disk".
-- Deploy path: /system/ui.lua
-- Not a module: /system/kernel.lua calls this chunk as
--     loadfile("/system/ui.lua")(token, session, sandbox, user)
-- The chunk always returns to the ITN-Pass prompt; there is no exit path.
--
-- In free mode the kernel hands over a synthetic guest user ("free = true",
-- empty code) and the station writes the disk without a card key. The screen
-- must not talk about a card key then, so both the menu and the result page
-- branch on user.free / info.free.

local token, session, sandbox, user = ...
local client = dofile("/auth/itnpass_client.lua")

local FREE = type(user) == "table" and user.free == true

term.clear()
term.setCursorPos(1, 1)
print("ITN-Pass Disk Writer")
if FREE then
    print("")
    print("Free mode: no card key needed.")
end
print("")
print("1. Write Disk")
print("0. Cancel")
print("")
write("Select: ")
local choice = read()

if choice ~= "1" then
    return
end

print("Writing disk...")
print("(the server is copying the payload)")
print("")

local ok, info, detail = client.write(user.code)
if ok then
    if info.free == true then
        print("[OK] Disk written (free mode).")
        print("")
        print("No card key was charged.")
    elseif info.charged == false then
        print("[OK] Disk written.")
        print("")
        print("[Warning] Use was NOT charged:")
        print("the server could not confirm it.")
    else
        print("[OK] Disk written and key charged.")
    end
    print("")
    print("Files: " .. tostring(info.files or 0))
    if (info.dirs or 0) > 0 then
        print("Dirs:  " .. tostring(info.dirs))
    end
    print("Bytes: " .. tostring(info.bytes or 0))
    print("")
    if info.uses_left ~= nil then
        print("Uses left on this key: " .. tostring(info.uses_left))
    end
    print("")
    print("Logging out...")
    sleep(3)
else
    print("[Failed] " .. tostring(info))
    if detail ~= nil and detail ~= "" then
        print(tostring(detail))
    end
    print("")
    if FREE then
        print("No card key was used.")
        print("The disk was not written.")
    else
        print("Your card key was NOT charged.")
        print("No use was consumed.")
    end
    print("")
    print("Logging out...")
    sleep(3)
end
