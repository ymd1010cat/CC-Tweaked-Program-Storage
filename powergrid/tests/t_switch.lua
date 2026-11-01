-- t_switch.lua - the tiny switch.lua front end for power.lua.
--
-- switch.lua is the "physical watchdog hook": anything that can run a shell
-- command (a redstone-triggered computer, a player, a timer) can call
-- `switch <mode>` and the controller's power.lua does the rest.

local H = ...

local S = H.switch
local P = H.power

local function readText(path)
    local f = fs.open(path, "r")
    if not f then return nil end
    local text = f.readAll()
    f.close()
    return text
end

local function writeText(path, text)
    local f = fs.open(path, "w")
    f.write(text)
    f.close()
end

local function newRedstone()
    local rs = { calls = {} }
    function rs.setOutput(side, value)
        rs.calls[#rs.calls + 1] = { "setOutput", side, value }
        return true
    end
    function rs.setAnalogOutput(side, value)
        rs.calls[#rs.calls + 1] = { "setAnalogOutput", side, value }
        return true
    end
    return rs
end

local function newPeripheral()
    local p = { sounds = {} }
    function p.find(kind)
        if kind == "speaker" then
            return { playSound = function(name)
                p.sounds[#p.sounds + 1] = name
            end }
        end
        return nil
    end
    return p
end

-- Argument parsing -----------------------------------------------------------

H.group("switch-parse")
H.eq(S.parseArgs(nil), nil, "no argument is an error")
H.eq(select(2, S.parseArgs(nil)), "usage: switch <0-3>", "the usage line is the error")
H.num(S.parseArgs({ "0" }), 0, "mode 0 is accepted")
H.num(S.parseArgs({ "1" }), 1, "mode 1 is accepted")
H.num(S.parseArgs({ "2" }), 2, "mode 2 is accepted")
H.num(S.parseArgs({ "3" }), 3, "mode 3 is accepted")
H.eq(S.parseArgs({ "4" }), nil, "mode 4 is rejected")
H.contains(select(2, S.parseArgs({ "4" })), "0-3", "the range error names the range")
H.eq(S.parseArgs({ "-1" }), nil, "a negative mode is rejected")
H.eq(S.parseArgs({ "1.5" }), nil, "a fractional mode is rejected")
H.eq(S.parseArgs({ "abc" }), nil, "text is rejected")
H.contains(select(2, S.parseArgs({ "abc" })), "must be a number",
    "the text error is readable")

-- Running the switch ---------------------------------------------------------

H.group("switch-run")
local modePath = "/tests/switch_mode.ini"
writeText(modePath, "mode=1\ncustom.extra=7\n")
local rs = newRedstone()
local periph = newPeripheral()
local powerOpts = { path = modePath, redstone = rs, peripheral = periph }
local okMode, runErr = S.run({ "2" }, { power = P, powerOpts = powerOpts })
H.eq(runErr, nil, "a valid switch returns no error")
H.num(okMode, 2, "the switch reports the applied mode")
H.eq(readText(modePath), "mode=2\ncustom.extra=7\n",
    "the mode line is rewritten, the unknown key is kept")
H.eq(#rs.calls, 2, "the redstone output is driven")
H.eq(rs.calls[1][1], "setOutput", "setOutput first")
H.eq(rs.calls[1][3], true, "the output goes on")
H.num(rs.calls[2][3], 2, "the analog level is the new mode")
H.eq(periph.sounds[1], "create:confirm", "the speaker chirped")

writeText("/tests/switch_legacy.ini", "1\n")
S.run({ "3" }, { power = P, powerOpts = {
    path = "/tests/switch_legacy.ini", redstone = newRedstone(),
    peripheral = newPeripheral() } })
H.eq(readText("/tests/switch_legacy.ini"), "3\n",
    "a legacy file keeps the bare number format")

-- Failure paths --------------------------------------------------------------

H.group("switch-fail")
local noPowerMode, noPowerErr = S.run({ "2" }, { power = false })
H.eq(noPowerMode, nil, "a missing power module is an error")
H.contains(noPowerErr, "MISSING_LIBRARY name=power",
    "the missing library token is used")
H.contains(noPowerErr, "cannot switch the grid", "the consequence is explained")

local failedMode, failedErr = S.run({ "2" }, { power = {
    apply = function() return nil, "CONFIG_WRITE_FAILED" end,
} })
H.eq(failedMode, nil, "a failed write is reported")
H.contains(failedErr, "CONFIG_WRITE_FAILED", "the write failure code is used")
H.contains(failedErr, "redstone output was still driven",
    "the caller is told the output was driven anyway")

local badMode, badErr = S.run({ "9" }, { power = P })
H.eq(badMode, nil, "an out of range argument does not touch power.lua")
H.contains(badErr, "0-3", "the range error is reported")

-- Console line ---------------------------------------------------------------

H.group("switch-report")
H.eq(S.report(2, nil), "Power mode set to 2.", "the success line is readable")
H.eq(S.report(nil, "usage: switch <0-3>"), "switch: usage: switch <0-3>",
    "the error line is readable")

-- Module resolution and source pinning ---------------------------------------

H.group("switch-source")
local loaded = S.loadPower()
H.isType(loaded, "table", "loadPower finds the staged power.lua")
H.isType(loaded.apply, "function", "the loaded module has apply")
H.eq(loaded.VERSION, "1.3", "the loaded module is the current power.lua")

local src = H.readAll("/switch.lua") or ""
H.contains(src, "power.apply(mode", "switch delegates the write to power.lua")
H.contains(src, "MISSING_LIBRARY name=power", "switch reports a missing power.lua")
H.contains(src, "CONFIG_WRITE_FAILED", "switch reports a failed write")
H.lacks(src, 'require("watchdog")', "switch loads no watchdog module")
H.lacks(src, 'dofile("/watchdog', "switch loads no watchdog module by path")
H.lacks(src, "M.WATCHDOG_KEYS", "switch carries no watchdog config")
