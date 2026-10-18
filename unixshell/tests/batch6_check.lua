-- batch6_check.lua - PC side logic assertions for the sixth batch, group E of
-- the ush project: the prompt themes (lib/theme.lua, /etc/theme.conf), the way
-- usr/ush.lua glues them into the prompt of the line editor, the control keys
-- of that editor (Ctrl+A/E/W/C/L) and the completion of lib/complete.lua (the
-- options of a command, sudo, the accounts behind sudo -u).
--
-- Two halves. The first half drives the library and the shipped configuration
-- file directly, the second half boots usr/ush.lua with _G.__USH_TEST and
-- looks at the prompt, at the theme builtin, at the editor keys and at the
-- completion, which are driven one event at a time through the event queue.
--
-- Run through tests/run_all.py with lupa. Everything here is a PC side
-- simulation result, it is NOT a CraftOS-PC result.

local PROJ = _G.PROJ
package.path = PROJ .. "/lib/?.lua;" .. PROJ .. "/usr/?.lua;" .. package.path

local say = _G.__realprint
local fs = _G.fs

local pass, fail = 0, 0
local fails = {}

local function check(name, cond, extra)
    if cond then
        pass = pass + 1
    else
        fail = fail + 1
        fails[#fails + 1] = name .. (extra ~= nil and ("  [" .. tostring(extra) .. "]") or "")
    end
end

local function clear() _G.__OUT = {} end
local function out() return table.concat(_G.__OUT, "\n") end
local function has(sub) return out():find(sub, 1, true) ~= nil end

local function section(title)
    say("")
    say("=== " .. title .. " ===")
end

local function count_of(text, sub)
    local n, i = 0, 1
    while true do
        local a, b = text:find(sub, i, true)
        if not a then break end
        n = n + 1
        i = b + 1
    end
    return n
end

local function write(path, text)
    local parent = path:match("^(.*)/[^/]+$")
    if parent and parent ~= "" and not fs.exists(parent) then fs.makeDir(parent) end
    local handle = fs.open(path, "w")
    handle.write(text)
    handle.close()
end

local function read(path)
    local handle = fs.open(path, "r")
    if not handle then return nil end
    local text = handle.readAll()
    handle.close()
    return text
end

-- The suites run inside the emulated file system, so the shipped
-- /etc/theme.conf is fetched from the repository through the runner. The
-- helper arrives as a host function, so it is called through pcall.
local function host_text(path)
    local reader = _G.read_host_file
    if reader == nil then return nil end
    local ok, text = pcall(function() return reader(path) end)
    if ok and type(text) == "string" then return text end
    return nil
end

if not fs.exists("/tmp") then fs.makeDir("/tmp") end

local theme = require("theme")

-- ============================================================
section("etc/theme.conf - the shipped file")
-- ============================================================
local conf_path = PROJ .. "/etc/theme.conf"
local conf = host_text(conf_path)
check("the repository holds etc/theme.conf", type(conf) == "string", conf_path)
conf = conf or ""

if #conf > 0 then
    check("the file is pure ASCII", conf:find("[\128-\255]") == nil)
    check("no real escape byte is written", conf:find("\27", 1, true) == nil)
    check("it explains itself with comments", count_of(conf, "\n#") > 10,
          tostring(count_of(conf, "\n#")))
    check("it documents the escapes", conf:find("\\e{NAME}", 1, true) ~= nil)
    check("it documents the variables", conf:find("$NAME", 1, true) ~= nil)
    check("it documents PS1", conf:find("PS1", 1, true) ~= nil)
    check("it documents theme save", conf:find("theme save", 1, true) ~= nil)

    local data = 0
    for line in (conf .. "\n"):gmatch("([^\n]*)\n") do
        local trimmed = line:gsub("^%s+", "")
        if trimmed ~= "" and trimmed:sub(1, 1) ~= "#" then data = data + 1 end
    end
    check("it holds the selection and two templates", data == 3, tostring(data))

    check("dark is the default selection", conf:find("theme = dark", 1, true) ~= nil)

    local seen = {}
    local quoted_number = 0
    for line in (conf .. "\n"):gmatch("([^\n]*)\n") do
        local name, value = line:match("^([%w_%-]+)%.prompt%s*=%s*\"(.-)\"$")
        if name then
            seen[name] = value
            quoted_number = quoted_number + 1
            check("the template of " .. name .. " keeps its trailing space",
                  value:sub(-1) == " ", "[" .. value .. "]")
            check("the template of " .. name .. " ends with a dollar prompt",
                  value:sub(-3) == "\\$ ", "[" .. value .. "]")
        end
    end
    check("both built-in themes are written out", quoted_number == 2,
          tostring(quoted_number))
    check("dark.prompt is the dark template", seen.dark ~= nil and
          seen.dark:find("$USER", 1, true) ~= nil and
          seen.dark:find("$PWD", 1, true) ~= nil)
    check("light.prompt is the light template", seen.light ~= nil and
          seen.light:find("$USER@$HOST", 1, true) ~= nil)
    check("the written dark template is the built-in one",
          seen.dark == theme.builtin("dark"), seen.dark)
    check("the written light template is the built-in one",
          seen.light == theme.builtin("light"), seen.light)
end

-- ============================================================
section("lib/theme - the colour palette")
-- ============================================================
check("the default theme is dark", theme.DEFAULT_NAME == "dark")
check("the configuration file is /etc/theme.conf", theme.CONF == "/etc/theme.conf")
check("the palette has the sixteen colours", #theme.colour_names() == 16,
      tostring(#theme.colour_names()))
check("lime is a colour", theme.is_colour("lime") == true)
check("chartreuse is not", theme.is_colour("chartreuse") == false)
check("nil is not a colour", theme.is_colour(nil) == false)
check("lime is 32", theme.colour("lime") == 32, tostring(theme.colour("lime")))
check("white is 1", theme.colour("white") == 1)
check("the empty name is the default colour", theme.colour("") == theme.colour("white"))
check("an unknown colour is the default colour", theme.colour("nope") == theme.colour("white"))
check("a nil colour is the default colour", theme.colour(nil) == theme.colour("white"))

-- ============================================================
section("lib/theme - the theme table")
-- ============================================================
theme.reset()
check("reset comes back to dark", theme.current() == "dark")
check("reset drops the file", theme.source() == nil)
check("reset has no warning", #theme.warnings() == 0)

local names = theme.names()
check("the built-in themes are there", #names == 2, table.concat(names, " "))
check("the names are sorted", names[1] == "dark" and names[2] == "light",
      table.concat(names, " "))
check("dark exists", theme.exists("dark") == true)
check("a missing theme does not exist", theme.exists("nope") == false)
check("nil does not exist", theme.exists(nil) == false)
check("builtin dark returns its template", theme.builtin("dark") == theme.template("dark"))
check("builtin of a missing theme is nil", theme.builtin("nope") == nil)
check("template of a missing name falls back to the current one",
      theme.template("nope") == theme.template("dark"))
check("the host name is a non empty string",
      type(theme.hostname()) == "string" and #theme.hostname() > 0, theme.hostname())

local ok_l, err_l = theme.select("light")
check("select takes a theme", ok_l == true, tostring(err_l))
check("light is current then", theme.current() == "light")
check("template without a name is the current one",
      theme.template() == theme.template("light"))
local ok_b, err_b = theme.select("nope")
check("select refuses a missing theme", ok_b == false and err_b ~= nil, tostring(err_b))
check("a refused select keeps the current theme", theme.current() == "light")

-- ============================================================
section("lib/theme - expand")
-- ============================================================
local function lk(t)
    return function(name) return t[name] end
end
local vars_t = { USER = "root", PWD = "/etc", ["?"] = "0" }

local e = theme.expand("$USER@$HOST:$PWD\\$ ", lk(vars_t))
check("expand substitutes the variables", e.plain == "root@:/etc$ ", "[" .. e.plain .. "]")
check("an unset variable expands to nothing", e.plain:find("@:", 1, true) ~= nil)
check("expand keeps the trailing space", e.plain:sub(-1) == " ")
check("expand counts the width", e.width == #e.plain, tostring(e.width))
check("the plain text is the parts joined",
      (function()
          local acc = {}
          for _, part in ipairs(e.parts) do acc[#acc + 1] = part.text end
          return table.concat(acc) == e.plain
      end)())
check("every part carries a text", (function()
    for _, part in ipairs(e.parts) do
        if type(part.text) ~= "string" then return false end
    end
    return true
end)())

local braced = theme.expand("${USER}x", lk(vars_t))
check("a braced name expands", braced.plain == "rootx", braced.plain)

local money = theme.expand("\\$100", lk(vars_t))
check("a backslash dollar is a literal dollar", money.plain == "$100", money.plain)

local slash = theme.expand("a\\\\b", lk(vars_t))
check("a double backslash is one backslash", slash.plain == "a\\b", slash.plain)

local lone = theme.expand("100% $", lk(vars_t))
check("a lone dollar stays", lone.plain == "100% $", lone.plain)

local other = theme.expand("\\w", lk(vars_t))
check("an unknown escape is kept", other.plain == "\\w", other.plain)

local open = theme.expand("\\e{lime", lk(vars_t))
check("an open escape is kept", open.plain == "\\e{lime", open.plain)

check("expand of nil is empty", theme.expand(nil).plain == "")
check("expand without a lookup still expands",
      theme.expand("a$USER").plain == "a", theme.expand("a$USER").plain)
check("an empty template is empty", theme.expand("").plain == "")
check("an empty template has no parts", #theme.expand("").parts == 0)

local colours = theme.expand("\\e{lime}ab\\e{}cd", lk(vars_t))
check("the colour escape is cut out", colours.plain == "abcd", colours.plain)
check("the colour escape splits the parts", #colours.parts == 2,
      tostring(#colours.parts))
check("the first part is lime", colours.parts[1].colour == 32,
      tostring(colours.parts[1].colour))
check("the reset is the default colour", colours.parts[2].colour == 1,
      tostring(colours.parts[2].colour))
check("the text before the reset is kept", colours.parts[1].text == "ab")
check("the text after the reset is kept", colours.parts[2].text == "cd")

local rendered = theme.render(nil, lk(vars_t))
check("render without PS1 uses the current theme",
      rendered.plain == theme.expand(theme.template(), lk(vars_t)).plain)
check("render does not leak the theme into the plain text",
      rendered.plain:find("\\e", 1, true) == nil, rendered.plain)
check("the rendered prompt is not empty", #rendered.plain > 3)

local ps1_render = theme.render("[PS1] ", lk(vars_t))
check("render takes PS1 when it is set", ps1_render.plain == "[PS1] ", ps1_render.plain)
check("render of an empty PS1 uses the theme",
      theme.render("", lk(vars_t)).plain == rendered.plain)

-- ============================================================
section("lib/theme - the configuration file")
-- ============================================================
write("/tmp/theme_extra.conf",
      "# a test file\n" ..
      "theme = ghost\n" ..
      "bogus = 1\n" ..
      "!! not a line\n" ..
      "bare.prompt = trimmed   \n" ..
      "solar.prompt = \"[\\e{pink}$USER\\e{}] \\$ \"\n" ..
      "theme = solar\n" ..
      "\n")
local ok_load, count_load = theme.load("/tmp/theme_extra.conf")
check("load reads the file", ok_load == true, tostring(count_load))
check("load reports the number of templates", count_load == 2, tostring(count_load))
check("the file is the source then", theme.source() == "/tmp/theme_extra.conf")
check("a new theme is added", theme.exists("solar") == true)
check("the built-in themes survive", theme.exists("dark") == true and
      theme.exists("light") == true)
check("the quoted template keeps the tail space",
      theme.template("solar") == "[\\e{pink}$USER\\e{}] \\$ ",
      "[" .. theme.template("solar") .. "]")
check("a bare value is trimmed", theme.template("bare") == "trimmed",
      "[" .. theme.template("bare") .. "]")
check("four themes are known now", #theme.names() == 4,
      table.concat(theme.names(), " "))
check("the names are still sorted", theme.names()[1] == "bare" and
      theme.names()[4] == "solar", table.concat(theme.names(), " "))
check("the chosen theme is current", theme.current() == "solar", theme.current())

local warnings = table.concat(theme.warnings(), " | ")
check("the unknown key is a warning",
      warnings:find("unknown key: bogus", 1, true) ~= nil, warnings)
check("the broken line is a warning",
      warnings:find("cannot parse", 1, true) ~= nil, warnings)
check("two warnings were collected", #theme.warnings() == 2, tostring(#theme.warnings()))
check("the selection of the file is the last one", theme.current() == "solar")

-- A selection that names a theme nobody defined is a warning and nothing else,
-- the session keeps the default theme.
write("/tmp/theme_ghost.conf", "theme = ghost\n")
check("a file with a broken selection still loads",
      theme.load("/tmp/theme_ghost.conf") == true)
check("the broken selection falls back to dark", theme.current() == "dark",
      theme.current())
check("the broken selection is a warning",
      table.concat(theme.warnings(), " | "):find("unknown theme: ghost", 1, true) ~= nil,
      table.concat(theme.warnings(), " | "))
check("a broken selection is the only warning", #theme.warnings() == 1,
      tostring(#theme.warnings()))

check("load of a missing file fails", theme.load("/no/such/theme.conf") == false)
check("load of a missing file resets the themes", #theme.names() == 2,
      table.concat(theme.names(), " "))
check("load of a missing file keeps a warning free state",
      #theme.warnings() == 0, table.concat(theme.warnings(), " "))

theme.load("/tmp/theme_extra.conf")
local ok_save, err_save = theme.save("/tmp/theme_saved.conf")
check("save writes a file", ok_save == true, tostring(err_save))
local saved = read("/tmp/theme_saved.conf") or ""
check("the saved file names the current theme",
      saved:find("theme = solar", 1, true) ~= nil, saved)
check("the saved file holds the new template",
      saved:find("solar.prompt = \"", 1, true) ~= nil, saved)
check("the saved file holds the built-in templates",
      saved:find("dark.prompt", 1, true) ~= nil and
      saved:find("light.prompt", 1, true) ~= nil)
check("the saved file is ASCII", saved:find("[\128-\255]") == nil)
check("save does not write real escape bytes", saved:find("\27", 1, true) == nil)

local ok_reload = theme.load("/tmp/theme_saved.conf")
check("the saved file can be read back", ok_reload == true)
check("the round trip keeps the current theme", theme.current() == "solar",
      theme.current())
check("the round trip keeps the template",
      theme.template("solar") == "[\\e{pink}$USER\\e{}] \\$ ",
      "[" .. theme.template("solar") .. "]")
theme.reset()

-- ============================================================
section("usr/ush.lua - the prompt of the session")
-- ============================================================
write("/etc/theme.conf", conf)
_G.__USH_TEST = true
local chunk = assert(loadfile(PROJ .. "/usr/ush.lua"))
chunk()
local ush = _G.__ush_test
local perm = require("perm")
pcall(perm.set_current_user, "root")
ush.init()

local function run(line)
    clear()
    local status = ush.run(line)
    return status, out()
end

check("the shell publishes the theme glue", type(ush.prompt) == "function" and
      type(ush.prompt_write) == "function")
check("init reads /etc/theme.conf", theme.source() == "/etc/theme.conf",
      tostring(theme.source()))
check("the file selects dark", theme.current() == "dark", theme.current())
check("the shipped file raises no warning", #theme.warnings() == 0,
      table.concat(theme.warnings(), " | "))
check("the dark template of the file wins",
      theme.template("dark") == theme.builtin("dark"), theme.template("dark"))
check("HOST is a shell variable now", type(ush.vars.get("HOST")) == "string",
      tostring(ush.vars.get("HOST")))
check("HOST is the host name", ush.vars.get("HOST") == theme.hostname())

local user = ush.vars.get("USER") or "root"
local host = theme.hostname()

local prompt = ush.prompt()
check("the prompt is a rendered table", type(prompt) == "table" and
      type(prompt.plain) == "string")
check("the prompt starts with the user", prompt.plain:sub(1, #user) == user,
      prompt.plain)
check("the prompt of the root session ends with a sharp and a space",
      prompt.plain:sub(-2) == "# ", "[" .. prompt.plain .. "]")
check("the prompt carries the user", prompt.plain:find(user, 1, true) ~= nil,
      prompt.plain)
check("the prompt carries the host",
      prompt.plain:find("@" .. host, 1, true) ~= nil, prompt.plain)
check("the prompt carries the working directory",
      prompt.plain:find(require("cwd").get(), 1, true) ~= nil, prompt.plain)
check("the prompt has no escape left", prompt.plain:find("\\e", 1, true) == nil,
      prompt.plain)
check("the prompt has colours", prompt.parts[1].colour == 8,
      tostring(prompt.parts[1].colour))
check("the width matches the plain text", prompt.width == #prompt.plain,
      tostring(prompt.width))

local drawn = ush.prompt_write(prompt)
check("prompt_write returns the plain text", drawn == prompt.plain)

-- PS1 wins over the theme while it is set.
local st_ps1, o_ps1 = run("export PS1='[$USER]$ '")
check("export PS1 succeeds", st_ps1 == 0, tostring(st_ps1) .. " " .. o_ps1)
check("PS1 holds the template", ush.vars.get("PS1") == "[$USER]$ ",
      tostring(ush.vars.get("PS1")))
local with_ps1 = ush.prompt()
-- The session runs as root, so the sign of the account is a sharp here as well.
check("PS1 is used for the prompt", with_ps1.plain == "[" .. user .. "]# ",
      "[" .. with_ps1.plain .. "]")
check("a plain PS1 has no colour", with_ps1.parts[1].colour == nil,
      tostring(with_ps1.parts[1].colour))

ush.vars.set("PS1", "\\e{lime}$USER\\e{} \\$ ")
local coloured = ush.prompt()
check("a PS1 with escapes expands", coloured.plain == user .. " # ",
      "[" .. coloured.plain .. "]")
check("the lime escape reaches the parts", coloured.parts[1].colour == 32,
      tostring(coloured.parts[1].colour))
check("the reset reaches the parts", coloured.parts[2].colour == 1,
      tostring(coloured.parts[2].colour))

local st_unset = run("unset PS1")
check("unset PS1 succeeds", st_unset == 0, tostring(st_unset))
check("PS1 is gone", ush.vars.get("PS1") == nil or ush.vars.get("PS1") == "",
      tostring(ush.vars.get("PS1")))
check("the theme is used again", ush.prompt().parts[1].colour == 8)

-- A broken configuration cannot keep the prompt away: an empty template
-- still falls back to the theme of the shell.
local st_empty = run("export PS1=''")
check("an empty PS1 is accepted", st_empty == 0, tostring(st_empty))
check("an empty PS1 falls back to the theme of the root session",
      ush.prompt().plain:sub(-2) == "# ", ush.prompt().plain)
run("unset PS1")

-- ============================================================
section("usr/ush.lua - the theme builtin")
-- ============================================================
local st_show, o_show = run("theme")
check("theme succeeds", st_show == 0, tostring(st_show) .. " " .. o_show)
check("theme names the current theme", o_show:find("theme: dark", 1, true) ~= nil, o_show)
check("theme names the configuration file",
      o_show:find("file:  /etc/theme.conf", 1, true) ~= nil, o_show)
check("theme draws the prompt",
      o_show:find("prompt: " .. user .. "@" .. host, 1, true) ~= nil, o_show)
check("theme does not report a warning", o_show:find("warning:", 1, true) == nil, o_show)

ush.vars.set("PS1", "\\e{lime}$USER\\e{} \\$ ")
local _, o_ps1_show = run("theme")
check("theme reports PS1 when it is set",
      o_ps1_show:find("PS1:", 1, true) ~= nil and
      o_ps1_show:find("wins over the theme", 1, true) ~= nil, o_ps1_show)
run("unset PS1")
check("theme without PS1 stays quiet about it",
      select(2, run("theme")):find("PS1:", 1, true) == nil)

local _, o_list = run("theme -l")
check("theme -l lists dark", o_list:find("dark", 1, true) ~= nil, o_list)
check("theme -l lists light", o_list:find("light", 1, true) ~= nil, o_list)
check("theme -l marks the current theme", o_list:find("* dark", 1, true) ~= nil, o_list)
check("theme -l prints the templates", o_list:find("$USER", 1, true) ~= nil, o_list)

local _, o_cat = run("theme -c")
check("theme -c prints the current template",
      o_cat:find("$PWD", 1, true) ~= nil and o_cat:find("\\e{", 1, true) ~= nil, o_cat)
local _, o_cat_light = run("theme -c light")
check("theme -c light prints the light template",
      o_cat_light:find("$USER@$HOST", 1, true) ~= nil, o_cat_light)
local st_cat_bad, o_cat_bad = run("theme -c nope")
check("theme -c refuses a missing theme", st_cat_bad == 1, tostring(st_cat_bad))
check("theme -c explains itself", o_cat_bad:find("no such theme", 1, true) ~= nil, o_cat_bad)

local st_use, o_use = run("theme light")
check("theme light succeeds", st_use == 0, tostring(st_use) .. " " .. o_use)
check("light is current for the session", theme.current() == "light")
check("the prompt follows the theme", ush.prompt().parts[1].colour == 128,
      tostring(ush.prompt().parts[1].colour))
check("theme says what it did", o_use:find("light is current", 1, true) ~= nil, o_use)

local _, o_list2 = run("theme -l")
check("theme -l moves the mark", o_list2:find("* light", 1, true) ~= nil, o_list2)
check("theme -l leaves one mark only", count_of(o_list2, "* ") == 1, o_list2)

local st_bad, o_bad = run("theme nope")
check("theme refuses a missing theme", st_bad == 1, tostring(st_bad))
check("theme explains the refused name", o_bad:find("unknown theme: nope", 1, true) ~= nil, o_bad)
check("the refused name changes nothing", theme.current() == "light")

local st_opt, o_opt = run("theme -x")
check("theme refuses an unknown option", st_opt == 1, tostring(st_opt))
check("theme names the bad option", o_opt:find("unknown option -x", 1, true) ~= nil, o_opt)

local st_help, o_help = run("theme -h")
check("theme -h succeeds", st_help == 0, tostring(st_help))
check("theme -h shows the usage", o_help:find("usage: theme", 1, true) ~= nil, o_help)
check("theme -h mentions save", o_help:find("theme save", 1, true) ~= nil, o_help)

local st_default, o_default = run("theme -d")
check("theme -d succeeds", st_default == 0, tostring(st_default) .. " " .. o_default)
check("theme -d drops the file", theme.source() == nil, tostring(theme.source()))
check("theme -d comes back to dark", theme.current() == "dark")
check("theme -d uses the built-in template",
      theme.template("dark") == theme.builtin("dark"))
check("theme -d says what it did",
      o_default:find("built-in templates", 1, true) ~= nil, o_default)

local st_default2 = run("theme -d light")
check("theme -d NAME succeeds", st_default2 == 0, tostring(st_default2))
check("theme -d NAME selects the theme", theme.current() == "light")
local st_default3, o_default3 = run("theme -d nope")
check("theme -d refuses a name without a built-in template", st_default3 == 1,
      tostring(st_default3))
check("theme -d names the refused template",
      o_default3:find("no built-in theme", 1, true) ~= nil, o_default3)

local st_save, o_save = run("theme save -f")
check("theme save -f succeeds", st_save == 0, tostring(st_save) .. " " .. o_save)
check("theme save says where it wrote", o_save:find("/etc/theme.conf", 1, true) ~= nil, o_save)
local written = read("/etc/theme.conf") or ""
check("the file holds the selection", written:find("theme = light", 1, true) ~= nil,
      written)
check("the file holds both templates",
      written:find("dark.prompt", 1, true) ~= nil and
      written:find("light.prompt", 1, true) ~= nil)
check("the written file is ASCII", written:find("[\128-\255]") == nil)
check("the written file has no real escapes", written:find("\27", 1, true) == nil)

local ok_again = theme.load()
check("the written file loads again", ok_again == true)
check("the selection survived the round trip", theme.current() == "light",
      theme.current())
check("the round trip keeps the built-in dark template",
      theme.template("dark") == theme.builtin("dark"))
theme.reset()
write("/etc/theme.conf", conf)

-- ============================================================
section("lib/man.lua - the prompt pages")
-- ============================================================
local man = require("man")
check("a page for theme", man.exists("theme") == true)
check("a page for PS1", man.exists("PS1") == true)
check("a page for theme.conf", man.exists("theme.conf") == true)

local theme_page = table.concat(man.render("theme"), "\n")
check("the theme page is a page", theme_page:find("NAME\n  theme - ", 1, true) ~= nil,
      theme_page)
check("the theme page shows -l", theme_page:find("-l", 1, true) ~= nil)
check("the theme page shows save", theme_page:find("save", 1, true) ~= nil)
check("the theme page points at PS1", theme_page:find("PS1", 1, true) ~= nil)
check("the theme page points at theme.conf",
      theme_page:find("theme.conf", 1, true) ~= nil)
check("the theme page names the sharp of the root account",
      theme_page:find("sharp", 1, true) ~= nil, theme_page)

local ps1_page = table.concat(man.render("PS1"), "\n")
check("the PS1 page is a page", ps1_page:find("NAME\n  PS1 - ", 1, true) ~= nil,
      ps1_page)
check("the PS1 page shows unset", ps1_page:find("unset PS1", 1, true) ~= nil)
check("the PS1 page names the colour escape",
      ps1_page:find("COLOUR", 1, true) ~= nil, ps1_page)
check("the PS1 page points at theme", ps1_page:find("theme", 1, true) ~= nil)
check("the PS1 page names the sharp of the root account",
      ps1_page:find("sharp", 1, true) ~= nil, ps1_page)

local conf_page = table.concat(man.render("theme.conf"), "\n")
check("the theme.conf page is a page",
      conf_page:find("NAME\n  theme.conf - ", 1, true) ~= nil, conf_page)
check("the theme.conf page names the path",
      conf_page:find("/etc/theme.conf", 1, true) ~= nil)
check("the theme.conf page explains the quoting",
      conf_page:find("quotes", 1, true) ~= nil, conf_page)

local st_man, o_man = run("man theme")
check("man theme works from the shell", st_man == 0, tostring(st_man))
check("man theme prints the page",
      o_man:find("theme - show or change", 1, true) ~= nil, o_man)
local st_help2, o_help2 = run("help PS1")
check("help PS1 works from the shell", st_help2 == 0, tostring(st_help2))
check("help PS1 prints the page",
      o_help2:find("PS1 - the prompt variable", 1, true) ~= nil, o_help2)

local st_keys, o_keys = run("man keys")
check("man keys works from the shell", st_keys == 0, tostring(st_keys))
check("man keys prints the page",
      o_keys:find("keys - the keys the prompt line editor", 1, true) ~= nil, o_keys)
for _, combo in ipairs({ "Ctrl+A", "Ctrl+E", "Ctrl+W", "Ctrl+C", "Ctrl+L" }) do
    check("the key page names " .. combo, o_keys:find(combo, 1, true) ~= nil, o_keys)
end
check("the key page keeps Ctrl+T for the system",
      o_keys:find("terminate key of the system", 1, true) ~= nil, o_keys)

-- ============================================================
section("usr/ush.lua - the wiring")
-- ============================================================
local src = _G.SH_SRC and (_G.SH_SRC.ush or _G.SH_SRC["usr/ush.lua"])
check("the shell source is available for the wiring check", type(src) == "string")
if type(src) == "string" then
    check("the shell installs the module search path itself",
          src:find('"/lib/?.lua"', 1, true) ~= nil and
          src:find('"/usr/?.lua"', 1, true) ~= nil,
          tostring(src:find("/lib/?", 1, true)))
    check("the shell requires lib/theme", src:find('require("theme")', 1, true) ~= nil)
    check("the shell loads the configuration file at start up",
          src:find("theme.load", 1, true) ~= nil)
    check("the shell exports HOST", src:find('vars.set("HOST"', 1, true) ~= nil)
    check("the line editor draws the rendered prompt",
          src:find("safe_read(prompt_render())", 1, true) ~= nil)
    check("the prompt is rendered once per line",
          count_of(src, "prompt_render()") >= 3, tostring(count_of(src, "prompt_render()")))
    check("PS1 is read from the variables",
          src:find('vars.get("PS1")', 1, true) ~= nil)
    check("the overview names the theme builtin",
          src:find("history source theme help", 1, true) ~= nil)
    check("the old hard coded prompt is gone",
          src:find('safe_read("$ ")', 1, true) == nil)
    check("the theme builtin is registered",
          src:find('BUILTINS["theme"]', 1, true) ~= nil)
    local builtins = 0
    for _ in src:gmatch('\nBUILTINS%["([^"]+)"%]%s*=') do builtins = builtins + 1 end
    check("the shell still has its builtin surface", builtins > 100, tostring(builtins))
end

-- ============================================================
section("usr/ush.lua - the line editor keys")
-- ============================================================
-- The editor is driven through the event queue, one keystroke at a time.
-- Every group below holds the events the real machine delivers for it: typing
-- a character delivers the key event of that character followed by its char
-- event, a special key is a bare key event, and "Ctrl+letter" is the key event
-- of the Ctrl key, then the key event of the letter, then the key_up of the
-- Ctrl key -- and no char event, because a control combination stands for no
-- printable character.
local function ev(...)
    local list = { ... }
    return list
end

local function typed(text)
    local list = {}
    for i = 1, #text do
        local ch = text:sub(i, i)
        if keys[ch] ~= nil then list[#list + 1] = ev("key", keys[ch], false) end
        list[#list + 1] = ev("char", ch)
    end
    return list
end

local function press(code) return { ev("key", code, false) } end

local function ctrl_letter(letter)
    return { ev("key", keys.leftCtrl, false), ev("key", keys[letter], false),
             ev("key_up", keys.leftCtrl) }
end

-- Queue the groups in order, read one line and hand back the accepted line and
-- everything the read wrote to the screen.
local function drive(groups, prompt)
    clear()
    for _, group in ipairs(groups) do
        for _, e in ipairs(group) do os.queueEvent(e[1], e[2], e[3]) end
    end
    return ush.read_line(prompt or "$ "), out()
end

-- What was drawn after the last screen clear.
local function drawn_after_clear(o)
    local from, last = 1, nil
    while true do
        local a = o:find("<clear>", from, true)
        if not a then break end
        last = a
        from = a + 1
    end
    if not last then return o end
    return o:sub(last)
end

check("the editor is reachable from the test hook", type(ush.read_line) == "function")

-- Enter on an empty line: the line is accepted, the break is written and the
-- cursor does not stay where the typing left it.
term.setCursorPos(7, 3)
local text_blank = drive({ press(keys.enter) })
check("Enter on an empty line accepts an empty line", text_blank == "",
      "[" .. tostring(text_blank) .. "]")
check("Enter on an empty line writes the break", _G.__OUT[#_G.__OUT] == "\n",
      tostring(_G.__OUT[#_G.__OUT]))
check("Enter on an empty line leaves the cursor at the first column",
      select(1, term.getCursorPos()) == 1,
      tostring(select(1, term.getCursorPos())))
local text_typed = drive({ typed("echo hi"), press(keys.enter) })
check("a line with text is accepted as before", text_typed == "echo hi",
      tostring(text_typed))

-- THE CURSOR HAS TO BE ASKED FOR, and this editor is the thing that must ask.
-- The terminal starts with the cursor blink off and CraftOS's own line reader
-- turns it on while it reads; ush replaced that reader with its own, so without a
-- call of its own the prompt has no cursor at all -- measured on the real machine
-- as "the arrow keys mark no position", because Left/Right were moving an
-- insertion point nobody could see.
_G.__CURSOR_BLINK_ON, _G.__CURSOR_BLINK_OFF, _G.__CURSOR_BLINK = 0, 0, false
drive({ typed("ls"), press(keys.enter) })
check("the line editor asks for the visible cursor",
      (_G.__CURSOR_BLINK_ON or 0) > 0, tostring(_G.__CURSOR_BLINK_ON))
check("and hides it again when the line is accepted",
      _G.__CURSOR_BLINK == false and (_G.__CURSOR_BLINK_OFF or 0) > 0,
      tostring(_G.__CURSOR_BLINK) .. " off=" .. tostring(_G.__CURSOR_BLINK_OFF))
check("a line with text leaves the cursor at the first column too",
      select(1, term.getCursorPos()) == 1,
      tostring(select(1, term.getCursorPos())))

-- Ctrl+C: the half typed line goes away, the session stays
local text_c, out_c = drive({
    typed("shutdown now"), ctrl_letter("c"), typed("ls"), press(keys.enter),
})
check("Ctrl+C drops the line and reads the next one", text_c == "ls",
      tostring(text_c))
check("Ctrl+C leaves a mark on the screen", out_c:find("^C", 1, true) ~= nil, out_c)
check("Ctrl+C does not end the session", text_c ~= nil)

-- Ctrl+L: screen cleared, prompt and line drawn again
local text_l, out_l = drive({
    typed("echo hi"), ctrl_letter("l"), press(keys.enter),
})
check("Ctrl+L keeps the line that was on screen", text_l == "echo hi",
      tostring(text_l))
check("Ctrl+L clears the screen once", count_of(out_l, "<clear>") == 1,
      tostring(count_of(out_l, "<clear>")))
local repainted = drawn_after_clear(out_l)
check("Ctrl+L draws the prompt again", repainted:find("$ ", 1, true) ~= nil,
      repainted)
check("Ctrl+L draws the edited line again", repainted:find("echo hi", 1, true) ~= nil,
      repainted)

-- The interactive loop hands the editor a rendered prompt (colours and all),
-- which is what Ctrl+L has to draw again.
local rp = ush.prompt()
local text_rp, out_rp = drive({ typed("pwd"), ctrl_letter("l"), press(keys.enter) }, rp)
check("the editor accepts the rendered prompt of the session", text_rp == "pwd",
      tostring(text_rp))
local rp_tail = drawn_after_clear(out_rp)
check("Ctrl+L draws the rendered prompt again", rp_tail:find(user, 1, true) ~= nil,
      rp_tail)
check("Ctrl+L keeps the tail of the rendered prompt",
      rp_tail:find(rp.plain:sub(-2), 1, true) ~= nil, rp_tail)

-- Ctrl+A: start of line, Ctrl+E: end of line
local text_a = drive({ typed("bc"), ctrl_letter("a"), typed("a"), press(keys.enter) })
check("Ctrl+A puts the cursor at the start of the line", text_a == "abc",
      tostring(text_a))
local text_ae = drive({
    typed("ab"), ctrl_letter("a"), ctrl_letter("e"), typed("z"), press(keys.enter),
})
check("Ctrl+E puts the cursor back at the end of the line", text_ae == "abz",
      tostring(text_ae))
local text_aa = drive({
    typed("c"), ctrl_letter("a"), ctrl_letter("a"), typed("a"), typed("b"),
    press(keys.enter),
})
check("Ctrl+A twice is still the start of the line", text_aa == "abc",
      tostring(text_aa))

-- Ctrl+W: rub out the word in front of the cursor
local text_w1 = drive({ typed("echo one two"), ctrl_letter("w"), press(keys.enter) })
check("Ctrl+W rubs out the word in front of the cursor", text_w1 == "echo one ",
      "[" .. tostring(text_w1) .. "]")
local text_w2 = drive({
    typed("echo one two"), ctrl_letter("w"), ctrl_letter("w"), press(keys.enter),
})
check("Ctrl+W walks back through the line", text_w2 == "echo ",
      "[" .. tostring(text_w2) .. "]")
local text_w3 = drive({
    typed("echo one two"), ctrl_letter("w"), ctrl_letter("w"), ctrl_letter("w"),
    press(keys.enter),
})
check("Ctrl+W empties the line word by word", text_w3 == "",
      "[" .. tostring(text_w3) .. "]")
local text_w4 = drive({ typed("   "), ctrl_letter("w"), press(keys.enter) })
check("Ctrl+W rubs out blanks too", text_w4 == "", "[" .. tostring(text_w4) .. "]")
local text_w5 = drive({ ctrl_letter("w"), typed("x"), press(keys.enter) })
check("Ctrl+W on an empty line changes nothing", text_w5 == "x",
      "[" .. tostring(text_w5) .. "]")
local text_w6 = drive({
    typed("echo one two"), ctrl_letter("a"), typed("a"), ctrl_letter("e"),
    ctrl_letter("w"), press(keys.enter),
})
check("Ctrl+W follows the cursor to the end of the line", text_w6 == "aecho one ",
      "[" .. tostring(text_w6) .. "]")

-- Ctrl has to be let go again: the key event of a plain letter must not be
-- taken for a Ctrl combination any more (Ctrl+L would clear the screen again).
local text_plain, out_plain = drive({
    typed("abc"), ctrl_letter("l"), typed("l"), press(keys.enter),
})
check("a plain letter after Ctrl+L is a character", text_plain == "abcl",
      tostring(text_plain))
check("a plain letter after Ctrl+L does not clear the screen again",
      count_of(out_plain, "<clear>") == 1, tostring(count_of(out_plain, "<clear>")))

-- The keys that were there before still behave
local text_home = drive({
    typed("abcd"), press(keys.home), typed("x"), press(keys.right),
    press(keys.right), press(keys.delete), press(keys.enter),
})
check("Home, Right and Delete still move and rub out", text_home == "xabd",
      tostring(text_home))
local text_back = drive({
    typed("abcd"), press(keys.left), press(keys.left), press(keys.backspace),
    press(keys.enter),
})
check("Left and Backspace still move and rub out", text_back == "acd",
      tostring(text_back))
local text_end = drive({
    typed("abcd"), press(keys.left), press(keys.left), press(keys["end"]),
    typed("z"), press(keys.enter),
})
check("End still jumps to the end of the line", text_end == "abcdz",
      tostring(text_end))
local text_edge = drive({
    typed("ab"), press(keys.home), press(keys.left), press(keys["end"]),
    press(keys.right), press(keys.enter),
})
check("Left at the start and Right at the end change nothing", text_edge == "ab",
      tostring(text_edge))

-- Ctrl+T stays the terminate key: the editor ignores it and the line survives
local text_t = drive({
    typed("ab"), { ev("terminate") }, typed("c"), press(keys.enter),
})
check("Ctrl+T is ignored by the editor", text_t == "abc", tostring(text_t))

-- The history still walks with Up and Down
ush.history.clear()
ush.history.add("echo one")
ush.history.add("echo two")
local text_up = drive({ press(keys.up), press(keys.enter) })
check("Up brings back the last command", text_up == "echo two", tostring(text_up))
local text_up2 = drive({ press(keys.up), press(keys.up), press(keys.enter) })
check("Up twice brings back the one before", text_up2 == "echo one",
      tostring(text_up2))
local text_down = drive({
    press(keys.up), press(keys.up), press(keys.down), press(keys.enter),
})
check("Down walks forward again", text_down == "echo two", tostring(text_down))
local text_draft = drive({
    typed("draft"), press(keys.up), press(keys.down), press(keys.enter),
})
check("Down restores the line that was being typed", text_draft == "draft",
      tostring(text_draft))
local text_cut = drive({
    press(keys.up), ctrl_letter("c"), press(keys.enter),
})
check("Ctrl+C also leaves the history list alone", text_cut == "",
      "[" .. tostring(text_cut) .. "]")
local text_restart = drive({
    press(keys.up), ctrl_letter("c"), press(keys.up), press(keys.enter),
})
check("Ctrl+C starts the walk through the history over again",
      text_restart == "echo two", tostring(text_restart))
check("the history still holds both entries", ush.history.count() == 2,
      tostring(ush.history.count()))

-- ============================================================
section("usr/ush.lua - Tab with options and with sudo")
-- ============================================================

-- The editor and the tests share one completion entry: the cursor of the
-- editor is the insertion point, so a word that is being typed is handed over
-- with the cursor behind it.
local function comp(text, cursor)
    return ush.complete_line(text, cursor or (#text + 1))
end

local function cands_of(text)
    return select(3, comp(text))
end

local function same(list, want)
    if #list ~= #want then return false end
    for i = 1, #want do
        if list[i] ~= want[i] then return false end
    end
    return true
end

local function names(list)
    return table.concat(list, " ")
end

-- A word that starts with a dash asks the command in front of it for the
-- options its manual page names.
local line_dash, cursor_dash, cands_dash = comp("ls -")
check("a dash asks the command in front for its options",
      same(cands_dash, { "-a", "-l" }), names(cands_dash))
check("two options leave the line as it is", line_dash == "ls -", line_dash)
check("two options leave the cursor where it was", cursor_dash == 5,
      tostring(cursor_dash))

local line_opt, cursor_opt, cands_opt = comp("ls -l")
check("only the option that matches the word is offered",
      same(cands_opt, { "-l" }), names(cands_opt))
check("the one option is completed", line_opt == "ls -l ", "[" .. line_opt .. "]")
check("the cursor comes to rest behind the blank", cursor_opt == 7,
      tostring(cursor_opt))

local line_miss, _, cands_miss = comp("ls -z")
check("an option the command does not take is not invented", #cands_miss == 0,
      names(cands_miss))
check("a word without a match stays as it is", line_miss == "ls -z", line_miss)

check("the manual page of a command is the source of its options",
      same(cands_of("cat -"), { "-n" }), names(cands_of("cat -")))
check("a command with several options lists them",
      same(cands_of("theme -"), { "-c", "-d", "-f", "-l" }),
      names(cands_of("theme -")))
check("the long options of a command are offered",
      same(cands_of("netd --"), { "--allow", "--force", "--once", "--save" }),
      names(cands_of("netd --")))
check("a long option is completed", select(1, comp("netd --a")) == "netd --allow ")
check("a command with many options lists them all",
      same(cands_of("grep -"), { "-E", "-F", "-c", "-i", "-l", "-n", "-q", "-r", "-v" }),
      names(cands_of("grep -")))

local line_pathopt = select(1, comp("ls -a /etc/pass"))
check("a path behind an option is completed", line_pathopt == "ls -a /etc/passwd ",
      "[" .. line_pathopt .. "]")

-- An unknown command is not an error, it simply has no options.
local ok_ghost, ghost_line, _, ghost_cands = pcall(ush.complete_line, "nosuchcmd -", 12)
check("an unknown command does not raise", ok_ghost == true, tostring(ghost_line))
check("an unknown command offers no options", ok_ghost == true and #ghost_cands == 0)
check("the line of an unknown command is not touched",
      ok_ghost == true and ghost_line == "nosuchcmd -", tostring(ghost_line))

-- sudo first reads its own options ...
check("sudo offers its own options",
      same(cands_of("sudo -"), { "-k", "-l", "-n", "-u" }), names(cands_of("sudo -")))
check("an option of sudo is completed", select(1, comp("sudo -n")) == "sudo -n ")
check("sudo keeps offering its own options behind one of them",
      same(cands_of("sudo -k -"), { "-k", "-l", "-n", "-u" }),
      names(cands_of("sudo -k -")))
check("an empty word behind sudo lists the commands", #cands_of("sudo ") > 1,
      tostring(#cands_of("sudo ")))
check("sudo completes the command it wraps",
      select(1, comp("sudo pw")) == "sudo pwd ")

-- ... it names the accounts behind -u ...
check("sudo -u lists the accounts",
      same(cands_of("sudo -u "), { "admin", "guest", "root" }),
      names(cands_of("sudo -u ")))
check("an account is completed", select(1, comp("sudo -u g")) == "sudo -u guest ")
check("a part of an account that matches nothing offers nothing",
      #cands_of("sudo -u zzz") == 0)
check("the word behind -u is an account and not a command",
      same(cands_of("sudo -u r"), { "root" }), names(cands_of("sudo -u r")))

-- ... and afterwards hands the completion over to that command.
check("sudo hands the options over to the command it wraps",
      same(cands_of("sudo ls -"), { "-a", "-l" }), names(cands_of("sudo ls -")))
check("the option of the wrapped command is completed",
      select(1, comp("sudo ls -l")) == "sudo ls -l ")
check("a built-in may be the command behind sudo",
      select(1, comp("sudo theme -d")) == "sudo theme -d ")
check("sudo -- stops reading its own options",
      same(cands_of("sudo -- ls -"), { "-a", "-l" }),
      names(cands_of("sudo -- ls -")))
check("an option of sudo in front of the command is stepped over",
      select(1, comp("sudo -k ls /etc/pass")) == "sudo -k ls /etc/passwd ")
check("the account does not stop the path completion",
      select(1, comp("sudo -u root ls /etc/pass")) == "sudo -u root ls /etc/passwd ")
check("a path behind the wrapped command is completed",
      select(1, comp("sudo ls /etc/pass")) == "sudo ls /etc/passwd ")
check("an unknown command behind sudo offers no options",
      #cands_of("sudo nosuchcmd -") == 0, names(cands_of("sudo nosuchcmd -")))

-- The completion that was there before is untouched.
check("a command name is still completed", select(1, comp("pw")) == "pwd ")
check("a directory keeps its trailing slash", select(1, comp("ls /et")) == "ls /etc/",
      "[" .. select(1, comp("ls /et")) .. "]")
check("a path is still completed inside a command line",
      select(1, comp("ls /etc/pass")) == "ls /etc/passwd ")
check("an empty line still lists the commands", #cands_of("") > 50,
      tostring(#cands_of("")))
check("a dash at the start of a command is not an option", #cands_of("-") == 0,
      names(cands_of("-")))

-- ============================================================
section("usr/ush.lua - the Tab key of the editor")
-- ============================================================

local text_tab1, out_tab1 = drive({ typed("ls -l"), press(keys.tab), press(keys.enter) })
check("Tab completes an option", text_tab1 == "ls -l ",
      "[" .. tostring(text_tab1) .. "]")
check("a single option is not listed", out_tab1:find("-a", 1, true) == nil, out_tab1)

local text_tab2, out_tab2 = drive({ typed("ls -"), press(keys.tab), press(keys.enter) })
check("Tab keeps the line when there are several options", text_tab2 == "ls -",
      "[" .. tostring(text_tab2) .. "]")
check("Tab lists the options", out_tab2:find("-a", 1, true) ~= nil and
      out_tab2:find("-l", 1, true) ~= nil, out_tab2)

local text_tab3 = drive({
    typed("ls -"), press(keys.tab), typed("l"), press(keys.tab), press(keys.enter),
})
check("the list of options does not get in the way of the next Tab",
      text_tab3 == "ls -l ", "[" .. tostring(text_tab3) .. "]")

local text_tab4, out_tab4 = drive({
    typed("sudo -u "), press(keys.tab), press(keys.enter),
})
check("Tab keeps the line while the accounts are listed", text_tab4 == "sudo -u ",
      "[" .. tostring(text_tab4) .. "]")
check("Tab lists the accounts", out_tab4:find("root", 1, true) ~= nil, out_tab4)

local text_tab5, _ = drive({ typed("sudo -u g"), press(keys.tab), press(keys.enter) })
check("Tab completes the account behind sudo -u", text_tab5 == "sudo -u guest ",
      "[" .. tostring(text_tab5) .. "]")

local text_tab6, _ = drive({ typed("sudo pw"), press(keys.tab), press(keys.enter) })
check("Tab completes the command behind sudo", text_tab6 == "sudo pwd ",
      "[" .. tostring(text_tab6) .. "]")

local text_tab7, _ = drive({ typed("sudo ls -l"), press(keys.tab), press(keys.enter) })
check("Tab completes the option of the wrapped command",
      text_tab7 == "sudo ls -l ", "[" .. tostring(text_tab7) .. "]")
check("the Tab key never ends the session", text_tab7 ~= nil)

-- ============================================================
section("lib/complete.lua - the wiring")
-- ============================================================

local csrc = host_text(PROJ .. "/lib/complete.lua")
check("the completion source is readable", type(csrc) == "string",
      tostring(csrc))
if type(csrc) == "string" then
    check("the completion asks the manual pages",
          csrc:find('require("man")', 1, true) ~= nil)
    check("the completion keeps away from the account api",
          csrc:find('require("perm")', 1, true) == nil)
    check("the accounts arrive in the context",
          csrc:find("ctx.users", 1, true) ~= nil)
    check("the shell hands the accounts over",
          src:find("complete_ctx.users", 1, true) ~= nil)
    check("the shell asks lib/perm for the account list",
          src:find("perm.list_users", 1, true) ~= nil)
end

-- ============================================================
section("usr/ush.lua - the account of the session")
-- ============================================================
-- "su" and "sudo" move /etc/current_user. The variables of the session and
-- the prompt have to follow the account, both ways: the name it shows, the
-- sign after it ("$" for an account, "#" for root) and HOME.
if not perm.user_exists("pyam") then
    perm.add_user("pyam", { level = 1, groups = "pyam", password = "pyam-pw" })
end
if not perm.is_sudoer("pyam") then perm.add_sudoer("pyam") end
perm.set_password("root", "root-pw")

local function queue_events(groups)
    for _, group in ipairs(groups) do
        for _, e in ipairs(group) do os.queueEvent(e[1], e[2], e[3]) end
    end
end

-- The tail of the last segment: the sign the prompt really draws.
local function parts_tail(prompt)
    local part = prompt.parts[#prompt.parts]
    return (part and part.text) or ""
end

-- The session of this file runs as root: its prompt ends with a sharp.
check("the session runs as root", perm.get_current_user() == "root",
      tostring(perm.get_current_user()))
local p_root = ush.prompt()
check("the prompt of root ends with a sharp", p_root.plain:sub(-2) == "# ",
      "[" .. p_root.plain .. "]")
check("the sharp reaches the drawn segments",
      parts_tail(p_root):sub(-2) == "# ", "[" .. parts_tail(p_root) .. "]")
check("the width of the prompt still matches the plain text",
      p_root.width == #p_root.plain, tostring(p_root.width))

-- su, from root: no password is asked and the session changes hands.
local st_su1, o_su1 = run("su pyam")
check("su succeeds", st_su1 == 0, tostring(st_su1) .. " " .. o_su1)
check("su reports the new account",
      o_su1:find("switched to pyam", 1, true) ~= nil, o_su1)
check("su moves /etc/current_user", perm.get_current_user() == "pyam",
      tostring(perm.get_current_user()))
check("su publishes the account as USER", ush.vars.get("USER") == "pyam",
      tostring(ush.vars.get("USER")))
check("su takes HOME to the account", ush.vars.get("HOME") == "/home/pyam",
      tostring(ush.vars.get("HOME")))
local p_pyam = ush.prompt()
check("the prompt names the account that owns the console",
      p_pyam.plain:sub(1, 4) == "pyam", "[" .. p_pyam.plain .. "]")
check("the prompt of an account ends with a dollar",
      p_pyam.plain:sub(-2) == "$ ", "[" .. p_pyam.plain .. "]")
check("the drawn segments and the plain text agree",
      parts_tail(p_pyam):sub(-2) == "$ ",
      "[" .. parts_tail(p_pyam) .. "]")

-- A variable left over from the old account cannot change what the prompt
-- says: the account file wins, and the next prompt puts the variable right.
ush.vars.set("USER", "root")
local p_lying = ush.prompt()
check("the prompt follows the account, not a stale variable",
      p_lying.plain:sub(1, 4) == "pyam", "[" .. p_lying.plain .. "]")
check("the next prompt puts USER right", ush.vars.get("USER") == "pyam",
      tostring(ush.vars.get("USER")))

-- su, from an account: the password of the target is asked, and the sign is a
-- sharp once it is root again.
clear()
queue_events({ typed("root-pw"), press(keys.enter) })
local st_su2 = ush.run("su root")
check("su root succeeds with the password of root", st_su2 == 0,
      tostring(st_su2) .. " " .. out())
check("the session is root again", perm.get_current_user() == "root",
      tostring(perm.get_current_user()))
check("USER is root again", ush.vars.get("USER") == "root",
      tostring(ush.vars.get("USER")))
check("HOME is root again", ush.vars.get("HOME") == "/home/root",
      tostring(ush.vars.get("HOME")))
local p_root2 = ush.prompt()
check("the prompt ends with a sharp again", p_root2.plain:sub(-2) == "# ",
      "[" .. p_root2.plain .. "]")
check("the sharp reaches the drawn segments again",
      parts_tail(p_root2):sub(-2) == "# ", "[" .. parts_tail(p_root2) .. "]")

-- Back to the account, then sudo: the wrapped command runs as root and the
-- session comes back afterwards.
local st_back, o_back = run("su pyam")
check("su takes the session back to the account",
      st_back == 0 and perm.get_current_user() == "pyam",
      tostring(st_back) .. " " .. o_back)
clear()
queue_events({ typed("pyam-pw"), press(keys.enter) })
local st_sudo = ush.run("sudo whoami")
check("sudo runs the wrapped command", st_sudo == 0,
      tostring(st_sudo) .. " " .. out())
check("the wrapped command ran as root", out():find("root", 1, true) ~= nil,
      out())
check("sudo hands the session back", perm.get_current_user() == "pyam",
      tostring(perm.get_current_user()))
check("USER is the account again", ush.vars.get("USER") == "pyam",
      tostring(ush.vars.get("USER")))
check("the prompt of the account ends with a dollar again",
      ush.prompt().plain:sub(-2) == "$ ", "[" .. ush.prompt().plain .. "]")

local function passwd_section()
    -- passwd: an account changes ITS OWN password by proving the old one ----------
    -- lib/perm.lua now writes /etc/shadow through the unguarded open (the guard can
    -- no longer refuse for it), so the rule "only root changes the login database"
    -- had to move into perm -- and the shell hands the old password over as the proof.
    -- Measured on a real machine: a program that reached perm could otherwise reset
    -- any password, and an account owner without the hand-over was refused by their
    -- own account.
    check("the session is the account before passwd",
          perm.get_current_user() == "pyam", tostring(perm.get_current_user()))
    clear()
    queue_events({ typed("pyam-pw"), press(keys.enter) })
    queue_events({ typed("Pyam-pw2"), press(keys.enter) })
    queue_events({ typed("Pyam-pw2"), press(keys.enter) })
    local st_pw, o_pw = run("passwd")
    check("passwd updates the password of the account", st_pw == 0,
          tostring(st_pw) .. " " .. o_pw)
    check("the new password is the one stored",
          perm.check_password("pyam", "Pyam-pw2") == true)
    check("the old password no longer works",
          perm.check_password("pyam", "pyam-pw") == false)

    -- root resets somebody else's password: no old password is asked for.
    perm.set_current_user("root")
    clear()
    queue_events({ typed("Pyam-pw3"), press(keys.enter) })
    queue_events({ typed("Pyam-pw3"), press(keys.enter) })
    local st_pw2, o_pw2 = run("passwd pyam")
    check("root resets an account password without the old one",
          st_pw2 == 0 and perm.check_password("pyam", "Pyam-pw3") == true,
          tostring(st_pw2) .. " " .. o_pw2)

    -- put the account and its password back for the rest of the file
    perm.set_password("pyam", "pyam-pw")
    perm.set_current_user("pyam")
end
passwd_section()

-- ============================================================
section("usr/ush.lua - the console state and the control bytes")
-- ============================================================
-- The console of the machine must not stay root between sessions. A shell that
-- was killed while it was root (a crash, the power going off) leaves the
-- account file as root; the next shell claims the console back for the account
-- that owns the machine, so root never survives the session that asked for it.
perm.set_current_user("root")
local owner = ush.console_owner()
check("an account owns the machine", type(owner) == "string" and owner ~= "root",
      tostring(owner))
local claimed = ush.claim_console()
check("a console left as root is claimed back", claimed == true, tostring(claimed))
check("the claim gives the console to the account that owns the machine",
      perm.get_current_user() == owner, tostring(perm.get_current_user()))
check("the console of an account is left alone", ush.claim_console() == false)
check("a claimed console draws the prompt of an account",
      ush.prompt().plain:sub(-2) == "$ ", "[" .. ush.prompt().plain .. "]")

-- The console hands a line over with bytes below 32 in it (a pasted line, a
-- keyboard that pads): they are not text. A stray byte in the line would turn
-- blanks into a command to look up, and one in a password would make a correct
-- entry fail, keeping root out of reach.
clear()
local text_stray, _ = drive({ typed("echo "), ev("char", "\0"), typed("hi"),
                              press(keys.enter) })
check("a control byte never reaches the line", text_stray == "echo hi",
      "[" .. tostring(text_stray) .. "]")
clear()
local text_blanks, _ = drive({ typed("   "), ev("char", "\0"),
                               press(keys.enter) })
check("blanks around a control byte read back blank",
      type(text_blanks) == "string" and text_blanks:match("^%s*$") ~= nil,
      "[" .. tostring(text_blanks) .. "]")
clear()
local ran_blanks = ush.feed(text_blanks)
check("blanks are not a command to run", ran_blanks == true)
check("blanks are not reported as an unknown command",
      out():find("not found", 1, true) == nil, out())
check("blanks leave the cursor at the first column of the next row",
      select(1, term.getCursorPos()) == 1, tostring(select(1, term.getCursorPos())))

-- The answer of whoami gets a line of its own: the break of the accepted line
-- puts the cursor back in the first column, so the message cannot take the
-- tail of the prompt row.
clear()
local text_who, _ = drive({ typed("whoami"), press(keys.enter) })
check("the editor accepts the whoami line", text_who == "whoami",
      tostring(text_who))
check("the accepted line leaves the cursor in the first column",
      select(1, term.getCursorPos()) == 1, tostring(select(1, term.getCursorPos())))
clear()
ush.feed("whoami")
check("whoami answers with the account on a line of its own",
      table.concat(_G.__OUT, "") == perm.get_current_user(),
      "[" .. table.concat(_G.__OUT, "") .. "]")

-- su asks the password of the target and every answer of the shell starts on a
-- fresh line, whether the entry is right or wrong.
perm.set_current_user(owner)
clear()
queue_events({ typed("nope"), press(keys.enter) })
ush.run("su root")
check("a wrong password does not reach root", perm.get_current_user() ~= "root",
      tostring(perm.get_current_user()))
local bad_text = table.concat(_G.__OUT, "")
local pos = bad_text:find("Password: ", 1, true)
check("su asks for the password", pos ~= nil, "[" .. bad_text .. "]")
check("the answer of su starts on a fresh line",
      pos ~= nil and bad_text:sub(pos + 10, pos + 10) == "\n",
      "[" .. bad_text .. "]")
check("su reports the failed authentication",
      bad_text:find("authentication failure", 1, true) ~= nil, "[" .. bad_text .. "]")

clear()
queue_events({ typed("root-"), ev("char", "\0"), typed("pw"), press(keys.enter) })
local st_ok = ush.run("su root")
check("a password with a stray byte still reaches root", st_ok == 0,
      tostring(st_ok) .. " " .. table.concat(_G.__OUT, ""))
check("the session is root after the password", perm.get_current_user() == "root",
      tostring(perm.get_current_user()))
check("USER is root after the password", ush.vars.get("USER") == "root",
      tostring(ush.vars.get("USER")))
check("the prompt ends with a sharp after the password",
      ush.prompt().plain:sub(-2) == "# ", "[" .. ush.prompt().plain .. "]")

-- Leave the session on the account the rest of the suite started with.
perm.set_current_user("root")
ush.prompt()

-- ============================================================
say("")
say("=== batch 6 (group E, steps 1-3) summary ===")
say(string.format("passed: %d  failed: %d", pass, fail))
if fail > 0 then
    for _, name in ipairs(fails) do
        say("  FAIL " .. name)
    end
end

_G.__RESULT = { pass = pass, fail = fail, report = table.concat(fails, "\n") }
