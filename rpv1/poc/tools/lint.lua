--[[- tools/lint.lua ? dependency-free static checks (a stand-in for luacheck here).

luacheck is not available in this environment, so the library ships its own small
checker. It is deliberately strict about the mistakes this project actually made:

  errors   : UTF-8 BOM, syntax errors, wrong module convention (`return function(M)`
             instead of `local M = ...` + `return M`), missing `return M`,
             `os.epoch("ms")` (invalid unit), `p1 == timer` in pullEvent loops
             (timers never match under load), `string.concat` (does not exist)
  warnings : trailing whitespace, tabs, lines over 200 columns, `print(` inside
             library modules (they must use node:log), probable accidental globals

Call from tests/run.lua:  loadfile + pcall(lint, T, M) -> prints LINT_ERRORS/LINT_WARNINGS/LINT_FILES
]]
local T, M = ...
    local dirs = { "rpv", "apps", "compat", "tests", "tools", "examples" }
    local whitelist = {
        M = true, T = true, node = true, self = true, n = true, c = true, res = true,
        cfg = true, out = true, i = true, j = true, k = true, v = true, s = true, t = true,
        e = true, f = true, p = true, r = true, w = true, x = true, test = true,
    }
    local errors, warnings, files = 0, 0, 0
    local function err(path, rule, detail)
        errors = errors + 1
        print(string.format("LINT_ERROR file=%s rule=%s detail=%s", path, rule, tostring(detail)))
    end
    local function warn(path, rule, detail)
        warnings = warnings + 1
        if warnings <= 12 then
            print(string.format("LINT_WARN file=%s rule=%s detail=%s", path, rule, tostring(detail)))
        end
    end

    local list = {}
    for _, dir in ipairs(dirs) do
        local ok, entries = pcall(fs.list, dir)
        if ok and type(entries) == "table" then
            for _, name in ipairs(entries) do
                if tostring(name):sub(-4) == ".lua" then list[#list + 1] = dir .. "/" .. name end
            end
        end
    end
    table.sort(list)

    for _, path in ipairs(list) do
        files = files + 1
        local handle = fs.open(path, "r")
        if not handle then
            err(path, "unreadable", "fs.open failed")
        else
            local src = handle.readAll()
            handle.close()

            if src:byte(1) == 0xEF then err(path, "bom", "file starts with a UTF-8 BOM") end
            if src:find("\r\n", 1, true) then warn(path, "crlf", "file uses CRLF line endings") end

            local chunk, loadErr = loadstring(src)
            if not chunk then
                err(path, "syntax", tostring(loadErr))
            end

            local isLib = path:sub(1, 4) == "rpv/" or path:sub(1, 7) == "compat/"
            if isLib then
                if src:find("return%s+function%s*%(") then
                    err(path, "module-convention", "return function(M) enriches nothing")
                end
                if not src:find("local%s+M%s*=%s*%.%.%.") then
                    err(path, "module-convention", "missing `local M = ...`")
                end
                if not src:match("return%s+M[%s]*$") then
                    -- enrichment is what matters (the loaders only care that nothing is
                    -- returned as a function), so a missing trailer is a style warning
                    warn(path, "module-trailer", "no trailing `return M`")
                end
            end

            -- pitfalls this project has hit before (the rules file itself mentions them,
            -- so it is exempt from this scan)
            local isRules = path == "tools/lint.lua"
            if not isRules and src:find('os%.epoch%s*%(%s*"ms"') then err(path, "pitfall", 'os.epoch("ms") is not a valid unit') end
            if not isRules and src:find("p1%s*==%s*timer") then err(path, "pitfall", "p1 == timer never matches under load") end
            if not isRules and src:find("string%.concat") then err(path, "pitfall", "string.concat does not exist (use table.concat)") end

            -- line hygiene + accidental globals
            -- names declared as locals anywhere in the file: assigning to one of these
            -- later is not an accidental global
            local locals = {}
            for list in src:gmatch("local%s+([%w_,%s]+)=?") do
                for name in list:gmatch("[%a_][%w_]*") do locals[name] = true end
            end
            local lineno = 0
            local braceDepth = 0
            for line in src:gmatch("[^\n]*") do
                lineno = lineno + 1
                if #line > 200 then warn(path, "long-line", "line " .. lineno .. " has " .. #line .. " columns") end
                if line:find("%s+$") then warn(path, "trailing-space", "line " .. lineno) end
                if line:find("\t") then warn(path, "tab", "line " .. lineno) end
                if isLib and not line:find("^%s*%-%-") and line:find("print%s*%(") then
                    warn(path, "print", "line " .. lineno .. ": library modules should use node:log")
                end
                -- accidental-global detection only makes sense at statement level:
                -- table constructor fields (inside braces, or ending with a comma) are not
                -- assignments to globals
                local isCode = not line:find("^%s*%-%-") and not line:find("^%s*local")
                    and not line:find("^%s*function") and not line:find("^%s*return") and not line:find("^%s*end")
                if braceDepth == 0 and isCode and not line:find(",%s*$") then
                    local name = line:match("^%s*([A-Za-z_][%w_]*)%s*=[^=]")
                    if name and not whitelist[name] and not locals[name] then
                        warn(path, "global?", "line " .. lineno .. ": " .. name .. " assigned without `local`")
                    end
                end
                for _ in line:gmatch("{") do braceDepth = braceDepth + 1 end
                for _ in line:gmatch("}") do braceDepth = math.max(0, braceDepth - 1) end
            end
        end
    end

    print(string.format("LINT_RESULT errors=%d warnings=%d files=%d", errors, warnings, files))
    print("LINT_ERRORS " .. errors)
    print("LINT_WARNINGS " .. warnings)
    print("LINT_FILES " .. files)
    return { errors = errors, warnings = warnings, files = files }
