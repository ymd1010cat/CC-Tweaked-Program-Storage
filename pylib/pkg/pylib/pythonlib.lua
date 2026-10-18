-- pythonlib.lua - Python subset interpreter
-- Compatible with: Lua 5.1, Lua 5.2, Lua 5.3+, CC:Tweaked
-- ============================================================
-- 0. COMPATIBILITY LAYER (must be first)
-- ============================================================

local IS_CC = (type(fs) == "table" and type(fs.open) == "function"
               and type(term) == "table")

if not IS_CC then
    -- ---------- fs shim ----------
    fs = {}
    function fs.exists(path)
        local f = io.open(path, "r")
        if f then f:close(); return true end
        if fs.isDir(path) then return true end
        return false
    end
    function fs.isDir(path)
        local ok = os.execute("test -d '" .. path .. "' 2>/dev/null")
        return ok == 0 or ok == true
    end
    function fs.list(path)
        local result = {}
        local p = io.popen("ls -1 '" .. path .. "' 2>/dev/null")
        if p then
            for line in p:lines() do table.insert(result, line) end
            p:close()
        end
        return result
    end
    function fs.combine(a, b)
        if a == "" then return b end
        if a:sub(-1) == "/" then return a .. b end
        return a .. "/" .. b
    end
    function fs.open(path, mode)
        local f = io.open(path, mode)
        if not f then return nil end
        return {
            readAll = function() return f:read("*all") end,
            readLine = function() return f:read("*line") end,
            read = function(n)
                if n == nil then return f:read(1) end
                return f:read(n)
            end,
            write = function(s) f:write(s) end,
            close = function() f:close() end,
        }
    end
    function fs.makeDir(path) os.execute("mkdir -p '" .. path .. "'") end
    function fs.delete(path) os.remove(path) end

    -- ---------- textutils shim ----------
    textutils = {}
    local function _ser(x)
        local t = type(x)
        if t == "number" or t == "boolean" then return tostring(x) end
        if t == "string" then return string.format("%q", x) end
        if t == "nil" then return "nil" end
        if t == "table" then
            local parts = {}
            for k, val in pairs(x) do
                parts[#parts+1] = "[" .. _ser(k) .. "]=" .. _ser(val)
            end
            return "{" .. table.concat(parts, ",") .. "}"
        end
        return "nil"
    end
    function textutils.serialize(v) return _ser(v) end
    function textutils.unserialize(s)
        local f = loadstring("return " .. s)
        if not f then return nil end
        local ok, v = pcall(f)
        if ok then return v end
        return nil
    end
    function textutils.serializeJSON(v)
        return textutils.serialize(v)
    end
    function textutils.unserializeJSON(s)
        return textutils.unserialize(s)
    end

    -- ---------- os shim ----------
    if not os.epoch then
        os.epoch = function() return math.floor(os.time() * 1000) end
    end
    if not os.sleep then
        os.sleep = function(sec)
            local t0 = os.clock()
            while os.clock() - t0 < sec do end
        end
    end

    -- ---------- term shim ----------
    term = {}
    function term.getSize() return 80, 24 end
    function term.clear() end
    function term.setCursorPos() end
    function term.write(s) io.write(s) end
    function term.setTextColor() end
    function term.setBackgroundColor() end
    function term.getTextColor() return 1 end
    function term.getBackgroundColor() return 32768 end
    function term.current() return term end

    -- ---------- colors ----------
    colors = {
        white=1, orange=2, magenta=4, lightBlue=8,
        yellow=16, lime=32, pink=64, gray=128,
        lightGray=256, cyan=512, purple=1024,
        blue=2048, brown=4096, green=8192,
        red=16384, black=32768,
    }

    -- ---------- read/write shims ----------
    function read(prompt)
        if prompt then io.write(prompt) end
        return io.read()
    end
    function write(s) io.write(s) end
end

-- ---------- bit32 shim ----------
if not bit32 then
    bit32 = {}
    function bit32.band(a, b)
        local r, m = 0, 1
        a, b = math.floor(a), math.floor(b)
        while a > 0 and b > 0 do
            if a % 2 == 1 and b % 2 == 1 then r = r + m end
            a = math.floor(a / 2); b = math.floor(b / 2); m = m * 2
        end
        return r
    end
    function bit32.bor(a, b)
        local r, m = 0, 1
        a, b = math.floor(a), math.floor(b)
        while a > 0 or b > 0 do
            if a % 2 == 1 or b % 2 == 1 then r = r + m end
            a = math.floor(a / 2); b = math.floor(b / 2); m = m * 2
        end
        return r
    end
    function bit32.bxor(a, b)
        local r, m = 0, 1
        a, b = math.floor(a), math.floor(b)
        while a > 0 or b > 0 do
            if a % 2 ~= b % 2 then r = r + m end
            a = math.floor(a / 2); b = math.floor(b / 2); m = m * 2
        end
        return r
    end
    function bit32.lshift(a, n) return math.floor(a * (2 ^ n)) end
    function bit32.rshift(a, n) return math.floor(a / (2 ^ n)) end
end

local unpack = unpack or table.unpack
local py = {}

-- ============================================================
-- 1. MODULE SYSTEM
-- ============================================================

local MODULE_CACHE = {}
local PYLIB_PATH = "/pylib"

local BUILTIN_MODULES = nil
local function getBuiltinModules()
    if BUILTIN_MODULES then return BUILTIN_MODULES end
    BUILTIN_MODULES = {
        ["math"] = {__pytype="module", __name="math", __scope={
            pi=math.pi, e=2.718281828459045,
            sqrt=math.sqrt, sin=math.sin, cos=math.cos, tan=math.tan,
            asin=math.asin, acos=math.acos, atan=math.atan,
            floor=math.floor, ceil=math.ceil, abs=math.abs,
            log=math.log, exp=math.exp, pow=function(a,b) return a^b end,
            max=math.max, min=math.min,
        }},
        ["random"] = {__pytype="module", __name="random", __scope={
            random=function() return math.random() end,
            randint=function(a,b) return math.random(a,b) end,
            choice=function(l) return l[math.random(#l)] end,
            seed=function() end,
        }},
        ["time"] = {__pytype="module", __name="time", __scope={
            sleep=function(s) os.sleep(s) end,
            time=function() return os.epoch("utc")/1000 end,
        }},
        ["os"] = {__pytype="module", __name="os", __scope={
            getcwd=function() return "/" end,
            listdir=function(p) return fs.list(p or "/") end,
        }},
    }
    return BUILTIN_MODULES
end

-- ============================================================
-- 2. EXCEPTION HELPERS
-- ============================================================

local function makeException(excType, value)
    return {__pyexception = true, type = excType, value = value}
end
local function isException(x)
    return type(x) == "table" and x.__pyexception == true
end
local function wrapError(err)
    if isException(err) then return err end
    if type(err) == "table"
       and (err.__return or err.__break or err.__continue) then
        return err
    end
    return makeException("RuntimeError", tostring(err))
end
local function excStr(e)
    if not isException(e) then return tostring(e) end
    if e.value == nil or e.value == "" then return e.type end
    return e.type .. ": " .. tostring(e.value)
end

local function containsYield(node)
    if type(node) ~= "table" then return false end
    if node.type == "Yield" or node.type == "YieldFrom" then return true end
    if node.type == "Def" or node.type == "Lambda" then return false end
    for _, v in pairs(node) do
        if type(v) == "table" and containsYield(v) then return true end
    end
    return false
end

-- ============================================================
-- 3. LEXER
-- ============================================================

local KEYWORDS = {
    ["and"]=true, ["or"]=true, ["not"]=true, ["if"]=true, ["elif"]=true,
    ["else"]=true, ["while"]=true, ["for"]=true, ["in"]=true, ["def"]=true,
    ["return"]=true, ["pass"]=true, ["break"]=true, ["continue"]=true,
    ["True"]=true, ["False"]=true, ["None"]=true, ["import"]=true,
    ["from"]=true, ["as"]=true, ["lambda"]=true, ["global"]=true,
    ["is"]=true, ["del"]=true, ["raise"]=true, ["assert"]=true,
    ["try"]=true, ["except"]=true, ["finally"]=true,
    ["class"]=true, ["nonlocal"]=true, ["with"]=true, ["yield"]=true,
    ["async"]=true, ["await"]=true,
}

local function isDigit(c) return c >= "0" and c <= "9" end
local function isAlpha(c)
    return (c >= "a" and c <= "z") or (c >= "A" and c <= "Z") or c == "_"
end
local function isAlnum(c) return isAlpha(c) or isDigit(c) end

local Lexer = {}
Lexer.__index = Lexer

function Lexer.new(src)
    return setmetatable({
        src = src:gsub("\r\n", "\n"):gsub("\r", "\n"),
        pos = 1, line = 1, indentStack = {0}, tokens = {}, parenDepth = 0
    }, Lexer)
end
function Lexer:peek(o)
    o = o or 0
    local p = self.pos + o
    if p > #self.src then return nil end
    return self.src:sub(p, p)
end
function Lexer:advance()
    local c = self.src:sub(self.pos, self.pos)
    self.pos = self.pos + 1
    if c == "\n" then self.line = self.line + 1 end
    return c
end
function Lexer:error(m)
    error(string.format("Syntax error at line %d: %s", self.line, m))
end
function Lexer:addToken(t, v)
    table.insert(self.tokens, {type=t, value=v, line=self.line})
end

function Lexer:readString(q)
    local ch = {}
    while true do
        local c = self:peek()
        if c == nil then self:error("Unterminated string") end
        if c == q then self:advance(); break end
        if c == "\\" then
            self:advance()
            local e = self:advance()
            if e=="n" then table.insert(ch,"\n")
            elseif e=="t" then table.insert(ch,"\t")
            elseif e=="r" then table.insert(ch,"\r")
            elseif e=="\\" then table.insert(ch,"\\")
            elseif e=="'" then table.insert(ch,"'")
            elseif e=='"' then table.insert(ch,'"')
            elseif e=="0" then table.insert(ch,"\0")
            else table.insert(ch,e) end
        else
            table.insert(ch, self:advance())
        end
    end
    return table.concat(ch)
end

function Lexer:readMultilineString(q)
    local ch = {}
    while true do
        local c = self:peek()
        if c == nil then self:error("Unterminated multi-line string") end
        if c == q and self:peek(1) == q and self:peek(2) == q then
            self:advance(); self:advance(); self:advance()
            break
        end
        if c == "\\" then
            self:advance()
            local e = self:advance()
            if e=="n" then table.insert(ch,"\n")
            elseif e=="t" then table.insert(ch,"\t")
            elseif e=="r" then table.insert(ch,"\r")
            elseif e=="\\" then table.insert(ch,"\\")
            elseif e=="'" then table.insert(ch,"'")
            elseif e=='"' then table.insert(ch,'"')
            elseif e=="\n" then
            else table.insert(ch,e) end
        else
            table.insert(ch, self:advance())
        end
    end
    return table.concat(ch)
end

function Lexer:readFString(q)
    return self:readString(q)
end

function Lexer:readNumber()
    local ch = {}
    while true do
        local c = self:peek()
        if c and (isDigit(c) or c=="." or c=="e" or c=="E"
           or (c=="-" and #ch>0 and (ch[#ch]=="e" or ch[#ch]=="E"))
           or (c=="+" and #ch>0 and (ch[#ch]=="e" or ch[#ch]=="E"))) then
            table.insert(ch, self:advance())
        else break end
    end
    local s = table.concat(ch)
    local n = tonumber(s)
    if not n then self:error("Invalid number: " .. s) end
    return n
end

function Lexer:readName()
    local ch = {}
    while true do
        local c = self:peek()
        if c and isAlnum(c) then table.insert(ch, self:advance())
        else break end
    end
    return table.concat(ch)
end

function Lexer:tokenize()
    while self.pos <= #self.src do
        local c = self:peek()
        if c == "\n" then
            self:advance()
            if self.parenDepth == 0 then
                self:addToken("NEWLINE","\n")
                local indent = 0
                while true do
                    local ch = self:peek()
                    if ch==" " then indent=indent+1; self:advance()
                    elseif ch=="\t" then indent=indent+4; self:advance()
                    else break end
                end
                if self:peek()~="\n" and self:peek()~="#" and self:peek()~=nil then
                    local top = self.indentStack[#self.indentStack]
                    if indent > top then
                        table.insert(self.indentStack, indent)
                        self:addToken("INDENT", indent)
                    elseif indent < top then
                        while #self.indentStack > 1
                              and self.indentStack[#self.indentStack] > indent do
                            table.remove(self.indentStack)
                            self:addToken("DEDENT", indent)
                        end
                        if self.indentStack[#self.indentStack] ~= indent then
                            self:error("Indentation error")
                        end
                    end
                end
            end
        elseif c==" " or c=="\t" then self:advance()
        elseif c=="#" then
            while self:peek() and self:peek()~="\n" do self:advance() end
        elseif c=='"' or c=="'" then
            if self:peek(1) == c and self:peek(2) == c then
                self:advance(); self:advance(); self:advance()
                self:addToken("STRING", self:readMultilineString(c))
            else
                self:advance()
                self:addToken("STRING", self:readString(c))
            end
        elseif (c == "f" or c == "F")
               and (self:peek(1) == '"' or self:peek(1) == "'") then
            self:advance()
            local q = self:advance()
            self:addToken("FSTRING", self:readFString(q))
        elseif isDigit(c) then
            self:addToken("NUMBER", self:readNumber())
        elseif isAlpha(c) then
            local name = self:readName()
            if KEYWORDS[name] then self:addToken("KEYWORD", name)
            else self:addToken("NAME", name) end
        else
            self:advance()
            local two = c .. (self:peek() or "")
            if two=="==" or two=="!=" or two=="<=" or two==">="
               or two=="**" or two=="//" or two=="+=" or two=="-="
               or two=="*=" or two=="/=" or two=="<<" or two==">>"
               or two==":=" then
                self:advance()
                self:addToken("OP", two)
            else
                if c=="(" or c=="[" or c=="{" then
                    self.parenDepth = self.parenDepth + 1
                elseif c==")" or c=="]" or c=="}" then
                    self.parenDepth = self.parenDepth - 1
                end
                self:addToken("OP", c)
            end
        end
    end
    if #self.tokens > 0 and self.tokens[#self.tokens].type ~= "NEWLINE" then
        self:addToken("NEWLINE", "\n")
    end
    while #self.indentStack > 1 do
        table.remove(self.indentStack)
        self:addToken("DEDENT", 0)
    end
    self:addToken("EOF", nil)
    return self.tokens
end

-- ============================================================
-- 4. PARSER
-- ============================================================

local Parser = {}
Parser.__index = Parser

function Parser.new(tokens)
    return setmetatable({tokens=tokens, pos=1}, Parser)
end
function Parser:peek() return self.tokens[self.pos] end
function Parser:next()
    local t = self.tokens[self.pos]
    self.pos = self.pos + 1
    return t
end
function Parser:expect(type, value)
    local t = self:peek()
    if not t or t.type ~= type then
        self:error("Expected "..type..", got "..(t and t.type or "EOF"))
    end
    if value and t.value ~= value then
        self:error("Expected '"..value.."', got '"..tostring(t.value).."'")
    end
    return self:next()
end
function Parser:error(msg)
    local t = self:peek()
    error(string.format("Parse error at line %s: %s",
        t and t.line or "?", msg))
end
function Parser:skipNewlines()
    while self:peek() and (self:peek().type=="NEWLINE"
                          or self:peek().type=="DEDENT") do
        self:next()
    end
end

function Parser:parse()
    self:skipNewlines()
    local stmts = {}
    while self:peek() and self:peek().type ~= "EOF" do
        local stmt = self:parseStatement()
        if stmt then table.insert(stmts, stmt) end
        self:skipNewlines()
    end
    self:expect("EOF")
    return {type="Module", body=stmts}
end

function Parser:parseBlock()
    if self:peek() and self:peek().type ~= "NEWLINE" then
        local stmts = {}
        repeat
            local s = self:parseStatement()
            if s then table.insert(stmts, s) end
            if self:peek() and self:peek().type == "OP"
               and self:peek().value == ";" then
                self:next()
            else
                break
            end
        until false
        if self:peek() and self:peek().type == "NEWLINE" then
            self:next()
        end
        return stmts
    end
    if self:peek() and self:peek().type == "NEWLINE" then
        self:next()
    end
    while self:peek() and self:peek().type == "NEWLINE" do
        self:next()
    end
    self:expect("INDENT")
    local stmts = {}
    while self:peek() and self:peek().type~="DEDENT"
          and self:peek().type~="EOF" do
        if self:peek().type=="NEWLINE" then
            self:next()
        else
            local s = self:parseStatement()
            if s then table.insert(stmts, s) end
            while self:peek() and self:peek().type=="NEWLINE" do
                self:next()
            end
        end
    end
    if self:peek() and self:peek().type=="DEDENT" then
        self:next()
    end
    return stmts
end

function Parser:parseDottedName()
    local parts = {self:expect("NAME").value}
    while self:peek().type == "OP" and self:peek().value == "." do
        self:next()
        table.insert(parts, self:expect("NAME").value)
    end
    return table.concat(parts, ".")
end

function Parser:parseImport()
    self:next()
    local modules = {}
    repeat
        local name = self:parseDottedName()
        local alias = nil
        if self:peek().type == "KEYWORD" and self:peek().value == "as" then
            self:next()
            alias = self:expect("NAME").value
        end
        table.insert(modules, {name=name, alias=alias})
        if self:peek().type == "OP" and self:peek().value == "," then
            self:next()
        else
            break
        end
    until false
    return {type="Import", modules=modules}
end

function Parser:parseFrom()
    self:next()
    local moduleName = self:parseDottedName()
    self:expect("KEYWORD", "import")
    if self:peek().type == "OP" and self:peek().value == "*" then
        self:next()
        return {type="FromImport", module=moduleName,
                names={{name="*", alias=nil}}}
    end
    local names = {}
    repeat
        local name = self:expect("NAME").value
        local alias = nil
        if self:peek().type == "KEYWORD" and self:peek().value == "as" then
            self:next()
            alias = self:expect("NAME").value
        end
        table.insert(names, {name=name, alias=alias})
        if self:peek().type == "OP" and self:peek().value == "," then
            self:next()
        else
            break
        end
    until false
    return {type="FromImport", module=moduleName, names=names}
end

function Parser:parseDecorated()
    local decorators = {}
    while self:peek().type == "OP" and self:peek().value == "@" do
        self:next()
        local dec = self:parsePostfix()
        table.insert(decorators, dec)
        while self:peek() and self:peek().type == "NEWLINE" do
            self:next()
        end
    end
    if not self:peek() or self:peek().type ~= "KEYWORD"
       or self:peek().value ~= "def" then
        self:error("decorators can only be applied to function definitions")
    end
    local stmt = self:parseDef()
    stmt.decorators = decorators
    return stmt
end

function Parser:parseStatement()
    local t = self:peek()
    if not t or t.type == "NEWLINE" or t.type == "DEDENT"
       or t.type == "EOF" then
        return nil
    end
    if t.type == "OP" and t.value == "@" then
        return self:parseDecorated()
    end

    if t.type == "NAME" and (t.value == "match" or t.value == "case") then
        local scan = self.pos + 1
        local lastSig = nil
        while self.tokens[scan]
              and self.tokens[scan].type ~= "NEWLINE"
              and self.tokens[scan].type ~= "EOF"
              and self.tokens[scan].type ~= "DEDENT" do
            lastSig = self.tokens[scan]
            scan = scan + 1
        end
        if lastSig and lastSig.type == "OP" and lastSig.value == ":" then
            local lineNum = t.line
            while self:peek() and self:peek().type ~= "NEWLINE"
                  and self:peek().type ~= "EOF"
                  and self:peek().type ~= "DEDENT" do
                self:next()
            end
            if self:peek() and self:peek().type == "NEWLINE" then
                self:next()
                while self:peek() and self:peek().type == "NEWLINE" do
                    self:next()
                end
                if self:peek() and self:peek().type == "INDENT" then
                    local depth = 1
                    self:next()
                    while depth > 0 and self:peek()
                          and self:peek().type ~= "EOF" do
                        if self:peek().type == "INDENT" then
                            depth = depth + 1
                        elseif self:peek().type == "DEDENT" then
                            depth = depth - 1
                        end
                        self:next()
                    end
                end
            end
            local feat = (t.value == "match") and "match" or "case"
            return {type="Unsupported", feature=feat, line=lineNum}
        end
    end

    if t.type == "KEYWORD" then
        if t.value=="if" then return self:parseIf()
        elseif t.value=="while" then return self:parseWhile()
        elseif t.value=="for" then return self:parseFor()
        elseif t.value=="def" then return self:parseDef()
        elseif t.value=="class" then return self:parseClass()
        elseif t.value=="async" then
            self:next()
            local nt = self:peek()
            if nt and nt.type == "KEYWORD" then
                if nt.value == "def" then return self:parseDef()
                elseif nt.value == "for" then return self:parseFor()
                elseif nt.value == "with" then return self:parseWith()
                end
            end
            self:error("'async' must be followed by def, for, or with")
        elseif t.value=="return" then
            self:next()
            local nt = self:peek()
            if nt.type=="NEWLINE" or nt.type=="DEDENT"
               or nt.type=="EOF" then
                return {type="Return", value=nil}
            end
            local elems = {self:parseExpression()}
            while self:peek().type=="OP" and self:peek().value=="," do
                self:next()
                if self:peek().type=="NEWLINE" or self:peek().type=="DEDENT"
                   or self:peek().type=="EOF" then break end
                table.insert(elems, self:parseExpression())
            end
            local value = #elems == 1 and elems[1]
                          or {type="Tuple", elements=elems}
            return {type="Return", value=value}
        elseif t.value=="pass" then self:next(); return {type="Pass"}
        elseif t.value=="break" then self:next(); return {type="Break"}
        elseif t.value=="continue" then
            self:next(); return {type="Continue"}
        elseif t.value=="import" then return self:parseImport()
        elseif t.value=="from" then return self:parseFrom()
        elseif t.value=="global" then
            self:next()
            local names = {}
            repeat
                table.insert(names, self:expect("NAME").value)
                if self:peek().type=="OP" and self:peek().value=="," then
                    self:next()
                else break end
            until false
            return {type="Global", names=names}
        elseif t.value=="nonlocal" then
            self:next()
            local names = {}
            repeat
                table.insert(names, self:expect("NAME").value)
                if self:peek().type=="OP" and self:peek().value=="," then
                    self:next()
                else break end
            until false
            return {type="Nonlocal", names=names}
        elseif t.value=="try" then return self:parseTry()
        elseif t.value=="raise" then return self:parseRaise()
        elseif t.value=="with" then return self:parseWith()
        elseif t.value=="del" then
            self:next()
            local targets = {}
            repeat
                table.insert(targets, self:parsePostfix())
                if self:peek().type=="OP" and self:peek().value=="," then
                    self:next()
                else break end
            until false
            return {type="Del", targets=targets}
        elseif t.value=="assert" then
            self:next()
            local cond = self:parseExpression()
            local msg = nil
            if self:peek().type=="OP" and self:peek().value=="," then
                self:next()
                msg = self:parseExpression()
            end
            return {type="Assert", cond=cond, msg=msg}
        elseif t.value=="yield" then
            self:next()
            if self:peek().type == "KEYWORD"
               and self:peek().value == "from" then
                self:next()
                return {type="YieldFrom", value=self:parseExpression()}
            end
            local nt = self:peek()
            if nt.type=="NEWLINE" or nt.type=="DEDENT"
               or nt.type=="EOF" then
                return {type="Yield", value=nil}
            end
            return {type="Yield", value=self:parseExpression()}
        end
    end

    if t.type == "NAME" then
        local nxt = self.tokens[self.pos + 1]
        if nxt and nxt.type == "OP" and nxt.value == ":" then
            local name = t.value
            self:next(); self:next()
            while self:peek() and not (self:peek().type == "OP"
                and (self:peek().value == "=" or self:peek().value == ";"))
                and self:peek().type ~= "NEWLINE"
                and self:peek().type ~= "EOF" do
                self:next()
            end
            if self:peek() and self:peek().type == "OP"
               and self:peek().value == "=" then
                self:next()
                local value = self:parseExpression()
                return {type="Assign",
                        target={type="Name", name=name},
                        op="=", value=value}
            end
            return {type="Pass"}
        end
    end

    return self:parseExprStatement()
end

function Parser:parseWith()
    self:next()
    local items = {}
    repeat
        local expr = self:parseExpression()
        local name = nil
        if self:peek().type == "KEYWORD" and self:peek().value == "as" then
            self:next()
            name = self:expect("NAME").value
        end
        table.insert(items, {expr=expr, name=name})
        if self:peek().type == "OP" and self:peek().value == "," then
            self:next()
        else
            break
        end
    until false
    self:expect("OP", ":")
    local body = self:parseBlock()
    return {type="With", items=items, body=body}
end

function Parser:parseClass()
    self:next()
    local name = self:expect("NAME").value
    local bases = {}
    if self:peek().type=="OP" and self:peek().value=="(" then
        self:next()
        if not (self:peek().type=="OP" and self:peek().value==")") then
            repeat
                local baseName = self:expect("NAME").value
                if self:peek().type == "OP" and self:peek().value == "=" then
                    local lineNum = self:peek().line
                    while self:peek() and self:peek().type ~= "NEWLINE"
                          and self:peek().type ~= "EOF" do
                        self:next()
                    end
                    if self:peek() and self:peek().type == "NEWLINE" then
                        self:next()
                        while self:peek() and self:peek().type == "NEWLINE" do
                            self:next()
                        end
                        if self:peek() and self:peek().type == "INDENT" then
                            local depth = 1
                            self:next()
                            while depth > 0 and self:peek()
                                  and self:peek().type ~= "EOF" do
                                if self:peek().type == "INDENT" then
                                    depth = depth + 1
                                elseif self:peek().type == "DEDENT" then
                                    depth = depth - 1
                                end
                                self:next()
                            end
                        end
                    end
                    return {type="Unsupported",
                            feature="metaclass", line=lineNum}
                end
                table.insert(bases, baseName)
                if self:peek().type=="OP" and self:peek().value=="," then
                    self:next()
                else break end
            until false
        end
        self:expect("OP", ")")
    end
    self:expect("OP", ":")
    local body = self:parseBlock()
    return {type="Class", name=name, bases=bases, body=body}
end

function Parser:parseTry()
    self:next()
    self:expect("OP", ":")
    local body = self:parseBlock()
    local handlers = {}
    local elseBody = nil
    local finallyBody = nil
    while self:peek() and self:peek().type=="KEYWORD"
          and self:peek().value=="except" do
        self:next()
        local excType, varName = nil, nil
        if not (self:peek().type=="OP" and self:peek().value==":") then
            excType = self:expect("NAME").value
            if self:peek().type=="KEYWORD" and self:peek().value=="as" then
                self:next(); varName = self:expect("NAME").value
            elseif self:peek().type=="OP" and self:peek().value=="," then
                self:next(); varName = self:expect("NAME").value
            end
        end
        self:expect("OP", ":")
        local hbody = self:parseBlock()
        table.insert(handlers, {excType=excType, name=varName, body=hbody})
    end
    if self:peek() and self:peek().type=="KEYWORD"
       and self:peek().value=="else" then
        self:next(); self:expect("OP", ":"); elseBody = self:parseBlock()
    end
    if self:peek() and self:peek().type=="KEYWORD"
       and self:peek().value=="finally" then
        self:next(); self:expect("OP", ":"); finallyBody = self:parseBlock()
    end
    return {type="Try", body=body, handlers=handlers,
            elseBody=elseBody, finallyBody=finallyBody}
end

function Parser:parseRaise()
    self:next()
    local t = self:peek()
    if t.type=="NEWLINE" or t.type=="DEDENT" or t.type=="EOF" then
        return {type="Raise", exc=nil}
    end
    return {type="Raise", exc=self:parseExpression()}
end

function Parser:parseIf()
    self:next()
    local cond = self:parseExpression()
    self:expect("OP", ":")
    local body = self:parseBlock()
    local elifs, elseBody = {}, nil
    while self:peek() and self:peek().type=="KEYWORD"
          and self:peek().value=="elif" do
        self:next()
        local c = self:parseExpression()
        self:expect("OP", ":")
        table.insert(elifs, {cond=c, body=self:parseBlock()})
    end
    if self:peek() and self:peek().type=="KEYWORD"
       and self:peek().value=="else" then
        self:next(); self:expect("OP", ":"); elseBody = self:parseBlock()
    end
    return {type="If", cond=cond, body=body, elifs=elifs, elseBody=elseBody}
end

function Parser:parseWhile()
    self:next()
    local cond = self:parseExpression()
    self:expect("OP", ":")
    return {type="While", cond=cond, body=self:parseBlock()}
end

function Parser:parseFor()
    self:next()
    local names = {self:expect("NAME").value}
    while self:peek().type=="OP" and self:peek().value=="," do
        self:next()
        table.insert(names, self:expect("NAME").value)
    end
    self:expect("KEYWORD", "in")
    local iter = self:parseExpression()
    self:expect("OP", ":")
    return {type="For", names=names, iter=iter, body=self:parseBlock()}
end

function Parser:parseDef()
    self:next()
    local name = self:expect("NAME").value
    self:expect("OP", "(")
    local params = {}
    local vararg = nil
    local kwarg = nil
    if not (self:peek().type=="OP" and self:peek().value==")") then
        repeat
            local isStar = false
            local isDoubleStar = false
            local t = self:peek()
            if t.type == "OP" and t.value == "**" then
                isDoubleStar = true; self:next()
            elseif t.type == "OP" and t.value == "*" then
                isStar = true; self:next()
            end
            local pname = self:expect("NAME").value
            if self:peek().type == "OP" and self:peek().value == ":" then
                self:next()
                while self:peek() and not (self:peek().type == "OP"
                    and (self:peek().value == "," or self:peek().value == "="
                         or self:peek().value == ")")) do
                    self:next()
                end
            end
            local default = nil
            if self:peek().type=="OP" and self:peek().value=="=" then
                self:next(); default = self:parseExpression()
            end
            if isDoubleStar then kwarg = pname
            elseif isStar then vararg = pname
            else table.insert(params, {name=pname, default=default}) end
            if self:peek().type=="OP" and self:peek().value=="," then
                self:next()
            else break end
        until false
    end
    self:expect("OP", ")")
    if self:peek().type == "OP" and self:peek().value == "-" then
        local nxt = self.tokens[self.pos+1]
        if nxt and nxt.type == "OP" and nxt.value == ">" then
            self:next(); self:next()
            while self:peek() and not (self:peek().type == "OP"
                and self:peek().value == ":") do
                self:next()
            end
        end
    end
    self:expect("OP", ":")
    return {type="Def", name=name, params=params, vararg=vararg,
            kwarg=kwarg, body=self:parseBlock()}
end

function Parser:parseExprStatement()
    local function parseTarget()
        if self:peek().type == "OP" and self:peek().value == "*" then
            self:next()
            return {type="StarArg", expr=self:parseExpression()}
        end
        return self:parseExpression()
    end
    local elems = {parseTarget()}
    while self:peek().type=="OP" and self:peek().value=="," do
        self:next()
        if self:peek().type=="NEWLINE" or self:peek().type=="EOF"
           or self:peek().type=="DEDENT" then break end
        table.insert(elems, parseTarget())
    end
    local expr = #elems == 1 and elems[1]
                 or {type="Tuple", elements=elems}
    local t = self:peek()
    if t.type=="OP" and (t.value=="=" or t.value=="+=" or t.value=="-="
                         or t.value=="*=" or t.value=="/=") then
        local op = self:next().value
        local rhsElems = {self:parseExpression()}
        while self:peek().type=="OP" and self:peek().value=="," do
            self:next()
            if self:peek().type=="NEWLINE" or self:peek().type=="EOF"
               or self:peek().type=="DEDENT" then break end
            table.insert(rhsElems, self:parseExpression())
        end
        local value = #rhsElems == 1 and rhsElems[1]
                      or {type="Tuple", elements=rhsElems}
        if expr.type~="Name" and expr.type~="Index" and expr.type~="Attr"
           and expr.type~="Tuple" and expr.type~="StarArg" then
            self:error("Invalid assignment target")
        end
        return {type="Assign", target=expr, op=op, value=value}
    end
    return {type="ExprStmt", expr=expr}
end

-- Expressions
function Parser:parseExpression()
    local e = self:parseTernary()
    if self:peek().type == "OP" and self:peek().value == ":=" then
        self:next()
        if e.type ~= "Name" then
            self:error(":= requires a simple name on the left")
        end
        local value = self:parseTernary()
        return {type="Walrus", name=e.name, value=value}
    end
    return e
end

function Parser:parseTernary()
    local cond = self:parseOr()
    if self:peek().type=="KEYWORD" and self:peek().value=="if" then
        self:next()
        local c = self:parseOr()
        self:expect("KEYWORD", "else")
        return {type="Ternary", cond=c, then_expr=cond,
                else_expr=self:parseTernary()}
    end
    return cond
end

function Parser:parseOr()
    local left = self:parseAnd()
    while self:peek().type=="KEYWORD" and self:peek().value=="or" do
        self:next()
        left = {type="BinOp", op="or", left=left, right=self:parseAnd()}
    end
    return left
end

function Parser:parseAnd()
    local left = self:parseNot()
    while self:peek().type=="KEYWORD" and self:peek().value=="and" do
        self:next()
        left = {type="BinOp", op="and", left=left, right=self:parseNot()}
    end
    return left
end

function Parser:parseNot()
    if self:peek().type=="KEYWORD" and self:peek().value=="not" then
        self:next()
        return {type="UnaryOp", op="not", operand=self:parseNot()}
    end
    return self:parseComparison()
end

function Parser:parseBitOr()
    local left = self:parseBitXor()
    while self:peek().type=="OP" and self:peek().value=="|" do
        self:next()
        left = {type="BinOp", op="|", left=left, right=self:parseBitXor()}
    end
    return left
end
function Parser:parseBitXor()
    local left = self:parseBitAnd()
    while self:peek().type=="OP" and self:peek().value=="^" do
        self:next()
        left = {type="BinOp", op="^", left=left, right=self:parseBitAnd()}
    end
    return left
end
function Parser:parseBitAnd()
    local left = self:parseShift()
    while self:peek().type=="OP" and self:peek().value=="&" do
        self:next()
        left = {type="BinOp", op="&", left=left, right=self:parseShift()}
    end
    return left
end
function Parser:parseShift()
    local left = self:parseArith()
    while self:peek().type=="OP"
          and (self:peek().value=="<<" or self:peek().value==">>") do
        local op = self:next().value
        left = {type="BinOp", op=op, left=left, right=self:parseArith()}
    end
    return left
end

function Parser:parseComparison()
    local left = self:parseBitOr()
    while true do
        local t = self:peek()
        if t.type=="OP" and (t.value=="==" or t.value=="!="
            or t.value=="<" or t.value=="<=" or t.value==">"
            or t.value==">=") then
            self:next()
            left = {type="BinOp", op=t.value, left=left,
                    right=self:parseBitOr()}
        elseif t.type=="KEYWORD" and t.value=="in" then
            self:next()
            left = {type="BinOp", op="in", left=left,
                    right=self:parseBitOr()}
        elseif t.type=="KEYWORD" and t.value=="not" then
            local nxt = self.tokens[self.pos+1]
            if nxt and nxt.type=="KEYWORD" and nxt.value=="in" then
                self:next(); self:next()
                left = {type="UnaryOp", op="not",
                        operand={type="BinOp", op="in", left=left,
                                 right=self:parseBitOr()}}
            else break end
        else break end
    end
    return left
end

function Parser:parseArith()
    local left = self:parseTerm()
    while self:peek().type=="OP"
          and (self:peek().value=="+" or self:peek().value=="-") do
        local op = self:next().value
        left = {type="BinOp", op=op, left=left, right=self:parseTerm()}
    end
    return left
end

function Parser:parseTerm()
    local left = self:parseUnary()
    while self:peek().type=="OP"
          and (self:peek().value=="*" or self:peek().value=="/"
               or self:peek().value=="//" or self:peek().value=="%") do
        local op = self:next().value
        left = {type="BinOp", op=op, left=left, right=self:parseUnary()}
    end
    return left
end

function Parser:parseUnary()
    local t = self:peek()
    if t.type == "KEYWORD" and t.value == "await" then
        self:next()
        return self:parseUnary()
    end
    if t.type=="OP" and (t.value=="-" or t.value=="+" or t.value=="~") then
        self:next()
        local operand = self:parseUnary()
        if t.value=="-" then return {type="UnaryOp", op="-", operand=operand} end
        if t.value=="~" then return {type="UnaryOp", op="~", operand=operand} end
        return operand
    end
    return self:parsePower()
end

function Parser:parsePower()
    local left = self:parsePostfix()
    if self:peek().type=="OP" and self:peek().value=="**" then
        self:next()
        return {type="BinOp", op="**", left=left, right=self:parseUnary()}
    end
    return left
end

function Parser:parsePostfix()
    local expr = self:parsePrimary()
    while true do
        local t = self:peek()
        if t.type=="OP" and t.value=="(" then
            self:next()
            local args = {}
            if not (self:peek().type=="OP" and self:peek().value==")") then
                repeat
                    if self:peek().type=="OP" and self:peek().value=="*" then
                        self:next()
                        table.insert(args, {type="StarArg",
                                            expr=self:parseExpression()})
                    elseif self:peek().type=="OP"
                           and self:peek().value=="**" then
                        self:next()
                        table.insert(args, {type="DoubleStarArg",
                                            expr=self:parseExpression()})
                    elseif self:peek().type=="NAME"
                           and self.tokens[self.pos+1]
                           and self.tokens[self.pos+1].type=="OP"
                           and self.tokens[self.pos+1].value=="=" then
                        local name = self:next().value
                        self:next()
                        local value = self:parseExpression()
                        table.insert(args, {type="KwArg", name=name,
                                            value=value})
                    else
                        table.insert(args, self:parseExpression())
                    end
                    if self:peek().type=="OP" and self:peek().value=="," then
                        self:next()
                    else break end
                until false
            end
            self:expect("OP", ")")
            expr = {type="Call", func=expr, args=args}
        elseif t.type=="OP" and t.value=="[" then
            self:next()
            local index = self:parseExpression()
            self:expect("OP", "]")
            expr = {type="Index", obj=expr, index=index}
        elseif t.type=="OP" and t.value=="." then
            self:next()
            expr = {type="Attr", obj=expr, name=self:expect("NAME").value}
        else break end
    end
    return expr
end

function Parser:parseFString(raw)
    local parts = {}
    local i = 1
    local buf = {}
    while i <= #raw do
        local c = raw:sub(i, i)
        if c == "{" then
            if raw:sub(i+1, i+1) == "{" then
                table.insert(buf, "{")
                i = i + 2
            else
                if #buf > 0 then
                    table.insert(parts,
                        {type="String", value=table.concat(buf)})
                    buf = {}
                end
                local depth = 1
                local j = i + 1
                while j <= #raw and depth > 0 do
                    local cc = raw:sub(j, j)
                    if cc == "{" then depth = depth + 1
                    elseif cc == "}" then depth = depth - 1 end
                    if depth == 0 then break end
                    j = j + 1
                end
                local inner = raw:sub(i + 1, j - 1)
                local conv = nil
                local spec = nil
                local exprSrc = inner
                local colonPos = inner:find(":")
                local bangPos = inner:find("!")
                if bangPos and (not colonPos or bangPos < colonPos) then
                    conv = inner:sub(bangPos + 1, bangPos + 1)
                    exprSrc = inner:sub(1, bangPos - 1)
                    if colonPos then spec = inner:sub(colonPos + 1) end
                elseif colonPos then
                    exprSrc = inner:sub(1, colonPos - 1)
                    spec = inner:sub(colonPos + 1)
                end
                local l = Lexer.new(exprSrc)
                local subToks = l:tokenize()
                local subP = Parser.new(subToks)
                local expr = subP:parseExpression()
                table.insert(parts, {type="FStringExpr", expr=expr,
                                     conv=conv, spec=spec})
                i = j + 1
            end
        elseif c == "}" and raw:sub(i+1, i+1) == "}" then
            table.insert(buf, "}")
            i = i + 2
        else
            table.insert(buf, c)
            i = i + 1
        end
    end
    if #buf > 0 then
        table.insert(parts, {type="String", value=table.concat(buf)})
    end
    return {type="FString", parts=parts}
end

function Parser:parsePrimary()
    local t = self:peek()
    if t.type=="NUMBER" then
        self:next(); return {type="Number", value=t.value}
    elseif t.type=="STRING" then
        self:next(); return {type="String", value=t.value}
    elseif t.type=="FSTRING" then
        self:next(); return self:parseFString(t.value)
    elseif t.type=="NAME" then
        self:next(); return {type="Name", name=t.value}
    elseif t.type=="KEYWORD" then
        if t.value=="True" then
            self:next(); return {type="Bool", value=true}
        elseif t.value=="False" then
            self:next(); return {type="Bool", value=false}
        elseif t.value=="None" then
            self:next(); return {type="None"}
        elseif t.value=="lambda" then
            self:next()
            local params = {}
            if not (self:peek().type=="OP"
                    and self:peek().value==":") then
                repeat
                    table.insert(params,
                        {name=self:expect("NAME").value})
                    if self:peek().type=="OP"
                       and self:peek().value=="," then
                        self:next()
                    else break end
                until false
            end
            self:expect("OP", ":")
            return {type="Lambda", params=params,
                    body=self:parseExpression()}
        end
    elseif t.type=="OP" then
        if t.value=="(" then
            self:next()
            if self:peek().type=="OP" and self:peek().value==")" then
                self:next(); return {type="Tuple", elements={}}
            end
            local first = self:parseExpression()
            if self:peek().type=="KEYWORD"
               and self:peek().value=="for" then
                local comp = self:parseComprehension("generator", first)
                self:expect("OP", ")")
                return comp
            end
            if self:peek().type=="OP" and self:peek().value=="," then
                local elems = {first}
                while self:peek().type=="OP"
                      and self:peek().value=="," do
                    self:next()
                    if self:peek().type=="OP"
                       and self:peek().value==")" then break end
                    table.insert(elems, self:parseExpression())
                end
                self:expect("OP", ")")
                return {type="Tuple", elements=elems}
            end
            self:expect("OP", ")")
            return first
        elseif t.value=="[" then
            self:next()
            if self:peek().type=="OP" and self:peek().value=="]" then
                self:next(); return {type="List", elements={}}
            end
            local first
            if self:peek().type=="OP" and self:peek().value=="*" then
                self:next()
                first = {type="StarArg", expr=self:parseExpression()}
            else
                first = self:parseExpression()
            end
            if self:peek().type=="KEYWORD"
               and self:peek().value=="for" then
                local comp = self:parseComprehension("list", first)
                self:expect("OP", "]")
                return comp
            end
            local elems = {first}
            while self:peek().type=="OP" and self:peek().value=="," do
                self:next()
                if self:peek().type=="OP"
                   and self:peek().value=="]" then break end
                if self:peek().type=="OP"
                   and self:peek().value=="*" then
                    self:next()
                    table.insert(elems, {type="StarArg",
                                         expr=self:parseExpression()})
                else
                    table.insert(elems, self:parseExpression())
                end
            end
            self:expect("OP", "]")
            return {type="List", elements=elems}
        elseif t.value=="{" then
            self:next()
            if self:peek().type=="OP" and self:peek().value=="}" then
                self:next(); return {type="Dict", pairs={}}
            end
            local first = self:parseExpression()
            if self:peek().type=="KEYWORD"
               and self:peek().value=="for" then
                local comp = self:parseComprehension("set", first)
                self:expect("OP", "}")
                return comp
            end
            self:expect("OP", ":")
            local firstV = self:parseExpression()
            if self:peek().type=="KEYWORD"
               and self:peek().value=="for" then
                local comp = self:parseComprehension("dict", first, firstV)
                self:expect("OP", "}")
                return comp
            end
            local pairs_ = {{key=first, value=firstV}}
            while self:peek().type=="OP" and self:peek().value=="," do
                self:next()
                if self:peek().type=="OP"
                   and self:peek().value=="}" then break end
                local k = self:parseExpression()
                self:expect("OP", ":")
                local v = self:parseExpression()
                table.insert(pairs_, {key=k, value=v})
            end
            self:expect("OP", "}")
            return {type="Dict", pairs=pairs_}
        end
    end
    self:error("Unexpected token: " .. tostring(t.value)
               .. " (" .. t.type .. ")")
end

function Parser:parseComprehension(kind, first, firstV)
    local clauses = {}
    while self:peek().type=="KEYWORD" and self:peek().value=="for" do
        self:next()
        local names = {self:expect("NAME").value}
        while self:peek().type=="OP" and self:peek().value=="," do
            self:next()
            table.insert(names, self:expect("NAME").value)
        end
        self:expect("KEYWORD", "in")
        local iter = self:parseOr()
        local cond = nil
        if self:peek().type=="KEYWORD" and self:peek().value=="if" then
            self:next()
            cond = self:parseOr()
        end
        table.insert(clauses, {names=names, iter=iter, cond=cond})
    end
    return {type="Comprehension", kind=kind, element=first,
            value=firstV, clauses=clauses}
end

-- ============================================================
-- 5. INTERPRETER
-- ============================================================

local METHOD_FLAGS = setmetatable({}, {__mode="k"})

local Interpreter = {}
Interpreter.__index = Interpreter

function Interpreter.new()
    return setmetatable({
        globals = {}, scopes = {{}},
        currentClass = nil, currentInstance = nil,
    }, Interpreter)
end

function Interpreter:error(msg)
    error(makeException("RuntimeError", msg), 0)
end

function Interpreter:lookup(name)
    for i = #self.scopes, 1, -1 do
        local v = rawget(self.scopes[i], name)
        if v ~= nil then return v end
    end
    return nil
end

function Interpreter:assign(name, value)
    local top = self.scopes[#self.scopes]
    if top.__globalNames and top.__globalNames[name] then
        self.scopes[1][name] = value
        return
    end
    if top.__nonlocalNames and top.__nonlocalNames[name] then
        for i = #self.scopes - 1, 1, -1 do
            if rawget(self.scopes[i], name) ~= nil then
                self.scopes[i][name] = value
                return
            end
        end
        top[name] = value
        return
    end
    top[name] = value
end

local function pyTruthy(v)
    if v == nil or v == false then return false end
    if v == 0 or v == "" then return false end
    if type(v) == "table" then
        if v.__pytype == "list" or v.__pytype == "tuple" then
            return #v > 0
        end
        if v.__pytype == "dict" then return next(v.data) ~= nil end
        if v.__pyexception then return true end
    end
    return true
end

local function pyEq(a, b)
    if a == b then return true end
    if type(a) == "table" and type(b) == "table" then
        if a.__pytype == "list" and b.__pytype == "list"
           and #a == #b then
            for i = 1, #a do
                if not pyEq(a[i], b[i]) then return false end
            end
            return true
        end
    end
    return false
end

local function lookupMethod(class, name)
    if class.methods[name] then return class.methods[name] end
    for _, base in ipairs(class.bases) do
        local m = lookupMethod(base, name)
        if m then return m end
    end
    return nil
end

local function lookupClassAttr(class, name)
    if class.attrs[name] ~= nil then return class.attrs[name] end
    for _, base in ipairs(class.bases) do
        local a = lookupClassAttr(base, name)
        if a ~= nil then return a end
    end
    return nil
end

local function isSubclass(cls, base)
    if cls == base then return true end
    for _, b in ipairs(cls.bases) do
        if isSubclass(b, base) then return true end
    end
    return false
end

local function pyRepr(v)
    if v == nil then return "None" end
    if v == true then return "True" end
    if v == false then return "False" end
    if type(v) == "number" then
        if math.floor(v) == v and math.abs(v) < 1e15 then
            return string.format("%d", v)
        end
        return tostring(v)
    end
    if type(v) == "string" then return "'" .. v .. "'" end
    if type(v) == "table" then
        if v.__pyexception then return excStr(v) end
        if v.__pytype == "module" then
            return "<module '" .. v.__name .. "'>"
        end
        if v.__pytype == "instance" then
            return "<" .. v.__class.name .. " object>"
        end
        if v.__pytype == "class" then
            return "<class '" .. v.name .. "'>"
        end
        if v.__pytype == "generator" then return "<generator>" end
        if v.__pytype == "super" then return "<super>" end
        if v.__pytype == "list" then
            local p = {}
            for i=1,#v do p[i]=pyRepr(v[i]) end
            return "[" .. table.concat(p, ", ") .. "]"
        elseif v.__pytype == "dict" then
            local p = {}
            for k,val in pairs(v.data) do
                p[#p+1]=pyRepr(k)..": "..pyRepr(val)
            end
            return "{" .. table.concat(p, ", ") .. "}"
        elseif v.__pytype == "tuple" then
            local p = {}
            for i=1,#v do p[i]=pyRepr(v[i]) end
            if #v == 1 then return "(" .. p[1] .. ",)" end
            return "(" .. table.concat(p, ", ") .. ")"
        end
        return "<object>"
    end
    if type(v) == "function" then return "<function>" end
    return tostring(v)
end

local function pyStr(v, interp)
    if v == nil then return "None" end
    if v == true then return "True" end
    if v == false then return "False" end
    if type(v) == "string" then return v end
    if type(v) == "table" then
        if v.__pytype == "instance" and interp then
            local m = lookupMethod(v.__class, "__str__")
            if m then return tostring(m(v)) end
        end
    end
    if isException(v) then return excStr(v) end
    return pyRepr(v)
end

local function formatSpec(s, spec)
    if spec == "" then return s end
    local align, rest = spec:match("^([<>^])(.*)$")
    if align then spec = rest end
    local num = tonumber(s)
    local w, prec, typ = spec:match("^(%d*)%.?(%d*)(%a?)$")
    w = tonumber(w) or 0
    prec = tonumber(prec) or 0
    local out = s
    if typ == "f" and num then
        if spec:find("%.") then
            out = string.format("%." .. prec .. "f", num)
        else
            out = string.format("%.6f", num)
        end
    elseif typ == "d" and num then
        out = string.format("%d", math.floor(num))
    elseif typ == "x" and num then
        out = string.format("%x", math.floor(num))
    elseif typ == "o" and num then
        out = string.format("%o", math.floor(num))
    elseif typ == "e" and num then
        out = string.format("%e", num)
    elseif typ == "s" then
        out = s
    end
    if align == ">" then
        if w > #out then out = string.rep(" ", w - #out) .. out end
    elseif align == "<" then
        if w > #out then out = out .. string.rep(" ", w - #out) end
    elseif align == "^" then
        if w > #out then
            local pad = w - #out
            local left = math.floor(pad / 2)
            local right = pad - left
            out = string.rep(" ", left) .. out .. string.rep(" ", right)
        end
    else
        if w > #out then out = string.rep(" ", w - #out) .. out end
    end
    return out
end

local function makeRange(start, stop, step)
    if stop == nil then stop = start; start = 0 end
    step = step or 1
    if step == 0 then
        error(makeException("ValueError",
            "range() arg 3 must not be zero"), 0)
    end
    local list = {__pytype="list"}
    if step > 0 then
        local i = start
        while i < stop do table.insert(list, i); i = i + step end
    else
        local i = start
        while i > stop do table.insert(list, i); i = i + step end
    end
    return list
end

function Interpreter:getBuiltins()
    return {
        ["lua"] = function(code, ...)
            local loader = loadstring or load
            local fn, err = loader(tostring(code))
            if not fn then
                error(makeException("RuntimeError",
                    "lua(): " .. tostring(err)), 0)
            end
            local args = {...}
            local luaArgs = {}
            for i = 1, #args do
                luaArgs[i] = pyToLua(args[i])
            end
            local results = {pcall(fn, unpack(luaArgs))}
            if not results[1] then
                error(makeException("RuntimeError",
                    "lua(): " .. tostring(results[2])), 0)
            end
            table.remove(results, 1)
            if #results == 0 then return nil end
            if #results == 1 then return luaToPy(results[1]) end
            local t = {__pytype = "tuple"}
            for i = 1, #results do t[i] = luaToPy(results[i]) end
            return t
        end,
        ["lua_call"] = function(fnPath, ...)
            local args = {...}
            local parts = {}
            for p in tostring(fnPath):gmatch("[^%.]+") do
                table.insert(parts, p)
            end
            if #parts == 0 then
                error(makeException("RuntimeError",
                    "lua_call(): empty path"), 0)
            end
            local obj = _G
            for i = 1, #parts - 1 do
                obj = obj[parts[i]]
                if obj == nil then
                    error(makeException("RuntimeError",
                        "lua_call(): undefined '" .. parts[i]
                        .. "' in path '" .. fnPath .. "'"), 0)
                end
            end
            local fn = obj[parts[#parts]]
            if type(fn) ~= "function" then
                error(makeException("RuntimeError",
                    "lua_call(): '" .. fnPath
                    .. "' is not a function"), 0)
            end
            local luaArgs = {}
            for i = 1, #args do
                luaArgs[i] = pyToLua(args[i])
            end
            local results = {pcall(fn, unpack(luaArgs))}
            if not results[1] then
                error(makeException("RuntimeError",
                    "lua_call(): " .. tostring(results[2])), 0)
            end
            table.remove(results, 1)
            if #results == 0 then return nil end
            if #results == 1 then return luaToPy(results[1]) end
            local t = {__pytype = "tuple"}
            for i = 1, #results do t[i] = luaToPy(results[i]) end
            return t
        end,
        ["print"] = function(...)
            local a = {...}
            local p = {}
            for i=1,#a do p[i]=pyStr(a[i], self) end
            print(table.concat(p, " "))
        end,
        ["len"] = function(x)
            if type(x)=="string" then return #x end
            if type(x)=="table" then
                if x.__pytype=="list" or x.__pytype=="tuple" then
                    return #x
                end
                if x.__pytype=="dict" then
                    local n=0; for _ in pairs(x.data) do n=n+1 end
                    return n
                end
                if x.__pytype=="instance" then
                    local m = lookupMethod(x.__class, "__len__")
                    if m then return m(x) end
                end
            end
            error(makeException("TypeError", "object has no len()"), 0)
        end,
        ["range"] = makeRange,
        ["str"] = function(x)
            if type(x) == "table" and x.__pytype == "instance" then
                local m = lookupMethod(x.__class, "__str__")
                if m then return pyStr(m(x), self) end
            end
            return pyStr(x, self)
        end,
        ["repr"] = function(x)
            if type(x) == "table" and x.__pytype == "instance" then
                local m = lookupMethod(x.__class, "__repr__")
                if m then return pyStr(m(x), self) end
            end
            return pyRepr(x)
        end,
        ["int"] = function(x)
            if x==nil then return 0 end
            if type(x)=="number" then return math.floor(x) end
            if type(x)=="string" then
                local n=tonumber(x); if n then return math.floor(n) end
            end
            error(makeException("ValueError",
                "invalid literal for int()"), 0)
        end,
        ["float"] = function(x)
            if type(x)=="number" then return x + 0.0 end
            if type(x)=="string" then
                local n=tonumber(x); if n then return n + 0.0 end
            end
            error(makeException("ValueError",
                "invalid literal for float()"), 0)
        end,
        ["bool"] = pyTruthy,
        ["abs"] = math.abs,
        ["min"] = function(a,b)
            if type(a)=="table" and a.__pytype=="list" then
                local m=a[1]
                for i=2,#a do if a[i]<m then m=a[i] end end
                return m
            end
            return math.min(a,b)
        end,
        ["max"] = function(a,b)
            if type(a)=="table" and a.__pytype=="list" then
                local m=a[1]
                for i=2,#a do if a[i]>m then m=a[i] end end
                return m
            end
            return math.max(a,b)
        end,
        ["sum"] = function(l)
            local s=0; for i=1,#l do s=s+l[i] end; return s
        end,
        ["input"] = function(p)
            if p then write(pyStr(p, self)) end
            return io.read() or ""
        end,
        ["type"] = function(x)
            if x==nil then return "NoneType" end
            if type(x)=="boolean" then return "bool" end
            if type(x)=="number" then
                if math.floor(x)==x then return "int"
                else return "float" end
            end
            if type(x)=="string" then return "str" end
            if type(x)=="table" then
                if x.__pyexception then return x.type end
                if x.__pytype=="list" then return "list" end
                if x.__pytype=="dict" then return "dict" end
                if x.__pytype=="tuple" then return "tuple" end
                if x.__pytype=="instance" then return x.__class.name end
                if x.__pytype=="class" then return "type" end
                if x.__pytype=="module" then return "module" end
                if x.__pytype=="generator" then return "generator" end
            end
            return type(x)
        end,
        ["isinstance"] = function(obj, cls)
            if type(obj)~="table" or obj.__pytype~="instance" then
                if cls and cls.__pytype == "class" then
                    if cls.name == "int" and type(obj)=="number"
                       and math.floor(obj)==obj then return true end
                    if cls.name == "float" and type(obj)=="number"
                       and math.floor(obj)~=obj then return true end
                    if cls.name == "str" and type(obj)=="string" then
                        return true
                    end
                    if cls.name == "bool" and type(obj)=="boolean" then
                        return true
                    end
                    if cls.name == "list" and type(obj)=="table"
                       and obj.__pytype=="list" then return true end
                    if cls.name == "dict" and type(obj)=="table"
                       and obj.__pytype=="dict" then return true end
                end
                return false
            end
            if type(cls)~="table" or cls.__pytype~="class" then
                return false
            end
            return isSubclass(obj.__class, cls)
        end,
        ["list"] = function(x)
            local o = {__pytype="list"}
            if x then for i=1,#x do o[i]=x[i] end end
            return o
        end,
        ["tuple"] = function(x)
            local o = {__pytype="tuple"}
            if x then for i=1,#x do o[i]=x[i] end end
            return o
        end,
        ["dict"] = function() return {__pytype="dict", data={}} end,
        ["ord"] = string.byte,
        ["chr"] = string.char,
        ["pow"] = function(a,b) return a^b end,
        ["round"] = function(x) return math.floor(x+0.5) end,
        ["enumerate"] = function(l, start)
            start = start or 0
            local o = {__pytype="list"}
            for i=1,#l do o[i]={__pytype="tuple",
                                start + i - 1, l[i]} end
            return o
        end,
        ["zip"] = function(...)
            local lists = {...}
            if #lists == 0 then return {__pytype="list"} end
            local minLen = #lists[1]
            for i=2,#lists do
                if #lists[i] < minLen then minLen = #lists[i] end
            end
            local o = {__pytype="list"}
            for i=1,minLen do
                local tup = {__pytype="tuple"}
                for j=1,#lists do tup[j] = lists[j][i] end
                o[i] = tup
            end
            return o
        end,
        ["sorted"] = function(l)
            local o = {__pytype="list"}
            for i=1,#l do o[i]=l[i] end
            table.sort(o)
            return o
        end,
        ["reversed"] = function(l)
            local o = {__pytype="list"}
            for i=#l,1,-1 do o[#o+1]=l[i] end
            return o
        end,
        ["next"] = function(gen, default)
            if type(gen) ~= "table" or gen.__pytype ~= "generator" then
                error(makeException("TypeError",
                    "next() requires a generator"), 0)
            end
            local ok, val = pcall(gen.__next__)
            if not ok then
                local e = wrapError(val)
                if e.type == "StopIteration" then return default end
                error(val, 0)
            end
            return val
        end,
        ["map"] = function(fn, iterable)
            local o = {__pytype = "list"}
            if type(iterable) == "table" then
                for i = 1, #iterable do
                    o[i] = fn(iterable[i])
                end
            end
            return o
        end,
        ["filter"] = function(fn, iterable)
            local o = {__pytype = "list"}
            if type(iterable) == "table" then
                for i = 1, #iterable do
                    if pyTruthy(fn(iterable[i])) then
                        table.insert(o, iterable[i])
                    end
                end
            end
            return o
        end,
        ["all"] = function(iterable)
            if type(iterable) ~= "table" then return true end
            for i = 1, #iterable do
                if not pyTruthy(iterable[i]) then return false end
            end
            return true
        end,
        ["any"] = function(iterable)
            if type(iterable) ~= "table" then return false end
            for i = 1, #iterable do
                if pyTruthy(iterable[i]) then return true end
            end
            return false
        end,
        ["format"] = function(value, spec)
            if spec == nil then return pyStr(value, self) end
            return pyStr(value, self)
        end,
        ["getattr"] = function(obj, name, default)
            local ok, v = pcall(function()
                return self:getAttr(obj, name) end)
            if ok then return v end
            return default
        end,
        ["setattr"] = function(obj, name, value)
            if type(obj) == "table" and obj.__pytype == "instance" then
                obj.__attrs[name] = value
            elseif type(obj) == "table" then
                obj[name] = value
            end
        end,
        ["hasattr"] = function(obj, name)
            local ok, _ = pcall(function()
                return self:getAttr(obj, name) end)
            return ok
        end,
        ["dir"] = function(obj)
            local o = {__pytype = "list"}
            if type(obj) == "table" then
                if obj.__pytype == "instance" then
                    for k, _ in pairs(obj.__attrs) do
                        table.insert(o, k)
                    end
                    for k, _ in pairs(obj.__class.methods) do
                        table.insert(o, k)
                    end
                    for k, _ in pairs(obj.__class.attrs) do
                        table.insert(o, k)
                    end
                else
                    for k, _ in pairs(obj) do table.insert(o, k) end
                end
            end
            return o
        end,
        ["open"] = function(path, mode)
            mode = mode or "r"
            return {
                __pytype = "file",
                __path = path,
                __mode = mode,
                __handle = nil,
            }
        end,
        ["super"] = function()
            if not self.currentClass or not self.currentInstance then
                error(makeException("RuntimeError",
                    "super(): no enclosing class"), 0)
            end
            return {
                __pytype = "super",
                __class = self.currentClass,
                __instance = self.currentInstance,
            }
        end,
        ["property"] = function(f) return f end,
        ["staticmethod"] = function(f) return f end,
        ["classmethod"] = function(f) return f end,
        ["object"] = {__pytype="class", name="object", bases={},
                      methods={}, attrs={}},
        ["int"]    = {__pytype="class", name="int", bases={},
                      methods={}, attrs={}},
        ["float"]  = {__pytype="class", name="float", bases={},
                      methods={}, attrs={}},
        ["str"]    = {__pytype="class", name="str", bases={},
                      methods={}, attrs={}},
        ["bool"]   = {__pytype="class", name="bool", bases={},
                      methods={}, attrs={}},
        ["list"]   = {__pytype="class", name="list", bases={},
                      methods={}, attrs={}},
        ["dict"]   = {__pytype="class", name="dict", bases={},
                      methods={}, attrs={}},
        ["Exception"]        = function(m) return makeException("Exception", m) end,
        ["BaseException"]    = function(m) return makeException("BaseException", m) end,
        ["ValueError"]       = function(m) return makeException("ValueError", m) end,
        ["TypeError"]        = function(m) return makeException("TypeError", m) end,
        ["RuntimeError"]     = function(m) return makeException("RuntimeError", m) end,
        ["ZeroDivisionError"] = function(m) return makeException("ZeroDivisionError", m) end,
        ["IndexError"]       = function(m) return makeException("IndexError", m) end,
        ["KeyError"]         = function(m) return makeException("KeyError", m) end,
        ["NameError"]        = function(m) return makeException("NameError", m) end,
        ["ImportError"]      = function(m) return makeException("ImportError", m) end,
        ["AssertionError"]   = function(m) return makeException("AssertionError", m) end,
        ["StopIteration"]    = function(m) return makeException("StopIteration", m) end,
        ["AttributeError"]   = function(m) return makeException("AttributeError", m) end,
        ["NotImplementedError"] = function(m) return makeException("NotImplementedError", m) end,
    }
end

function Interpreter:eval(node)
    local t = node.type
    if t=="Number" then return node.value
    elseif t=="String" then return node.value
    elseif t=="Bool" then return node.value
    elseif t=="None" then return nil
    elseif t=="Name" then return self:lookup(node.name)
    elseif t=="List" then
        local l = {__pytype="list"}
        for _, e in ipairs(node.elements) do
            if e.type == "StarArg" then
                local v = self:eval(e.expr)
                if type(v) == "table" then
                    for j = 1, #v do table.insert(l, v[j]) end
                end
            else
                table.insert(l, self:eval(e))
            end
        end
        return l
    elseif t=="Tuple" then
        local l = {__pytype="tuple"}
        for _, e in ipairs(node.elements) do
            if e.type == "StarArg" then
                local v = self:eval(e.expr)
                if type(v) == "table" then
                    for j = 1, #v do table.insert(l, v[j]) end
                end
            else
                table.insert(l, self:eval(e))
            end
        end
        return l
    elseif t=="Dict" then
        local d = {__pytype="dict", data={}}
        for _,p in ipairs(node.pairs) do
            d.data[self:eval(p.key)] = self:eval(p.value)
        end
        return d
    elseif t=="BinOp" then return self:evalBinOp(node)
    elseif t=="UnaryOp" then
        local v = self:eval(node.operand)
        if node.op=="not" then return not pyTruthy(v) end
        if node.op=="-" then
            if type(v) ~= "number" then
                error(makeException("TypeError",
                    "bad operand for unary -"),0)
            end
            return -v
        end
        if node.op=="~" then
            if type(v) ~= "number" then
                error(makeException("TypeError",
                    "bad operand for unary ~"),0)
            end
            return -1 - math.floor(v)
        end
        self:error("unknown unary op: " .. node.op)
    elseif t=="Walrus" then
        local v = self:eval(node.value)
        self:assign(node.name, v)
        return v
    elseif t=="Call" then return self:evalCall(node)
    elseif t=="Index" then
        local obj = self:eval(node.obj)
        local idx = self:eval(node.index)
        if type(obj) == "string" then
            local i = idx + 1
            if i < 1 or i > #obj then
                error(makeException("IndexError",
                    "string index out of range"),0)
            end
            return obj:sub(i, i)
        elseif type(obj) == "table" then
            if obj.__pytype == "dict" then
                local v = obj.data[idx]
                if v == nil then
                    error(makeException("KeyError", pyStr(idx)), 0)
                end
                return v
            end
            if obj.__pytype == "instance" then
                local m = lookupMethod(obj.__class, "__getitem__")
                if m then return m(obj, idx) end
            end
            local i = idx + 1
            if i < 1 or i > #obj then
                error(makeException("IndexError",
                    "list index out of range"),0)
            end
            return obj[i]
        end
        self:error("cannot index this object")
    elseif t=="Attr" then
        return self:getAttr(self:eval(node.obj), node.name)
    elseif t=="Ternary" then
        if pyTruthy(self:eval(node.cond)) then
            return self:eval(node.then_expr)
        else
            return self:eval(node.else_expr)
        end
    elseif t=="Lambda" then
        return self:makeFunction("lambda", node.params,
            {{type="Return", value=node.body}})
    elseif t=="FString" then
        local parts = {}
        for _, p in ipairs(node.parts) do
            if p.type == "String" then
                table.insert(parts, p.value)
            else
                local v = self:eval(p.expr)
                local s
                if p.conv == "r" then s = pyRepr(v)
                elseif p.conv == "s" then s = pyStr(v, self)
                else s = pyStr(v, self) end
                if p.spec and p.spec ~= "" then
                    s = formatSpec(s, p.spec)
                end
                table.insert(parts, s)
            end
        end
        return table.concat(parts)
    elseif t=="Comprehension" then
        return self:evalComprehension(node)
    end
    self:error("unknown expression: " .. t)
end

-- Lua <-> Python value conversion
local function luaToPy(v)
    if type(v) ~= "table" then return v end
    local isArray = true
    local maxIndex = 0
    local count = 0
    for k, _ in pairs(v) do
        count = count + 1
        if type(k) ~= "number" or k < 1 or k ~= math.floor(k) then
            isArray = false
            break
        end
        if k > maxIndex then maxIndex = k end
    end
    if count == 0 then return {__pytype = "list"} end
    if isArray and maxIndex == count then
        local result = {__pytype = "list"}
        for i = 1, maxIndex do result[i] = luaToPy(v[i]) end
        return result
    end
    local result = {__pytype = "dict", data = {}}
    for k, val in pairs(v) do
        result.data[k] = luaToPy(val)
    end
    return result
end

local function pyToLua(v)
    if type(v) ~= "table" then return v end
    if v.__pytype == "list" or v.__pytype == "tuple" then
        local t = {}
        for i = 1, #v do t[i] = pyToLua(v[i]) end
        return t
    end
    if v.__pytype == "dict" then
        local t = {}
        for k, val in pairs(v.data) do
            t[pyToLua(k)] = pyToLua(val)
        end
        return t
    end
    return v
end

function Interpreter:evalComprehension(node)
    local kind = node.kind
    local result
    if kind == "list" or kind == "generator" then
        result = {__pytype = "list"}
    elseif kind == "dict" then
        result = {__pytype = "dict", data = {}}
    elseif kind == "set" then
        result = {__pytype = "list"}
    end

    local function iterateClause(idx, callback)
        if idx > #node.clauses then
            callback()
            return
        end
        local clause = node.clauses[idx]
        local iterable = self:eval(clause.iter)
        local function handleItem(item)
            if #clause.names == 1 then
                self:assign(clause.names[1], item)
            else
                if type(item) ~= "table" then return end
                for j = 1, #clause.names do
                    self:assign(clause.names[j], item[j])
                end
            end
            if clause.cond then
                if not pyTruthy(self:eval(clause.cond)) then return end
            end
            iterateClause(idx + 1, callback)
        end
        if type(iterable) ~= "table" then return end
        if iterable.__pytype == "generator" then
            while true do
                local ok, val = pcall(iterable.__next__)
                if not ok then
                    local e = wrapError(val)
                    if e.type == "StopIteration" then break end
                    error(val, 0)
                end
                handleItem(val)
            end
        elseif iterable.__pytype == "instance" then
            local iterFn = self:getAttr(iterable, "__iter__")
            local iterator = iterFn()
            while true do
                local nextFn = self:getAttr(iterator, "__next__")
                local ok, val = pcall(nextFn)
                if not ok then
                    local e = wrapError(val)
                    if e.type == "StopIteration" then break end
                    error(val, 0)
                end
                handleItem(val)
            end
        else
            for i = 1, #iterable do
                handleItem(iterable[i])
            end
        end
    end

    iterateClause(1, function()
        if kind == "list" or kind == "set" or kind == "generator" then
            table.insert(result, self:eval(node.element))
        elseif kind == "dict" then
            local k = self:eval(node.element)
            local v = self:eval(node.value)
            result.data[k] = v
        end
    end)

    if kind == "generator" then
        local idx = 0
        local gen = {__pytype = "generator", __done = false}
        gen.__next__ = function()
            idx = idx + 1
            if idx > #result then
                gen.__done = true
                error(makeException("StopIteration", ""), 0)
            end
            return result[idx]
        end
        gen.__iter__ = function() return gen end
        return gen
    end
    return result
end

local function collectGlobalNonlocal(body, globalSet, nonlocalSet)
    for _, stmt in ipairs(body) do
        if type(stmt) == "table" then
            if stmt.type == "Global" then
                for _, n in ipairs(stmt.names) do globalSet[n] = true end
            elseif stmt.type == "Nonlocal" then
                for _, n in ipairs(stmt.names) do nonlocalSet[n] = true end
            elseif stmt.type == "If" then
                collectGlobalNonlocal(stmt.body, globalSet, nonlocalSet)
                for _, e in ipairs(stmt.elifs) do
                    collectGlobalNonlocal(e.body, globalSet, nonlocalSet)
                end
                if stmt.elseBody then
                    collectGlobalNonlocal(stmt.elseBody, globalSet,
                                          nonlocalSet)
                end
            elseif stmt.type == "While" or stmt.type == "For"
                or stmt.type == "With" then
                collectGlobalNonlocal(stmt.body, globalSet, nonlocalSet)
            elseif stmt.type == "Try" then
                collectGlobalNonlocal(stmt.body, globalSet, nonlocalSet)
                for _, h in ipairs(stmt.handlers) do
                    collectGlobalNonlocal(h.body, globalSet, nonlocalSet)
                end
                if stmt.elseBody then
                    collectGlobalNonlocal(stmt.elseBody, globalSet,
                                          nonlocalSet)
                end
                if stmt.finallyBody then
                    collectGlobalNonlocal(stmt.finallyBody, globalSet,
                                          nonlocalSet)
                end
            end
        end
    end
end

function Interpreter:makeFunction(name, params, body, vararg, kwarg)
    local interp = self
    local capturedScopes = {}
    for i, s in ipairs(self.scopes) do capturedScopes[i] = s end
    local isGenerator = containsYield(body)
    local globalSet = {}
    local nonlocalSet = {}
    collectGlobalNonlocal(body, globalSet, nonlocalSet)

    local precomputedDefaults = {}
    for i, p in ipairs(params) do
        if p.default then
            precomputedDefaults[i] = interp:eval(p.default)
        end
    end

    local function bindArgs(args, funcScope)
        local kwData = nil
        if #args > 0 then
            local last = args[#args]
            if type(last) == "table" and last.__pykwargs then
                kwData = last.data
                table.remove(args)
            end
        end
        for i, p in ipairs(params) do
            if args[i] == nil and p.default then
                funcScope[p.name] = precomputedDefaults[i]
            else
                funcScope[p.name] = args[i]
            end
        end
        if vararg then
            local rest = {__pytype = "tuple"}
            for i = #params + 1, #args do
                table.insert(rest, args[i])
            end
            funcScope[vararg] = rest
        end
        if kwarg then
            funcScope[kwarg] = {__pytype = "dict", data = {}}
        end
        if kwData then
            for k, v in pairs(kwData) do
                local matched = false
                for _, p in ipairs(params) do
                    if p.name == k then
                        funcScope[p.name] = v
                        matched = true
                        break
                    end
                end
                if not matched and kwarg then
                    funcScope[kwarg].data[k] = v
                end
            end
        end
    end

    if not isGenerator then
        return function(...)
            local args = {...}
            local funcScope = {__isFunctionScope=true,
                __globalNames=globalSet, __nonlocalNames=nonlocalSet}
            local savedScopes = interp.scopes
            local newScopes = {}
            for i, s in ipairs(capturedScopes) do newScopes[i] = s end
            newScopes[#newScopes + 1] = funcScope
            interp.scopes = newScopes
            bindArgs(args, funcScope)
            local ok, result = pcall(function()
                return interp:execBlock(body)
            end)
            interp.scopes = savedScopes
            if not ok then error(result, 0) end
            if result and result.__return then
                return result.value
            end
            return nil
        end
    end

    return function(...)
        local args = {...}
        local funcScope = {__isFunctionScope=true,
            __globalNames=globalSet, __nonlocalNames=nonlocalSet}
        local newScopes = {}
        for i, s in ipairs(capturedScopes) do newScopes[i] = s end
        newScopes[#newScopes + 1] = funcScope

        local savedForInit = interp.scopes
        interp.scopes = newScopes
        bindArgs(args, funcScope)
        interp.scopes = savedForInit

        local co = coroutine.create(function()
            local result = interp:execBlock(body)
            if result and result.__return then
                return result.value
            end
            return nil
        end)
        local gen = {
            __pytype = "generator", __co = co, __done = false,
            __scopes = newScopes,
        }
        gen.__next__ = function()
            if gen.__done then
                error(makeException("StopIteration", ""), 0)
            end
            local savedScopes = interp.scopes
            interp.scopes = gen.__scopes
            local ok, val = coroutine.resume(co)
            interp.scopes = savedScopes
            if not ok then
                gen.__done = true
                error(wrapError(val), 0)
            end
            if coroutine.status(co) == "dead" then
                gen.__done = true
                error(makeException("StopIteration", ""), 0)
            end
            return val
        end
        gen.__iter__ = function() return gen end
        return gen
    end
end

local function makeInstance(class, args, interp)
    local instance = {__pytype="instance", __class=class, __attrs={}}
    local init = lookupMethod(class, "__init__")
    if init then
        local flags = METHOD_FLAGS[init] or {}
        local savedClass, savedInstance =
            interp.currentClass, interp.currentInstance
        interp.currentClass = flags.definingClass or class
        interp.currentInstance = instance
        local ok, err = pcall(init, instance, unpack(args))
        interp.currentClass, interp.currentInstance =
            savedClass, savedInstance
        if not ok then error(err, 0) end
    end
    return instance
end

function Interpreter:evalCall(node)
    local func = self:eval(node.func)
    local args = {}
    local kwData = nil
    for _, a in ipairs(node.args) do
        if a.type == "StarArg" then
            local v = self:eval(a.expr)
            if type(v) == "table" then
                for j = 1, #v do table.insert(args, v[j]) end
            end
        elseif a.type == "DoubleStarArg" then
            local v = self:eval(a.expr)
            if type(v) == "table" and v.__pytype == "dict" then
                if not kwData then kwData = {} end
                for k, val in pairs(v.data) do kwData[k] = val end
            end
        elseif a.type == "KwArg" then
            if not kwData then kwData = {} end
            kwData[a.name] = self:eval(a.value)
        else
            table.insert(args, self:eval(a))
        end
    end
    if kwData then
        table.insert(args, {__pykwargs = true, data = kwData})
    end

    if type(func) == "function" then
        return func(unpack(args))
    end
    if type(func) == "table" and func.__pytype == "instance" then
        local call = lookupMethod(func.__class, "__call__")
        if call then return call(func, unpack(args)) end
        self:error("object is not callable")
    end
    if type(func) == "table" and func.__pytype == "class" then
        if func.name == "int" then
            return math.floor(tonumber(args[1]) or 0)
        end
        if func.name == "float" then
            return (tonumber(args[1]) or 0) + 0.0
        end
        if func.name == "str" then return pyStr(args[1], self) end
        if func.name == "bool" then return pyTruthy(args[1]) end
        if func.name == "list" then
            local o = {__pytype="list"}
            if args[1] then
                for i=1,#args[1] do o[i]=args[1][i] end
            end
            return o
        end
        if func.name == "dict" then
            return {__pytype="dict", data={}}
        end
        return makeInstance(func, args, self)
    end
    self:error("object is not callable")
end

function Interpreter:getAttr(obj, name)
    if type(obj) == "string" then
        local s = obj
        if name=="upper" then return function() return s:upper() end end
        if name=="lower" then return function() return s:lower() end end
        if name=="strip" then
            return function()
                return (s:gsub("^%s+",""):gsub("%s+$",""))
            end
        end
        if name=="split" then
            return function(sep)
                sep = sep or " "
                local o = {__pytype="list"}
                local pat = "([^" .. sep:gsub("(%W)","%%%1") .. "]+)"
                for m in s:gmatch(pat) do table.insert(o, m) end
                return o
            end
        end
        if name=="replace" then
            return function(a,b)
                local pa = a:gsub("(%W)","%%%1")
                local pb = b:gsub("%%","%%%%")
                return (s:gsub(pa, pb))
            end
        end
        if name=="find" then
            return function(sub) return s:find(sub,1,true) end
        end
        if name=="join" then
            return function(l)
                local p = {}
                for i=1,#l do p[i]=tostring(l[i]) end
                return table.concat(p, s)
            end
        end
        if name=="startswith" then
            return function(p) return s:sub(1,#p)==p end
        end
        if name=="endswith" then
            return function(p) return s:sub(-#p)==p end
        end
        if name=="format" then
            return function(...)
                local a = {...}; local i = 0
                return (s:gsub("{}", function()
                    i=i+1; return pyStr(a[i], self)
                end))
            end
        end
        if name=="isdigit" then
            return function() return s:match("^%d+$") ~= nil end
        end
        if name=="isalpha" then
            return function() return s:match("^%a+$") ~= nil end
        end
    elseif type(obj) == "table" then
        if obj.__pytype == "module" then
            local v = obj.__scope[name]
            if v ~= nil then return v end
            self:error("module '" .. obj.__name
                .. "' has no attribute '" .. name .. "'")
        end
        if obj.__pytype == "generator" then
            if name == "__next__" then return obj.__next__ end
            if name == "__iter__" then return obj.__iter__ end
            self:error("generator has no attribute '" .. name .. "'")
        end
        if obj.__pytype == "super" then
            for _, base in ipairs(obj.__class.bases) do
                local m = lookupMethod(base, name)
                if m then
                    local inst = obj.__instance
                    return function(...) return m(inst, ...) end
                end
                local a = lookupClassAttr(base, name)
                if a ~= nil then return a end
            end
            self:error("'super' object has no attribute '"
                .. name .. "'")
        end
        if obj.__pytype == "instance" then
            if obj.__attrs[name] ~= nil then
                return obj.__attrs[name]
            end
            local m = lookupMethod(obj.__class, name)
            if m then
                local flags = METHOD_FLAGS[m] or {}
                if flags.static then
                    return m
                elseif flags.classmethod then
                    return function(...)
                        return m(flags.definingClass or obj.__class, ...)
                    end
                elseif flags.property then
                    local savedClass, savedInstance =
                        self.currentClass, self.currentInstance
                    self.currentClass = flags.definingClass or obj.__class
                    self.currentInstance = obj
                    local ok, result = pcall(m, obj)
                    self.currentClass, self.currentInstance =
                        savedClass, savedInstance
                    if not ok then error(result, 0) end
                    return result
                else
                    return function(...)
                        local savedClass, savedInstance =
                            self.currentClass, self.currentInstance
                        self.currentClass =
                            flags.definingClass or obj.__class
                        self.currentInstance = obj
                        local ok, result = pcall(m, obj, ...)
                        self.currentClass, self.currentInstance =
                            savedClass, savedInstance
                        if not ok then error(result, 0) end
                        return result
                    end
                end
            end
            local a = lookupClassAttr(obj.__class, name)
            if a ~= nil then return a end
            local ga = lookupMethod(obj.__class, "__getattr__")
            if ga then return ga(obj, name) end
            self:error("instance has no attribute '" .. name .. "'")
        end
        if obj.__pytype == "class" then
            local m = lookupMethod(obj, name)
            if m then
                local flags = METHOD_FLAGS[m] or {}
                if flags.static then return m end
                if flags.classmethod then
                    return function(...) return m(obj, ...) end
                end
                return m
            end
            local a = lookupClassAttr(obj, name)
            if a ~= nil then return a end
            self:error("class has no attribute '" .. name .. "'")
        end
        if obj.__pytype == "file" then
            if name == "__enter__" then
                return function()
                    obj.__handle = fs.open(obj.__path, obj.__mode)
                    if not obj.__handle then
                        error(makeException("IOError",
                            "cannot open " .. obj.__path), 0)
                    end
                    return obj
                end
            end
            if name == "__exit__" then
                return function(et, ev, tb)
                    if obj.__handle then
                        obj.__handle.close()
                        obj.__handle = nil
                    end
                    return false
                end
            end
            if name == "read" then
                return function(n)
                    if not obj.__handle then
                        obj.__handle = fs.open(obj.__path, "r")
                    end
                    if not obj.__handle then return nil end
                    if n == nil then return obj.__handle.readAll() end
                    local buf = {}
                    for i = 1, n do
                        local c = obj.__handle.read()
                        if not c then break end
                        table.insert(buf, c)
                    end
                    return table.concat(buf)
                end
            end
            if name == "readAll" or name == "readall" then
                return function()
                    if not obj.__handle then
                        obj.__handle = fs.open(obj.__path, "r")
                    end
                    if not obj.__handle then return nil end
                    return obj.__handle.readAll()
                end
            end
            if name == "readLine" or name == "readline" then
                return function()
                    if not obj.__handle then
                        obj.__handle = fs.open(obj.__path, "r")
                    end
                    if not obj.__handle then return nil end
                    return obj.__handle.readLine()
                end
            end
            if name == "write" then
                return function(s)
                    if not obj.__handle then
                        obj.__handle = fs.open(obj.__path, "w")
                    end
                    if obj.__handle then
                        obj.__handle.write(tostring(s))
                    end
                end
            end
            if name == "close" then
                return function()
                    if obj.__handle then
                        obj.__handle.close()
                        obj.__handle = nil
                    end
                end
            end
            self:error("file has no attribute '" .. name .. "'")
        end
        if obj.__pytype == "list" then
            if name=="append" then
                return function(v) table.insert(obj, v) end
            end
            if name=="pop" then
                return function()
                    if #obj==0 then
                        error(makeException("IndexError",
                            "pop from empty list"),0)
                    end
                    return table.remove(obj)
                end
            end
            if name=="insert" then
                return function(i,v) table.insert(obj, i+1, v) end
            end
            if name=="remove" then
                return function(v)
                    for i=1,#obj do
                        if obj[i]==v then table.remove(obj, i); return end
                    end
                end
            end
            if name=="sort" then return function() table.sort(obj) end end
            if name=="reverse" then
                return function()
                    local n = #obj
                    for i=1,math.floor(n/2) do
                        obj[i],obj[n-i+1]=obj[n-i+1],obj[i]
                    end
                end
            end
            if name=="index" then
                return function(v)
                    for i=1,#obj do
                        if obj[i]==v then return i-1 end
                    end
                    error(makeException("ValueError",
                        "value not in list"),0)
                end
            end
            if name=="count" then
                return function(v)
                    local n=0
                    for i=1,#obj do if obj[i]==v then n=n+1 end end
                    return n
                end
            end
            if name=="extend" then
                return function(other)
                    for i=1,#other do table.insert(obj, other[i]) end
                end
            end
            if name=="copy" then
                return function()
                    local c={__pytype="list"}
                    for i=1,#obj do c[i]=obj[i] end
                    return c
                end
            end
        elseif obj.__pytype == "dict" then
            if name=="get" then
                return function(k,d)
                    local v=obj.data[k]
                    if v==nil then return d end
                    return v
                end
            end
            if name=="keys" then
                return function()
                    local o={__pytype="list"}
                    for k in pairs(obj.data) do table.insert(o, k) end
                    return o
                end
            end
            if name=="values" then
                return function()
                    local o={__pytype="list"}
                    for _,v in pairs(obj.data) do
                        table.insert(o, v)
                    end
                    return o
                end
            end
            if name=="items" then
                return function()
                    local o={__pytype="list"}
                    for k,v in pairs(obj.data) do
                        table.insert(o, {__pytype="tuple", k, v})
                    end
                    return o
                end
            end
            if name=="update" then
                return function(other)
                    for k,v in pairs(other.data) do
                        obj.data[k]=v
                    end
                end
            end
            if name=="pop" then
                return function(k,d)
                    local v = obj.data[k]
                    if v==nil then return d end
                    obj.data[k] = nil
                    return v
                end
            end
        end
    end
    self:error("object has no attribute '" .. name .. "'")
end

function Interpreter:evalBinOp(node)
    local op = node.op
    if op=="and" then
        local l = self:eval(node.left)
        if not pyTruthy(l) then return l end
        return self:eval(node.right)
    elseif op=="or" then
        local l = self:eval(node.left)
        if pyTruthy(l) then return l end
        return self:eval(node.right)
    end

    local l = self:eval(node.left)
    local r = self:eval(node.right)

    if type(l) == "table" and l.__pytype == "instance" then
        local methodName = ({
            ["+"]="__add__", ["-"]="__sub__", ["*"]="__mul__",
            ["/"]="__truediv__", ["//"]="__floordiv__", ["%"]="__mod__",
            ["**"]="__pow__", ["=="]="__eq__", ["<"]="__lt__",
            [">"]="__gt__", ["<="]="__le__", [">="]="__ge__",
            ["!="]="__ne__", ["&"]="__and__", ["|"]="__or__",
            ["^"]="__xor__", ["<<"]="__lshift__", [">>"]="__rshift__",
        })[op]
        if methodName then
            local m = lookupMethod(l.__class, methodName)
            if m then return m(l, r) end
        end
    end

    if op=="+" then
        if type(l)=="table" and type(r)=="table" then
            if (l.__pytype=="list" and r.__pytype=="list")
               or (l.__pytype=="tuple" and r.__pytype=="tuple") then
                local o = {__pytype=l.__pytype}
                for i=1,#l do o[#o+1]=l[i] end
                for i=1,#r do o[#o+1]=r[i] end
                return o
            end
        end
        if type(l)=="string" and type(r)=="string" then
            return l .. r
        end
        if type(l)~="number" or type(r)~="number" then
            error(makeException("TypeError",
                "unsupported operand type(s) for +"), 0)
        end
        return l + r
    elseif op=="-" then
        if type(l)~="number" or type(r)~="number" then
            error(makeException("TypeError",
                "unsupported operand type(s) for -"), 0)
        end
        return l - r
    elseif op=="*" then
        if type(l)=="string" and type(r)=="number" then
            return string.rep(l, r)
        end
        if type(r)=="string" and type(l)=="number" then
            return string.rep(r, l)
        end
        if type(l)~="number" or type(r)~="number" then
            error(makeException("TypeError",
                "unsupported operand type(s) for *"), 0)
        end
        return l * r
    elseif op=="/" then
        if r == 0 then
            error(makeException("ZeroDivisionError",
                "division by zero"),0)
        end
        return l / r
    elseif op=="//" then
        if r == 0 then
            error(makeException("ZeroDivisionError",
                "division by zero"),0)
        end
        return math.floor(l / r)
    elseif op=="%" then
        if r == 0 then
            error(makeException("ZeroDivisionError",
                "modulo by zero"),0)
        end
        return l % r
    elseif op=="**" then
        return l ^ r
    elseif op=="&" then
        return bit32.band(math.floor(l), math.floor(r))
    elseif op=="|" then
        return bit32.bor(math.floor(l), math.floor(r))
    elseif op=="^" then
        return bit32.bxor(math.floor(l), math.floor(r))
    elseif op=="<<" then
        return bit32.lshift(math.floor(l), math.floor(r))
    elseif op==">>" then
        return bit32.rshift(math.floor(l), math.floor(r))
    elseif op=="==" then
        return pyEq(l, r)
    elseif op=="!=" then
        return not pyEq(l, r)
    elseif op=="<" then return l < r
    elseif op=="<=" then return l <= r
    elseif op==">" then return l > r
    elseif op==">=" then return l >= r
    elseif op=="in" then
        if type(r)=="string" then
            return r:find(l,1,true) ~= nil
        end
        if type(r)=="table" then
            if r.__pytype=="dict" then
                return r.data[l] ~= nil
            end
            if r.__pytype == "instance" then
                local contains = lookupMethod(r.__class, "__contains__")
                if contains then return pyTruthy(contains(r, l)) end
            end
            if r.__pytype=="generator" then
                while true do
                    local ok, v = pcall(r.__next__)
                    if not ok then break end
                    if pyEq(v, l) then return true end
                end
                return false
            end
            for i=1,#r do if pyEq(r[i], l) then return true end end
            return false
        end
        self:error("'in' requires iterable")
    end
    self:error("unknown binop: " .. op)
end

function Interpreter:execWithInline(items, idx, body)
    if idx > #items then
        return self:execBlock(body)
    end
    local item = items[idx]
    local mgr = self:eval(item.expr)
    local enter = self:getAttr(mgr, "__enter__")
    local exit_ = self:getAttr(mgr, "__exit__")
    local value = enter()
    if item.name then self:assign(item.name, value) end
    local result
    local ok, err = pcall(function()
        result = self:execWithInline(items, idx + 1, body)
    end)
    if ok then
        exit_(nil, nil, nil)
    else
        local exc = wrapError(err)
        local suppress = exit_(exc.type, exc.value, nil)
        if not pyTruthy(suppress) then error(exc, 0) end
    end
    return result
end

function Interpreter:execDel(target)
    if target.type == "Name" then
        local name = target.name
        for i = #self.scopes, 1, -1 do
            if rawget(self.scopes[i], name) ~= nil then
                self.scopes[i][name] = nil
                return
            end
        end
        error(makeException("NameError",
            "name '" .. name .. "' is not defined"), 0)
    elseif target.type == "Index" then
        local obj = self:eval(target.obj)
        local idx = self:eval(target.index)
        if type(obj) == "table" then
            if obj.__pytype == "dict" then
                obj.data[idx] = nil
            elseif obj.__pytype == "list" then
                table.remove(obj, idx + 1)
            else
                obj[idx] = nil
            end
        end
    elseif target.type == "Attr" then
        local obj = self:eval(target.obj)
        if type(obj) == "table" and obj.__pytype == "instance" then
            obj.__attrs[target.name] = nil
        end
    else
        self:error("cannot delete this target")
    end
end

function Interpreter:execStmt(node)
    local t = node.type
    if t=="ExprStmt" then
        self:eval(node.expr)
    elseif t=="Assign" then
        local value = self:eval(node.value)
        if node.op ~= "=" then
            local current = self:eval(node.target)
            local binop = node.op:sub(1, -2)
            if binop=="+" and type(current)=="table"
               and type(value)=="table" then
                if current.__pytype=="list"
                   and value.__pytype=="list" then
                    for i=1,#value do
                        table.insert(current, value[i])
                    end
                    value = current
                else
                    value = current + value
                end
            elseif binop=="-" then value = current - value
            elseif binop=="*" then value = current * value
            elseif binop=="/" then
                if value==0 then
                    error(makeException("ZeroDivisionError",
                        "division by zero"),0)
                end
                value = current / value
            end
        end
        self:assignTarget(node.target, value)
    elseif t=="If" then
        if pyTruthy(self:eval(node.cond)) then
            return self:execBlock(node.body)
        end
        for _,e in ipairs(node.elifs) do
            if pyTruthy(self:eval(e.cond)) then
                return self:execBlock(e.body)
            end
        end
        if node.elseBody then
            return self:execBlock(node.elseBody)
        end
    elseif t=="While" then
        while pyTruthy(self:eval(node.cond)) do
            local r = self:execBlock(node.body)
            if r and r.__return then return r end
            if r and r.__break then break end
        end
    elseif t=="For" then
        local iterable = self:eval(node.iter)
        if type(iterable) ~= "table" then
            self:error("'for' requires iterable")
        end
        local function iterNext(iterator)
            local nextFn
            if iterator.__pytype == "generator" then
                nextFn = iterator.__next__
            elseif iterator.__pytype == "instance" then
                nextFn = self:getAttr(iterator, "__next__")
            elseif type(iterator.__next__) == "function" then
                nextFn = iterator.__next__
            end
            if not nextFn then
                self:error("iterator has no __next__")
            end
            local ok, val = pcall(nextFn)
            if not ok then
                local e = wrapError(val)
                if e.type == "StopIteration" then
                    return nil, true
                end
                error(val, 0)
            end
            return val, false
        end
        local function runLoop(iterator)
            while true do
                local val, stop = iterNext(iterator)
                if stop then break end
                if #node.names == 1 then
                    self:assign(node.names[1], val)
                else
                    if type(val) ~= "table" then
                        self:error("cannot unpack non-iterable")
                    end
                    for j = 1, #node.names do
                        self:assign(node.names[j], val[j])
                    end
                end
                local r = self:execBlock(node.body)
                if r and r.__return then return r end
                if r and r.__break then break end
            end
            return nil
        end
        if iterable.__pytype == "generator" then
            local r = runLoop(iterable)
            if r then return r end
        elseif iterable.__pytype == "instance" then
            local iterFn = self:getAttr(iterable, "__iter__")
            if not iterFn then self:error("object is not iterable") end
            local iterator = iterFn()
            local r = runLoop(iterator)
            if r then return r end
        else
            for i = 1, #iterable do
                local item = iterable[i]
                if #node.names == 1 then
                    self:assign(node.names[1], item)
                else
                    if type(item) ~= "table" then
                        self:error("cannot unpack non-iterable "
                            .. type(item))
                    end
                    for j = 1, #node.names do
                        self:assign(node.names[j], item[j])
                    end
                end
                local r = self:execBlock(node.body)
                if r and r.__return then return r end
                if r and r.__break then break end
            end
        end
    elseif t=="Def" then
        local fn = self:makeFunction(node.name, node.params, node.body,
                                     node.vararg, node.kwarg)
        local flags = {}
        local customs = {}
        if node.decorators then
            for _, dec in ipairs(node.decorators) do
                if dec.type == "Name" and (dec.name == "staticmethod"
                    or dec.name == "property"
                    or dec.name == "classmethod") then
                    if dec.name == "staticmethod" then
                        flags.static = true
                    elseif dec.name == "property" then
                        flags.property = true
                    elseif dec.name == "classmethod" then
                        flags.classmethod = true
                    end
                else
                    table.insert(customs, dec)
                end
            end
        end
        METHOD_FLAGS[fn] = flags
        for i = #customs, 1, -1 do
            local dec = self:eval(customs[i])
            if type(dec) == "function" then fn = dec(fn) end
        end
        self:assign(node.name, fn)
    elseif t=="Class" then
        self:execClass(node)
    elseif t=="Return" then
        local v = nil
        if node.value then v = self:eval(node.value) end
        return {__return=true, value=v}
    elseif t=="Yield" then
        local value = nil
        if node.value then value = self:eval(node.value) end
        coroutine.yield(value)
        return nil
    elseif t=="YieldFrom" then
        local iterable = self:eval(node.value)
        if type(iterable) ~= "table" then
            self:error("yield from requires an iterable")
        end
        if iterable.__pytype == "generator" then
            while true do
                local ok, val = pcall(iterable.__next__)
                if not ok then
                    local e = wrapError(val)
                    if e.type == "StopIteration" then break end
                    error(val, 0)
                end
                coroutine.yield(val)
            end
        else
            for i = 1, #iterable do coroutine.yield(iterable[i]) end
        end
        return nil
    elseif t=="Pass" then
    elseif t=="Del" then
        for _, target in ipairs(node.targets) do
            self:execDel(target)
        end
    elseif t=="Assert" then
        if not pyTruthy(self:eval(node.cond)) then
            local msg = "Assertion failed"
            if node.msg then msg = pyStr(self:eval(node.msg)) end
            error(makeException("AssertionError", msg), 0)
        end
    elseif t=="Break" then return {__break=true}
    elseif t=="Continue" then return {__continue=true}
    elseif t=="Unsupported" then
        error(makeException("NotImplementedError",
            "feature not supported: " .. (node.feature or "unknown")), 0)
    elseif t=="With" then
        return self:execWithInline(node.items, 1, node.body)
    elseif t=="Import" then
        for _, mod in ipairs(node.modules) do
            local modTable = self:importModule(mod.name)
            local bindName = mod.alias or mod.name:match("^([^.]+)")
            if mod.alias then
                self:assign(mod.alias, modTable)
            else
                self:assign(bindName, modTable)
            end
        end
    elseif t=="FromImport" then
        local modTable = self:importModule(node.module)
        for _, n in ipairs(node.names) do
            if n.name == "*" then
                local ns = modTable.__scope
                for k, v in pairs(ns) do
                    if not k:match("^_") then self:assign(k, v) end
                end
            else
                local value = modTable.__scope[n.name]
                if value == nil then
                    error(makeException("ImportError",
                        "cannot import name '" .. n.name
                        .. "' from '" .. node.module .. "'"), 0)
                end
                self:assign(n.alias or n.name, value)
            end
        end
    elseif t=="Global" then
        for _, name in ipairs(node.names) do
            self.scopes[1][name] = self.scopes[1][name] or nil
        end
    elseif t=="Nonlocal" then
    elseif t=="Raise" then
        if node.exc == nil then
            error(makeException("RuntimeError",
                "No active exception to reraise"), 0)
        end
        local exc = self:eval(node.exc)
        if isException(exc) then error(exc, 0) end
        error(makeException("RuntimeError", pyStr(exc)), 0)
    elseif t=="Try" then
        return self:execTry(node)
    else
        self:error("unknown statement: " .. t)
    end
end

function Interpreter:importModule(name)
    if MODULE_CACHE[name] then return MODULE_CACHE[name] end
    local bmods = getBuiltinModules()
    if bmods[name] then
        MODULE_CACHE[name] = bmods[name]
        return bmods[name]
    end
    local parts = {}
    for part in name:gmatch("[^%.]+") do table.insert(parts, part) end
    local relPath = table.concat(parts, "/")
    local candidatePaths = {
        PYLIB_PATH .. "/" .. relPath .. ".py",
        PYLIB_PATH .. "/" .. relPath .. "/__init__.py",
    }
    local filePath = nil
    for _, p in ipairs(candidatePaths) do
        if fs.exists(p) and not fs.isDir(p) then
            filePath = p; break
        end
    end
    if not filePath then
        error(makeException("ImportError",
            "No module named '" .. name .. "'"), 0)
    end
    local f = fs.open(filePath, "r")
    if not f then
        error(makeException("ImportError",
            "Cannot open " .. filePath), 0)
    end
    local src = f.readAll()
    f.close()
    local modInterp = Interpreter.new()
    local builtins = modInterp:getBuiltins()
    for k, v in pairs(builtins) do modInterp.scopes[1][k] = v end
    table.insert(modInterp.scopes, {})
    local lexer = Lexer.new(src)
    local tokens = lexer:tokenize()
    local parser = Parser.new(tokens)
    local ast = parser:parse()
    local ok, err = pcall(function()
        for _, stmt in ipairs(ast.body) do
            modInterp:execStmt(stmt)
        end
    end)
    if not ok then error(wrapError(err), 0) end
    local modTable = {
        __pytype = "module",
        __name = name,
        __scope = modInterp.scopes[#modInterp.scopes],
        __path = filePath,
    }
    MODULE_CACHE[name] = modTable
    return modTable
end

function Interpreter:execClass(node)
    local bases = {}
    for _, bname in ipairs(node.bases) do
        local b = self:lookup(bname)
        if not b or type(b) ~= "table" or b.__pytype ~= "class" then
            self:error("base class not found or not a class: " .. bname)
        end
        table.insert(bases, b)
    end
    local classTable = {
        __pytype = "class", name = node.name, bases = bases,
        methods = {}, attrs = {}
    }
    for _, stmt in ipairs(node.body) do
        if stmt.type == "Def" then
            local fn = self:makeFunction(stmt.name, stmt.params,
                stmt.body, stmt.vararg, stmt.kwarg)
            local flags = { definingClass = classTable }
            local customs = {}
            if stmt.decorators then
                for _, dec in ipairs(stmt.decorators) do
                    if dec.type == "Name"
                       and (dec.name == "staticmethod"
                        or dec.name == "property"
                        or dec.name == "classmethod") then
                        if dec.name == "staticmethod" then
                            flags.static = true
                        elseif dec.name == "property" then
                            flags.property = true
                        elseif dec.name == "classmethod" then
                            flags.classmethod = true
                        end
                    else
                        table.insert(customs, dec)
                    end
                end
            end
            METHOD_FLAGS[fn] = flags
            for i = #customs, 1, -1 do
                local dec = self:eval(customs[i])
                if type(dec) == "function" then fn = dec(fn) end
            end
            classTable.methods[stmt.name] = fn
        elseif stmt.type == "Pass" then
        elseif stmt.type == "Assign" and stmt.target.type == "Name" then
            classTable.attrs[stmt.target.name] = self:eval(stmt.value)
        end
    end
    self:assign(node.name, classTable)
end

function Interpreter:execTry(node)
    local tryResult, tryException
    local ok, err = pcall(function() return self:execBlock(node.body) end)
    if ok then tryResult = err else tryException = wrapError(err) end
    local handled = false
    local finalResult = tryResult
    if tryException then
        for _, handler in ipairs(node.handlers) do
            local shouldCatch = false
            if not handler.excType then shouldCatch = true
            elseif handler.excType == tryException.type then
                shouldCatch = true
            elseif handler.excType == "Exception" then
                shouldCatch = (tryException.type ~= "BaseException")
            elseif handler.excType == "BaseException" then
                shouldCatch = true
            end
            if shouldCatch then
                if handler.name then
                    self:assign(handler.name, tryException)
                end
                local hok, herr = pcall(function()
                    return self:execBlock(handler.body)
                end)
                if hok then
                    if herr then finalResult = herr end
                    handled = true
                    tryException = nil
                else
                    tryException = wrapError(herr)
                    handled = false
                end
                break
            end
        end
    else
        if node.elseBody then
            local eok, eerr = pcall(function()
                return self:execBlock(node.elseBody)
            end)
            if eok then
                if eerr then finalResult = eerr end
            else
                tryException = wrapError(eerr)
                handled = false
            end
        else
            handled = true
        end
    end
    if node.finallyBody then
        local fok, ferr = pcall(function()
            return self:execBlock(node.finallyBody)
        end)
        if not fok then
            tryException = wrapError(ferr)
            handled = false
        elseif ferr and not finalResult then
            finalResult = ferr
        end
    end
    if tryException and not handled then error(tryException, 0) end
    return finalResult
end

function Interpreter:assignTarget(target, value)
    if target.type=="Name" then
        self:assign(target.name, value)
    elseif target.type=="Index" then
        local obj = self:eval(target.obj)
        local idx = self:eval(target.index)
        if type(obj)=="table" then
            if obj.__pytype=="dict" then
                obj.data[idx]=value
            elseif obj.__pytype == "instance" then
                local m = lookupMethod(obj.__class, "__setitem__")
                if m then m(obj, idx, value); return end
                error(makeException("TypeError",
                    "object does not support item assignment"), 0)
            else
                obj[idx+1]=value
            end
        else
            self:error("cannot assign to index")
        end
    elseif target.type=="Attr" then
        local obj = self:eval(target.obj)
        if type(obj)=="table" then
            if obj.__pytype == "instance" then
                local slots = lookupClassAttr(obj.__class, "__slots__")
                if slots and slots.__pytype == "list" then
                    local allowed = false
                    for i = 1, #slots do
                        if slots[i] == target.name then
                            allowed = true; break
                        end
                    end
                    if not allowed then
                        error(makeException("AttributeError",
                            "object has no attribute '"
                            .. target.name .. "'"), 0)
                    end
                end
                local sa = lookupMethod(obj.__class, "__setattr__")
                if sa then
                    sa(obj, target.name, value)
                else
                    obj.__attrs[target.name] = value
                end
            elseif obj.__pytype == "module" then
                obj.__scope[target.name] = value
            else
                obj[target.name] = value
            end
        end
    elseif target.type=="StarArg" then
        self:assignTarget(target.expr, value)
    elseif target.type=="Tuple" then
        if type(value)=="table" then
            local starIdx = nil
            for i, t in ipairs(target.elements) do
                if t.type == "StarArg" then
                    starIdx = i; break
                end
            end
            if starIdx then
                local before = starIdx - 1
                local after = #target.elements - starIdx
                for i = 1, before do
                    self:assignTarget(target.elements[i], value[i])
                end
                local rest = {__pytype = "list"}
                local from = before + 1
                local to = #value - after
                for i = from, to do
                    table.insert(rest, value[i])
                end
                self:assignTarget(target.elements[starIdx].expr, rest)
                for i = 1, after do
                    local srcIdx = #value - after + i
                    local dstIdx = starIdx + i
                    self:assignTarget(target.elements[dstIdx],
                                      value[srcIdx])
                end
            else
                for i, t in ipairs(target.elements) do
                    self:assignTarget(t, value[i])
                end
            end
        end
    else
        self:error("invalid assignment target")
    end
end

function Interpreter:execBlock(stmts)
    for _,stmt in ipairs(stmts) do
        local r = self:execStmt(stmt)
        if r then return r end
    end
end

function Interpreter:run(ast)
    local builtins = self:getBuiltins()
    for k,v in pairs(builtins) do self.scopes[1][k] = v end
    for _,stmt in ipairs(ast.body) do self:execStmt(stmt) end
end

-- ============================================================
-- 6. PUBLIC API
-- ============================================================

function py.runString(src)
    local lexer = Lexer.new(src)
    local tokens = lexer:tokenize()
    local parser = Parser.new(tokens)
    local ast = parser:parse()
    local interp = Interpreter.new()
    interp:run(ast)
end

function py.runFile(path)
    local f = fs.open(path, "r")
    if not f then error("cannot open file: " .. path) end
    local src = f.readAll()
    f.close()
    py.runString(src)
end

py.Interpreter = Interpreter
py.Lexer = Lexer
py.Parser = Parser

if type(arg) == "table" and arg[1] then
    local ok, err = pcall(py.runFile, arg[1])
    if not ok then
        print("Traceback (most recent call last):")
        if isException(err) then
            print("  " .. excStr(err))
        else
            print("  " .. tostring(err))
        end
    end
end

return py
