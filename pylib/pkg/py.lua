-- py.lua - Python subset interpreter for CraftOS 1.9
-- Supports: classes, closures, exceptions, multi-line strings, and /pylib imports
local unpack = unpack or table.unpack
local py = {}

-- ============================================================
-- 0. MODULE SYSTEM
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
-- 1. EXCEPTION HELPERS
-- ============================================================

local function makeException(excType, value)
    return {__pyexception = true, type = excType, value = value}
end
local function isException(x) return type(x) == "table" and x.__pyexception == true end
local function wrapError(err)
    if isException(err) then return err end
    if type(err) == "table" and (err.__return or err.__break or err.__continue) then return err end
    return makeException("RuntimeError", tostring(err))
end
local function excStr(e)
    if not isException(e) then return tostring(e) end
    if e.value == nil or e.value == "" then return e.type end
    return e.type .. ": " .. tostring(e.value)
end

-- ============================================================
-- 2. LEXER
-- ============================================================

local KEYWORDS = {
    ["and"]=true, ["or"]=true, ["not"]=true, ["if"]=true, ["elif"]=true,
    ["else"]=true, ["while"]=true, ["for"]=true, ["in"]=true, ["def"]=true,
    ["return"]=true, ["pass"]=true, ["break"]=true, ["continue"]=true,
    ["True"]=true, ["False"]=true, ["None"]=true, ["import"]=true,
    ["from"]=true, ["as"]=true, ["lambda"]=true, ["global"]=true,
    ["is"]=true, ["del"]=true, ["raise"]=true, ["assert"]=true,
    ["try"]=true, ["except"]=true, ["finally"]=true,
    ["class"]=true, ["nonlocal"]=true,
}

local function isDigit(c) return c >= "0" and c <= "9" end
local function isAlpha(c) return (c >= "a" and c <= "z") or (c >= "A" and c <= "Z") or c == "_" end
local function isAlnum(c) return isAlpha(c) or isDigit(c) end

local Lexer = {}
Lexer.__index = Lexer
function Lexer.new(src)
    return setmetatable({
        src = src:gsub("\r\n", "\n"):gsub("\r", "\n"),
        pos = 1, line = 1, indentStack = {0}, tokens = {}, parenDepth = 0
    }, Lexer)
end
function Lexer:peek(o) o=o or 0; local p=self.pos+o; if p>#self.src then return nil end; return self.src:sub(p,p) end
function Lexer:advance() local c=self.src:sub(self.pos,self.pos); self.pos=self.pos+1; if c=="\n" then self.line=self.line+1 end; return c end
function Lexer:error(m) error(string.format("Syntax error at line %d: %s", self.line, m)) end
function Lexer:addToken(t,v) table.insert(self.tokens,{type=t,value=v,line=self.line}) end

function Lexer:readString(q)
    local ch = {}
    while true do
        local c = self:peek()
        if c == nil then self:error("Unterminated string") end
        if c == q then self:advance(); break end
        if c == "\\" then
            self:advance(); local e = self:advance()
            if e=="n" then table.insert(ch,"\n")
            elseif e=="t" then table.insert(ch,"\t")
            elseif e=="r" then table.insert(ch,"\r")
            elseif e=="\\" then table.insert(ch,"\\")
            elseif e=="'" then table.insert(ch,"'")
            elseif e=='"' then table.insert(ch,'"')
            elseif e=="0" then table.insert(ch,"\0")
            else table.insert(ch,e) end
        else table.insert(ch, self:advance()) end
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
            self:advance(); local e = self:advance()
            if e=="n" then table.insert(ch,"\n")
            elseif e=="t" then table.insert(ch,"\t")
            elseif e=="r" then table.insert(ch,"\r")
            elseif e=="\\" then table.insert(ch,"\\")
            elseif e=="'" then table.insert(ch,"'")
            elseif e=='"' then table.insert(ch,'"')
            elseif e=="\n" then -- line continuation, skip
            else table.insert(ch,e) end
        else table.insert(ch, self:advance()) end
    end
    return table.concat(ch)
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
        if c and isAlnum(c) then table.insert(ch, self:advance()) else break end
    end
    return table.concat(ch)
end

function Lexer:tokenize()
    while self.pos <= #self.src do
        local c = self:peek()
        if c == "\n" then
            self:advance()
            self:addToken("NEWLINE","\n")
            if self.parenDepth == 0 then
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
                        while #self.indentStack > 1 and self.indentStack[#self.indentStack] > indent do
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
        elseif c=="#" then while self:peek() and self:peek()~="\n" do self:advance() end
        elseif c=='"' or c=="'" then
            if self:peek(1) == c and self:peek(2) == c then
                self:advance(); self:advance(); self:advance()
                self:addToken("STRING", self:readMultilineString(c))
            else
                self:advance()
                self:addToken("STRING", self:readString(c))
            end
        elseif isDigit(c) then self:addToken("NUMBER", self:readNumber())
        elseif isAlpha(c) then
            local name = self:readName()
            if KEYWORDS[name] then self:addToken("KEYWORD", name)
            else self:addToken("NAME", name) end
        else
            self:advance()
            local two = c .. (self:peek() or "")
            if two=="==" or two=="!=" or two=="<=" or two==">="
               or two=="**" or two=="//" or two=="+=" or two=="-="
               or two=="*=" or two=="/=" then
                self:advance(); self:addToken("OP", two)
            else
                if c=="(" or c=="[" or c=="{" then self.parenDepth=self.parenDepth+1
                elseif c==")" or c=="]" or c=="}" then self.parenDepth=self.parenDepth-1 end
                self:addToken("OP", c)
            end
        end
    end
    if #self.tokens>0 and self.tokens[#self.tokens].type~="NEWLINE" then self:addToken("NEWLINE","\n") end
    while #self.indentStack > 1 do table.remove(self.indentStack); self:addToken("DEDENT",0) end
    self:addToken("EOF", nil)
    return self.tokens
