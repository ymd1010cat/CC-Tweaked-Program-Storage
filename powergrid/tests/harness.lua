-- harness.lua - assertion helper for the powergrid offline suite.
--
-- Same shape as the itn-pass / pylib harnesses: every result line is written to
-- stdout with term.write (not print, so a suite can swap _G.print without
-- losing the report) and appended to /logs/suite.log, which is what
-- run-tests.ps1 reads - CraftOS-PC buffers redirected stdout, so the in-computer
-- log file is the reliable copy.

local H = {}
H.pass = 0
H.fail = 0
H.groups = 0
H.current = "?"
H.log = nil

local function emit(line)
    if H.log then
        H.log.write(line .. "\n")
        H.log.flush()
    end
    term.write(line .. "\n")
end
H.emit = emit

function H.note(line)
    emit("NOTE " .. tostring(line))
end

function H.openLog(path)
    if not fs.exists("/logs") then fs.makeDir("/logs") end
    H.log = fs.open(path, "w")
    if not H.log then error("cannot open log: " .. path) end
end

function H.group(name)
    H.current = name
    H.groups = H.groups + 1
    emit("GROUP " .. name)
end

function H.ok(cond, name, detail)
    if cond then
        H.pass = H.pass + 1
    else
        H.fail = H.fail + 1
        local text = tostring(detail or ""):gsub("[\r\n]+", " | ")
        emit("TEST_FAIL " .. H.current .. " :: " .. name .. " :: " .. text)
    end
    return cond and true or false
end

function H.eq(got, want, name)
    return H.ok(got == want, name,
        "want=" .. tostring(want) .. " got=" .. tostring(got))
end

function H.ne(got, want, name)
    return H.ok(got ~= want, name,
        "did not want=" .. tostring(want) .. " got=" .. tostring(got))
end

function H.num(got, want, name)
    local ok = type(got) == "number" and math.abs(got - want) < 1e-6
    return H.ok(ok, name, "want=" .. tostring(want) .. " got=" .. tostring(got))
end

function H.isType(got, want, name)
    return H.ok(type(got) == want, name,
        "want type " .. want .. " got " .. type(got))
end

-- Failure details stay short even when the haystack is a whole source file:
-- report the byte length plus up to three matching lines.
local function sourceHint(hay, needle)
    if type(hay) ~= "string" then return "not a string" end
    if #hay <= 240 then return hay end
    local hits = {}
    for line in hay:gmatch("[^\n]+") do
        if line:find(needle, 1, true) then
            hits[#hits + 1] = line:sub(1, 160)
        end
        if #hits >= 3 then break end
    end
    if #hits == 0 then
        return string.format("<%d byte string, no line contains the needle>", #hay)
    end
    return table.concat(hits, " || ")
end

function H.contains(hay, needle, name)
    local ok = type(hay) == "string" and hay:find(needle, 1, true) ~= nil
    return H.ok(ok, name,
        "missing <" .. tostring(needle) .. "> in " .. sourceHint(hay, needle))
end

function H.lacks(hay, needle, name)
    local found = type(hay) == "string" and hay:find(needle, 1, true) ~= nil
    return H.ok(not found, name,
        "unexpected <" .. tostring(needle) .. "> in " .. sourceHint(hay, needle))
end

function H.errText(err)
    if type(err) == "table" then
        local ok, text = pcall(tostring, err)
        if ok and type(text) == "string" then return text end
    end
    return tostring(err)
end

function H.summary()
    emit("OFFLINE_PASS " .. H.pass)
    emit("OFFLINE_FAIL " .. H.fail)
    emit("OFFLINE_GROUPS " .. H.groups)
    emit("TEST_DONE")
end

return H
