-- CardKey terminal menu: the only action is "Write Disk".
-- Deploy path: /system/ui.lua
-- Not a module: /system/kernel.lua calls this chunk as
--     loadfile("/system/ui.lua")(token, session, sandbox, user)
-- The chunk always returns to the card key prompt; there is no exit path.
--
-- In free mode (/cardkey_mode.lua says "free") the kernel hands in a guest
-- user with user.free == true: the menu writes with an empty code and words its
-- result screen without a card key story. Every pass-mode line below stays
-- exactly as it was.

local token, session, sandbox, user = ...
local client = dofile("/auth/cardkey_client.lua")

local free = type(user) == "table" and user.free == true

term.clear()
term.setCursorPos(1, 1)
print("Secure System")
print("")
if free then
    print("Free mode: no card key needed.")
    print("")
end
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
    if free then
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
    if free then
        print("The disk was not written.")
    else
        print("Your card key was NOT charged.")
        print("No use was consumed.")
    end
    print("")
    print("Logging out...")
    sleep(3)
end
