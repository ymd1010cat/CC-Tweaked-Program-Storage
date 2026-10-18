-- batch5_check.lua - PC side logic assertions for the fifth batch, group D of
-- the ush project (the manual pages of lib/man.lua, the man and help builtins,
-- and the coverage of the shipped command surface).
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

-- Count the lines that are exactly one word: the page header "NAME" only
-- counts once per page even when the synopsis repeats the word.
local function count_word_line(text, want)
    local n = 0
    for line in (text .. "\n"):gmatch("([^\n]*)\n") do
        if line:match("^%s*" .. want .. "%s*$") then n = n + 1 end
    end
    return n
end

if not fs.exists("/tmp") then fs.makeDir("/tmp") end

-- Names that have a page but are not a BUILTINS entry of ush.lua: the shell
-- keywords, the programs in /usr/cmd, the root level daemons, the pkg alias
-- and the topic pages of the shell language (keys, expansion). Used by the
-- coverage section to spot a page for a typo.
local NOT_A_BUILTIN = {}
for _, name in ipairs({ "if", "for", "while", "until", "case", "function",
                        "chmod", "chown", "chgrp", "w", "who", "last", "lastlog",
                        "rput", "rget", "rexec", "netd", "pkgserver",
                        "startup", "firstboot", "apt", "keys", "expansion",
                        "heredoc" }) do
    NOT_A_BUILTIN[name] = true
end

-- ============================================================
section("lib/man - the page table")
-- ============================================================
local man = require("man")

check("man.pages is a table", type(man.pages) == "table")
check("man.exists finds ls", man.exists("ls") == true)
check("man.exists refuses a missing name", man.exists("no-such-command") == false)
check("man.exists refuses nil", man.exists(nil) == false)

