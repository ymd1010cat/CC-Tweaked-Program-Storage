local logger = {}
local LOG_PATH = "Main.log"
local DEFAULT_FORMAT = "%Y.%m.%d %H:%M"
function logger.write(tag, message, ...)
    if not tag or not message then
        print("logger.write:tag and message are required")
        return false
    end
    if ... then
        local args = { ... }
        for i = 1, #args do
            message = message .. tostring(args[i])
        end
    end
   local file = fs.open(LOG_PATH, "a")
    if not file then
        print("Failed to open log file: " .. LOG_PATH)
        return false
    end
    local timeStr = os.date(DEFAULT_FORMAT)
    local line = string.format("[%s] %s %s\n", tag, timeStr, message)
    file.write(line)
    file.close()
    return true
end
function logger.info(message, ...)
    return logger.write("info", message, ...)
end
function logger.warn(message, ...)
    return logger.write("warn", message, ...)
end
function logger.error(message, ...)
    return logger.write("error", message, ...)
end
function logger.debug(message, ...)
    return logger.write("debug", message, ...)
end
return logger
