-- theme.lua - prompt templates and colours of the psh shell
--
-- One theme is one prompt template stored under a name. Two themes ship with
-- the shell (dark and light); /etc/theme.conf may replace them or add more,
-- and it also selects the theme of the session. A missing or unreadable file is
-- not an error: the built-in defaults are used then, so a broken configuration
-- can never keep the prompt from showing up.
--
-- expand() only turns a template into segments and their colours, it never
-- touches the terminal. The line editor in usr/psh.lua writes the segments, so
-- the prompt can be unit tested on a PC without a screen.
--
-- Template escapes (the user level view is in the header of etc/theme.conf):
--   $NAME  ${NAME}   shell variable, an unset variable expands to nothing
--   \e{NAME}         switch to that CraftOS colour
--   \e{}             back to the default colour (white)
--   \$               a literal dollar sign
--   \\               a literal backslash
--
-- The palette below repeats the CraftOS colours on purpose: the numbers are
-- fixed by CraftOS itself, and the prompt must be resolved the same way on the
-- PC side test stub, which has no colours table of its own.

local theme = {}

theme.CONF = "/etc/theme.conf"
theme.DEFAULT_NAME = "dark"
theme.DEFAULT_COLOUR = "white"

local PALETTE = {
    white = 1, orange = 2, magenta = 4, lightBlue = 8, yellow = 16,
    lime = 32, pink = 64, gray = 128, lightGray = 256, cyan = 512,
    purple = 1024, blue = 2048, brown = 4096, green = 8192, red = 16384,
    black = 32768,
}

local DEFAULTS = {
    dark = { prompt = "\\e{lightBlue}$USER\\e{white}@\\e{yellow}$HOST" ..
                     "\\e{white}:\\e{lime}$PWD\\e{}\\$ " },
    light = { prompt = "\\e{gray}$USER@$HOST\\e{white}:\\e{blue}$PWD\\e{}\\$ " },
}

local state = {}

local function default_themes()
    local out = {}
    for name, def in pairs(DEFAULTS) do out[name] = { prompt = def.prompt } end
    return out
end

-- Back to the built-in themes and to the default selection. Called on load
-- again before every read of the configuration file.
function theme.reset()
    state.themes = default_themes()
    state.current = theme.DEFAULT_NAME
    state.source = nil
    state.warnings = {}
    return true
end

theme.reset()

-- ------------------------------------------------------------------ colours

-- A colour number for the terminal, an unknown or empty name is the default
-- colour, the way "\e{}" resets the prompt.
function theme.colour(name)
    local value = PALETTE[tostring(name or "")]
    if value == nil then value = PALETTE[theme.DEFAULT_COLOUR] end
    return value
end