local names = man.list()
check("man.list returns a sorted list", #names >= 100, tostring(#names))
local sorted_ok = true
for i = 2, #names do
    if names[i - 1] > names[i] then sorted_ok = false end
end
check("man.list is in order", sorted_ok)
for _, wanted in ipairs({ "man", "help", "ls", "pkg", "apt", "service", "crontab",
                         "disk", "logrotate", "rput", "rget", "rexec", "sudo",
                         "passwd", "test", "[", "." }) do
    check("page for " .. wanted, man.exists(wanted), wanted)
end

local no_what, no_syn = 0, 0
for _, name in ipairs(names) do
    local page = man.pages[name]
    if type(page.what) ~= "string" or #page.what == 0 then no_what = no_what + 1 end
    if type(page.syn) ~= "table" or #page.syn == 0 then no_syn = no_syn + 1 end
end
check("every page has a description", no_what == 0, tostring(no_what))
check("every page has a synopsis", no_syn == 0, tostring(no_syn))

local rendered = man.render("ls")
check("render returns lines", type(rendered) == "table" and #rendered > 6)
local joined = table.concat(rendered, "\n")
check("render prints NAME", joined:find("NAME\n  ls - ", 1, true) ~= nil, joined)
check("render prints SYNOPSIS", joined:find("SYNOPSIS", 1, true) ~= nil)
check("render prints OPTIONS", joined:find("OPTIONS", 1, true) ~= nil)
check("render prints SEE ALSO", joined:find("SEE ALSO", 1, true) ~= nil)
check("render of an unknown name is nil", man.render("no-such-command") == nil)

local sub_page = table.concat(man.render("pkg"), "\n")
check("render prints SUBCOMMANDS", sub_page:find("SUBCOMMANDS", 1, true) ~= nil)
check("pkg page documents install", sub_page:find("install", 1, true) ~= nil)

-- ============================================================
section("lib/man - search")
-- ============================================================
local function hit_names(word)
    local hits, acc = man.search(word), {}
    for _, hit in ipairs(hits) do acc[#acc + 1] = hit.name end
    return table.concat(acc, " "), hits
end

local pw, pw_hits = hit_names("password")
check("search finds passwd", pw:find("passwd", 1, true) ~= nil, pw)
check("search is case insensitive", (select(1, hit_names("PASSWORD"))):find("passwd", 1, true) ~= nil)
check("search hits carry a description", type(pw_hits[1].what) == "string")
local du_hits = hit_names("disk usage")
check("search finds du by its description", du_hits:find("du", 1, true) ~= nil, du_hits)
local log_hits = hit_names("log")
check("search finds the log commands", log_hits:find("logrotate", 1, true) ~= nil, log_hits)
check("search refuses an empty word", #man.search("") == 0)
check("search reports nothing for a nonsense word", #man.search("zzzznope") == 0)

local order_ok = true
local all_hits = man.search("a")
for i = 2, #all_hits do
    if all_hits[i - 1].name > all_hits[i].name then order_ok = false end
end
check("search results are sorted", order_ok)

-- ============================================================
section("usr/ush.lua - the man and help builtins")
-- ============================================================
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

local st_ls, o_ls = run("man ls")
check("man ls succeeds", st_ls == 0, tostring(st_ls))
check("man ls describes ls", o_ls:find("ls - list directory contents", 1, true) ~= nil, o_ls)
check("man ls documents -a", o_ls:find("-a", 1, true) ~= nil)
check("man ls documents -l", o_ls:find("-l", 1, true) ~= nil)
check("man ls points at stat", o_ls:find("stat", 1, true) ~= nil)

local _, o_pkg = run("man pkg")
check("man pkg lists the subcommands", o_pkg:find("SUBCOMMANDS", 1, true) ~= nil)
check("man pkg mentions upgrade", o_pkg:find("upgrade", 1, true) ~= nil)
check("man pkg mentions sudo", o_pkg:find("sudo", 1, true) ~= nil)

local _, o_svc = run("man service")
check("man service shows the actions", o_svc:find("restart", 1, true) ~= nil)
check("man service shows boot", o_svc:find("boot", 1, true) ~= nil)
check("man service shows shutdown", o_svc:find("shutdown", 1, true) ~= nil)

local _, o_disk = run("man disk")
check("man disk shows scan", o_disk:find("scan", 1, true) ~= nil)
check("man disk shows automount", o_disk:find("automount", 1, true) ~= nil)

local _, o_help = run("man help")
check("man help explains the topic mode", o_help:find("help COMMAND", 1, true) ~= nil)

local st_list, o_list = run("man -l")
check("man -l succeeds", st_list == 0, tostring(st_list))
check("man -l lists many pages", count_of(o_list, "\n") > 100, tostring(count_of(o_list, "\n")))
check("man -l lists the bracket builtin", o_list:find("[  ", 1, true) ~= nil)
check("man -l describes ls", o_list:find("list directory contents", 1, true) ~= nil
      and o_list:find("ls ", 1, true) ~= nil)

local st_k, o_k = run("man -k password")
check("man -k succeeds when it finds something", st_k == 0, tostring(st_k))
check("man -k password names passwd", o_k:find("passwd", 1, true) ~= nil, o_k)
check("man -k prints the name and the description", o_k:find(" - ", 1, true) ~= nil)

local st_k0, o_k0 = run("man -k zzzznope")
check("man -k fails when it finds nothing", st_k0 == 1, tostring(st_k0))
check("man -k says nothing appropriate", o_k0:find("nothing appropriate", 1, true) ~= nil, o_k0)

local st_miss, o_miss = run("man no-such-command")
check("man fails on an unknown page", st_miss == 1, tostring(st_miss))
check("man names the unknown page", o_miss:find("no manual entry for no-such-command", 1, true) ~= nil, o_miss)

local st_bare, o_bare = run("man")
check("a bare man asks for a name", st_bare == 1, tostring(st_bare))
check("a bare man points at man -l", o_bare:find("man -l", 1, true) ~= nil, o_bare)

local st_h, o_h = run("man -h")
check("man -h succeeds", st_h == 0, tostring(st_h))
check("man -h prints its usage", o_h:find("usage: man NAME", 1, true) ~= nil, o_h)

local st_bad, o_bad = run("man --bogus")
check("an unknown man option fails", st_bad == 1, tostring(st_bad))
check("an unknown man option is reported", o_bad:find("unknown option", 1, true) ~= nil, o_bad)

local st_two, o_two = run("man ls pkg")
check("man takes several names", st_two == 0, tostring(st_two))
check("man prints one page per name",
      count_word_line(o_two, "NAME") == 2, tostring(count_word_line(o_two, "NAME")))
check("man separates the pages with a blank line", o_two:find("\n\nNAME", 1, true) ~= nil)

local _, o_again = run("man ls")
check("man is deterministic", o_again == o_ls)

local st_pipe, o_pipe = run("man -l | wc -l")
check("man survives a pipe", st_pipe == 0, tostring(st_pipe))
check("the pipe counted more than 100 pages", tonumber(o_pipe:match("(%d+)")) > 100, o_pipe)

local _, o_redir = run("man ls > /tmp/manpage.txt")
check("man can be redirected", fs.exists("/tmp/manpage.txt"))
local f = fs.open("/tmp/manpage.txt", "r")
local redirected = f and f.readAll() or ""
if f then f.close() end
check("the redirected page holds the text", redirected:find("SYNOPSIS", 1, true) ~= nil,
      string.sub(redirected, 1, 40))
check("the redirection printed nothing", o_redir == "" or o_redir:find("SYNOPSIS") == nil)

local st_which, o_which = run("which man")
check("which calls man a builtin", st_which == 0 and o_which:find("shell builtin", 1, true) ~= nil, o_which)
local st_which2, o_which2 = run("which help")
check("which calls help a builtin", st_which2 == 0 and o_which2:find("shell builtin", 1, true) ~= nil, o_which2)

local st_ov, o_ov = run("help")
check("help still succeeds", st_ov == 0, tostring(st_ov))
check("the overview lists help", o_ov:find("help", 1, true) ~= nil)
check("the overview lists man", o_ov:find("man", 1, true) ~= nil)
check("the overview mentions help NAME", o_ov:find("help NAME", 1, true) ~= nil)

local st_hp, o_hp = run("help pkg")
local _, o_mp = run("man pkg")
check("help NAME succeeds", st_hp == 0, tostring(st_hp))
check("help NAME prints the same page as man NAME", o_hp == o_mp)
local st_hx, o_hx = run("help no-such-command")
check("help NAME fails on an unknown name", st_hx == 1, tostring(st_hx))
check("help NAME reports the unknown name", o_hx:find("no manual entry", 1, true) ~= nil, o_hx)

local _, o_cd = run("cd /tmp")
local st_cdman, o_cdman = run("man pwd")
check("man works from another directory", st_cdman == 0 and o_cdman:find("pwd", 1, true) ~= nil)
run("cd /")

-- ============================================================
section("coverage - every builtin has a page")
-- ============================================================
local src = _G.SH_SRC and (_G.SH_SRC.ush or _G.SH_SRC["usr/ush.lua"])
check("the shell source is available for the coverage check", type(src) == "string")

local builtins, missing = {}, {}
if type(src) == "string" then
    for name in src:gmatch('\nBUILTINS%["([^"]+)"%]%s*=') do
        builtins[name] = true
    end
end
local total = 0
for name in pairs(builtins) do
    total = total + 1
    if not man.exists(name) then missing[#missing + 1] = name end
end
table.sort(missing)
check("the shell has more than 100 builtins", total > 100, tostring(total))
check("every builtin has a manual page", #missing == 0, table.concat(missing, " "))
check("the shell registers the man builtin", builtins["man"] == true)
check("the shell registers the help builtin", builtins["help"] == true)
check("help NAME delegates to lib/man", src:find('require("man").main', 1, true) ~= nil)
check("the overview names the man builtin", src:find("which man stat", 1, true) ~= nil)

for _, program in ipairs({ "chmod", "chown", "chgrp", "w", "who", "last", "lastlog",
                          "rput", "rget", "rexec", "netd", "pkgserver",
                          "startup", "firstboot" }) do
    check("page for the outside program " .. program, man.exists(program), program)
end

for _, keyword in ipairs({ "if", "for", "while", "case", "function", "break",
                          "continue", "return", "shift", "exit", "[", "test" }) do
    check("page for the shell keyword " .. keyword, man.exists(keyword), keyword)
end

local ghosts = {}
for _, name in ipairs(man.list()) do
    if name:match("^[a-z]+$") and not builtins[name] and not NOT_A_BUILTIN[name] then
        ghosts[#ghosts + 1] = name
    end
end
check("no page describes a name the shell does not have", #ghosts == 0,
      table.concat(ghosts, " "))

-- ============================================================
say("")
say("=== batch 5 (group D) summary ===")
say(string.format("passed: %d  failed: %d", pass, fail))
if fail > 0 then
    for _, name in ipairs(fails) do
        say("  FAIL " .. name)
    end
end

_G.__RESULT = { pass = pass, fail = fail, report = table.concat(fails, "\n") }