end

-- ============================================================
-- 3. PARSER
-- ============================================================

local Parser = {}
Parser.__index = Parser
function Parser.new(tokens) return setmetatable({tokens=tokens,pos=1}, Parser) end
function Parser:peek() return self.tokens[self.pos] end
function Parser:next() local t=self.tokens[self.pos]; self.pos=self.pos+1; return t end
function Parser:expect(type, value)
    local t = self:peek()
    if not t or t.type~=type then self:error("Expected "..type..", got "..(t and t.type or "EOF")) end
    if value and t.value~=value then self:error("Expected '"..value.."', got '"..tostring(t.value).."'") end
    return self:next()
end
function Parser:error(msg) local t=self:peek(); error(string.format("Parse error at line %s: %s", t and t.line or "?", msg)) end
function Parser:skipNewlines() while self:peek() and self:peek().type=="NEWLINE" do self:next() end end

function Parser:parse()
    local body = self:parseBlock()
    self:expect("EOF")
    return {type="Module", body=body}
end

function Parser:parseBlock()
    self:expect("NEWLINE"); self:expect("INDENT")
    local stmts = {}
    while self:peek() and self:peek().type~="DEDENT" and self:peek().type~="EOF" do
        self:skipNewlines()
        if self:peek().type=="DEDENT" or self:peek().type=="EOF" then break end
        local s = self:parseStatement()
        if s then table.insert(stmts, s) end
    end
    if self:peek().type=="DEDENT" then self:next() end
    return stmts
end

-- Parse dotted module name like foo.bar.baz
function Parser:parseDottedName()
    local parts = {self:expect("NAME").value}
    while self:peek().type == "OP" and self:peek().value == "." do
        self:next()
        table.insert(parts, self:expect("NAME").value)
    end
    return table.concat(parts, ".")
end

function Parser:parseImport()
    self:next()  -- consume 'import'
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
    self:next()  -- consume 'from'
    local moduleName = self:parseDottedName()
    self:expect("KEYWORD", "import")
    -- from foo import *
    if self:peek().type == "OP" and self:peek().value == "*" then
        self:next()
        return {type="FromImport", module=moduleName, names={{name="*", alias=nil}}}
    end
    -- from foo import bar, baz as qux
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

function Parser:parseStatement()
    local t = self:peek()
    if t.type == "KEYWORD" then
        if t.value=="if" then return self:parseIf()
        elseif t.value=="while" then return self:parseWhile()
        elseif t.value=="for" then return self:parseFor()
        elseif t.value=="def" then return self:parseDef()
        elseif t.value=="class" then return self:parseClass()
        elseif t.value=="return" then
            self:next()
            local nt = self:peek()
            if nt.type=="NEWLINE" or nt.type=="DEDENT" or nt.type=="EOF" then
                return {type="Return", value=nil}
            end
            return {type="Return", value=self:parseExpression()}
        elseif t.value=="pass" then self:next(); return {type="Pass"}
        elseif t.value=="break" then self:next(); return {type="Break"}
        elseif t.value=="continue" then self:next(); return {type="Continue"}
        elseif t.value=="import" then return self:parseImport()
        elseif t.value=="from" then return self:parseFrom()
        elseif t.value=="global" then
            self:next()
            local names = {}
            repeat
                table.insert(names, self:expect("NAME").value)
                if self:peek().type=="OP" and self:peek().value=="," then self:next() else break end
            until false
            return {type="Global", names=names}
        elseif t.value=="nonlocal" then
            self:next()
            local names = {}
            repeat
                table.insert(names, self:expect("NAME").value)
                if self:peek().type=="OP" and self:peek().value=="," then self:next() else break end
            until false
            return {type="Nonlocal", names=names}
        elseif t.value=="try" then return self:parseTry()
        elseif t.value=="raise" then return self:parseRaise()
        end
    end
    return self:parseExprStatement()
end

function Parser:parseClass()
    self:next()
    local name = self:expect("NAME").value
    local bases = {}
    if self:peek().type=="OP" and self:peek().value=="(" then
        self:next()
        if not (self:peek().type=="OP" and self:peek().value==")") then
            repeat
                table.insert(bases, self:expect("NAME").value)
                if self:peek().type=="OP" and self:peek().value=="," then self:next() else break end
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
    while self:peek() and self:peek().type=="KEYWORD" and self:peek().value=="except" do
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
    if self:peek() and self:peek().type=="KEYWORD" and self:peek().value=="else" then
        self:next(); self:expect("OP", ":"); elseBody = self:parseBlock()
    end
    if self:peek() and self:peek().type=="KEYWORD" and self:peek().value=="finally" then
        self:next(); self:expect("OP", ":"); finallyBody = self:parseBlock()
    end
    return {type="Try", body=body, handlers=handlers, elseBody=elseBody, finallyBody=finallyBody}
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
    while self:peek() and self:peek().type=="KEYWORD" and self:peek().value=="elif" do
        self:next()
        local c = self:parseExpression()
        self:expect("OP", ":")
        table.insert(elifs, {cond=c, body=self:parseBlock()})
    end
    if self:peek() and self:peek().type=="KEYWORD" and self:peek().value=="else" then
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
    if not (self:peek().type=="OP" and self:peek().value==")") then
        repeat
            local pname = self:expect("NAME").value
            local default = nil
            if self:peek().type=="OP" and self:peek().value=="=" then
                self:next(); default = self:parseExpression()
            end
            table.insert(params, {name=pname, default=default})
            if self:peek().type=="OP" and self:peek().value=="," then self:next() else break end
        until false
    end
    self:expect("OP", ")")
    self:expect("OP", ":")
    return {type="Def", name=name, params=params, body=self:parseBlock()}
