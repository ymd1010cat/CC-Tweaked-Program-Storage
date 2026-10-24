--startup.lua
shell.run("clear")

-- Load required modules
local bsod = require("bsod")
local logger = require("logger")

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

-- Helper: update config file, redstone output and play sound
local function applyPower(value)
    local f = io.open("PowerGrid.ini", "w")
    if f then
        f:write(tostring(value) .. "\n")
        f:close()
    end

    if value > 0 then
        redstone.setOutput("back", true)
        redstone.setAnalogOutput("back", value)
    else
        redstone.setOutput("back", false)
        redstone.setAnalogOutput("back", 0)
    end

    local speaker = peripheral.find("speaker")
    if speaker then
        speaker.playSound("create:confirm")
    end
end

-- Read config file
local file = io.open("PowerGrid.ini", "r")
if not file then
    logger.error("Configuration file PowerGrid.ini not found")
    bsod.show({
        error = "FILE_NOT_FOUND",
        file = "PowerGrid.ini",
        title = "This Terminal ran into a problem and need fix.",
        extra = "Configuration file missing."
    })
end

local line = file:read("*line")
file:close()

-- Check empty value
if line == nil or #line == 0 then
    logger.error("PowerGrid.ini is empty")
    bsod.show({
        error = "VALUE_LENGTH_IS_ZERO",
        file = "PowerGrid.ini",
        title = "This Terminal ran into a problem and need fix.",
        extra = "Power value is empty."
    })
end

-- Check type
local power = tonumber(line)
if power == nil then
    logger.error("Invalid power value format: " .. line)
    bsod.show({
        error = "VALUE_TYPE_NOT_CORRECT",
        file = "PowerGrid.ini",
        title = "This Terminal ran into a problem and need fix.",
        extra = "Invalid power value format."
    })
end

-- Check range (allows 0,1,2,3)
if power < 0 or power > 3 then
    logger.error("Power value out of range: " .. power)
    bsod.show({
        error = "INI_VALUE_OUT_RANGE",
        file = "PowerGrid.ini",
        title = "This Terminal ran into a problem and need fix.",
        extra = "Power value must be between 0 and 3."
    })
end

-- Apply initial configuration
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
