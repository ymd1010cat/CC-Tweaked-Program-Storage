-- pyrepl.lua - Interactive Python REPL for pythonlib
-- Usage: pythonlib pyrepl.lua

local py = require("pythonlib")

-- ============================================================
-- Interpreter setup
-- ============================================================
local interp = py.Interpreter.new()
local builtins = interp:getBuiltins()
for k, v in pairs(builtins) do
    interp.scopes[1][k] = v
end

-- Auto-save last result as `_`
local lastResult = nil

-- ============================================================
-- Helpers
-- ============================================================
local function writePrompt(p)
    term.setTextColor(colors.lime)
    term.write(p)
    term.setTextColor(colors.white)
end

local function printError(msg)
    term.setTextColor(colors.red)
    print(msg)
    term.setTextColor(colors.white)
end

local function printResult(v)
    if v == nil then return end
    local s = py.pyStr and py.pyStr(v, interp)
    if not s then
        local strFn = interp:lookup("str")
        if strFn then s = strFn(v) else s = tostring(v) end
    end
    term.setTextColor(colors.yellow)
    print(s)
    term.setTextColor(colors.white)
end

-- Determine if a line opens a block (ends with ':')
local function opensBlock(line)
    local trimmed = line:gsub("%s+$", "")
    -- Match `...:` at end, but ignore dict literals `{"a": 1}`
    if trimmed:sub(-1) ~= ":" then return false end
    -- Count braces to make sure it's not inside a dict literal
    local depth = 0
    local inStr = nil
    local i = 1
    while i <= #trimmed do
        local c = trimmed:sub(i, i)
        if inStr then
            if c == "\\" then i = i + 1
            elseif c == inStr then inStr = nil end
        else
            if c == '"' or c == "'" then inStr = c
            elseif c == "(" or c == "[" or c == "{" then depth = depth + 1
            elseif c == ")" or c == "]" or c == "}" then depth = depth - 1 end
        end
        i = i + 1
    end
    return depth == 0
end

local function isBlank(line)
    return line:match("^%s*$") ~= nil
end

local function hasOpenBracket(src)
    local depth = 0
    local inStr = nil
    local i = 1
    while i <= #src do
        local c = src:sub(i, i)
        if inStr then
            if c == "\\" then i = i + 1
            elseif c == inStr then inStr = nil end
        else
            if c == '"' or c == "'" then inStr = c
            elseif c == "(" or c == "[" or c == "{" then depth = depth + 1
            elseif c == ")" or c == "]" or c == "}" then depth = depth - 1 end
        end
        i = i + 1
    end
    return depth > 0
end

-- ============================================================
-- Eval a completed chunk
-- ============================================================
local function evalChunk(src)
    -- Try as a single expression first
    local firstWord = src:match("^%s*(%a+)")
    local stmtKeywords = {
        ["if"]=true, ["while"]=true, ["for"]=true, ["def"]=true,
        ["class"]=true, ["return"]=true, ["pass"]=true, ["break"]=true,
        ["continue"]=true, ["import"]=true, ["from"]=true, ["try"]=true,
        ["raise"]=true, ["with"]=true, ["global"]=true, ["nonlocal"]=true,
        ["del"]=true, ["assert"]=true, ["yield"]=true, ["match"]=true,
        ["async"]=true, ["type"]=true,
    }
    local isExpr = not (firstWord and stmtKeywords[firstWord])
    if isExpr then
        local lexer = py.Lexer.new(src)
        local tokens = lexer:tokenize()
        local parser = py.Parser.new(tokens)
        local ok, ast = pcall(function() return parser:parse() end)
        if ok and ast and #ast.body == 1 and ast.body[1].type == "ExprStmt" then
            local ok2, result = pcall(function()
                return interp:eval(ast.body[1].expr)
            end)
            if ok2 then
                lastResult = result
                interp:assign("_", result)
                printResult(result)
                return
            else
                local e = result
                if type(e) == "table" and e.type then
                    printError(e.type .. ": " .. tostring(e.value))
                else
                    printError(tostring(e))
                end
                return
            end
        end
    end

    -- Execute as a full program
    local ok, err = pcall(function()
        local lexer = py.Lexer.new(src)
        local tokens = lexer:tokenize()
        local parser = py.Parser.new(tokens)
        local ast = parser:parse()
        for _, stmt in ipairs(ast.body) do
            interp:execStmt(stmt)
        end
    end)
    if not ok then
        if type(err) == "table" and err.type then
            printError(err.type .. ": " .. tostring(err.value))
        else
            printError(tostring(err))
        end
    end
end

-- ============================================================
-- REPL command handling
-- ============================================================
local function handleCommand(line)
    local cmd = line:match("^%%(%a+)")
    if cmd == "help" then
        print("REPL commands:")
        print("  %help          show this help")
        print("  %exit / %quit  exit the REPL")
        print("  %reset         clear all variables")
        print("  _              holds the last expression result")
        print("  exit()         also exits")
    elseif cmd == "exit" or cmd == "quit" then
        return "exit"
    elseif cmd == "reset" then
        interp = py.Interpreter.new()
        local b = interp:getBuiltins()
        for k, v in pairs(b) do interp.scopes[1][k] = v end
        lastResult = nil
        print("(session reset)")
    else
        printError("Unknown command: " .. cmd)
    end
    return nil
end

-- ============================================================
-- Main loop
-- ============================================================
print("Python REPL for pythonlib")
print("Type %help for commands, %exit to quit.")
print()

local buffer = {}

while true do
    if #buffer == 0 then
        writePrompt(">>> ")
    else
        writePrompt("... ")
    end

    local line = read()

    if line == nil then
        print("")
        break
    end

    -- Commands only when not in a block
    if #buffer == 0 and line:match("^%%") then
        local action = handleCommand(line)
        if action == "exit" then break end
    elseif #buffer == 0 and (line == "exit()" or line == "quit()") then
        break
    elseif #buffer > 0 then
        if isBlank(line) then
            local src = table.concat(buffer, "\n")
            buffer = {}
            evalChunk(src)
        else
            table.insert(buffer, line)
        end
    else
        if opensBlock(line) or hasOpenBracket(line) then
            table.insert(buffer, line)
        else
            evalChunk(line)
        end
    end
end

print("Bye.")
