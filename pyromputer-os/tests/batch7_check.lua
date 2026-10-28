-- batch7_check.lua - PC side logic assertions for the seventh batch, group F of
-- the psh project: the shell syntax layer. This file covers F1, the parameter
-- expansion operators of "${...}":
--
--   ${NAME:-WORD}  ${NAME:=WORD}  ${NAME:+WORD}  ${NAME:?WORD}  ${#NAME}
--   ${NAME-WORD}   ${NAME=WORD}   ${NAME+WORD}   ${NAME?WORD}
--   ${NAME#PAT}    ${NAME##PAT}   ${NAME%PAT}    ${NAME%%PAT}
--
-- and F2, the arithmetic expansion "$((EXPR))":
--
--   + - * / %  ~ & | ^ << >>  !  == != < <= > >=  && || ?:  ( )  names  0x 0b
--
-- and F3, the command substitution "$(CMD)" and the old "`CMD`" form:
--
--   $(CMD)  `CMD`  trailing newlines, splitting, quoting, glob, nesting,
--   sub shell isolation, the status, the escapes of the backquoted form
--
-- and F4, the here document "<<WORD" and its tab stripping form "<<-WORD":
--
--   the body as the standard input of the command, the line that holds the
--   delimiter, the quoted delimiter, the expansion of a bare body, the
--   escapes of the body, the clash with the "<" redirection, the faults
--
-- and F5, the trap built-in:
--
--   trap ACTION SIGNAL, trap '' SIGNAL, trap - SIGNAL, trap and trap -p, the
--   trap of EXIT, of ERR and of INT, the frame of a sub shell and a script
--
-- and F6, the set built-in and the options it holds:
--
--   set -e / set +e (errexit), set -u / set +u (nounset), set -x / set +x
--   (xtrace), set -o pipefail / set +o pipefail, the listing forms "set -o"
--   and "set +o", an assignment beside an option, the word that ends the
--   options, the letters that "$-" names, and the options of a command
--   substitution, of a sourced script, of a command script and of a function
--
-- The first part drives lib/glob.lua (the value scoped matcher behind the
-- pattern operators), lib/man.lua (the expansion page) and lib/arith.lua (the
-- arithmetic evaluator, on top of lib/bignum.lua), the last part boots
-- usr/psh.lua through _G.__PSH_TEST and expands the forms on the real command
-- line.
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
        fails[#fails + 1] = name ..
            (extra ~= nil and ("  [" .. tostring(extra) .. "]") or "")
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

local function trim(text)
    return (text:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function write(path, text)
    local parent = path:match("^(.*)/[^/]+$")
    if parent and parent ~= "" and not fs.exists(parent) then
        fs.makeDir(parent)
    end
    local handle = fs.open(path, "w")
    handle.write(text)
    handle.close()
end

local function host_text(path)
    local reader = _G.read_host_file
    if reader == nil then return nil end
    local ok, text = pcall(function() return reader(path) end)
    if ok and type(text) == "string" then return text end
    return nil
end

local glob = require("glob")
local man = require("man")

if not fs.exists("/tmp") then fs.makeDir("/tmp") end

-- ============================================================
section("lib/glob.lua - the value scoped matcher")
-- ============================================================
check("a value pattern still matches a plain name", glob.match_value("abc", "abc"))
check("the star of a value spans anything", glob.match_value("abc", "a*"))
check("a question mark is one character", glob.match_value("ab", "a?"))
check("a question mark does not match two", glob.match_value("abc", "a?") == false)
check("a value pattern is anchored at the front",
      glob.match_value("xabc", "abc") == false)
check("a value pattern is anchored at the back",
      glob.match_value("abcx", "abc") == false)
check("the star of a value crosses a separator", glob.match_value("a/b/", "*/"))
check("the star of a value reaches over separators",
      glob.match_value("a/b/c", "*/c"))
check("a value pattern may hold several separators",
      glob.match_value("/usr/etc/x", "*/x"))
check("a bracket group works inside a value", glob.match_value("a7b", "a[0-9]b"))
check("a bracket group stays a group", glob.match_value("axb", "a[0-9]b") == false)
check("a compiled value pattern is anchored", glob.compile_value("*") == "^.*$")
check("the star of a file name does not cross a separator",
      glob.match("a/b", "*") == false)
check("the star of a file name still works", glob.match("ab", "a*"))
check("the question mark of a file name stops at the separator",
      glob.match("a/b", "a?b") == false)

-- ============================================================
section("lib/man.lua - the expansion page")
-- ============================================================
check("the page is listed", man.exists("expansion"))
check("the page holds a description", type(man.pages.expansion.what) == "string",
      tostring(type(man.pages.expansion.what)))

local page = man.pages.expansion
if page then
    local syn = table.concat(page.syn or {}, " ")
    local note = table.concat(page.note or {}, " ")
    local opts = ""
    for _, opt in ipairs(page.opts or {}) do
        opts = opts .. opt[1] .. " " .. opt[2] .. " "
    end
    check("the synopsis shows the plain form", syn:find("$NAME", 1, true) ~= nil)
    check("the synopsis shows the default form",
          syn:find("${NAME:-WORD}", 1, true) ~= nil)
    check("the synopsis shows the length form",
          syn:find("${#NAME}", 1, true) ~= nil)
    check("the synopsis shows the suffix form",
          syn:find("${NAME%%PAT}", 1, true) ~= nil)
    check("the text names the colon rule",
          note:find("colon", 1, true) ~= nil)
    check("the text names the shortest match",
          note:find("shortest", 1, true) ~= nil)
    check("the text names the longest match", note:find("longest", 1, true) ~= nil)
    check("the text points at the basename idiom",
          note:find("${PATH##*/}", 1, true) ~= nil)
    check("the text points at the dirname idiom",
          note:find("${PATH%/*}", 1, true) ~= nil)
    check("the text mentions the failing exit", note:find("status", 1, true) ~= nil)
    for _, form in ipairs({ ":-WORD", ":=WORD", ":+WORD", ":?WORD", "-WORD",
                            "=WORD", "+WORD", "?WORD", "#PAT", "##PAT", "%PAT",
                            "%%PAT", "#NAME" }) do
        check("the options explain " .. form, opts:find(form, 1, true) ~= nil)
    end
    check("the page points at the neighbours",
          (page.see or ""):find("set", 1, true) ~= nil)
end

local cpage = man.pages.expansion
if cpage then
    local syn = table.concat(cpage.syn or {}, " ")
    local note = table.concat(cpage.note or {}, " ")
    local opts = ""
    for _, opt in ipairs(cpage.opts or {}) do
        opts = opts .. opt[1] .. " " .. opt[2] .. " "
    end
    check("the synopsis shows the $( ) form",
          syn:find("$(CMD)", 1, true) ~= nil)
    check("the synopsis shows the backquoted form",
          syn:find("`CMD`", 1, true) ~= nil)
    check("the text names the command substitution",
          note:find("command substitution", 1, true) ~= nil)
    check("the text names the sub shell",
          note:find("sub shell", 1, true) ~= nil)
    check("the text explains the trailing newlines",
          (note:find("newline", 1, true) ~= nil and
           note:find("dropped", 1, true) ~= nil))
    check("the text explains the splitting",
          note:find("split", 1, true) ~= nil)
    check("the text explains the file name expansion",
          note:find("file name expansion", 1, true) ~= nil)
    check("the text explains the double quotes",
          note:find("double quotes", 1, true) ~= nil)
    check("the text shows a nested substitution",
          note:find("$(echo $(echo a))", 1, true) ~= nil)
    check("the text explains the escapes of the old form",
          note:find("backslash", 1, true) ~= nil)
    check("the text explains the status of the substitution",
          note:find("status", 1, true) ~= nil)
    check("the options explain the $( ) form",
          opts:find("$(CMD)", 1, true) ~= nil)
    check("the options explain the backquoted form",
          opts:find("`CMD`", 1, true) ~= nil)
end

check("a search by name finds the page", man.search("expansion")[1] ~= nil)
local found = false
for _, hit in ipairs(man.search("parameter")) do
    if hit.name == "expansion" then found = true end
end
check("a search by word finds the page", found)

local rendered = man.render("expansion")
check("the page renders", type(rendered) == "table" and #rendered > 10,
      tostring(rendered and #rendered))
if type(rendered) == "table" then
    local text = table.concat(rendered, "\n")
    check("the render starts with the name section",
          text:find("^NAME\n") ~= nil)
    check("the render holds a SYNOPSIS section",
          text:find("\nSYNOPSIS\n", 1, true) ~= nil)
    check("the render holds an OPTIONS section",
          text:find("\nOPTIONS\n", 1, true) ~= nil)
    check("the render names the page",
          text:find("expansion - ", 1, true) ~= nil)
end

-- ============================================================
section("usr/psh.lua - the boot of the suite")
-- ============================================================
_G.__PSH_TEST = true
local chunk = assert(loadfile(PROJ .. "/usr/psh.lua"))
chunk()
local psh = _G.__psh_test
local vars = psh.vars
local params = require("params")
local perm = require("perm")
pcall(perm.set_current_user, "root")
psh.init()

local function run(line)
    clear()
    local status = psh.run(line)
    return status, out()
end

local function echo_of(line)
    local status, text = run(line)
    return status, trim(text)
end

check("the shell publishes the variables", type(vars.get) == "function")
check("the shell publishes the parameters", type(params.set) == "function")

-- ============================================================
section("usr/psh.lua - ${NAME:-WORD} and ${NAME-WORD}")
-- ============================================================
vars.unset("PX")
local st, o = echo_of("echo ${PX:-fallback}")
check("unset: the colon form uses the word", o == "fallback", o)
check("unset: the colon form reports success", st == 0, tostring(st))

vars.set("PX", "")
st, o = echo_of("echo ${PX:-fallback}")
check("set but empty: the colon form uses the word", o == "fallback", o)

vars.set("PX", "value")
st, o = echo_of("echo ${PX:-fallback}")
check("set: the value wins over the word", o == "value", o)

vars.set("PX", "")
st, o = echo_of("echo ${PX-fallback}")
check("set but empty: the form without a colon keeps the value", o == "",
      "[" .. o .. "]")

vars.unset("PX")
st, o = echo_of("echo ${PX-fallback}")
check("unset: the form without a colon uses the word", o == "fallback", o)

st, o = echo_of("echo ${PX:-}")
check("an empty word gives an empty value", o == "", "[" .. o .. "]")

st, o = echo_of("echo ${PX:-a-b.c_d}")
check("the word may hold any plain text", o == "a-b.c_d", o)

st, o = echo_of("echo p${PX:-q}s")
check("the operator works inside a longer word", o == "pqs", o)

vars.set("PX", "1")
st, o = echo_of("echo p${PX:-q}s")
check("a set name keeps the rest of the word", o == "p1s", o)

vars.set("PN", "inner")
vars.unset("PX")
st, o = echo_of("echo ${PX:-$PN}")
check("the word may hold a plain reference", o == "inner", o)

st, o = echo_of("echo ${PX:-${PN}}")
check("the word may hold a braced reference", o == "inner", o)

st, o = echo_of("echo ${PX:-${PN:-deep}}")
check("the word may hold a nested default", o == "inner", o)

vars.unset("PN")
st, o = echo_of("echo ${PX:-${PN:-deep}}")
check("the nested default is used when both are unset", o == "deep", o)

vars.set("PN", "inner")
vars.set("PX", "outer")
st, o = echo_of("echo ${PX:-${PN:-deep}}")
check("an outer value stops the word from being read", o == "outer", o)

vars.unset("PX")
st, o = echo_of("echo ${PX:-'q'}")
check("a quote inside the word is an ordinary character", o == "'q'", o)

st, o = echo_of("echo ${PX:-a b}")
check("an unquoted word is split into fields", count_of(out(), "a b") == 1, o)

-- ============================================================
section("usr/psh.lua - ${NAME:=WORD} writes the variable back")
-- ============================================================
vars.unset("AS")
st, o = echo_of("echo ${AS:=assigned}")
check("unset: the word is used", o == "assigned", o)
check("unset: the word is written back", vars.get("AS") == "assigned",
      tostring(vars.get("AS")))

vars.set("AS", "")
st, o = echo_of("echo ${AS:=filled}")
check("set but empty: the word is used", o == "filled", o)
check("set but empty: the value is replaced", vars.get("AS") == "filled",
      tostring(vars.get("AS")))

vars.set("AS", "keep")
st, o = echo_of("echo ${AS:=other}")
check("set: the value wins", o == "keep", o)
check("set: the value is untouched", vars.get("AS") == "keep",
      tostring(vars.get("AS")))

vars.set("AS", "")
st, o = echo_of("echo ${AS=plain}")
check("set but empty: the form without a colon keeps the value", o == "",
      "[" .. o .. "]")
check("set but empty: the form without a colon writes nothing",
      vars.get("AS") == "", "[" .. tostring(vars.get("AS")) .. "]")

vars.unset("AS")
st, o = echo_of("echo ${AS=plain}")
check("unset: the form without a colon assigns", vars.get("AS") == "plain",
      tostring(vars.get("AS")))

vars.set("NW", "bee")
vars.unset("AS")
st, o = echo_of("echo ${AS:=${NW}}")
check("the assigned word may hold a reference", o == "bee", o)
check("the assigned word is expanded before it is stored",
      vars.get("AS") == "bee", tostring(vars.get("AS")))

vars.unset("AS")
st, o = echo_of("echo a${AS:=b}c")
check("the assignment works inside a longer word", o == "abc", o)
check("the assignment of a middle word is stored", vars.get("AS") == "b",
      tostring(vars.get("AS")))

params.set({})
st, o = echo_of("echo ${1:=one}")
check("a positional parameter takes the word too", o == "one", o)
check("a positional parameter has no name to assign to",
      params.get("1") == nil, tostring(params.get("1")))

params.set({ "first" })
st, o = echo_of("echo ${1:=one}")
check("a set positional parameter keeps its value", o == "first", o)
params.set({})

-- ============================================================
section("usr/psh.lua - ${NAME:+WORD} and ${NAME+WORD}")
-- ============================================================
vars.unset("AV")
st, o = echo_of("echo ${AV:+alt}")
check("unset: the colon form gives nothing", o == "", "[" .. o .. "]")

vars.set("AV", "")
st, o = echo_of("echo ${AV:+alt}")
check("set but empty: the colon form gives nothing", o == "", "[" .. o .. "]")

vars.set("AV", "")
st, o = echo_of("echo ${AV+alt}")
check("set but empty: the form without a colon gives the word", o == "alt", o)

vars.set("AV", "set")
st, o = echo_of("echo ${AV:+alt}")
check("set: the colon form gives the word", o == "alt", o)

st, o = echo_of("echo ${AV+alt}")
check("set: the form without a colon gives the word", o == "alt", o)

st, o = echo_of("echo ${AV:+}")
check("an empty word stays empty", o == "", "[" .. o .. "]")

vars.set("PN", "inner")
st, o = echo_of("echo ${AV:+$PN}")
check("the alternate word is expanded", o == "inner", o)

st, o = echo_of("echo p${AV:+s}s")
check("the alternate form works inside a longer word", o == "pss", o)

-- ============================================================
section("usr/psh.lua - ${NAME:?WORD} stops a command")
-- ============================================================
vars.set("ER", "fine")
st, o = echo_of("echo ${ER:?boom}")
check("set: the value is used", o == "fine", o)
check("set: the status stays 0", st == 0, tostring(st))

st, o = echo_of("echo ${ER:?}")
check("set: an empty word is never needed", o == "fine", o)

vars.unset("ER")
st, o = echo_of("echo sentinel ${ER:?boom}")
check("unset: the status is not 0", st ~= 0, tostring(st))
check("unset: the word is reported", o == "psh: ER: boom", o)
check("unset: the command never runs", count_of(out(), "sentinel") == 0)

vars.set("ER", "")
st, o = echo_of("echo sentinel ${ER:?empty}")
check("set but empty: the colon form fails", st ~= 0, tostring(st))
check("set but empty: the word is reported", o == "psh: ER: empty", o)

vars.set("ER", "")
st, o = echo_of("echo ok ${ER?plain}")
check("set but empty: the form without a colon passes", st == 0, tostring(st))
check("set but empty: the value is used again", o == "ok", o)

vars.unset("ER")
st, o = echo_of("echo ${ER:?}")
check("unset: the message carries the name", o == "psh: ER: parameter not set or null", o)

run("echo ${ER:?once}")
st, o = echo_of("echo $?")
check("the failing expansion sets $?", o == "1", o)

st, o = run("for x in ${ER:?looped}; do echo never; done")
check("the for list reports the failure", st ~= 0, tostring(st))
check("the for list names the word", has("ER: looped"))
check("the for list runs no iteration", count_of(out(), "never") == 0)

vars.set("ER", "x")
st, o = echo_of("echo ${ER:?boom}ok")
check("a passing reference keeps its neighbours", o == "xok", o)

vars.unset("ER")
st, o = run('echo "x ${ER:?quoted}"')
check("a quoted failing reference stops the command", st ~= 0, tostring(st))
check("a quoted failing reference reports the word", has("ER: quoted"))
check("a quoted failing reference prints no field", count_of(out(), "x ") == 0)

-- ============================================================
section("usr/psh.lua - ${#NAME} is the length")
-- ============================================================
vars.set("LN", "hello")
st, o = echo_of("echo ${#LN}")
check("the length of a value is counted", o == "5", o)

vars.set("LN", "")
st, o = echo_of("echo ${#LN}")
check("an empty value has length 0", o == "0", o)

vars.unset("LN")
st, o = echo_of("echo ${#LN}")
check("an unset name has length 0", o == "0", o)

vars.set("LN", "hello")
st, o = echo_of("echo ${#LN}-end")
check("the length works inside a longer word", o == "5-end", o)

st, o = echo_of("echo ${#LN}${#LN}")
check("two lengths in one word", o == "55", o)

params.set({ "abc", "d" })
st, o = echo_of("echo ${#1}")
check("the length of a positional parameter", o == "3", o)
st, o = echo_of("echo ${#2}")
check("the length of the second positional parameter", o == "1", o)
params.set({})

-- ============================================================
section("usr/psh.lua - ${NAME#PAT} and the pattern operators")
-- ============================================================
vars.set("P", "/usr/etc/x")
st, o = echo_of("echo ${P##*/}")
check("the longest prefix gives the base name", o == "x", o)
st, o = echo_of("echo ${P#*/}")
check("the shortest prefix starts after the first separator",
      o == "usr/etc/x", o)
st, o = echo_of("echo ${P%%/*}")
check("the longest suffix gives the directory above", o == "", "[" .. o .. "]")
st, o = echo_of("echo ${P%/*}")
check("the shortest suffix gives the directory", o == "/usr/etc", o)

vars.set("S2", "a/b/c")
st, o = echo_of("echo ${S2#*/}")
check("a shortest prefix match is the first one", o == "b/c", o)
st, o = echo_of("echo ${S2##*/}")
check("a longest prefix match is the last one", o == "c", o)
st, o = echo_of("echo ${S2%/*}")
check("a shortest suffix match is the last one", o == "a/b", o)
st, o = echo_of("echo ${S2%%/*}")
check("a longest suffix match is the first one", o == "a", o)

vars.set("F", "foo.tar.gz")
st, o = echo_of("echo ${F%.*}")
check("the shortest suffix drops one extension", o == "foo.tar", o)
st, o = echo_of("echo ${F%%.*}")
check("the longest suffix drops every extension", o == "foo", o)
st, o = echo_of("echo ${F#*.}")
check("the shortest prefix drops the first extension", o == "tar.gz", o)
st, o = echo_of("echo ${F##*.}")
check("the longest prefix keeps the last extension", o == "gz", o)

vars.set("W", "abc")
st, o = echo_of("echo ${W#?}")
check("a question mark takes one character off", o == "bc", o)
st, o = echo_of("echo ${W%?}")
check("a question mark takes one character off the back", o == "ab", o)
st, o = echo_of("echo ${W##?}")
check("the longest match of one character is the same", o == "bc", o)

vars.set("X", "abc123")
st, o = echo_of("echo ${X%[0-9]*}")
check("a bracket group strips the shortest tail", o == "abc12", o)
st, o = echo_of("echo ${X%%[0-9]*}")
check("a bracket group strips the longest tail", o == "abc", o)
st, o = echo_of("echo ${X#[a-z]*}")
check("a bracket group strips the shortest head", o == "bc123", o)
st, o = echo_of("echo ${X##[a-z]*}")
check("a bracket group strips the longest head", o == "", "[" .. o .. "]")

vars.set("Y", "a7b")
st, o = echo_of("echo ${Y#[0-9]}")
check("a group that does not match leaves the value", o == "a7b", o)

vars.set("N", "abc")
st, o = echo_of("echo ${N#z}")
check("a pattern that does not match leaves the value", o == "abc", o)
st, o = echo_of("echo ${N%z}")
check("an unmatched suffix leaves the value", o == "abc", o)

vars.set("T", "a/b/")
st, o = echo_of("echo ${T%/*}")
check("a trailing separator is not special", o == "a/b", o)
st, o = echo_of("echo ${T##*/}")
check("the base name of a trailing separator is empty", o == "",
      "[" .. o .. "]")

vars.unset("U")
st, o = echo_of("echo ${U#x}")
check("an unset name gives an empty value", o == "", "[" .. o .. "]")
st, o = echo_of("echo ${U%x}")
check("an unset name gives an empty value for a suffix too", o == "",
      "[" .. o .. "]")

vars.set("V2", "value")
st, o = echo_of("echo ${V2#${W}}")
check("the pattern may hold a reference", o == "value", o)

vars.set("PAT", "ab")
st, o = echo_of("echo ${W#${PAT}}")
check("the referenced pattern is used as it stands", o == "c", o)

-- ============================================================
section("usr/psh.lua - positional parameters")
-- ============================================================
params.set({ "alpha", "beta" })
vars.set("DF", "fallback")
st, o = echo_of("echo ${1:-$DF}")
check("a set positional parameter wins", o == "alpha", o)
st, o = echo_of("echo ${3:-$DF}")
check("a missing positional parameter takes the word", o == "fallback", o)
st, o = echo_of("echo ${3-fallback}")
check("a missing positional parameter takes the plain word", o == "fallback", o)
st, o = echo_of("echo ${5:+alt}")
check("a missing positional parameter has no alternate", o == "", "[" .. o .. "]")
st, o = echo_of("echo ${1#a}")
check("a positional parameter can be cut", o == "lpha", o)
st, o = echo_of("echo ${2%%t*}")
check("a positional parameter can be cut from the back", o == "be", o)
st, o = echo_of("echo ${#1}")
check("the length of the first positional parameter", o == "5", o)
st, o = echo_of("echo ${#3}")
check("the length of a missing positional parameter", o == "0", o)
st, o = echo_of("echo $#")
check("$# counts the parameters", o == "2", o)
st, o = echo_of("echo $1 $2")
check("the plain forms still work", o == "alpha beta", o)
st, o = echo_of("echo ${@}")
check("the braced @ still expands to every parameter", o == "alpha beta", o)
params.set({})

-- ============================================================
section("usr/psh.lua - the forms of the old shell are unchanged")
-- ============================================================
vars.set("RG", "rg")
st, o = echo_of("echo $RG")
check("the short reference still works", o == "rg", o)
st, o = echo_of("echo ${RG}")
check("the braced reference still works", o == "rg", o)
st, o = echo_of("echo ${RG}x")
check("text is glued to a braced reference", o == "rgx", o)
st, o = echo_of('echo "a $RG b"')
check("a reference inside quotes still works", o == "a rg b", o)
st, o = echo_of('echo "$RG"')
check("a quoted reference is one word", o == "rg", o)

st, o = echo_of("echo ${RG:~x}")
check("an unknown operator keeps the old empty value", o == "", "[" .. o .. "]")
st, o = echo_of("echo A${RG:~x}B")
check("an unknown operator is not fatal", o == "AB", o)
st, o = echo_of("echo A${RG:}B")
check("a lone colon is not an operator", o == "AB", o)
st, o = echo_of("echo ${RG")
check("an unterminated brace still reads the name", o == "rg", o)
st, o = echo_of("echo ${}")
check("an empty brace is literal text", o == "${}", o)
st, o = echo_of("echo ${,}")
check("a brace without a name is literal text", o == "${,}", o)

st, o = echo_of("true; echo $?")
check("$? is 0 after a success", o == "0", o)
st, o = echo_of("false; echo $?")
check("$? is 1 after a failure", o == "1", o)

vars.set("D", "dx")
st, o = echo_of("echo $$")
check("$$ is still the computer id", o == tostring(vars.get("$")), o)
check("$$ is not an expansion of D", o ~= "dx")

params.set({ "a", "b" })
st, o = echo_of("echo ${#}")
check("${#} is still the number of parameters", o == "2", o)
st, o = echo_of("echo ${#}-end")
check("${#} works inside a word", o == "2-end", o)
st, o = echo_of("echo $*")
check("$* still joins the parameters", o == "a b", o)
params.set({})

-- ============================================================
section("usr/psh.lua - the fields of a word")
-- ============================================================
vars.set("SP", "a b")
st, o = run("for x in ${SP}; do echo p:$x; done")
check("a plain reference is split", has("p:a") and has("p:b"), trim(o))
st, o = run('for x in "${SP}"; do echo q:$x; done')
check("a quoted reference is one field", has("q:a b"), trim(o))

st, o = run("for x in ${SP:-z}; do echo r:$x; done")
check("the word of a colon form is split too",
      has("r:a") and has("r:b"), trim(o))
st, o = run('for x in "${SP:-z}"; do echo s:$x; done')
check("a quoted colon form is one field", has("s:a b"), trim(o))

st, o = run("for x in ${SP:+z}; do echo t:$x; done")
check("the alternate word is one field here", has("t:z"), trim(o))

vars.set("SP", "")
st, o = run("for x in ${SP:-}; do echo u:$x; done")
check("an empty word expands to no field at all",
      count_of(out(), "u:") == 0, trim(o))
vars.set("SP", "a b")

write("/tmp/px1.txt", "x")
write("/tmp/px2.txt", "x")
run("cd /tmp")
vars.set("GG", "px?.txt")
st, o = echo_of("echo ${GG}")
check("a plain reference is still globbed",
      has("px1.txt") and has("px2.txt"), o)
st, o = echo_of("echo ${GG:-px1.txt}")
check("the value of an operator is globbed as well",
      has("px1.txt") and has("px2.txt"), o)
st, o = echo_of('echo "${GG:-px1.txt}"')
check("a quoted operator is not globbed", o == "px?.txt", o)
st, o = echo_of("cd /")
check("the shell is back at the root", st == 0, tostring(st))

-- ============================================================
section("usr/psh.lua - $(( )) arithmetic, the operators")
-- ============================================================
st, o = echo_of("echo $((1+2))")
check("a sum is expanded", o == "3", o)
check("a successful expansion reports success", st == 0, tostring(st))
st, o = echo_of("echo $(( 2 * 3 + 4 ))")
check("blanks around the operators are allowed", o == "10", o)
st, o = echo_of("echo $((2+3*4))")
check("a product binds tighter than a sum", o == "14", o)
st, o = echo_of("echo $(( (1+2) * 3 ))")
check("parentheses group", o == "9", o)
st, o = echo_of("echo $(( (2+3)*(4-1) ))")
check("grouping survives nesting", o == "15", o)
st, o = echo_of("echo $((17-5))")
check("a difference is expanded", o == "12", o)
st, o = echo_of("echo $((10/3))")
check("the division truncates", o == "3", o)
st, o = echo_of("echo $((10%3))")
check("the modulo is the remainder", o == "1", o)
st, o = echo_of("echo $((-10/3))")
check("the division truncates towards zero", o == "-3", o)
st, o = echo_of("echo $((-10%3))")
check("the modulo takes the sign of the left side", o == "-1", o)
st, o = echo_of("echo $((10%-3))")
check("the modulo follows the left side, not the right one", o == "1", o)

st, o = echo_of("echo $((1<<4))")
check("a shift to the left multiplies", o == "16", o)
st, o = echo_of("echo $((256>>4))")
check("a shift to the right divides", o == "16", o)
st, o = echo_of("echo $((-8>>1))")
check("the right shift keeps the sign", o == "-4", o)
st, o = echo_of("echo $((1<<64))")
check("a shift past the width is zero", o == "0", o)

st, o = echo_of("echo $((~0))")
check("the complement of zero is minus one", o == "-1", o)
st, o = echo_of("echo $((~5))")
check("the complement flips every bit", o == "-6", o)
st, o = echo_of("echo $((5&3))")
check("the bitwise and", o == "1", o)
st, o = echo_of("echo $((5|3))")
check("the bitwise or", o == "7", o)
st, o = echo_of("echo $((5^3))")
check("the bitwise xor", o == "6", o)

st, o = echo_of("echo $((1<2))")
check("a true comparison is one", o == "1", o)
st, o = echo_of("echo $((2<=1))")
check("a false comparison is zero", o == "0", o)
st, o = echo_of("echo $((4>=5))")
check("a false comparison is zero here as well", o == "0", o)
st, o = echo_of("echo $((4>1))")
check("a true comparison is one here as well", o == "1", o)
st, o = echo_of("echo $((3==3))")
check("the equality", o == "1", o)
st, o = echo_of("echo $((3!=3))")
check("the inequality", o == "0", o)
st, o = echo_of("echo $((-1<0))")
check("a comparison reads the signs", o == "1", o)

st, o = echo_of("echo $((1&&0))")
check("the logical and", o == "0", o)
st, o = echo_of("echo $((1&&2))")
check("a non zero value is true", o == "1", o)
st, o = echo_of("echo $((0||3))")
check("the logical or", o == "1", o)
st, o = echo_of("echo $((!5))")
check("the logical not", o == "0", o)
st, o = echo_of("echo $((!0))")
check("the logical not of zero", o == "1", o)

st, o = echo_of("echo $((1?10:20))")
check("the true branch of a ternary", o == "10", o)
st, o = echo_of("echo $((0?10:20))")
check("the false branch of a ternary", o == "20", o)
st, o = echo_of("echo $((1?2?3:4:5))")
check("a ternary nests on the right", o == "3", o)

st, o = echo_of("echo $((+7))")
check("the unary plus", o == "7", o)
st, o = echo_of("echo $((- 7+1))")
check("the unary minus and a blank after it", o == "-6", o)
st, o = echo_of("echo $((0x10+0b11))")
check("the hex and binary bases are read", o == "19", o)
st, o = echo_of("echo $((9223372036854775807+1))")
check("a sum wraps around at the top of the width",
      o == "-9223372036854775808", o)
st, o = echo_of("echo $((0xFFFFFFFFFFFFFFFF))")
check("the last bit is the sign bit", o == "-1", o)
st, o = echo_of("echo $(( ))")
check("an empty expression is zero", o == "0", o)

-- ============================================================
section("usr/psh.lua - $(( )) arithmetic, the names")
-- ============================================================
vars.set("AN", "5")
st, o = echo_of("echo $((AN+1))")
check("a bare name stands for its variable", o == "6", o)
st, o = echo_of("echo $(($AN+1))")
check("a plain reference works inside the expression", o == "6", o)
st, o = echo_of("echo $((${AN}+1))")
check("a braced reference works inside the expression", o == "6", o)
st, o = echo_of("echo $((${AN}+${#AN}))")
check("a name and its length mix", o == "6", o)
vars.set("AN", "12")
st, o = echo_of("echo $((AN))")
check("a decimal value is read whole", o == "12", o)
vars.set("AN", " 0x10 ")
st, o = echo_of("echo $((AN))")
check("a value is read with its blanks and base", o == "16", o)
vars.set("AN", "12abc")
st, o = echo_of("echo $((AN+1))")
check("only the leading number of a value counts", o == "13", o)
vars.set("AN", "abc")
st, o = echo_of("echo $((AN+1))")
check("a value without a number counts as zero", o == "1", o)
vars.set("AN", "")
st, o = echo_of("echo $((AN+1))")
check("an empty value counts as zero", o == "1", o)
vars.unset("AN")
st, o = echo_of("echo $((AN+1))")
check("an unset name counts as zero", o == "1", o)
vars.set("AN", "-4")
st, o = echo_of("echo $((AN*2))")
check("a value may carry a sign", o == "-8", o)

params.set({ "42" })
st, o = echo_of("echo $(($1+1))")
check("a positional parameter works", o == "43", o)
params.set({})

vars.set("AB", "3")
st, o = echo_of("echo $((AB*AB))")
check("a name may be used twice", o == "9", o)
st, o = echo_of("echo a$((1+1))b")
check("an expansion sits inside a word", o == "a2b", o)
st, o = echo_of('echo "n=$((1+2))"')
check("an expansion inside double quotes", o == "n=3", o)
st, o = echo_of('echo "$((2+2)) x"')
check("a quoted result is not split", o == "4 x", o)
vars.set("AS", "1+2")
st, o = echo_of("echo $((AS))")
check("the value is a number, not an expression", o == "1", o)
st, o = echo_of("echo ${NOPE:-$((1+2))}")
check("an expansion may be the word of a colon form", o == "3", o)
st, o = echo_of("X=$((2+3)); echo $X")
check("an expansion may build an assignment", o == "5", o)
st, o = echo_of("false; echo $((1+1))")
check("the arithmetic runs whatever the last status was", o == "2", o)

-- ============================================================
section("usr/psh.lua - $(( )) arithmetic, the faults")
-- ============================================================
st, o = echo_of("echo $((1/0))")
check("a division by zero fails", st ~= 0, tostring(st))
check("the division by zero is explained",
      o:find("division by zero", 1, true) ~= nil, o)
st, o = echo_of("echo $((1%0))")
check("a modulo by zero fails", st ~= 0, tostring(st))
check("the modulo by zero is explained",
      o:find("division by zero", 1, true) ~= nil, o)
st, o = echo_of("echo $((1+))")
check("a broken expression fails", st ~= 0, tostring(st))
check("the broken expression is explained",
      o:find("syntax error", 1, true) ~= nil, o)
st, o = echo_of("echo $((1 @ 2))")
check("a stray character fails", st ~= 0, tostring(st))
st, o = echo_of("echo $((1+2))")
check("the shell recovered after the faults", o == "3", o)

-- ============================================================
section("usr/psh.lua - $(CMD) command substitution, the capture")
-- ============================================================
write("/tmp/f3c/cs1.txt", "x")
write("/tmp/f3c/cs2.txt", "x")

st, o = echo_of("echo $(echo hi)")
check("the reference is replaced by the output", o == "hi", o)
check("a substitution reports success", st == 0, tostring(st))
st, o = echo_of("echo $(seq 3)")
check("the output of the command is taken as it is", o == "1 2 3", o)
st, o = echo_of([[echo "$(seq 3)"]])
check("a middle newline of the output is kept", o == "1\n2\n3", o)
st, o = echo_of("echo $(echo a; echo b)")
check("a whole command list fits in the reference", o == "a b", o)
st, o = echo_of("echo $(true)")
check("an empty output is no field at all", o == "", o)
st, o = echo_of("echo $( )")
check("an empty reference is empty", o == "", o)
st, o = echo_of("echo pre$(echo mid)post")
check("a reference sits inside a word", o == "premidpost", o)
st, o = echo_of([[echo "x$(echo y)z"]])
check("a quoted reference sits inside a word", o == "xyz", o)
st, o = echo_of([[echo "$(seq 2; echo)"]])
check("every newline at the end of the output is dropped", o == "1\n2", o)
check("the dropped newlines leave no empty field",
      (o:find("\n", 1, true) ~= nil), o)

-- ============================================================
section("usr/psh.lua - $(CMD) command substitution, the fields")
-- ============================================================
st, o = echo_of("echo $(echo 'a  b')")
check("a plain result is split on the blanks", o == "a b", o)
st, o = echo_of([[echo "$(echo 'a  b')"]])
check("a quoted result is one field", o == "a  b", o)
st, o = run("for x in $(seq 2); do echo n:$x; done")
check("the split result feeds a for list", has("n:1") and has("n:2"), trim(o))
check("the split result is two fields", count_of(out(), "n:") == 2, trim(o))
st, o = run([[for x in "$(seq 2)"; do echo m:$x; done]])
check("a quoted result is one field of the list",
      count_of(out(), "m:") == 1, trim(o))
st, o = run("for x in $(true); do echo z:$x; done")
check("an empty result adds no field", count_of(out(), "z:") == 0, trim(o))

run("cd /tmp/f3c")
st, o = echo_of("echo $(echo 'cs?.txt')")
check("a plain result is globbed", has("cs1.txt") and has("cs2.txt"), o)
st, o = echo_of([[echo "$(echo 'cs?.txt')"]])
check("a quoted result is not globbed", o == "cs?.txt", o)
st, o = echo_of("echo x$(echo 'cs?.txt')")
check("a glued result is a pattern of its own word", o == "xcs?.txt", o)
st, o = echo_of("echo $(echo 'nope*')")
check("an unmatched pattern stays literal", o == "nope*", o)
run("cd /")

-- ============================================================
section("usr/psh.lua - $(CMD) command substitution, the nesting")
-- ============================================================
st, o = echo_of("echo $(echo $(echo a))")
check("a reference nests inside another", o == "a", o)
st, o = echo_of("echo a$(echo $(echo b))c")
check("a nested reference sits inside a word", o == "abc", o)
st, o = echo_of("echo $(echo $(echo $(echo deep)))")
check("the nesting goes deeper than two", o == "deep", o)
st, o = echo_of([[echo $(echo `echo a`)]])
check("the old form nests inside the new one", o == "a", o)
st, o = echo_of([[echo `echo $(echo a)`]])
check("the new form nests inside the old one", o == "a", o)
st, o = echo_of([[echo $(echo "a b")]])
check("a quoted string of the command is read as a whole", o == "a b", o)
st, o = echo_of([[echo "$(echo ")")"]])
check("a parenthesis inside double quotes does not close the reference",
      o == ")", o)
st, o = echo_of([[echo $(echo '(' )]])
check("a parenthesis inside single quotes does not close the reference",
      o == "(", o)
st, o = echo_of("echo $(echo hi) $(echo there)")
check("two references of one line both run", o == "hi there", o)
st, o = echo_of("echo $(echo 1)$(echo 2)$(echo 3)")
check("the references run from left to right", o == "123", o)

-- ============================================================
section("usr/psh.lua - the old `CMD` form")
-- ============================================================
st, o = echo_of([[echo `echo a`]])
check("the backquoted form is substituted", o == "a", o)
st, o = echo_of([[echo `seq 2`]])
check("the backquoted result is split", o == "1 2", o)
st, o = echo_of([[echo "`seq 2`"]])
check("a quoted backquoted result keeps its newline", o == "1\n2", o)
st, o = echo_of([[echo `echo \`echo a\``]])
check("an escaped backquote nests", o == "a", o)
vars.set("BX", "hi")
st, o = echo_of([[echo `echo \$BX`]])
check("the escaped dollar is handed to the inner command", o == "hi", o)
st, o = echo_of([[echo `echo \\$BX`]])
check("a doubled backslash keeps the dollar for the inner command",
      o == "$BX", o)
st, o = echo_of([[echo `echo '\n'`]])
check("a backslash before another character is an ordinary one",
      o == "\\n", o)

-- ============================================================
section("usr/psh.lua - the substitution runs in a sub shell")
-- ============================================================
vars.set("SI", "1")
st, o = run("echo $(SI=2); echo $SI")
check("a variable set inside is gone afterwards", out() == "\n1", trim(o))
st, o = echo_of("echo $(SI=2; echo $SI); echo $SI")
check("the new value is visible inside only", o == "2\n1", o)
st, o = echo_of("echo $(echo $(SI=9) $SI); echo $SI")
check("an inner reference sets nothing either", o == "1\n1", o)

run("cd /tmp/f3c")
st, o = echo_of("pwd; echo $(cd /tmp); pwd")
check("a cd inside does not move the shell",
      o == "/tmp/f3c\n\n/tmp/f3c", o)
st, o = echo_of("echo $(cd /tmp; pwd); pwd")
check("the cd works inside the reference",
      o == "/tmp\n/tmp/f3c", o)
run("cd /")

params.set({ "p1", "p2" })
st, o = echo_of("echo $(echo $1 $2)")
check("the parameters are inherited", o == "p1 p2", o)
st, o = echo_of("echo $(shift; echo $1); echo $1")
check("a shift inside does not move the shell parameters",
      o == "p2\np1", o)
params.set({})

-- ============================================================
section("usr/psh.lua - the status of a substitution")
-- ============================================================
st, o = echo_of("$(false); echo $?")
check("a lone reference takes the status of its command", o == "1", o)
st, o = echo_of("x=$(false); echo $?")
check("an assignment takes the status of its command", o == "1", o)
st, o = echo_of("$(true); echo $?")
check("a successful reference sets zero", o == "0", o)
st, o = run("echo $(false); echo $?")
check("a reference inside a word leaves the status to the command",
      out() == "\n0", trim(o))
st, o = echo_of("echo $(exit 4)")
check("an exit inside ends the reference only", o == "", o)
st, o = echo_of("x=$(exit 4); echo $?")
check("the exit status of the reference is kept", o == "4", o)
st, o = echo_of("false; echo $? $(false) $?")
check("both statuses of the line are read before the reference runs",
      o == "1 1", o)
st, o = echo_of("false; echo $(echo $?)")
check("the reference reads the status of the shell", o == "1", o)

-- ============================================================
section("usr/psh.lua - the faults of a substitution")
-- ============================================================
st, o = run("echo $(nosuchcmd)")
check("a failing command does not fail the echo", st == 0, tostring(st))
check("the fault of a command is a diagnostic",
      has("command not found"), trim(o))
st, o = run([[x=$(nosuchcmd); echo "x=[$x]"]])
check("what the command writes on the error output is not its value",
      has("x=[]"), trim(o))
st, o = run("x=$(nosuchcmd); echo $?")
check("the fault of the command is seen in the status",
      trim(o):match("([^\n]*)$") == "127", trim(o))
st, o = echo_of("echo $((1+2)) $(echo ok)")
check("the arithmetic and the substitution work together", o == "3 ok", o)
st, o = echo_of("echo ${NOPE:-$(echo hi)}")
check("a reference may be the word of a colon form", o == "hi", o)
st, o = echo_of("echo $(echo hi) $(seq 2)")
check("no reference is left behind", o == "hi 1 2", o)
st, o = echo_of("echo $(echo hi")
check("an unclosed reference ends at the end of the line", o == "hi", o)

-- ============================================================
section("usr/psh.lua - the substitution and the redirections")
-- ============================================================
st, o = echo_of([[echo hi > "$(echo /tmp/f3c/out1.txt)"; cat /tmp/f3c/out1.txt]])
check("a reference may name the target file", o == "hi", o)
st, o = echo_of("echo $(echo hi > /tmp/f3c/out2.txt; cat /tmp/f3c/out2.txt)")
check("a redirection inside the reference is not captured", o == "hi", o)
st, o = echo_of("echo $(echo bg) &")
check("a reference of a background command is written as typed",
      has("$(echo bg)"), trim(o))
check("the reference of a background command is not run yet",
      count_of(out(), "bg") == 1, trim(o))

-- ============================================================
section("usr/psh.lua - the here document, <<WORD")
-- ============================================================
st, o = run("cat <<EOF\nhi\nEOF")
check("a here document is a successful command", st == 0, tostring(st))
check("the body of the document is the input of the command", trim(o) == "hi",
      trim(o))
st, o = echo_of("cat <<EOF\nhello\nworld\nEOF")
check("the body may hold several lines", o == "hello\nworld", o)
st, o = echo_of("cat <<EOF\nEOF")
check("the body may be empty", o == "", o)
st, o = echo_of("wc -c <<EOF\nhi\nEOF")
check("the body keeps the newline in front of the delimiter", o == "3", o)
st, o = echo_of("wc -l <<EOF\na\nb\nc\nEOF")
check("every line of the body is a line of the input", o == "3", o)
st, o = echo_of("wc -l <<EOF\na\n\nb\nEOF")
check("a blank line of the body stays in the input", o == "3", o)
st, o = echo_of("wc -c <<EOF\n  spaced  text  \nEOF")
check("the blanks of the body are kept as they were typed", o == "17", o)
st, o = echo_of("cat <<EOF\nnot a EOF here\nEOF")
check("a word around the delimiter does not end the body",
      o == "not a EOF here", o)
st, o = echo_of("cat <<EOF\nEOF not alone\nEOF")
check("the delimiter must be the only text of its line",
      o == "EOF not alone", o)
st, o = echo_of("cat <<EOF\nthe end")
check("a body without its delimiter ends at the end of the text",
      o == "the end", o)
st, o = echo_of("cat <<EOF; echo after\nbody\nEOF")
check("a command may follow the document on the same line",
      o == "body\nafter", o)
st, o = echo_of("cat <<EOF && echo ok\nbody\nEOF")
check("a document works in a list", o == "body\nok", o)
st, o = echo_of("cat <<EOF\nbody\nEOF\necho $?")
check("the command behind the body sees the status of the document",
      o == "body\n0", o)
st, o = echo_of("cat <<EOF\nnosuchcmd_xyz -a\nEOF")
check("the body is text and not a command line", o == "nosuchcmd_xyz -a", o)
check("no line of the body is run", not has("command not found"), trim(out()))

-- ============================================================
section("usr/psh.lua - the body of a bare here document expands")
-- ============================================================
st, o = echo_of("HN=world; cat <<EOF\nhi $HN\nEOF")
check("a name of the body is expanded", o == "hi world", o)
st, o = echo_of("HN=world; cat <<EOF\nhi \"$HN\"\nEOF")
check("a quote of the body is an ordinary character", o == "hi \"world\"", o)
st, o = echo_of("cat <<EOF\n$((1+2)) and $(echo sub)\nEOF")
check("the arithmetic and the substitution work in the body",
      o == "3 and sub", o)
st, o = echo_of("cat <<EOF\n[$NOPE_HD]\nEOF")
check("an unset name of the body is empty", o == "[]", o)
st, o = echo_of("cat <<EOF\n$(echo 'a  b')\nEOF")
check("the body is not split into fields", o == "a  b", o)
st, o = echo_of("cat <<EOF\n*\nEOF")
check("no pattern is tried on the body", o == "*", o)
st, o = echo_of("cat <<EOF\n$((1+2)) */x\nEOF")
check("a live body expands and adds nothing else", o == "3 */x", o)
st, o = echo_of("x=$(cat <<EOF\nhi\nEOF\n); echo $x")
check("a document fits inside a command substitution", o == "hi", o)
st, o = echo_of("if true; then cat <<EOF\nin the branch\nEOF\nfi")
check("a document fits inside a branch", o == "in the branch", o)
st, o = echo_of("for i in 1 2; do cat <<EOF\n$i\nEOF\ndone")
check("a document fits inside a loop", o == "1\n2", o)
st, o = echo_of("HN=world; cat <<'EOF'\nhi $HN\nEOF")
check("a single quoted delimiter keeps the body as it was typed",
      o == "hi $HN", o)
st, o = echo_of("HN=world; cat <<\"EOF\"\nhi $HN\nEOF")
check("a double quoted delimiter does the same", o == "hi $HN", o)
st, o = echo_of("cat <<'EOF'\n$((1+2)) $(echo x)\nEOF")
check("a quoted delimiter turns the references off",
      o == "$((1+2)) $(echo x)", o)
st, o = echo_of("HN=world; cat <<EOF\nhi \\$HN\nEOF")
check("a backslash keeps a name of the body as text", o == "hi $HN", o)
st, o = echo_of("HN=world; cat <<'EOF'\nhi \\$HN\nEOF")
check("a quoted delimiter keeps the backslash too", o == "hi \\$HN", o)
st, o = echo_of("cat <<EOF\na\\\\b\nEOF")
check("a doubled backslash of the body is one backslash", o == "a\\b", o)
st, o = echo_of("cat <<EOF\n\\d+ pattern\nEOF")
check("a backslash before another character stays", o == "\\d+ pattern", o)
st, o = echo_of("cat <<EOF\none\\\ntwo\nEOF")
check("a backslash at the end of a line joins the next line",
      o == "onetwo", o)
st, o = echo_of("cat <<EOF\n$(echo \\$HN)\nEOF")
check("a quoted name inside a substitution stays text", o == "$HN", o)

-- ============================================================
section("usr/psh.lua - <<-WORD drops the tabs of the body")
-- ============================================================
st, o = echo_of("cat <<-EOF\n\thello\n\tEOF")
check("a tab in front of a body line is dropped", o == "hello", o)
st, o = echo_of("wc -c <<-EOF\n\thi\n\tEOF")
check("the body of <<- carries no tab of its own", o == "3", o)
st, o = echo_of("cat <<-EOF\n\t\thello\n\tEOF")
check("every tab in front of a line is dropped", o == "hello", o)
st, o = echo_of("wc -c <<-EOF\n\ta\tb\n\tEOF")
check("a tab inside a line is kept", o == "4", o)
st, o = echo_of("wc -c <<-EOF\n\ta  \n\tEOF")
check("the blanks of a <<- line are kept", o == "4", o)
st, o = echo_of("cat <<-EOF\n\t$((1+2))\n\tEOF")
check("the body of <<- is expanded like any other", o == "3", o)
st, o = echo_of("cat <<-'EOF'\n\t$((1+2))\n\tEOF")
check("a quoted delimiter of <<- turns the expansion off",
      o == "$((1+2))", o)
st, o = echo_of("cat <<-EOF\n\thello\n    EOF")
check("spaces do not end the body of <<-", has("    EOF"), trim(o))
st, o = echo_of("wc -l <<-EOF\n\tline one\n\tline two\n\tEOF")
check("the stripped body has the right number of lines", o == "2", o)

-- ============================================================
section("usr/psh.lua - the body is the standard input")
-- ============================================================
st, o = echo_of("grep b <<EOF\na\nb\nc\nEOF")
check("grep reads the body", o == "b", o)
st, o = echo_of("sort <<EOF\nc\na\nb\nEOF")
check("sort reads the body", o == "a\nb\nc", o)
st, o = echo_of("tr a-z A-Z <<EOF\nabc\nEOF")
check("tr reads the body", o == "ABC", o)
st, o = echo_of("head -1 <<EOF\na\nb\nEOF")
check("head reads the body", o == "a", o)
st, o = echo_of("wc -l <<EOF | cat\nx\ny\nEOF")
check("the body feeds a pipeline", o == "2", o)
st, o = echo_of("cat <<EOF | tr a-z A-Z\nabc\nEOF")
check("the body may pass through two commands", o == "ABC", o)
st, o = echo_of("cat <<EOF > /tmp/f4/out.txt\nwritten\nEOF\nwc -l /tmp/f4/out.txt")
check("the output of the command may go to a file", o == "1 /tmp/f4/out.txt", o)
st, o = echo_of("cat /tmp/f4/out.txt")
check("the file holds what the command wrote", o == "written", o)
st, o = echo_of("cat <<EOF >> /tmp/f4/out.txt\nsecond\nEOF\ncat /tmp/f4/out.txt")
check("the document works with an append too", o == "written\nsecond", o)

-- ============================================================
section("usr/psh.lua - the here document and the < redirection")
-- ============================================================
write("/tmp/f4/in.txt", "file line\n")
st, o = echo_of("cat <<EOF < /tmp/f4/in.txt\nbody\nEOF")
check("a later < takes the standard input over", o == "file line", o)
st, o = echo_of("cat < /tmp/f4/in.txt <<EOF\nbody\nEOF")
check("a later here document takes it back", o == "body", o)
st, o = echo_of("cat <<EOF <<SECOND\nfirst\nEOF\nsecond\nSECOND")
check("the last of two documents is the input", o == "second", o)
st, o = echo_of("cat <<-EOF <<-SECOND\n\tfirst\n\tEOF\n\tsecond\n\tSECOND")
check("the two documents may both strip the tabs", o == "second", o)
st, o = run("cat <<-EOF <<SECOND\n\tfirst\n\tEOF\n\tsecond\n\tSECOND")
check("a plain document next to a <<- one keeps its tabs",
      o == "\tsecond\n\tSECOND", o)
st, o = echo_of("cat <<EOF < /tmp/f4/missing.txt\nbody\nEOF")
check("a later < is the input even when the file is not there", o == "", o)
st, o = echo_of("grep body <<EOF < /tmp/f4/in.txt\nbody\nEOF\necho done")
check("the file replaces the body of the document", o == "done", o)

-- ============================================================
section("usr/psh.lua - the faults of a here document")
-- ============================================================
st, o = run("cat <<\nbody\nEOF")
check("a << without a word is a fault", has("syntax error"), trim(o))
st, o = run("cat <<- \nbody\nEOF")
check("a <<- without a word is a fault too", has("syntax error"), trim(o))
st, o = run("cat << EOF\nhi\nEOF")
check("a blank between the sign and the word is allowed", st == 0,
      tostring(st))
check("the body of that form still reaches the command",
      trim(out()) == "hi", trim(out()))
st, o = run("cat<<EOF\nhi\nEOF")
check("the sign and the word may touch the command", trim(out()) == "hi",
      trim(out()))

-- ============================================================
section("lib/man.lua - the here document page")
-- ============================================================
check("the page is listed", man.exists("heredoc"))
check("the page holds a description",
      type(man.pages.heredoc.what) == "string",
      tostring(type(man.pages.heredoc.what)))
check("the page lists the two signs", #man.pages.heredoc.syn == 4,
      tostring(#man.pages.heredoc.syn))
local htext = table.concat(man.render("heredoc"), "\n")
check("the rendered page names the here document",
      htext:find("here document", 1, true) ~= nil)
check("the rendered page shows its own name",
      htext:find("heredoc - ", 1, true) ~= nil)
check("a search by name finds the page", man.search("heredoc")[1] ~= nil)
local hfound = false
for _, hit in ipairs(man.search("standard input")) do
    if hit.name == "heredoc" then hfound = true end
end
check("a search by description finds the page", hfound)
check("the expansion page points at it",
      (man.pages.expansion.see or ""):find("heredoc", 1, true) ~= nil)

-- ============================================================
section("usr/psh.lua - the trap built-in, the words of the line")
-- ============================================================
run("trap -")
st, o = run("trap 'echo TRAPEXIT' INT")
check("trap ACTION SIGNAL installs a trap", st == 0, tostring(st))
check("the line of the install writes nothing", trim(o) == "", trim(o))
st, o = run("trap -p INT")
check("trap -p writes the trap as one word that may be run again",
      trim(o) == "trap -- 'echo TRAPEXIT' INT", trim(o))
st, o = run("trap")
check("trap with no word writes the same listing",
      trim(o) == "trap -- 'echo TRAPEXIT' INT", trim(o))
st, o = run("trap -p")
check("trap -p with no name writes every trap that is set",
      trim(o) == "trap -- 'echo TRAPEXIT' INT", trim(o))

run("trap -")
run("trap 'echo n' int")
run("trap 'echo n' SIGINT")
run("trap 'echo n' 2")
st, o = run("trap")
check("INT, int, SIGINT and 2 all name the same signal",
      trim(o) == "trap -- 'echo n' INT", trim(o))

run("trap -")
run("trap 'echo t' INT TERM")
st, o = run("trap -p INT TERM")
check("one action may be set for several signals",
      trim(o) == "trap -- 'echo t' INT\ntrap -- 'echo t' TERM", trim(o))
st, o = run("trap -p TERM INT")
check("the listing follows the words of the line",
      trim(o) == "trap -- 'echo t' TERM\ntrap -- 'echo t' INT", trim(o))

run("trap -")
run("trap 'x' HUP INT QUIT TERM EXIT ERR")
st, o = run("trap")
check("the listing walks the signals in their own order",
      trim(o) == "trap -- 'x' HUP\ntrap -- 'x' INT\ntrap -- 'x' QUIT\n" ..
                 "trap -- 'x' TERM\ntrap -- 'x' EXIT\ntrap -- 'x' ERR",
      trim(o))
st, o = run("trap -p KILL")
check("a signal with no trap writes no line, and it is not a fault",
      st == 0 and trim(o) == "", tostring(st) .. " " .. trim(o))

run("trap -")
run("trap 'echo $X' INT")
st, o = run("trap -p INT")
check("the text is kept as it was typed, it is read when it runs",
      trim(o) == "trap -- 'echo $X' INT", trim(o))
run("trap 'echo one; echo two' INT")
st, o = run("trap -p INT")
check("an action may hold a whole command list",
      trim(o) == "trap -- 'echo one; echo two' INT", trim(o))

run("trap -")
run("trap '' INT")
st, o = run("trap -p INT")
check("an empty action is the ignored signal, written as ''",
      trim(o) == "trap -- '' INT", trim(o))
st, o = run("trap - INT")
check("trap - puts the disposition of the signal back", st == 0, tostring(st))
st, o = run("trap -p INT")
check("the entry of the reset signal is gone", trim(o) == "", trim(o))
run("trap 'a' INT TERM HUP")
run("trap -")
st, o = run("trap")
check("trap - with no signal name resets every trap", trim(o) == "", trim(o))

run("trap -")
run([[trap "echo 'hi there'" INT]])
st, o = run("trap -p INT")
local listed = trim(o)
check("the text of the listing is quoted as one word",
      listed == [[trap -- 'echo '\''hi there'\''' INT]], listed)
run("trap -")
st, o = run(listed)
check("the line the listing wrote runs again", st == 0, tostring(st))
st, o = run("trap -p INT")
check("and it sets the same trap again", trim(o) == listed, trim(o))

run("trap -")
run("trap -- 'echo hi' INT")
st, o = run("trap -p INT")
check("-- ends the options in front of the action",
      trim(o) == "trap -- 'echo hi' INT", trim(o))
run("trap -")
run("trap -- '-p' INT")
st, o = run("trap -p INT")
check("an action that begins with a dash is still the action",
      trim(o) == "trap -- '-p' INT", trim(o))

run("trap -")
st, o = run("trap 'x' NOSUCH")
check("a signal the shell does not know is a fault",
      st == 1 and has("invalid signal specification"),
      tostring(st) .. " " .. trim(o))
st, o = run("trap -p NOSUCH")
check("the listing refuses it too",
      st == 1 and has("invalid signal specification"), tostring(st))
st, o = run("trap 'x' 999")
check("a number that names no signal is a fault as well",
      st == 1 and has("invalid signal specification"), tostring(st))
st, o = run("trap INT")
check("a signal with no action is a usage fault",
      st == 1 and has("usage"), tostring(st) .. " " .. trim(o))
st, o = run("trap -p INT NOSUCH")
check("a name that fails the listing leaves it unwritten",
      st == 1 and not has("trap --"), trim(o))
run("trap 'x' INT NOSUCH")
st, o = run("trap -p INT")
check("no trap is changed by a line that failed", trim(o) == "", trim(o))

st, o = run("trap 'x' KILL")
check("KILL is known but may never be caught",
      st == 1 and has("cannot be caught"), tostring(st) .. " " .. trim(o))
st, o = run("trap '' KILL")
check("KILL may never be ignored", st == 1 and has("cannot be caught"),
      tostring(st))
st, o = run("trap - KILL")
check("KILL may never be reset", st == 1 and has("cannot be caught"),
      tostring(st))
st, o = run("trap -p KILL")
check("KILL holds no trap, the listing says nothing", trim(o) == "", trim(o))

-- ============================================================
section("usr/psh.lua - the trap of EXIT")
-- ============================================================
-- These lines simulate an interactive SESSION leaving, so they say so. The
-- distinction is not cosmetic: "exit 3" in a one-shot run ("psh -c 'exit 3'") or
-- at the end of a script is how a STATUS is returned, and only a session is
-- subject to "the shell may not be left" (set -o noexit). The flag defaults to
-- false, which is the one-shot reading.
--
-- The noexit rule is turned OFF for this section and back on at its end: what is
-- under test here is the trap of EXIT, and the rule would otherwise stop the
-- session from leaving at all. The rule itself is tested in its own section.
psh.set_interactive(true)
run("set +o noexit")
run("trap -")
clear()
local alive = psh.feed("trap 'echo TRAPBYE' EXIT; exit 3")
check("the trap of EXIT runs when the session leaves",
      alive == false and has("TRAPBYE"), tostring(alive) .. " " .. trim(out()))
check("the status of the shell is the one of the exit",
      tonumber(vars.get("?")) == 3, tostring(vars.get("?")))
st, o = run("trap")
check("the trap of EXIT runs once, it is gone after that",
      trim(o) == "", trim(o))
run("trap -")
clear()
alive = psh.feed("trap 'exit 7' EXIT; exit 3")
check("a trap of EXIT may change the code of the exit",
      alive == false and tonumber(vars.get("?")) == 7,
      tostring(vars.get("?")))
run("trap -")
psh.set_interactive(false)
run("set -o noexit")

write("/tmp/f5/leave.sh", "trap 'echo TRAPBYE' EXIT\necho SCRIPT-BODY\n")
st, o = run("/tmp/f5/leave.sh")
check("a command script runs the trap of EXIT of its own shell",
      st == 0 and has("SCRIPT-BODY") and has("TRAPBYE"),
      tostring(st) .. " " .. trim(o))
local body_at = out():find("SCRIPT-BODY", 1, true)
local trap_at = out():find("TRAPBYE", 1, true)
check("the trap of the script runs behind its last command",
      body_at ~= nil and trap_at ~= nil and body_at < trap_at, out())
write("/tmp/f5/code.sh", "trap 'exit 9' EXIT\nexit 3\n")
st, o = run("/tmp/f5/code.sh")
check("the trap of EXIT of a script may change its code",
      st == 9 and trim(o) == "", tostring(st) .. " " .. trim(o))

run("trap -")
run("trap 'echo MINE' EXIT")
run("trap 'echo SIGONE' INT")
st, o = run("/tmp/f5/leave.sh")
check("a script does not touch the traps of the shell",
      trim(o) == "SCRIPT-BODY\nTRAPBYE", trim(o))
st, o = run("trap -p EXIT")
check("the trap of EXIT of the shell is still there",
      trim(o) == "trap -- 'echo MINE' EXIT", trim(o))
st, o = run("trap -p INT")
check("and so is the other trap",
      trim(o) == "trap -- 'echo SIGONE' INT", trim(o))
run("trap -")

-- ============================================================
section("usr/psh.lua - the trap of INT")
-- ============================================================
write("/tmp/f5/wait.lua",
      "os.queueEvent(\"terminate\")\nos.pullEvent(\"go\")\n")
run("trap -")
st, o = run("/tmp/f5/wait.lua")
check("a command that is stopped with no trap ends with 130",
      st == 130 and trim(o) == "", tostring(st) .. " " .. trim(o))
st, o = run("trap 'echo TRAPINT' INT; /tmp/f5/wait.lua")
check("the trap of INT runs when the command is stopped",
      st == 130 and has("TRAPINT"), tostring(st) .. " " .. trim(o))
st, o = run("trap 'echo got $X' INT; X=now; /tmp/f5/wait.lua")
check("the text is expanded when it runs, not when it is set",
      has("got now"), trim(o))
st, o = run("trap '' INT; /tmp/f5/wait.lua")
check("an ignored INT runs nothing",
      st == 130 and trim(o) == "", tostring(st) .. " " .. trim(o))
run("trap -")

write("/tmp/f5/stop.sh", "trap 'echo CHILD-INT' INT\n/tmp/f5/wait.lua\n")
run("trap -")
run("trap 'echo PARENT-INT' INT")
st, o = run("/tmp/f5/stop.sh")
check("a command script carries the trap of INT of its own shell",
      st == 130 and has("CHILD-INT"), tostring(st) .. " " .. trim(o))
check("the trap of the shell that started it does not run",
      not has("PARENT-INT"), trim(o))
st, o = run("trap -p INT")
check("the trap of the shell is back after the script",
      trim(o) == "trap -- 'echo PARENT-INT' INT", trim(o))
run("trap -")

-- ============================================================
section("usr/psh.lua - the trap of ERR")
-- ============================================================
run("trap -")
st, o = run("trap 'echo TRAPERR' ERR; false")
check("the trap of ERR runs for a command that fails",
      st == 1 and has("TRAPERR"), tostring(st) .. " " .. trim(o))
st, o = run("echo $?")
check("the status of the failing command stands",
      st == 0 and trim(o) == "1", trim(o))
st, o = run("trap 'echo TRAPERR' ERR; cd /no-such-dir")
check("a built-in that fails runs the trap too", has("TRAPERR"), trim(o))
st, o = run("trap 'echo TRAPERR' ERR; f() { return 4; }; f")
check("a function that fails runs the trap",
      st == 4 and has("TRAPERR"), tostring(st))
write("/tmp/f5/bad.lua", "return 3\n")
st, o = run("trap 'echo TRAPERR' ERR; /tmp/f5/bad.lua")
check("a command script that fails runs the trap",
      st == 3 and has("TRAPERR"), tostring(st))
st, o = run("trap 'echo TRAPERR' ERR; nosuchcmd_f5")
check("a word that is no command is the fault of the shell, no trap runs",
      st == 127 and not has("TRAPERR"), tostring(st) .. " " .. trim(o))
st, o = run("trap 'echo TRAPONCE' ERR; nosuchcmd_f5; false")
check("a trap that fails itself is not entered a second time",
      st == 1 and count_of(o, "TRAPONCE") == 1, o)
run("trap - ERR")
st, o = run("trap -p ERR")
check("the reset of ERR leaves nothing", trim(o) == "", trim(o))
st, o = run("false")
check("with the trap reset a failing command writes nothing",
      st == 1 and trim(o) == "", tostring(st) .. " " .. trim(o))
check("the status that the trap did not change is passed on",
      tonumber(vars.get("?")) == 1, tostring(vars.get("?")))
run("trap -")

-- ============================================================
section("lib/man.lua - the trap page")
-- ============================================================
check("the page is listed", man.exists("trap"))
check("the page holds a description", type(man.pages.trap.what) == "string",
      tostring(type(man.pages.trap.what)))
check("the page lists the forms of the line", #man.pages.trap.syn == 6,
      tostring(#man.pages.trap.syn))
local tpage = man.pages.trap
local tsyn = table.concat(tpage.syn or {}, " ")
local tnote = table.concat(tpage.note or {}, " ")
check("the synopsis shows the install form",
      tsyn:find("trap ACTION SIGNAL", 1, true) ~= nil)
check("the synopsis shows the listing form",
      tsyn:find("trap -p [SIGNAL ...]", 1, true) ~= nil)
check("the synopsis shows the ignored signal",
      tsyn:find("trap '' SIGNAL", 1, true) ~= nil)
check("the synopsis shows the reset form",
      tsyn:find("trap - SIGNAL", 1, true) ~= nil)
check("the synopsis shows the word that ends the options",
      tsyn:find("trap -- ACTION SIGNAL", 1, true) ~= nil)
check("the text names the signal that may never be caught",
      tnote:find("KILL", 1, true) ~= nil)
check("the text explains the trap of ERR",
      tnote:find("trap of ERR", 1, true) ~= nil)
check("the text names the one interrupt of CraftOS",
      tnote:find("Ctrl+T", 1, true) ~= nil)
check("the text tells that a word that is no command runs no trap",
      tnote:find("does not run the trap", 1, true) ~= nil)
check("the text tells that the line of the listing may be run again",
      tnote:find("run again", 1, true) ~= nil)
check("the text explains the word that ends the options",
      tnote:find("ends the options", 1, true) ~= nil)
local ttext = table.concat(man.render("trap"), "\n")
check("the rendered page shows its own name",
      ttext:find("trap - ", 1, true) ~= nil)
local thit = false
for _, hit in ipairs(man.search("trap")) do
    if hit.name == "trap" then thit = true end
end
check("a search by name finds the page", thit)
local tfound = false
for _, hit in ipairs(man.search("stopped")) do
    if hit.name == "trap" then tfound = true end
end
check("a search by description finds the page", tfound)

-- ============================================================
section("usr/psh.lua - the words of set")
-- ============================================================
local function options_off()
    -- The two machine rules are reset with the POSIX options: they persist in
    -- /etc/boot.conf, so a test that turned one off would leak into every later
    -- section (and into the next suite, since the file survives the state).
    run("set +e; set +u; set +x; set +o pipefail")
    run("set -o bootguard; set -o noexit")
end

options_off()
st, o = run("set -e\necho \"[$-]\"")
check("one letter turns an option on", st == 0 and trim(o) == "[e]", trim(o))
st, o = run("set -e; set +e\necho \"[$-]\"")
check("the plus sign turns it off again", trim(o) == "[]", trim(o))
st, o = run("set -eux\necho \"[$-]\"\nset +x")
check("the letters may be written together", has("[eux]"), trim(o))
st, o = run("set -e; set -u\necho \"[$-]\"")
check("two options are named in the order e, u, x",
      trim(o) == "[eu]", trim(o))
options_off()
st, o = run("set -o errexit\necho \"[$-]\"")
check("the long name names the same option", trim(o) == "[e]", trim(o))
options_off()
st, o = run("set -o pipefail\necho \"[$-]\"")
check("pipefail has no letter of its own", trim(o) == "[]", trim(o))
options_off()
st, o = run("set -e; set +o errexit\necho \"[$-]\"")
check("the long name takes the plus sign too", trim(o) == "[]", trim(o))
st, o = run("set -e; set +u\necho \"[$-]\"")
check("one option does not touch the other", trim(o) == "[e]", trim(o))
st, o = run("set -e F6V=one\necho \"[$F6V][$-]\"")
check("an option and an assignment share the line",
      st == 0 and has("[one][e]"), trim(o))
st, o = run("set +e F6W=two\necho \"[$F6W][$-]\"")
check("so do a plus option and an assignment",
      st == 0 and has("[two][]"), trim(o))
st, o = run("set F6A=1 F6B=2\necho \"[$F6A][$F6B]\"")
check("two assignments share a line", has("[1][2]"), trim(o))
st, o = run("set F6A")
check("set NAME writes the one variable",
      st == 0 and trim(o) == "F6A=1", trim(o))
st, o = run("set F6NOTSET")
check("set NAME writes nothing when the name is not set",
      st == 0 and trim(o) == "", trim(o))
st, o = run("set F6A=1\nset -- F6A")
check("a name behind the end of the options is read as a name",
      st == 0 and trim(o) == "F6A=1", trim(o))
st, o = run("set -e; set --\necho \"[$-]\"")
check("the word that ends the options keeps them",
      trim(o) == "[e]", trim(o))
st, o = run("set -z")
check("a letter that is no option is reported",
      st == 1 and has("invalid option"), trim(o))
st, o = run("set -o nosuchoption")
check("a name that is no option is reported",
      st == 1 and has("invalid option name"), trim(o))
st, o = run("set -ez\nfalse\necho never")
check("the letters that are good still count",
      st == 1 and not has("never"), tostring(st) .. " " .. trim(o))
options_off()
st, o = run("set")
check("set with no word writes the variables", st == 0 and has("F6A=1"), trim(o))
check("it writes one line for each of them",
      count_of(o, "\n") >= 5, tostring(count_of(o, "\n")))

-- ============================================================
section("usr/psh.lua - the listings of set -o and set +o")
-- ============================================================
options_off()
st, o = run("set -o")
check("set -o writes one line for each option", st == 0 and trim(o) ==
      "errexit  off\nnounset  off\npipefail off\nxtrace   off\n" ..
      "bootguard on\nnoexit   on", trim(o))
st, o = run("set +o")
check("set +o writes the commands that put them back", st == 0 and trim(o) ==
      "set +o errexit\nset +o nounset\nset +o pipefail\nset +o xtrace\n" ..
      "set -o bootguard\nset -o noexit", trim(o))
st, o = run("set -e\nset -o")
check("the listing follows the state of the options",
      st == 0 and has("errexit  on"), trim(o))
st, o = run("set -e\nset +o")
check("the command of an option that is on takes the minus sign",
      has("set -o errexit"), trim(o))
st, o = run("set -o pipefail\nset -o")
check("the listing names pipefail where a letter would stand",
      has("pipefail on"), trim(o))
local listing = ""
st, listing = run("set -eux\nset +o")
-- The trace of the command itself shares the console with what the shell
-- writes on it, so the line of xtrace is dropped before the listing is run
-- again: it is not one of the lines of the option.
local commands = {}
for line in listing:gmatch("[^\r\n]+") do
    if line:sub(1, 2) ~= "+ " then commands[#commands + 1] = line end
end
listing = table.concat(commands, "\n")
check("the listing holds no line of the trace",
      not listing:find("^%+ "), listing)
st, o = run(listing)
check("the lines of set +o are commands that may be run again",
      st == 0, tostring(st))
st, o = run("echo \"[$-]\"")
check("and they put the options back the way they were", has("[eux]"), trim(o))
options_off()

-- ============================================================
section("usr/psh.lua - set -e, the errexit option")
-- ============================================================
st, o = run("set -e\nfalse")
check("a command that fails ends the shell", st == 1, tostring(st))
check("the status is the one of the command",
      tonumber(vars.get("?")) == 1, tostring(vars.get("?")))
st, o = run("set -e\nfalse\necho never")
check("the words behind the failing command do not run",
      st == 1 and not has("never"), tostring(st) .. " " .. trim(o))
st, o = run("set -e\ntrue\necho after")
check("a command that works lets the shell go on",
      st == 0 and has("after"), trim(o))
st, o = run("set -e\ncd /no-such-dir\necho never")
check("a built-in that fails ends the shell as well",
      st == 1 and not has("never"), tostring(st) .. " " .. trim(o))
st, o = run("set -e\nnosuchcmd_f6\necho never")
check("a word that is no command ends the shell too",
      st == 127 and not has("never"), tostring(st) .. " " .. trim(o))
st, o = run("set -e\nfalse || echo recovered")
check("the left side of || is only read",
      st == 0 and has("recovered"), tostring(st) .. " " .. trim(o))
st, o = run("set -e\nfalse && echo no\necho tail")
check("the left side of && is only read",
      st == 0 and has("tail"), tostring(st) .. " " .. trim(o))
st, o = run("set -e\n! false\necho after")
check("a command that ! negates is only read",
      st == 0 and has("after"), tostring(st) .. " " .. trim(o))
st, o = run("set -e\nif false; then echo no; fi\necho after")
check("the condition of if is only read",
      st == 0 and has("after"), tostring(st) .. " " .. trim(o))
st, o = run("set -e\nwhile false; do echo no; done\necho after")
check("the condition of while is only read",
      st == 0 and has("after"), tostring(st) .. " " .. trim(o))
st, o = run("set -e\nfalse | true\necho after")
check("without pipefail a pipeline reports its last stage",
      st == 0 and has("after"), tostring(st) .. " " .. trim(o))
st, o = run("set -e\ntrue | false\necho never")
check("a pipeline whose last stage fails ends the shell",
      st == 1 and not has("never"), tostring(st) .. " " .. trim(o))
st, o = run("set -e\nf6fail() { false; }\nf6fail\necho never")
check("a function that fails ends the shell",
      st == 1 and not has("never"), tostring(st) .. " " .. trim(o))
st, o = run("set -e\nf6odd() { false; echo inside; }\n" ..
            "if f6odd; then echo yes; else echo no; fi\necho after")
check("a function whose name is read goes past its fault",
      st == 0 and has("inside") and has("yes") and has("after"),
      tostring(st) .. " " .. trim(o))
st, o = run("set -e\n{ false; }\necho never")
check("a brace group is this shell, so its fault counts",
      st == 1 and not has("never"), tostring(st) .. " " .. trim(o))
st, o = run("set -e\nset +e\nfalse\necho after")
check("the plus sign takes the rule off again",
      st == 0 and has("after"), tostring(st) .. " " .. trim(o))
options_off()

-- ============================================================
section("usr/psh.lua - set -u, the nounset option")
-- ============================================================
st, o = run("set -u\necho ${F6NOPE}")
check("a name that is not set is a fault", st == 1 and has("F6NOPE"), trim(o))
check("the fault says what it is", has("unbound variable"), trim(o))
st, o = run("set -u\necho $F6NOPE")
check("a plain reference is a fault too",
      st == 1 and has("unbound"), trim(o))
st, o = run("set -u\necho ${F6NOPE}\necho \"[$?]\"")
check("the fault stops the one command and no more",
      st == 0 and has("[1]"), tostring(st) .. " " .. trim(o))
st, o = run("set -u\necho ${F6NOPE}\necho never")
check("the words behind the fault do stand",
      st == 0 and has("never"), trim(o))
st, o = run("set -eu\necho ${F6NOPE}\necho never")
check("with errexit too the shell does end",
      st == 1 and not has("never"), tostring(st) .. " " .. trim(o))
st, o = run("set -u\nF6OK=ok\necho \"[$F6OK]\"")
check("a name that is set is read as before",
      st == 0 and has("[ok]"), trim(o))
st, o = run("set -u\nset +u\necho \"[${F6NOPE}]\"")
check("the plus sign turns the fault off",
      st == 0 and trim(o) == "[]", trim(o))
st, o = run("set -u\necho \"[${F6NOPE:-fallback}]\"")
check("a word that the reference carries is not a fault",
      st == 0 and has("[fallback]"), trim(o))
options_off()
st, o = run("set -u\necho \"[$-][$?]\"")
check("the names of the shell are never a fault",
      st == 0 and has("[u][0]"), trim(o))
options_off()
st, o = run("set +u\nf6noun() { set -u; echo ${F6NOPE}; }\nf6noun\necho after")
check("a fault inside a function does not leave the shell",
      st == 0 and has("after"), tostring(st) .. " " .. trim(o))
options_off()

-- ============================================================
section("usr/psh.lua - set -x, the xtrace option")
-- ============================================================
st, o = run("set -x\ntrue\nset +x")
check("a command is written before it runs", st == 0 and has("+ true"), trim(o))
check("the command that stops it is written as well",
      has("+ set +x"), trim(o))
st, o = run("set -x\nfalse | true\nset +x")
check("the stages of a pipeline are written as one line",
      has("+ false | true"), trim(o))
st, o = run("set -x\nF6X=1 true\nset +x")
check("an assignment in front of a command is shown",
      has("F6X=1"), trim(o))
st, o = run("set -x\necho hi > /tmp/f6/trace.txt\nset +x")
check("a redirection is shown with the command",
      has("+ echo hi > /tmp/f6/trace.txt"), trim(o))
st, o = run("set -x\necho $(echo inner)\nset +x")
check("the command of a reference is written too",
      count_of(o, "+ echo inner") >= 2, o)
st, o = run("set -x\necho \"[$-]\"\nset +x")
check("$- names the option while it is in force", has("[x]"), trim(o))
st, o = run("set +x\necho quiet")
check("with the option off nothing is written",
      st == 0 and not has("+ "), trim(o))
st, o = run("echo \"[$-]\"")
check("and no letter of it stands at the end", trim(o) == "[]", trim(o))
options_off()

-- ============================================================
section("usr/psh.lua - set -o pipefail")
-- ============================================================
st, o = run("set -o pipefail\nfalse | true\necho \"[$?]\"")
check("a pipeline fails with its first failing stage",
      has("[1]"), trim(o))
st, o = run("set -o pipefail\ntrue | false\necho \"[$?]\"")
check("the last stage still counts", has("[1]"), trim(o))
st, o = run("set -o pipefail\ntrue | true\necho \"[$?]\"")
check("a pipeline that works reports 0", has("[0]"), trim(o))
st, o = run("set -o pipefail\ntrue | false | true\necho \"[$?]\"")
check("the failing stage may stand in the middle", has("[1]"), trim(o))
st, o = run("set -o pipefail\nfalse | true")
check("the status of the pipeline is the one of the shell",
      st == 1, tostring(st))
st, o = run("set +o pipefail\nfalse | true\necho \"[$?]\"")
check("with the option off the last stage alone counts",
      has("[0]"), trim(o))
st, o = run("set -o pipefail\ncd /no-such-dir | true\necho \"[$?]\"")
check("a built-in that fails counts as a stage", has("[1]"), trim(o))
st, o = run("set -e; set -o pipefail\nfalse | true\necho never")
check("errexit ends the shell on a pipeline that pipefail fails",
      st == 1 and not has("never"), tostring(st) .. " " .. trim(o))
options_off()
st, o = run("set -o pipefail\nfalse | true\necho \"[$-]\"")
check("pipefail stands in no letter of $-", has("[]"), trim(o))
options_off()

-- ============================================================
section("usr/psh.lua - the options of a reference, a script and a function")
-- ============================================================
write("/tmp/f6/child_fail.sh", "false\necho never\n")
write("/tmp/f6/child_last.sh", "true\nfalse\n")
write("/tmp/f6/child_ok.sh", "set -e\necho CHILD\n")
write("/tmp/f6/source_on.sh", "set -e\necho SOURCED\n")
write("/tmp/f6/source_off.sh", "set +e\n")
write("/tmp/f6/trace_on.sh", "set -x\n")

st, o = run("set -e\nx=$(echo \"[$-]\")\necho \"[$x]\"")
check("a reference runs with the options of this shell",
      st == 0 and has("[e]"), tostring(st) .. " " .. trim(o))
st, o = run("set -e\nx=$(set +e; echo \"[$-]\")\necho \"[$-] x=$x\"")
check("an option set inside a reference dies with it",
      st == 0 and has("[e] x=[]"), trim(o))
st, o = run("set +e\nx=$(set -e; false; echo inner)\necho \"x=[$x]\"")
check("an option set inside a reference does not leave it",
      st == 0 and has("x=[]"), tostring(st) .. " " .. trim(o))
st, o = run("set +e\nx=$(set -u; echo ${F6NOPE})\necho \"x=[$x]\"")
check("a fault inside a reference does not end this shell",
      st == 0 and has("x=[]"), tostring(st) .. " " .. trim(o))

st, o = run("set +e\n. /tmp/f6/source_on.sh\necho \"[$-]\"")
check("a sourced script shares the options of the shell",
      st == 0 and has("SOURCED") and has("[e]"), tostring(st) .. " " .. trim(o))
st, o = run("set -e\n. /tmp/f6/source_off.sh\necho \"[$-]\"")
check("and it may turn one off for the shell as well",
      st == 0 and trim(o) == "[]", tostring(st) .. " " .. trim(o))
st, o = run("set +e\n. /tmp/f6/trace_on.sh\necho after\nset +x")
check("a sourced script turns xtrace on for the shell",
      has("+ echo after"), trim(o))

st, o = run("set -e\n/tmp/f6/child_fail.sh\necho never")
check("a command script runs with the options of this shell",
      st == 1 and not has("never"), tostring(st) .. " " .. trim(o))
st, o = run("set +e\n/tmp/f6/child_fail.sh\necho after")
check("with errexit off a script goes on past the fault",
      st == 0 and has("never") and has("after"), tostring(st) .. " " .. trim(o))
st, o = run("set +e\n/tmp/f6/child_last.sh")
check("the status of a script is the one of its last command",
      st == 1, tostring(st))
st, o = run("set +e\n/tmp/f6/child_ok.sh\nfalse\necho after")
check("an option set inside a script does not leave it",
      st == 0 and has("CHILD") and has("after"), tostring(st) .. " " .. trim(o))
st, o = run("set +e\n/tmp/f6/trace_on.sh\necho \"[$-]\"")
check("neither does xtrace of a script die outside it",
      st == 0 and trim(o) == "[]", tostring(st) .. " " .. trim(o))
st, o = run("set +e\nf6g() { set -e; }\nf6g\nfalse\necho never")
check("a function body is a part of this shell",
      st == 1 and not has("never"), tostring(st) .. " " .. trim(o))
options_off()

-- ============================================================
section("lib/man.lua - the set page")
-- ============================================================
check("the page is listed", man.exists("set"))
local spage = man.pages.set
check("the page holds a description", type(spage.what) == "string",
      tostring(type(spage.what)))
check("the description names the options",
      tostring(spage.what):find("option", 1, true) ~= nil,
      tostring(spage.what))
check("the page lists the forms of the line", #spage.syn == 10,
      tostring(#spage.syn))
local ssyn = table.concat(spage.syn or {}, " ")
local snote = table.concat(spage.note or {}, " ")
check("the synopsis shows the letters",
      ssyn:find("set -eux", 1, true) ~= nil)
check("the synopsis shows the plus letters",
      ssyn:find("set +eux", 1, true) ~= nil)
check("the synopsis shows the long name form",
      ssyn:find("set -o OPTION", 1, true) ~= nil)
check("the synopsis shows the assignment",
      ssyn:find("set NAME=value", 1, true) ~= nil)
check("the synopsis shows the word that ends the options",
      ssyn:find("set -- WORD", 1, true) ~= nil)
check("the two listings stand as lines of their own",
      spage.syn[8] == "set -o" and spage.syn[9] == "set +o",
      tostring(spage.syn[8]) .. " / " .. tostring(spage.syn[9]))
check("the text names errexit", snote:find("errexit", 1, true) ~= nil)
check("the text names nounset", snote:find("nounset", 1, true) ~= nil)
check("the text names xtrace", snote:find("xtrace", 1, true) ~= nil)
check("the text names pipefail", snote:find("pipefail", 1, true) ~= nil)
check("the text tells that pipefail has no letter",
      snote:find("no letter", 1, true) ~= nil)
check("the text explains the letters of $-",
      snote:find("$-", 1, true) ~= nil)
check("the text explains the sub shell of a reference",
      snote:find("sub shell", 1, true) ~= nil)
check("the text names the sourced script",
      snote:find("sourced script", 1, true) ~= nil)
check("the text explains the word that ends the options",
      snote:find("ends the options", 1, true) ~= nil)
local sopts = {}
for _, pair in ipairs(spage.opts or {}) do sopts[#sopts + 1] = pair[1] end
local sopts_text = table.concat(sopts, "\n")
check("the options list the two signs of errexit",
      sopts_text:find("-e", 1, true) ~= nil and
      sopts_text:find("+e", 1, true) ~= nil)
check("the options list the two signs of nounset",
      sopts_text:find("-u", 1, true) ~= nil and
      sopts_text:find("+u", 1, true) ~= nil)
check("the options list the two signs of xtrace",
      sopts_text:find("-x", 1, true) ~= nil and
      sopts_text:find("+x", 1, true) ~= nil)
check("the options list pipefail both ways",
      sopts_text:find("-o pipefail", 1, true) ~= nil and
      sopts_text:find("+o pipefail", 1, true) ~= nil)
check("the options list the assignment",
      sopts_text:find("NAME=value", 1, true) ~= nil)
check("the options list the word that ends them",
      sopts_text:find("--", 1, true) ~= nil)
local sren = table.concat(man.render("set"), "\n")
check("the rendered page shows the letters",
      sren:find("set -eux", 1, true) ~= nil)
check("the rendered page names pipefail",
      sren:find("pipefail", 1, true) ~= nil)
local shit = false
for _, hit in ipairs(man.search("pipefail")) do
    if hit.name == "set" then shit = true end
end
check("a search for pipefail finds the page", shit)
local shit2 = false
for _, hit in ipairs(man.search("errexit")) do
    if hit.name == "set" then shit2 = true end
end
check("a search for errexit finds the page", shit2)

-- ============================================================
section("lib/glob.lua - the bracket expression of a bare word")
-- ============================================================
-- The reader of a bracket expression follows POSIX: the "]" that stands right
-- behind the "[" (or behind its "[!" or "[^") is a member of the set and not
-- its end, so "[]]" is the set that holds the bracket itself and "[!]]" is the
-- set of everything but it, while a set that holds no member at all is not a
-- set. The old reader ended the set on the first "]" it met, so a word as
-- plain as "[]" became the Lua pattern "[]" and every match on it raised
-- "malformed pattern (missing ']')".
local function runs(pat)
    return pcall(function() return glob.compile(pat) end)
end

local function matches(name, pat)
    local ok, res = pcall(function() return glob.match(name, pat) end)
    return ok and res or false
end

check("a bare [] builds a pattern that runs", runs("[]"))
check("a bare [] is the literal text of two brackets",
      glob.compile("[]") == "^%[%]$", tostring(glob.compile("[]")))
check("a bare [] matches its own text", matches("[]", "[]"))
check("a bare [] matches nothing else", matches("a", "[]") == false)
check("a bare [] of a value matches its own text",
      glob.match_value("[]", "[]"))
check("a negated bare [!] is literal as well",
      glob.compile("[!]") == "^%[!%]$", tostring(glob.compile("[!]")))
check("a careted bare [^] is literal as well",
      glob.compile("[^]") == "^%[%^%]$", tostring(glob.compile("[^]")))
check("an unterminated [ is the literal bracket",
      glob.compile("[") == "^%[$", tostring(glob.compile("[")))
check("an unterminated [ matches the bracket", matches("[", "["))
check("an unterminated [ matches nothing else", matches("a", "[") == false)
check("a ] right behind the [ is a member of the set", matches("]", "[]]"))
check("the set of a lone ] holds nothing else", matches("a", "[]]") == false)
check("the compiled set of a lone ] is a real set",
      glob.compile("[]]") == "^[%]]$", tostring(glob.compile("[]]")))
check("a negated set may hold the ] as well", matches("a", "[!]]"))
check("that set refuses the ]", matches("]", "[!]]") == false)
check("a negated set of a lone ] builds a pattern that runs", runs("[!]]"))
check("a set that begins with the ] may hold more members",
      matches("]", "[]ab]") and matches("b", "[]ab]"))
check("such a set refuses what it does not name", matches("c", "[]ab]") == false)
check("a member behind the ] is read as it stands", matches("ab]", "[a]b]"))
check("that word is not read as a second set", matches("ab", "[a]b]") == false)
check("a set of plain members still works", matches("a", "[abc]"))
check("a negated set of plain members still works",
      matches("d", "[!abc]") and matches("a", "[!abc]") == false)

local st, o = echo_of("echo []")
check("the bare word [] is a plain word at the command line",
      st == 0 and o == "[]", tostring(st) .. " [" .. o .. "]")
check("the shell writes no malformed pattern of it",
      not has("malformed pattern"), o)
st, o = echo_of("echo a[]b")
check("a bare [] inside a longer word is plain text", o == "a[]b", o)
st, o = echo_of("echo [!] [^] [")
check("the other bare forms are plain text as well", o == "[!] [^] [", o)
vars.set("BR", "[]")
st, o = echo_of("echo \"[${BR#[]}]\"")
check("a bare [] cuts a value as a literal pattern", st == 0 and o == "[]", o)
vars.unset("BR")

-- ============================================================
section("the source of the two files")
-- ============================================================
local src = host_text(PROJ .. "/usr/psh.lua")
check("the shell source is readable", type(src) == "string", tostring(src))
if type(src) == "string" then
    check("the operator list is in the shell",
          src:find("PEXP_OPS", 1, true) ~= nil)
    check("the brace reader counts nested braces",
          src:find("closing_brace", 1, true) ~= nil)
    check("the word of an operator is read as segments",
          src:find("read_segments", 1, true) ~= nil)
    check("the shell asks glob for a value match",
          src:find("glob.match_value", 1, true) ~= nil)
    check("the pattern removal has its own routine",
          src:find("pattern_remove", 1, true) ~= nil)
    check("the value of an operator has its own routine",
          src:find("pexp_value", 1, true) ~= nil)
    check("a failing :? is remembered", src:find("expand_failure", 1, true) ~= nil)
    check("the arithmetic reference has its own reader",
          src:find("read_arith", 1, true) ~= nil)
    check("the value of an arithmetic reference has its own routine",
          src:find("arith_value", 1, true) ~= nil)
    check("the shell asks lib/arith.lua for the value",
          src:find("arith.eval", 1, true) ~= nil)
    check("the command substitution has its own reader",
          src:find("read_cmdsub", 1, true) ~= nil)
    check("the old form has its own reader",
          src:find("read_backquote", 1, true) ~= nil)
    check("the value of a substitution has its own routine",
          src:find("cmdsub_value", 1, true) ~= nil)
    check("the sub shell has an entry and an exit",
          src:find("subshell_enter", 1, true) ~= nil and
          src:find("subshell_leave", 1, true) ~= nil)
    check("the output of the sub shell is captured",
          src:find("capture_push", 1, true) ~= nil and
          src:find("capture_top", 1, true) ~= nil)
    check("a rendered unit does not run its substitution early",
          src:find("cmdsub_suppress", 1, true) ~= nil)
    check("the faults of the shell go to the error output",
          src:find("emit_diag", 1, true) ~= nil)
    check("the delimiter of a document has its own reader",
          src:find("read_heredoc_delim", 1, true) ~= nil)
    check("the body of a document has its own reader",
          src:find("heredoc_body", 1, true) ~= nil)
    check("the shell remembers the documents left open",
          src:find("heredocs_open", 1, true) ~= nil)
    check("the interactive loop reads the rest of a document",
          src:find("heredoc_more(line", 1, true) ~= nil)
    check("the body of a document is handed over as text",
          src:find("heredoc_text", 1, true) ~= nil and
          src:find("text_reader", 1, true) ~= nil)
    check("the body and the < share the standard input",
          src:find("stage.here", 1, true) ~= nil)
    check("the body of a live document asks for the escapes",
          src:find("read_segments(body, true)", 1, true) ~= nil)
    check("the tabs of a <<- body are dropped",
          src:find("tabstrip", 1, true) ~= nil)
    check("the document reader carries the quote flag",
          src:find("quoted", 1, true) ~= nil)
    check("the table of the signals is in the shell",
          src:find("TRAP_SIGNALS", 1, true) ~= nil)
    check("the signal that may never be caught is marked",
          src:find("locked = true", 1, true) ~= nil)
    check("the traps of the shell live in a table of their own",
          src:find("local TRAPS = {}", 1, true) ~= nil)
    check("a signal name has its own reader",
          src:find("trap_signal_of", 1, true) ~= nil)
    check("the text of a trap is quoted as one word",
          src:find("trap_quote", 1, true) ~= nil)
    check("the writer of the listing has its own routine",
          src:find("trap_line", 1, true) ~= nil)
    check("the runner of a trap has its own routine",
          src:find("trap_run", 1, true) ~= nil)
    check("a signal is fired through one entry",
          src:find("trap_fire", 1, true) ~= nil)
    check("the shell runs the trap of EXIT when it leaves",
          src:find("trap_run_exit", 1, true) ~= nil)
    check("a trap that is running is not entered again",
          src:find("trap_guard", 1, true) ~= nil)
    check("a sub shell and a script get their own frames",
          src:find("trap_frame_enter", 1, true) ~= nil and
          src:find("trap_frame_leave", 1, true) ~= nil)
    check("the interrupt of CraftOS has its own reader",
          src:find("is_interrupt_error", 1, true) ~= nil)
    check("the built-in of trap is registered",
          src:find('BUILTINS["trap"]', 1, true) ~= nil)
    check("the options of the shell stand in one table",
          src:find("local SET_OPTIONS", 1, true) ~= nil)
    check("the table keeps the letters of the options",
          src:find("by_letter", 1, true) ~= nil)
    check("the table keeps the long names of the options",
          src:find("by_name", 1, true) ~= nil)
    check("pipefail is the option that has no letter",
          src:find('name = "pipefail", letter = nil', 1, true) ~= nil)
    check("the table holds the list of the options",
          src:find("SET_OPTIONS.list", 1, true) ~= nil)
    check("$- is built from that table",
          src:find("SET_OPTIONS.letters", 1, true) ~= nil)
    check("a command that is only read holds the rule back",
          src:find("SET_OPTIONS.hold", 1, true) ~= nil)
    check("a failing command ends the shell through one routine",
          src:find("SET_OPTIONS.check", 1, true) ~= nil)
    check("the trace has its own routine",
          src:find("SET_OPTIONS.trace", 1, true) ~= nil)
    check("the line of the listing has its own routine",
          src:find("SET_OPTIONS.line", 1, true) ~= nil)
    check("the command of the listing has its own routine",
          src:find("SET_OPTIONS.command", 1, true) ~= nil)
    check("a sub shell saves the options it had",
          src:find("snap.options", 1, true) ~= nil)
    check("a command script saves the options it had",
          src:find("saved_options", 1, true) ~= nil)
end

local asrc = host_text(PROJ .. "/lib/arith.lua")
check("the arithmetic source is readable", type(asrc) == "string", tostring(asrc))
if type(asrc) == "string" then
    check("the evaluator is exported",
          asrc:find("function arith.eval", 1, true) ~= nil)
    check("the width is 64 bits", asrc:find("local WIDTH = 64", 1, true) ~= nil)
    check("the sign is read from the top bit",
          asrc:find("SIGN64", 1, true) ~= nil)
    check("the ternary has its own level",
          asrc:find("parse_ternary", 1, true) ~= nil)
    check("a division by zero is a fault",
          asrc:find("division by zero", 1, true) ~= nil)
    check("the exact integers are reused",
          asrc:find('require("bignum")', 1, true) ~= nil)
end

local bsrc = host_text(PROJ .. "/lib/bignum.lua")
check("the bignum source is readable", type(bsrc) == "string", tostring(bsrc))
if type(bsrc) == "string" then
    check("bignum grew the bitwise and",
          bsrc:find("function B.band", 1, true) ~= nil)
    check("bignum grew the bitwise or",
          bsrc:find("function B.bor", 1, true) ~= nil)
    check("bignum grew the bitwise xor",
          bsrc:find("function B.bxor", 1, true) ~= nil)
    check("bignum grew the shifts",
          bsrc:find("function B.shl", 1, true) ~= nil and
          bsrc:find("function B.shr", 1, true) ~= nil)
    check("bignum grew the decimal reader",
          bsrc:find("function B.from_dec", 1, true) ~= nil)
    check("bignum grew the decimal writer",
          bsrc:find("function B.to_dec", 1, true) ~= nil)
    check("the modular power is still there",
          bsrc:find("function B.modpow", 1, true) ~= nil)
end

local gsrc = host_text(PROJ .. "/lib/glob.lua")
check("the glob source is readable", type(gsrc) == "string", tostring(gsrc))
if type(gsrc) == "string" then
    check("glob grew a value compiler", gsrc:find("compile_value", 1, true) ~= nil)
    check("glob grew a value matcher", gsrc:find("match_value", 1, true) ~= nil)
    check("the separator rule is still documented",
          gsrc:find("never crosses", 1, true) ~= nil)
    check("the value case is documented",
          gsrc:find("pattern removal", 1, true) ~= nil)
end

local msrc = host_text(PROJ .. "/lib/man.lua")
check("the manual source is readable", type(msrc) == "string", tostring(msrc))
if type(msrc) == "string" then
    check("the manual holds the expansion page",
          msrc:find("expansion = {", 1, true) ~= nil)
    check("the page repeats the shortest and longest rule",
          msrc:find("shortest", 1, true) ~= nil and
          msrc:find("longest", 1, true) ~= nil)
    check("the manual explains the command substitution",
          msrc:find("command substitution", 1, true) ~= nil)
    check("the manual explains the sub shell of the reference",
          msrc:find("sub shell", 1, true) ~= nil)
    check("the manual shows the old backquoted form",
          msrc:find("backquotes", 1, true) ~= nil)
    check("the manual holds the here document page",
          msrc:find("heredoc = {", 1, true) ~= nil)
    check("the page explains the line of the delimiter",
          msrc:find("delimiter WORD and nothing else", 1, true) ~= nil)
    check("the page explains the quoted delimiter",
          msrc:find("turns the", 1, true) ~= nil and
          msrc:find("expansion off", 1, true) ~= nil)
    check("the page explains the tabs of <<-",
          msrc:find("drops the tabs", 1, true) ~= nil)
    check("the page explains the clash with <",
          msrc:find("the one written", 1, true) ~= nil and
          msrc:find("is the one that counts", 1, true) ~= nil)
    check("the page names the expansion, as it reuses it",
          msrc:find("$((EXPR)) and $(CMD) are expanded", 1, true) ~= nil)
    check("the manual holds the trap page",
          msrc:find("trap = {", 1, true) ~= nil)
    check("the page tells of the signal that may never be caught",
          msrc:find("may never", 1, true) ~= nil)
    check("the page explains the trap of ERR",
          msrc:find("trap of ERR", 1, true) ~= nil)
    check("the page tells the word that ends the options",
          msrc:find("ends the options", 1, true) ~= nil)
    check("the page shows the form with that word",
          msrc:find("trap -- ACTION SIGNAL", 1, true) ~= nil)
    check("the manual holds the set page",
          msrc:find("set = {", 1, true) ~= nil)
    check("the page names the option of the pipeline",
          msrc:find("pipefail", 1, true) ~= nil)
    check("the page tells that the option has no letter",
          msrc:find("no letter of its own", 1, true) ~= nil)
    check("the page tells which option a script keeps",
          msrc:find("sourced script is a part of this shell", 1, true) ~= nil)
    check("the page shows the listing of the options",
          msrc:find("set -o", 1, true) ~= nil and
          msrc:find("set +o", 1, true) ~= nil)
end

-- ============================================================
section("ed: a line editor")
-- ============================================================
local function contents(path)
    local handle = fs.open(path, "r")
    if not handle then return nil end
    local text = handle.readAll()
    handle.close()
    return text
end

-- a, w and q: the bytes land on disk and can be read back ----------------
st, o = run("ed /tmp/ed_a.txt <<EOF\na\none\ntwo\n.\nw\nq\nEOF")
check("a session appends, writes and quits", st == 0, tostring(st))
check("w reports the byte count", trim(o) == "8 bytes", o)
check("the file holds the bytes that were typed",
      contents("/tmp/ed_a.txt") == "one\ntwo\n",
      tostring(contents("/tmp/ed_a.txt")))
check("the size agrees with the byte count",
      fs.getSize("/tmp/ed_a.txt") == 8, tostring(fs.getSize("/tmp/ed_a.txt")))
st, o = echo_of("cat /tmp/ed_a.txt")
check("the shell reads the written file back", o == "one\ntwo", o)

-- p, n, =: opening the file prints nothing, the commands speak -----------
st, o = run("ed /tmp/ed_a.txt <<'EOF'\n1p\n$p\n1n\n2n\n1=\n$=\nq\nEOF")
check("opening a file prints nothing, and p, n and = speak",
      trim(o) == "one\ntwo\n1\tone\n2\ttwo\n1\n2", o)
check("a session of prints succeeds", st == 0, tostring(st))

-- a bare number, $ and . move the current line ---------------------------
write("/tmp/ed_addr.txt", "alpha\nbeta\ngamma\n")
st, o = run("ed /tmp/ed_addr.txt <<'EOF'\n2p\n$p\n2\np\n$\np\n.p\nEOF")
check("a bare number and $ move the current line",
      trim(o) == "beta\ngamma\nbeta\ngamma\ngamma", o)

-- i, c and d change the buffer; wq writes and quits ----------------------
st, o = run("ed /tmp/ed_a.txt <<EOF\n1i\nzero\n.\nwq\nEOF")
check("i inserts before the addressed line",
      st == 0 and contents("/tmp/ed_a.txt") == "zero\none\ntwo\n",
      tostring(st) .. " " .. tostring(contents("/tmp/ed_a.txt")))
st, o = run("ed /tmp/ed_a.txt <<EOF\n2c\nTWO\n.\nwq\nEOF")
check("c replaces the addressed line",
      st == 0 and contents("/tmp/ed_a.txt") == "zero\nTWO\ntwo\n",
      tostring(contents("/tmp/ed_a.txt")))
st, o = run("ed /tmp/ed_a.txt <<EOF\n3d\nwq\nEOF")
check("d deletes the addressed line",
      st == 0 and contents("/tmp/ed_a.txt") == "zero\nTWO\n",
      tostring(contents("/tmp/ed_a.txt")))

-- w FILE names the target, and q after a write succeeds ------------------
st, o = run("ed /tmp/ed_none.txt <<EOF\na\nnamed\n.\nw /tmp/ed_written.txt\nq\nEOF")
check("w FILE writes the named file",
      st == 0 and contents("/tmp/ed_written.txt") == "named\n",
      tostring(contents("/tmp/ed_written.txt")))
check("the startup name is not created when w names another file",
      not fs.exists("/tmp/ed_none.txt"))

-- q refuses a changed buffer; q! never does ------------------------------
st, o = run("ed /tmp/ed_q.txt <<EOF\na\nlost\n.\nq\nEOF")
check("q with unwritten changes is refused with status 1", st == 1, tostring(st))
check("and the refusal points at q!", o:find("q!", 1, true) ~= nil, o)
check("the refused session wrote no file", not fs.exists("/tmp/ed_q.txt"))
st, o = run("ed /tmp/ed_q.txt <<EOF\na\nlost\n.\nq!\nEOF")
check("q! quits and writes nothing",
      st == 0 and not fs.exists("/tmp/ed_q.txt"), tostring(st))

-- wq really writes before it quits ---------------------------------------
st, o = run("ed /tmp/ed_wq.txt <<EOF\na\nlast\n.\nwq\nEOF")
check("wq writes before it quits",
      st == 0 and contents("/tmp/ed_wq.txt") == "last\n", tostring(st))
check("wq reports the byte count", trim(o) == "5 bytes", o)

-- the errors that must not raise -----------------------------------------
st, o = run("ed <<EOF\nw\nEOF")
check("w without a file name fails", st == 1, tostring(st))
check("and it says the file name is missing",
      o:find("no file name", 1, true) ~= nil, o)
st, o = run("ed <<EOF\np\nEOF")
check("p on an empty buffer fails instead of raising",
      st == 1 and o:find("no current line", 1, true) ~= nil, o)
st, o = run("ed <<EOF\nz\nEOF")
check("an unknown command fails instead of raising",
      st == 1 and o:find("unknown command", 1, true) ~= nil, o)
st, o = run("ed <<EOF\nh\n?\nEOF")
check("h and ? print the command list",
      st == 0 and count_of(o, "q!") == 2, o)

-- a nil handle below the permission model is a message, not an index ------
local ed_real_open = fs.open
fs.open = function(p, m)
    if p == "/tmp/ed_locked.txt" then return nil end
    return ed_real_open(p, m)
end
st, o = run("ed /tmp/ed_locked.txt <<EOF\na\nx\n.\nw\nEOF")
fs.open = ed_real_open
check("a nil handle is a failed write, not a crash",
      st == 1 and o:find("attempt to index", 1, true) == nil, o)
check("and the message names what could not be created",
      o:find("/tmp/ed_locked.txt", 1, true) ~= nil, o)

-- a path that no ordinary account may write ------------------------------
local ed_previous = perm.get_current_user()
perm.set_current_user("root")
if not perm.user_exists("edprobe") then
    perm.add_user("edprobe", { level = 0 })
end
perm.set_current_user("edprobe")
st, o = run("ed /usr/ed_denied.txt <<EOF\na\nx\n.\nw\nEOF")
perm.set_current_user(ed_previous)
check("writing into /usr is refused for an ordinary account", st == 1, tostring(st))
check("and the refusal is permission denied",
      o:find("permission denied", 1, true) ~= nil, o)
check("the refused path was never created", not fs.exists("/usr/ed_denied.txt"))

-- ============================================================
say("")
say("=== batch 7 (group F, steps 1 to 6) summary ===")
say(string.format("passed: %d  failed: %d", pass, fail))
if fail > 0 then
    for _, name in ipairs(fails) do
        say("  FAIL " .. name)
    end
end

_G.__RESULT = { pass = pass, fail = fail, report = table.concat(fails, "\n") }
