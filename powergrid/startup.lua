--startup.lua
shell.run("clear")

-- Load the project libraries through a diagnostic loader: a missing file must
-- end in a readable blue screen (or, when bsod itself is missing, in a readable
-- terminal error) that names every missing library, never in a bare
-- "module 'x' not found" from require.
local function loadLibrary(name)
    if type(require) ~= "function" then
        return nil, "require() is unavailable"
    end
    local ok, mod = pcall(require, name)
    if ok and type(mod) == "table" then return mod end
    return nil, tostring(mod)
end

local bsod = loadLibrary("bsod")
local logger = loadLibrary("logger")
local power_api = loadLibrary("power")

local missingLibraries = {}
if bsod == nil then missingLibraries[#missingLibraries + 1] = "bsod" end
if logger == nil then missingLibraries[#missingLibraries + 1] = "logger" end
if power_api == nil then missingLibraries[#missingLibraries + 1] = "power" end

local function missingLines()
    local lines = {}
    for i = 1, #missingLibraries do
        local name = missingLibraries[i]
        local note = name .. ".lua is not in /"
        if name == "power" then
            note = "power.lua is not in /; the power mode cannot be read or written"
        elseif name == "logger" then
            note = "logger.lua is not in /; log lines are skipped"
        elseif name == "bsod" then
            note = "bsod.lua is not in /; the blue screen is unavailable"
        end
        lines[#lines + 1] = "MISSING_LIBRARY name=" .. name .. " file=" ..
            name .. ".lua: " .. note
    end
    return lines
end

if #missingLibraries > 0 then
    local names = table.concat(missingLibraries, ", ")
    local lines = missingLines()
    -- Log when a logger is available; it may be the library that is missing.
    if logger ~= nil then
        for i = 1, #missingLibraries do
            logger.error("MISSING_LIBRARY name=" .. missingLibraries[i] ..
                " file=" .. missingLibraries[i] .. ".lua")
        end
    end
    if bsod ~= nil then
        local extra = table.concat(lines, "\n")
        if #missingLibraries == 1 then
            extra = extra .. "\n\nPut " .. missingLibraries[1] ..
                ".lua back in / and restart."
        else
            extra = extra .. "\n\nPut these files back in / and restart."
        end
        bsod.show({
            error = "MISSING_LIBRARY",
            file = names,
            title = "Missing library",
            extra = extra
        })
        -- In the real bsod.show this line is unreachable (it raises by design);
        -- it keeps the failure greppable if a custom bsod ever returns.
        error("MISSING_LIBRARY " .. names, 0)
    else
        -- bsod itself is missing: print a readable error on the terminal and
        -- stop. The message always carries MISSING_LIBRARY for grep.
        local screen = term
        pcall(function()
            screen.setBackgroundColor(colors.blue)
            screen.setTextColor(colors.white)
            screen.clear()
            screen.setCursorPos(1, 1)
        end)
        pcall(screen.write, "Missing library\n")
        pcall(screen.write, "----------------\n")
        for i = 1, #lines do
            pcall(screen.write, lines[i] .. "\n")
        end
        pcall(screen.write, "\nThe Power Grid Controller cannot start.\n")
        pcall(screen.write, "Put the missing file(s) back in / and restart.\n")
        error("MISSING_LIBRARY " .. names, 0)
    end
end

-- Operation feedback display delay (seconds)
local FEEDBACK_DELAY = 1

-- Maximum characters per line for printer (CC:Tweaked default is about 40, adjust as needed)
local MAX_LINE_WIDTH = 40

-- Version information
local VERSION_INFO = {
    title = "Power Grid Controller v2.1",
    subtitle = "Example Power Station",
    details = {
        "Control Terminal #1",
        "Built with CC:Tweaked"
    }
}

-- Helper: wrap long text by max width, returns array of lines
local function wrapText(text, maxWidth)
    local lines = {}
    while #text > maxWidth do
        local cut = maxWidth
        for i = maxWidth, 1, -1 do
            local c = text:sub(i, i)
            if c == " " or c == "," or c == "." or c == "-" or c == "_" or c == ":" then
                cut = i
                break
            end
        end
        if cut == maxWidth and text:sub(cut, cut) ~= " " then
            cut = maxWidth
        end
        table.insert(lines, text:sub(1, cut))
        text = text:sub(cut + 1)
    end
    if #text > 0 then
        table.insert(lines, text)
    end
    return lines
end

-- Resolve the mode to run with. A broken/missing config never stops the
-- controller: power.lua hands back the default mode (1 = Main Grid) plus the
-- reason, we log one CONFIG_ERROR line and keep running.
local boot = power_api.boot()
local power = boot.mode
if not boot.ok then
    logger.error(power_api.errorLine(boot.code, { message = boot.message }))
end

-- Apply a mode and drive the redstone/speaker. Only an unwritable config file is
-- fatal (blue screen), because then the controller can no longer record its
-- state; the redstone output itself is still driven.
local function applyPower(value)
    local ok, err = power_api.apply(value)
    if ok ~= nil then return ok end
    local message, extra = power_api.describe("CONFIG_WRITE_FAILED")
    logger.error(power_api.errorLine("CONFIG_WRITE_FAILED", {
        fallback = "none",
        message = message
    }))
    bsod.show({
        error = "CONFIG_WRITE_FAILED",
        file = "PowerGrid.ini",
        title = "This Terminal ran into a problem and need fix.",
        extra = extra
    })
    return nil, err
end

-- Apply initial configuration (config write + redstone + speaker chirp)
applyPower(power)
logger.info("Power Grid initialized with value " .. power)

-- Main command loop (no exit function)
local function showMenu()
    shell.run("clear")
    print("Example Power Station")
    print("Power Grid Control Terminal #1")
    print("----------------------")
    print("Available Commands:")
    print("----------------------")
    if power == 1 then
        print("1 Switch To Main Grid(Currently In Use)")
    else
        print("1 Switch To Main Grid")
    end
    if power == 2 then
        print("2 Switch To Backup Battery(Currently In Use)")
    else
        print("2 Switch To Backup Battery")
    end
    if power == 3 then
        print("3 Switch To External Grid(Currently In Use)")
    else
        print("3 Switch To External Grid")
    end
    if power > 0 then
        print("4 Disable Power Grid")
    else
        print("4 Disable Power Grid(Currently In Use)")
    end
    print("5 Print Log ")
    print("Press ESC TO EXIT")   -- Just UI decoration
    print("----------------------")
    print("ENTER COMMAND:")
end

while true do
    showMenu()
    local input = io.read()
    if not input then break end
    input = input:gsub("^%s+", ""):gsub("%s+$", "")

    if input == "" then
        -- Ignore empty input
    elseif input == "1" then
        if power ~= 1 then
            local old = power
            power = 1
            applyPower(power)
            logger.info("Switched from " .. old .. " to Main Grid (mode 1)")
            print("Switched to Main Grid.")
            os.sleep(FEEDBACK_DELAY)
        else
            logger.info("Attempted to switch to Main Grid but already in mode 1")
            print("Already on Main Grid.")
            os.sleep(FEEDBACK_DELAY)
        end
    elseif input == "2" then
        if power ~= 2 then
            local old = power
            power = 2
            applyPower(power)
            logger.info("Switched from " .. old .. " to Backup Battery (mode 2)")
            print("Switched to Backup Battery.")
            os.sleep(FEEDBACK_DELAY)
        else
            logger.info("Attempted to switch to Backup Battery but already in mode 2")
            print("Already on Backup Battery.")
            os.sleep(FEEDBACK_DELAY)
        end
    elseif input == "3" then
        if power ~= 3 then
            local old = power
            power = 3
            applyPower(power)
            logger.info("Switched from " .. old .. " to External Grid (mode 3)")
            print("Switched to External Grid.")
            os.sleep(FEEDBACK_DELAY)
        else
            logger.info("Attempted to switch to External Grid but already in mode 3")
            print("Already on External Grid.")
            os.sleep(FEEDBACK_DELAY)
        end
    elseif input == "4" then
        if power ~= 0 then
            local old = power
            power = 0
            applyPower(power)
            logger.info("Switched from " .. old .. " to Disabled (mode 0)")
            print("Power Grid disabled.")
            os.sleep(FEEDBACK_DELAY)
        else
            logger.info("Attempted to disable Power Grid but already disabled (mode 0)")
            print("Power Grid already disabled.")
            os.sleep(FEEDBACK_DELAY)
        end
    elseif input:lower() == "5" then
        -- Print log function (auto word wrap + page break)
        local printer = peripheral.find("printer")
        if not printer then
            print("Printer not found. Please attach a printer.")
            os.sleep(FEEDBACK_DELAY)
        else
            -- Check paper
            if not printer.getPaperLevel() or printer.getPaperLevel() == 0 then
                print("Printer is out of paper.")
                os.sleep(FEEDBACK_DELAY)
            else
                -- Check ink
                local inkLevel = printer.getInkLevel()
                if not inkLevel or inkLevel == 0 then
                    print("Printer is out of ink. Please refill.")
                    os.sleep(FEEDBACK_DELAY)
                else
                    local logFile = fs.open("Main.log", "r")
                    if not logFile then
                        print("Log file Main.log not found.")
                        os.sleep(FEEDBACK_DELAY)
                    else
                        -- Maximum lines per page (reserve margins)
                        local MAX_LINES_PER_PAGE = 60
                        local totalLines = 0
                        local totalPages = 0
                        local currentLine = 0   -- Lines printed on current page

                        -- Start first page
                        printer.newPage()
                        totalPages = 1

                        local logLine = logFile.readLine()
                        while logLine do
                            -- Wrap this line
                            local wrapped = wrapText(logLine, MAX_LINE_WIDTH)
                            for _, seg in ipairs(wrapped) do
                                -- Check if current page is full
                                if currentLine >= MAX_LINES_PER_PAGE then
                                    printer.endPage()
                                    printer.newPage()
                                    totalPages = totalPages + 1
                                    currentLine = 0
                                end
                                -- Write current segment
                                printer.write(seg)
                                totalLines = totalLines + 1
                                currentLine = currentLine + 1
                                local x, y = printer.getCursorPos()
                                printer.setCursorPos(1, y + 1)
                            end
                            -- Read next line
                            logLine = logFile.readLine()
                        end

                        logFile.close()
                        printer.endPage()
                        print("Log printed successfully (" .. totalLines .. " lines, " .. totalPages .. " page(s)).")
                        os.sleep(FEEDBACK_DELAY)
                    end
                end
            end
        end
    elseif input:lower() == "version" then
        -- Display version information
        print(VERSION_INFO.title)
        print(VERSION_INFO.subtitle)
        for _, detail in ipairs(VERSION_INFO.details) do
            print(detail)
        end
        print("Press any key to continue...")
        os.pullEvent("key")
    else
        print("Invalid command. Please try again.")
        os.sleep(FEEDBACK_DELAY)
    end
end