end

function Parser:parseExprStatement()
    local expr = self:parseExpression()
    local t = self:peek()
    if t.type=="OP" and (t.value=="=" or t.value=="+=" or t.value=="-=" or t.value=="*=" or t.value=="/=") then
        local op = self:next().value
        local value = self:parseExpression()
        if expr.type~="Name" and expr.type~="Index" and expr.type~="Attr" and expr.type~="Tuple" then
            self:error("Invalid assignment target")
        end
        return {type="Assign", target=expr, op=op, value=value}
    end
    return {type="ExprStmt", expr=expr}
end

-- Expressions
function Parser:parseExpression() return self:parseTernary() end
function Parser:parseTernary()
    local cond = self:parseOr()
    if self:peek().type=="KEYWORD" and self:peek().value=="if" then
        self:next()
        local c = self:parseOr()
        self:expect("KEYWORD", "else")
        return {type="Ternary", cond=c, then_expr=cond, else_expr=self:parseTernary()}
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
function Parser:parseComparison()
    local left = self:parseArith()
    while true do
        local t = self:peek()
        if t.type=="OP" and (t.value=="==" or t.value=="!=" or t.value=="<" or t.value=="<=" or t.value==">" or t.value==">=") then
            self:next()
            left = {type="BinOp", op=t.value, left=left, right=self:parseArith()}
        elseif t.type=="KEYWORD" and t.value=="in" then
            self:next()
            left = {type="BinOp", op="in", left=left, right=self:parseArith()}
        elseif t.type=="KEYWORD" and t.value=="not" then
            local nxt = self.tokens[self.pos+1]
            if nxt and nxt.type=="KEYWORD" and nxt.value=="in" then
                self:next(); self:next()
                left = {type="UnaryOp", op="not", operand={type="BinOp", op="in", left=left, right=self:parseArith()}}
            else break end
        else break end
    end
    return left
end
function Parser:parseArith()
    local left = self:parseTerm()
    while self:peek().type=="OP" and (self:peek().value=="+" or self:peek().value=="-") do
        local op = self:next().value
        left = {type="BinOp", op=op, left=left, right=self:parseTerm()}
    end
    return left
end
function Parser:parseTerm()
    local left = self:parseUnary()
    while self:peek().type=="OP" and (self:peek().value=="*" or self:peek().value=="/" or self:peek().value=="//" or self:peek().value=="%") do
        local op = self:next().value
        left = {type="BinOp", op=op, left=left, right=self:parseUnary()}
    end
    return left
end
function Parser:parseUnary()
    local t = self:peek()
    if t.type=="OP" and (t.value=="-" or t.value=="+") then
        self:next()
        local operand = self:parseUnary()
        if t.value=="-" then return {type="UnaryOp", op="-", operand=operand} end
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
                    table.insert(args, self:parseExpression())
                    if self:peek().type=="OP" and self:peek().value=="," then self:next() else break end
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
function Parser:parsePrimary()
    local t = self:peek()
    if t.type=="NUMBER" then self:next(); return {type="Number", value=t.value}
    elseif t.type=="STRING" then self:next(); return {type="String", value=t.value}
    elseif t.type=="NAME" then self:next(); return {type="Name", name=t.value}
    elseif t.type=="KEYWORD" then
        if t.value=="True" then self:next(); return {type="Bool", value=true}
        elseif t.value=="False" then self:next(); return {type="Bool", value=false}
        elseif t.value=="None" then self:next(); return {type="None"}
        elseif t.value=="lambda" then
            self:next()
            local params = {}
            if not (self:peek().type=="OP" and self:peek().value==":") then
                repeat
                    table.insert(params, {name=self:expect("NAME").value})
                    if self:peek().type=="OP" and self:peek().value=="," then self:next() else break end
                until false
            end
            self:expect("OP", ":")
            return {type="Lambda", params=params, body=self:parseExpression()}
        end
    elseif t.type=="OP" then
        if t.value=="(" then
            self:next()
            if self:peek().type=="OP" and self:peek().value==")" then self:next(); return {type="Tuple", elements={}} end
            local first = self:parseExpression()
            if self:peek().type=="OP" and self:peek().value=="," then
                local elems = {first}
                while self:peek().type=="OP" and self:peek().value=="," do
                    self:next()
                    if self:peek().type=="OP" and self:peek().value==")" then break end
                    table.insert(elems, self:parseExpression())
                end
                self:expect("OP", ")")
                return {type="Tuple", elements=elems}
            end
            self:expect("OP", ")")
            return first
        elseif t.value=="[" then
            self:next()
            local elems = {}
            if not (self:peek().type=="OP" and self:peek().value=="]") then
                repeat
                    table.insert(elems, self:parseExpression())
                    if self:peek().type=="OP" and self:peek().value=="," then self:next() else break end
                until false
            end
            self:expect("OP", "]")
            return {type="List", elements=elems}
        elseif t.value=="{" then
            self:next()
            local pairs_ = {}
            if not (self:peek().type=="OP" and self:peek().value=="}") then
                repeat
                    local k = self:parseExpression()
                    self:expect("OP", ":")
                    local v = self:parseExpression()
                    table.insert(pairs_, {key=k, value=v})
                    if self:peek().type=="OP" and self:peek().value=="," then self:next() else break end
                until false
            end
            self:expect("OP", "}")
            return {type="Dict", pairs=pairs_}
        end
    end
    self:error("Unexpected token: " .. tostring(t.value) .. " (" .. t.type .. ")")
