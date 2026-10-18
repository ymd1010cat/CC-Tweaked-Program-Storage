-- marker.lua - the setup marker of this machine
--
-- WHAT THIS IS: the proof that firstboot has finished on THIS computer. startup
-- reads it before it starts the shell; firstboot writes it when the operator has
-- answered its questions. The four paths are the ones the project has always
-- used, so a machine that was set up before this change is still set up, and
-- deploy.py's --clean-firstboot (which erases them so setup runs again) keeps
-- working.
--
-- THERE IS NO SIGNATURE ON IT, AND THAT IS DELIBERATE. This file used to hold a
-- licence: authserver.lua signed "computerId:nonce" with a 512-bit RSA key and
-- license.lua verified it with the matching public key. The gate was removed on
-- 2026-10-17 because the private key shipped inside the same installation as the
-- public one -- anybody holding the install could sign their own licence -- so
-- it never proved anything, while it did put a second server, a second config
-- file and a second failure mode in front of every first boot. What the marker
-- still does is bind the setup to one computer: read() refuses a marker whose
-- computerId is not this computer's, so copying it to another machine does not
-- count.
local marker = {}

local LOCATIONS = {
    "/etc/.configured",
    "/var/lib/.sysmark",
    "/usr/.lib/.boot",
    "/.sysinfo",
}

local function ensure_dir(path)
    local dir = path:match("^(.*)/[^/]+$")
    if not dir or dir == "" then return end
    local acc = ""
    for seg in dir:gmatch("[^/]+") do
        acc = acc .. "/" .. seg
        if not fs.exists(acc) then fs.makeDir(acc) end
    end
end

-- Write the setup marker to all known locations. There is nothing to sign: the
-- table says which computer was set up and when, and that is all read() checks.
function marker.write(data)
    local payload = textutils.serialize({
        computerId = tostring(data and data.computerId or os.getComputerID()),
        setup      = true,
        at         = data and data.at or os.epoch("utc"),
    })
    for _, path in ipairs(LOCATIONS) do
        ensure_dir(path)
        local f = fs.open(path, "w")
        if f then
            f.write(payload)
            f.close()
        end
    end
end

-- Read the first marker written by THIS computer, or nil. A marker copied from
-- another machine is ignored: the setup is bound to the machine it was done on.
function marker.read()
    for _, path in ipairs(LOCATIONS) do
        if fs.exists(path) then
            local f = fs.open(path, "r")
            if f then
                local data = textutils.unserialize(f.readAll())
                f.close()
                if type(data) == "table" and data.computerId and
                   tostring(data.computerId) == tostring(os.getComputerID()) then
                    return data
                end
            end
        end
    end
    return nil
end

-- True when this machine has been set up: the gate startup uses before it starts
-- the shell (and before it hands over to firstboot when it has not).
function marker.done()
    return marker.read() ~= nil
end

-- True if any marker exists at all, this computer's or another one's: deploy's
-- --clean-firstboot only needs to know whether there is something to erase.
function marker.exists()
    for _, path in ipairs(LOCATIONS) do
        if fs.exists(path) then return true end
    end
    return false
end

-- Remove all markers.
function marker.clear()
    for _, path in ipairs(LOCATIONS) do
        if fs.exists(path) then fs.delete(path) end
    end
end

return marker