function theme.colour_names()
    local out = {}
    for name in pairs(PALETTE) do out[#out + 1] = name end
    table.sort(out)
    return out
end

function theme.is_colour(name)
    return PALETTE[tostring(name or "")] ~= nil
end

-- ------------------------------------------------------------------- themes

function theme.names()
    local out = {}
    for name in pairs(state.themes) do out[#out + 1] = name end
    table.sort(out)
    return out
end

function theme.exists(name)
    return name ~= nil and state.themes[name] ~= nil
end

function theme.current()
    return state.current
end

-- The file the themes came from, nil while the built-in defaults are in use.
function theme.source()
    return state.source
end

function theme.warnings()
    local out = {}
    for i, line in ipairs(state.warnings) do out[i] = line end
    return out
end

-- The template of one theme (the current one by default).
function theme.template(name)
    local entry = state.themes[name or state.current] or state.themes[theme.DEFAULT_NAME]
    if not entry then return "" end
    return entry.prompt
end

-- The template that shipped with the shell, used by "theme -d" and by the
-- tests that check a configuration file only overrides what it names.
function theme.builtin(name)
    local def = DEFAULTS[name]
    if not def then return nil end
    return def.prompt
end

function theme.hostname()
    local ok, label = pcall(os.getComputerLabel)
    if ok and type(label) == "string" and label ~= "" then return label end
    local id = 0
    local ok_id, got = pcall(os.getComputerID)
    if ok_id and tonumber(got) then id = tonumber(got) end
    return "cc-" .. tostring(id)
end

-- Session only, the file on disk is left alone.
function theme.select(name)
    if not theme.exists(name) then
        return false, "unknown theme: " .. tostring(name)
    end
    state.current = name
    return true
end

-- ------------------------------------------------------------ the plain file
--
-- Lines are "key = value". A value wrapped in double quotes keeps its blanks,
-- an unquoted one is trimmed, so a prompt may end in a space:
--
--   theme = dark
--   dark.prompt = "\e{lime}$USER\e{}\$ "

local function parse_lines(text)
    local items = {}
    for raw in (text .. "\n"):gmatch("([^\n]*)\n") do
        local line = raw:gsub("\r$", "")
        line = line:gsub("^[ \t]+", ""):gsub("[ \t]+$", "")
        if line ~= "" and line:sub(1, 1) ~= "#" then
            local key, value = line:match("^([%w_%.%-]+)[ \t]*=[ \t]*(.*)$")
            if key == nil then
                items[#items + 1] = { nil, line }
            else
                if #value >= 2 and value:sub(1, 1) == '"' and value:sub(-1) == '"' then
                    value = value:sub(2, -2)
                else
                    value = value:gsub("[ \t]+$", "")
                end
                items[#items + 1] = { key, value }
            end
        end
    end
    return items
end

-- Read a configuration file. Returns true when the file was read, false plus a
-- reason when there is nothing to read. Unknown keys and unknown theme names
-- are collected as warnings, they never stop the shell.
function theme.load(path)
    path = path or theme.CONF
    theme.reset()
    local ok, exists = pcall(fs.exists, path)
    if not ok or not exists then return false, "no theme file at " .. path end
    local handle = fs.open(path, "r")
    if not handle then return false, "cannot read " .. path end
    local text = handle.readAll() or ""
    handle.close()

    local wanted, count = nil, 0
    for _, item in ipairs(parse_lines(text)) do
        local key, value = item[1], item[2]
        if key == nil then
            state.warnings[#state.warnings + 1] = "cannot parse: " .. value
        elseif key == "theme" then
            wanted = value
        else
            local name, field = key:match("^([%w_%-]+)%.([%w_%-]+)$")
            if name and field == "prompt" then
                state.themes[name] = { prompt = value }
                count = count + 1
            else
                state.warnings[#state.warnings + 1] = "unknown key: " .. key
            end
        end
    end

    if wanted then
        if state.themes[wanted] then
            state.current = wanted
        else
            state.warnings[#state.warnings + 1] = "unknown theme: " .. wanted
        end
    end

    state.source = path
    return true, count
end

-- Write every theme and the selection back. The callers ask for permission
-- first: "theme save" is the only writer.
function theme.save(path)
    path = path or theme.CONF
    local handle = fs.open(path, "w")
    if not handle then return false, "cannot write " .. path end
    handle.writeLine("# theme.conf - prompt templates of psh, see man theme.conf")
    handle.writeLine("# theme = NAME picks the session theme, NAME.prompt is its template.")
    handle.writeLine("# A value in double quotes keeps its blanks, a prompt ends in a space.")
    handle.writeLine("")
    handle.writeLine("theme = " .. state.current)
    handle.writeLine("")
    for _, name in ipairs(theme.names()) do
        handle.writeLine(name .. ".prompt = \"" .. theme.template(name) .. "\"")
    end
    handle.close()
    state.source = path
    return true
end

-- ------------------------------------------------------------------ expand

-- Turn one template into { parts = { { text, colour } ... }, width = n,
-- plain = "..." }. The line editor needs the width and the plain text to place
-- the cursor and to redraw the line, the parts carry the colours.
function theme.expand(template, lookup)
    if type(template) ~= "string" then template = "" end
    if type(lookup) ~= "function" then lookup = function() return nil end end

    local parts, plain = {}, {}
    local width = 0
    local colour = nil             -- nil: leave the terminal colour alone
    local buffer = {}

    local function flush()
        if #buffer == 0 then return end
        local text = table.concat(buffer)
        buffer = {}
        parts[#parts + 1] = { text = text, colour = colour }
        width = width + #text
        plain[#plain + 1] = text
    end

    local function push(text)
        if text ~= "" then buffer[#buffer + 1] = text end
    end

    local i, n = 1, #template
    while i <= n do
        local c = template:sub(i, i)
        if c == "\\" then
            local nxt = template:sub(i + 1, i + 1)
            if nxt == "e" and template:sub(i + 2, i + 2) == "{" then
                local close = template:find("}", i + 3, true)
                if close then
                    flush()
                    colour = theme.colour(template:sub(i + 3, close - 1))
                    i = close + 1
                else
                    push("\\")
                    i = i + 1
                end
            elseif nxt == "$" or nxt == "\\" then
                push(nxt)
                i = i + 2
            else
                push("\\")
                i = i + 1
            end
        elseif c == "$" then
            local braced = template:match("^%${([%w_%?]+)}", i)
            local name, after = braced, nil
            if braced then
                after = i + #braced + 3
            else
                name = template:match("^%$([%w_%?]+)", i)
                if name then after = i + #name + 1 end
            end
            if name and after then
                local value = lookup(name)
                if value ~= nil then push(tostring(value)) end
                i = after
            else
                push("$")
                i = i + 1
            end
        else
            push(c)
            i = i + 1
        end
    end
    flush()

    return { parts = parts, width = width, plain = table.concat(plain) }
end

-- The rendered prompt of a session: PS1 when it is set, the current theme
-- otherwise. "lookup" is usually vars.get, so $USER, $PWD and $? work.
function theme.render(ps1, lookup)
    local template = ps1
    if template == nil or template == "" then template = theme.template() end
    return theme.expand(template, lookup)
end

return theme