end

-- ============================================================
-- 4. INTERPRETER
-- ============================================================

local Interpreter = {}
Interpreter.__index = Interpreter
function Interpreter.new() return setmetatable({globals={}, scopes={{}}}, Interpreter) end

function Interpreter:error(msg) error(makeException("RuntimeError", msg), 0) end

function Interpreter:lookup(name)
    for i = #self.scopes, 1, -1 do
        local v = rawget(self.scopes[i], name)
        if v ~= nil then return v end
    end
    return nil
end

-- Modified: default to innermost scope (supports module namespace isolation)
function Interpreter:assign(name, value)
    for i = #self.scopes, 1, -1 do
        if rawget(self.scopes[i], name) ~= nil then self.scopes[i][name] = value; return end
    end
    self.scopes[#self.scopes][name] = value
end

local function pyTruthy(v)
    if v == nil or v == false then return false end
    if v == 0 or v == "" then return false end
    if type(v) == "table" then
        if v.__pytype == "list" or v.__pytype == "tuple" then return #v > 0 end
        if v.__pytype == "dict" then return next(v.data) ~= nil end
        if v.__pyexception then return true end
    end
    return true
end

local function pyEq(a, b)
    if a == b then return true end
    if type(a) == "table" and type(b) == "table" then
        if a.__pytype == "list" and b.__pytype == "list" and #a == #b then
            for i = 1, #a do if not pyEq(a[i], b[i]) then return false end end
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
        if math.floor(v) == v and math.abs(v) < 1e15 then return string.format("%d", v) end
        return tostring(v)
    end
    if type(v) == "string" then return "'" .. v .. "'" end
    if type(v) == "table" then
        if v.__pyexception then return excStr(v) end
        if v.__pytype == "module" then return "<module '" .. v.__name .. "'>" end
        if v.__pytype == "instance" then return "<" .. v.__class.name .. " object>" end
        if v.__pytype == "class" then return "<class '" .. v.name .. "'>" end
        if v.__pytype == "list" then
            local p = {}; for i=1,#v do p[i]=pyRepr(v[i]) end
            return "[" .. table.concat(p, ", ") .. "]"
        elseif v.__pytype == "dict" then
            local p = {}; for k,val in pairs(v.data) do p[#p+1]=pyRepr(k)..": "..pyRepr(val) end
            return "{" .. table.concat(p, ", ") .. "}"
        elseif v.__pytype == "tuple" then
            local p = {}; for i=1,#v do p[i]=pyRepr(v[i]) end
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

local function makeRange(start, stop, step)
    if stop == nil then stop = start; start = 0 end
    step = step or 1
    if step == 0 then error(makeException("ValueError", "range() arg 3 must not be zero"), 0) end
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
        ["print"] = function(...)
            local a = {...}; local p = {}
            for i=1,#a do p[i]=pyStr(a[i], self) end
            print(table.concat(p, " "))
        end,
        ["len"] = function(x)
            if type(x)=="string" then return #x end
            if type(x)=="table" then
                if x.__pytype=="list" or x.__pytype=="tuple" then return #x end
                if x.__pytype=="dict" then local n=0; for _ in pairs(x.data) do n=n+1 end; return n end
            end
            error(makeException("TypeError", "object has no len()"), 0)
        end,
        ["range"] = makeRange,
        ["str"] = function(x) return pyStr(x, self) end,
        ["repr"] = function(x) return pyRepr(x) end,
        ["int"] = function(x)
            if x==nil then return 0 end
            if type(x)=="number" then return math.floor(x) end
            if type(x)=="string" then local n=tonumber(x); if n then return math.floor(n) end end
            error(makeException("ValueError", "invalid literal for int()"), 0)
        end,
        ["float"] = function(x)
            if type(x)=="number" then return x + 0.0 end
            if type(x)=="string" then local n=tonumber(x); if n then return n + 0.0 end end
            error(makeException("ValueError", "invalid literal for float()"), 0)
        end,
        ["bool"] = pyTruthy,
        ["abs"] = math.abs,
        ["min"] = function(a,b)
            if type(a)=="table" and a.__pytype=="list" then
                local m=a[1]; for i=2,#a do if a[i]<m then m=a[i] end end; return m
            end
            return math.min(a,b)
        end,
        ["max"] = function(a,b)
            if type(a)=="table" and a.__pytype=="list" then
                local m=a[1]; for i=2,#a do if a[i]>m then m=a[i] end end; return m
            end
            return math.max(a,b)
        end,
        ["sum"] = function(l) local s=0; for i=1,#l do s=s+l[i] end; return s end,
        ["input"] = function(p) if p then write(pyStr(p, self)) end; return io.read() or "" end,
        ["type"] = function(x)
            if x==nil then return "NoneType" end
            if type(x)=="boolean" then return "bool" end
            if type(x)=="number" then if math.floor(x)==x then return "int" else return "float" end end
            if type(x)=="string" then return "str" end
            if type(x)=="table" then
                if x.__pyexception then return x.type end
                if x.__pytype=="list" then return "list" end
                if x.__pytype=="dict" then return "dict" end
                if x.__pytype=="tuple" then return "tuple" end
                if x.__pytype=="instance" then return x.__class.name end
                if x.__pytype=="class" then return "type" end
                if x.__pytype=="module" then return "module" end
            end
            return type(x)
        end,
        ["isinstance"] = function(obj, cls)
            if type(obj)~="table" or obj.__pytype~="instance" then
                if cls and cls.__pytype == "class" then
                    if cls.name == "int" and type(obj)=="number" and math.floor(obj)==obj then return true end
                    if cls.name == "float" and type(obj)=="number" and math.floor(obj)~=obj then return true end
                    if cls.name == "str" and type(obj)=="string" then return true end
                    if cls.name == "bool" and type(obj)=="boolean" then return true end
                    if cls.name == "list" and type(obj)=="table" and obj.__pytype=="list" then return true end
                    if cls.name == "dict" and type(obj)=="table" and obj.__pytype=="dict" then return true end
                end
                return false
            end
            if type(cls)~="table" or cls.__pytype~="class" then return false end
            return isSubclass(obj.__class, cls)
        end,
        ["list"] = function(x)
            local o = {__pytype="list"}; if x then for i=1,#x do o[i]=x[i] end end; return o
        end,
        ["tuple"] = function(x)
            local o = {__pytype="tuple"}; if x then for i=1,#x do o[i]=x[i] end end; return o
        end,
        ["dict"] = function() return {__pytype="dict", data={}} end,
        ["ord"] = string.byte,
        ["chr"] = string.char,
        ["pow"] = function(a,b) return a^b end,
        ["round"] = function(x) return math.floor(x+0.5) end,
        ["enumerate"] = function(l, start)
            start = start or 0
            local o = {__pytype="list"}
            for i=1,#l do o[i]={__pytype="tuple", start + i - 1, l[i]} end
            return o
        end,
        ["zip"] = function(...)
            local lists = {...}
            if #lists == 0 then return {__pytype="list"} end
            local minLen = #lists[1]
            for i=2,#lists do if #lists[i] < minLen then minLen = #lists[i] end end
            local o = {__pytype="list"}
            for i=1,minLen do
                local tup = {__pytype="tuple"}
                for j=1,#lists do tup[j] = lists[j][i] end
                o[i] = tup
            end
            return o
        end,
        ["sorted"] = function(l)
            local o = {__pytype="list"}; for i=1,#l do o[i]=l[i] end; table.sort(o); return o
        end,
        ["reversed"] = function(l)
            local o = {__pytype="list"}; for i=#l,1,-1 do o[#o+1]=l[i] end; return o
        end,
        ["object"] = {__pytype="class", name="object", bases={}, methods={}, attrs={}},
        ["int"]    = {__pytype="class", name="int", bases={}, methods={}, attrs={}},
        ["float"]  = {__pytype="class", name="float", bases={}, methods={}, attrs={}},
        ["str"]    = {__pytype="class", name="str", bases={}, methods={}, attrs={}},
        ["bool"]   = {__pytype="class", name="bool", bases={}, methods={}, attrs={}},
        ["list"]   = {__pytype="class", name="list", bases={}, methods={}, attrs={}},
        ["dict"]   = {__pytype="class", name="dict", bases={}, methods={}, attrs={}},
        ["Exception"]       = function(m) return makeException("Exception", m) end,
        ["BaseException"]   = function(m) return makeException("BaseException", m) end,
        ["ValueError"]      = function(m) return makeException("ValueError", m) end,
        ["TypeError"]       = function(m) return makeException("TypeError", m) end,
        ["RuntimeError"]    = function(m) return makeException("RuntimeError", m) end,
        ["ZeroDivisionError"]= function(m) return makeException("ZeroDivisionError", m) end,
        ["IndexError"]      = function(m) return makeException("IndexError", m) end,
        ["KeyError"]        = function(m) return makeException("KeyError", m) end,
        ["NameError"]       = function(m) return makeException("NameError", m) end,
        ["ImportError"]     = function(m) return makeException("ImportError", m) end,
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
        local l = {__pytype="list"}; for i,e in ipairs(node.elements) do l[i]=self:eval(e) end; return l
    elseif t=="Tuple" then
        local l = {__pytype="tuple"}; for i,e in ipairs(node.elements) do l[i]=self:eval(e) end; return l
    elseif t=="Dict" then
        local d = {__pytype="dict", data={}}
        for _,p in ipairs(node.pairs) do d.data[self:eval(p.key)] = self:eval(p.value) end
        return d
    elseif t=="BinOp" then return self:evalBinOp(node)
    elseif t=="UnaryOp" then
        local v = self:eval(node.operand)
        if node.op=="not" then return not pyTruthy(v) end
        if node.op=="-" then
            if type(v) ~= "number" then error(makeException("TypeError", "bad operand type for unary -"), 0) end
            return -v
        end
        self:error("unknown unary op: " .. node.op)
    elseif t=="Call" then return self:evalCall(node)
    elseif t=="Index" then
        local obj = self:eval(node.obj)
        local idx = self:eval(node.index)
        if type(obj) == "string" then
            local i = idx + 1
            if i < 1 or i > #obj then error(makeException("IndexError", "string index out of range"), 0) end
            return obj:sub(i, i)
        elseif type(obj) == "table" then
            if obj.__pytype == "dict" then
                local v = obj.data[idx]
                if v == nil then error(makeException("KeyError", pyStr(idx)), 0) end
                return v
            end
            if obj.__pytype == "instance" then
                local m = lookupMethod(obj.__class, "__getitem__")
                if m then return m(obj, idx) end
            end
            local i = idx + 1
            if i < 1 or i > #obj then error(makeException("IndexError", "list index out of range"), 0) end
            return obj[i]
        end
        self:error("cannot index this object")
    elseif t=="Attr" then return self:getAttr(self:eval(node.obj), node.name)
    elseif t=="Ternary" then
        if pyTruthy(self:eval(node.cond)) then return self:eval(node.then_expr)
        else return self:eval(node.else_expr) end
    elseif t=="Lambda" then
        return self:makeFunction("lambda", node.params, {{type="Return", value=node.body}})
    end
    self:error("unknown expression: " .. t)
end

function Interpreter:makeFunction(name, params, body)
    local interp = self
    local capturedScopes = {}
    for i, s in ipairs(self.scopes) do capturedScopes[i] = s end
    return function(...)
        local args = {...}
        local funcScope = {}
        local savedScopes = interp.scopes
        local newScopes = {}
        for i, s in ipairs(capturedScopes) do newScopes[i] = s end
        newScopes[#newScopes + 1] = funcScope
        interp.scopes = newScopes
        for i, p in ipairs(params) do
            if args[i] == nil and p.default then
                funcScope[p.name] = interp:eval(p.default)
            else
                funcScope[p.name] = args[i]
            end
        end
        local ok, result = pcall(function() return interp:execBlock(body) end)
        interp.scopes = savedScopes
        if not ok then error(result, 0) end
        if result and result.__return then return result.value end
        return nil
    end
end

local function makeInstance(class, args, interp)
    local instance = {__pytype="instance", __class=class, __attrs={}}
    local init = lookupMethod(class, "__init__")
    if init then init(instance, unpack(args)) end
    return instance
end

function Interpreter:evalCall(node)
    local func = self:eval(node.func)
    local args = {}
    for i, a in ipairs(node.args) do args[i] = self:eval(a) end
    if type(func) == "function" then return func(unpack(args)) end
    if type(func) == "table" and func.__pytype == "class" then
        if func.name == "int" then return math.floor(tonumber(args[1]) or 0) end
        if func.name == "float" then return (tonumber(args[1]) or 0) + 0.0 end
        if func.name == "str" then return pyStr(args[1], self) end
        if func.name == "bool" then return pyTruthy(args[1]) end
        if func.name == "list" then
            local o = {__pytype="list"}
            if args[1] then for i=1,#args[1] do o[i]=args[1][i] end end
            return o
        end
        if func.name == "dict" then return {__pytype="dict", data={}} end
        return makeInstance(func, args, self)
    end
    self:error("object is not callable")
end

function Interpreter:getAttr(obj, name)
    if type(obj) == "string" then
        local s = obj
        if name=="upper" then return function() return s:upper() end end
        if name=="lower" then return function() return s:lower() end end
        if name=="strip" then return function() return (s:gsub("^%s+",""):gsub("%s+$","")) end end
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
        if name=="find" then return function(sub) return s:find(sub,1,true) end end
        if name=="join" then
            return function(l)
                local p = {}; for i=1,#l do p[i]=tostring(l[i]) end
                return table.concat(p, s)
            end
        end
        if name=="startswith" then return function(p) return s:sub(1,#p)==p end end
        if name=="endswith" then return function(p) return s:sub(-#p)==p end end
        if name=="format" then
            return function(...)
                local a = {...}; local i = 0
                return (s:gsub("{}", function() i=i+1; return pyStr(a[i], self) end))
            end
        end
        if name=="isdigit" then return function() return s:match("^%d+$") ~= nil end end
        if name=="isalpha" then return function() return s:match("^%a+$") ~= nil end end
    elseif type(obj) == "table" then
        -- Module attribute access
        if obj.__pytype == "module" then
            local v = obj.__scope[name]
            if v ~= nil then return v end
            self:error("module '" .. obj.__name .. "' has no attribute '" .. name .. "'")
        end
        if obj.__pytype == "instance" then
            if obj.__attrs[name] ~= nil then return obj.__attrs[name] end
            local m = lookupMethod(obj.__class, name)
            if m then return function(...) return m(obj, ...) end end
            local a = lookupClassAttr(obj.__class, name)
            if a ~= nil then return a end
            self:error("instance has no attribute '" .. name .. "'")
        end
        if obj.__pytype == "class" then
            local m = lookupMethod(obj, name)
            if m then return m end
            local a = lookupClassAttr(obj, name)
            if a ~= nil then return a end
            self:error("class has no attribute '" .. name .. "'")
        end
        if obj.__pytype == "list" then
            if name=="append" then return function(v) table.insert(obj, v) end end
            if name=="pop" then
                return function()
                    if #obj==0 then error(makeException("IndexError","pop from empty list"),0) end
                    return table.remove(obj)
                end
            end
            if name=="insert" then return function(i,v) table.insert(obj, i+1, v) end end
            if name=="remove" then
                return function(v)
                    for i=1,#obj do if obj[i]==v then table.remove(obj, i); return end end
                end
            end
            if name=="sort" then return function() table.sort(obj) end end
            if name=="reverse" then
                return function()
                    local n = #obj
                    for i=1,math.floor(n/2) do obj[i],obj[n-i+1]=obj[n-i+1],obj[i] end
                end
            end
            if name=="index" then
                return function(v)
                    for i=1,#obj do if obj[i]==v then return i-1 end end
                    error(makeException("ValueError","value not in list"),0)
                end
            end
            if name=="count" then
                return function(v)
                    local n=0; for i=1,#obj do if obj[i]==v then n=n+1 end end; return n
                end
            end
            if name=="extend" then
                return function(other) for i=1,#other do table.insert(obj, other[i]) end end
            end
            if name=="copy" then
                return function() local c={__pytype="list"}; for i=1,#obj do c[i]=obj[i] end; return c end
            end
        elseif obj.__pytype == "dict" then
            if name=="get" then
                return function(k,d) local v=obj.data[k]; if v==nil then return d end; return v end
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
                    for _,v in pairs(obj.data) do table.insert(o, v) end
                    return o
                end
            end
            if name=="items" then
                return function()
                    local o={__pytype="list"}
                    for k,v in pairs(obj.data) do table.insert(o, {__pytype="tuple", k, v}) end
                    return o
                end
            end
            if name=="update" then return function(other) for k,v in pairs(other.data) do obj.data[k]=v end end end
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
            ["+"]="__add__", ["-"]="__sub__", ["*"]="__mul__", ["/"]="__truediv__",
            ["//"]="__floordiv__", ["%"]="__mod__", ["**"]="__pow__",
            ["=="]="__eq__", ["<"]="__lt__", [">"]="__gt__",
            ["<="]="__le__", [">="]="__ge__", ["!="]="__ne__",
        })[op]
        if methodName then
            local m = lookupMethod(l.__class, methodName)
            if m then return m(l, r) end
        end
    end

    if op=="+" then
        if type(l)=="table" and type(r)=="table" then
            if (l.__pytype=="list" and r.__pytype=="list") or (l.__pytype=="tuple" and r.__pytype=="tuple") then
                local o = {__pytype=l.__pytype}
                for i=1,#l do o[#o+1]=l[i] end
                for i=1,#r do o[#o+1]=r[i] end
                return o
            end
        end
        if type(l)~="number" and type(l)~="string" then error(makeException("TypeError","unsupported operand"),0) end
        return l + r
    elseif op=="-" then return l - r
    elseif op=="*" then
        if type(l)=="string" and type(r)=="number" then return string.rep(l, r) end
        if type(r)=="string" and type(l)=="number" then return string.rep(r, l) end
        return l * r
    elseif op=="/" then
        if r == 0 then error(makeException("ZeroDivisionError","division by zero"),0) end
        return l / r
    elseif op=="//" then
        if r == 0 then error(makeException("ZeroDivisionError","division by zero"),0) end
        return math.floor(l / r)
    elseif op=="%" then
        if r == 0 then error(makeException("ZeroDivisionError","modulo by zero"),0) end
        return l % r
    elseif op=="**" then return l ^ r
    elseif op=="==" then return pyEq(l, r)
    elseif op=="!=" then return not pyEq(l, r)
    elseif op=="<" then return l < r
    elseif op=="<=" then return l <= r
    elseif op==">" then return l > r
    elseif op==">=" then return l >= r
    elseif op=="in" then
        if type(r)=="string" then return r:find(l,1,true) ~= nil end
        if type(r)=="table" then
            if r.__pytype=="dict" then return r.data[l] ~= nil end
            for i=1,#r do if pyEq(r[i], l) then return true end end
            return false
        end
        self:error("'in' requires iterable")
    end
    self:error("unknown binop: " .. op)
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
            if binop=="+" and type(current)=="table" and type(value)=="table" then
                if current.__pytype=="list" and value.__pytype=="list" then
                    for i=1,#value do table.insert(current, value[i]) end
                    value = current
                else value = current + value end
            elseif binop=="-" then value = current - value
            elseif binop=="*" then value = current * value
            elseif binop=="/" then
                if value==0 then error(makeException("ZeroDivisionError","division by zero"),0) end
                value = current / value
            end
        end
        self:assignTarget(node.target, value)
    elseif t=="If" then
        if pyTruthy(self:eval(node.cond)) then return self:execBlock(node.body) end
        for _,e in ipairs(node.elifs) do
            if pyTruthy(self:eval(e.cond)) then return self:execBlock(e.body) end
        end
        if node.elseBody then return self:execBlock(node.elseBody) end
    elseif t=="While" then
        while pyTruthy(self:eval(node.cond)) do
            local r = self:execBlock(node.body)
            if r and r.__return then return r end
            if r and r.__break then break end
        end
    elseif t=="For" then
        local iterable = self:eval(node.iter)
        if type(iterable) ~= "table" then self:error("'for' requires iterable") end
        for i = 1, #iterable do
            local item = iterable[i]
            if #node.names == 1 then
                self:assign(node.names[1], item)
            else
                if type(item) ~= "table" then
                    self:error("cannot unpack non-iterable " .. type(item))
                end
                for j = 1, #node.names do
                    self:assign(node.names[j], item[j])
                end
            end
            local r = self:execBlock(node.body)
            if r and r.__return then return r end
            if r and r.__break then break end
        end
    elseif t=="Def" then
        self:assign(node.name, self:makeFunction(node.name, node.params, node.body))
    elseif t=="Class" then
        self:execClass(node)
    elseif t=="Return" then
        local v = nil
        if node.value then v = self:eval(node.value) end
        return {__return=true, value=v}
    elseif t=="Pass" then
        -- no-op
    elseif t=="Break" then return {__break=true}
    elseif t=="Continue" then return {__continue=true}
    elseif t=="Import" then
        -- import foo, bar as b
        for _, mod in ipairs(node.modules) do
            local modTable = self:importModule(mod.name)
            local bindName = mod.alias or mod.name:match("^([^.]+)")  -- top-level name
            if mod.alias then
                self:assign(mod.alias, modTable)
            else
                -- For dotted import, bind top-level name
                self:assign(bindName, modTable)
            end
        end
    elseif t=="FromImport" then
        local modTable = self:importModule(node.module)
        for _, n in ipairs(node.names) do
            if n.name == "*" then
                -- Import all public names
                local ns = modTable.__scope
                for k, v in pairs(ns) do
                    if not k:match("^_") then
                        self:assign(k, v)
                    end
                end
            else
                local value = modTable.__scope[n.name]
                if value == nil then
                    error(makeException("ImportError",
                        "cannot import name '" .. n.name .. "' from '" .. node.module .. "'"), 0)
                end
                self:assign(n.alias or n.name, value)
            end
        end
    elseif t=="Global" then
        for _, name in ipairs(node.names) do
            self.scopes[1][name] = self.scopes[1][name] or nil
        end
    elseif t=="Nonlocal" then
        -- handled by closure scope chain
    elseif t=="Raise" then
        if node.exc == nil then
            error(makeException("RuntimeError", "No active exception to reraise"), 0)
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

-- Load a Python module by dotted name; search /pylib
function Interpreter:importModule(name)
    -- 1. Cache hit
    if MODULE_CACHE[name] then return MODULE_CACHE[name] end

    -- 2. Built-in modules
    local bmods = getBuiltinModules()
    if bmods[name] then
        MODULE_CACHE[name] = bmods[name]
        return bmods[name]
    end

    -- 3. File system search
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
            filePath = p
            break
        end
    end

    if not filePath then
        error(makeException("ImportError", "No module named '" .. name .. "'"), 0)
    end

    -- 4. Read and parse
    local f = fs.open(filePath, "r")
    if not f then
        error(makeException("ImportError", "Cannot open module file: " .. filePath), 0)
    end
    local src = f.readAll()
    f.close()

    -- 5. Create a new interpreter for the module
    local modInterp = Interpreter.new()
    -- Setup scopes: [builtins, module_namespace]
    local builtins = modInterp:getBuiltins()
    for k, v in pairs(builtins) do
        modInterp.scopes[1][k] = v
    end
    table.insert(modInterp.scopes, {})  -- scopes[2] = module namespace

    -- 6. Execute module code
    local lexer = Lexer.new(src)
    local tokens = lexer:tokenize()
    local parser = Parser.new(tokens)
    local ast = parser:parse()

    local ok, err = pcall(function()
        for _, stmt in ipairs(ast.body) do
            modInterp:execStmt(stmt)
        end
    end)
    if not ok then
        error(wrapError(err), 0)
    end

    -- 7. Build module table
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
            classTable.methods[stmt.name] = self:makeFunction(stmt.name, stmt.params, stmt.body)
        elseif stmt.type == "Pass" then
            -- no-op
        elseif stmt.type == "Assign" and stmt.target.type == "Name" then
            classTable.attrs[stmt.target.name] = self:eval(stmt.value)
        end
    end

    self:assign(node.name, classTable)
end

function Interpreter:execTry(node)
    local tryResult, tryException
    local ok, err = pcall(function() return self:execBlock(node.body) end)

    if ok then
        tryResult = err
    else
        tryException = wrapError(err)
    end

    local handled = false
    local finalResult = tryResult

    if tryException then
        for _, handler in ipairs(node.handlers) do
            local shouldCatch = false
            if not handler.excType then
                shouldCatch = true
            elseif handler.excType == tryException.type then
                shouldCatch = true
            elseif handler.excType == "Exception" then
                shouldCatch = (tryException.type ~= "BaseException")
            elseif handler.excType == "BaseException" then
                shouldCatch = true
            end
            if shouldCatch then
                if handler.name then self:assign(handler.name, tryException) end
                local hok, herr = pcall(function() return self:execBlock(handler.body) end)
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
            local eok, eerr = pcall(function() return self:execBlock(node.elseBody) end)
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
        local fok, ferr = pcall(function() return self:execBlock(node.finallyBody) end)
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
    if target.type=="Name" then self:assign(target.name, value)
    elseif target.type=="Index" then
        local obj = self:eval(target.obj)
        local idx = self:eval(target.index)
        if type(obj)=="table" then
            if obj.__pytype=="dict" then obj.data[idx]=value
            elseif obj.__pytype == "instance" then
                local m = lookupMethod(obj.__class, "__setitem__")
                if m then m(obj, idx, value); return end
                error(makeException("TypeError", "object does not support item assignment"), 0)
            else obj[idx+1]=value end
        else self:error("cannot assign to index") end
    elseif target.type=="Attr" then
        local obj = self:eval(target.obj)
        if type(obj)=="table" then
            if obj.__pytype == "instance" then
                obj.__attrs[target.name] = value
            elseif obj.__pytype == "module" then
                obj.__scope[target.name] = value
            else
                obj[target.name] = value
            end
        end
    elseif target.type=="Tuple" then
        if type(value)=="table" then
            for i,t in ipairs(target.elements) do self:assignTarget(t, value[i]) end
        end
    else self:error("invalid assignment target") end
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
-- 5. PUBLIC API
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

-- Expose the interpreter class for extension
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
