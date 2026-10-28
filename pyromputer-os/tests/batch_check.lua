-- batch_check.lua - PC side logic assertions for the two changes of this round
--   1. pkg / apt: every write subcommand needs root (or sudo) and honours the
--      mount table and the mode bits;
--   2. .sh / .psh batch scripts: shebang, arguments, exit status.
--
-- Run through tests/run_all.py with lupa over tests/cc_env_stub.lua.
-- Everything verified here is a PC side simulation result, it is NOT a
-- CraftOS-PC result.

local PROJ = _G.PROJ
package.path = PROJ .. "/lib/?.lua;" .. PROJ .. "/usr/?.lua;" .. package.path

local say = _G.__realprint
local unpack = _G.unpack or table.unpack

local pass, fail = 0, 0
local fails = {}
local sections = {}
local current = { name = "(before the first section)", pass = 0, fail = 0 }
sections[1] = current

local function check(name, cond, extra)
    if cond then
        pass = pass + 1
        current.pass = current.pass + 1
    else
        fail = fail + 1
        current.fail = current.fail + 1
        fails[#fails + 1] = name ..
            (extra ~= nil and ("  [" .. tostring(extra) .. "]") or "")
    end
end

local function clear() _G.__OUT = {} end
local function out() return table.concat(_G.__OUT, "\n") end
-- The terminal stub collects the output in chunks; the chunk borders are an
-- artefact of the simulation, so text is compared with the whitespace runs
-- folded into a single space.
local function flat(t) return (tostring(t):gsub("%s+", " ")) end
local function has(sub) return out():find(sub, 1, true) ~= nil end
local function section(title)
    say("")
    say("=== " .. title .. " ===")
    current = { name = title, pass = 0, fail = 0 }
    sections[#sections + 1] = current
end

local fs = _G.fs

local function write_file(path, text)
    local h = fs.open(path, "w")
    h.write(text)
    h.close()
end

-- ---------------------------------------------------------------- fixture fs
for _, d in ipairs({ "/etc", "/usr", "/usr/pkgs", "/usr/cmd", "/usr/local/bin",
                     "/bin", "/var", "/var/log", "/var/lib", "/var/lib/pkg",
                     "/var/cache", "/var/cache/pkg", "/home", "/home/root",
                     "/tmp", "/var/tmp", "/mnt" }) do
    fs.makeDir(d)
end
write_file("/etc/pkg.conf",
           "server_id=5\nkey=mysecretpassword\nchannel=pkg-repo\n")
write_file("/etc/path.conf",
           "# psh PATH configuration\n/usr/cmd\n/usr/local/bin\n/bin\n")
write_file("/etc/passwd", "root:2:root\nalice:0:users\n")
write_file("/etc/group", "root:root\nusers:alice\n")

local perm = require("perm")
perm.reload()
perm.set_current_user("root")
check("fixture: root and alice are known users",
      perm.user_exists("root") and perm.user_exists("alice"))
check("fixture: the shell starts as root", perm.get_current_user() == "root")

-- ------------------------------------------------------------------ the shell
_G.__PSH_TEST = true
local chunk = assert(loadfile(PROJ .. "/usr/psh.lua"))
chunk()
local psh = _G.__psh_test
psh.init()

local function run(line)
    clear()
    local status = psh.run(line)
    return status, out()
end

-- ============================================================
section("entry: \"psh FILE [args]\" argument split")
-- ============================================================
local cmd_a, script_a, rest_a = psh.parse_args({ "hello.sh", "A", "B" })
check("a script name is separated from its own arguments",
      cmd_a == nil and script_a == "hello.sh" and type(rest_a) == "table" and
      rest_a[1] == "A" and rest_a[2] == "B", tostring(script_a))
local cmd_b, script_b = psh.parse_args({ "-c", "echo hi" })
check("-c still wins over a script", cmd_b == "echo hi" and script_b == nil)
local _, script_c, rest_c = psh.parse_args({ "--", "s.sh", "-x" })
check("\"--\" forces the script form and keeps the flags as arguments",
      script_c == "s.sh" and rest_c[1] == "-x", tostring(script_c))
local _, _, rest_d = psh.parse_args({ "only.sh" })
check("a script without arguments gets an empty set",
      type(rest_d) == "table" and #rest_d == 0)

-- ============================================================
section("pkg / apt: write subcommands need root (shared threshold)")
-- ============================================================
local pkgmod = require("pkg")
local audit = require("audit")
local mounts = require("mounts")

local calls = {}
local saved = {}
for _, fn in ipairs({ "install", "remove", "purge", "update", "search",
                      "list" }) do
    saved[fn] = pkgmod[fn]
end
local function stub_all()
    calls = {}
    pkgmod.install = function(n)
        calls.install = tostring(n)
        return true, "installed " .. tostring(n)
    end
    pkgmod.remove = function(n)
        calls.remove = tostring(n)
        return true, "removed " .. tostring(n)
    end
    pkgmod.purge = function(n)
        calls.purge = tostring(n)
        return true, "purged " .. tostring(n)
    end
    pkgmod.update = function()
        calls.update = true
        return true, "index refreshed"
    end
    pkgmod.search = function(q)
        calls.search = tostring(q)
        return true, { { name = "demo", version = "1.0" } }
    end
    pkgmod.list = function()
        calls.list = true
        return { "demo" }
    end
end
stub_all()

-- phase 1: /etc/sudoers does not mention alice, so sudo would not help her ---
perm.remove_sudoer("alice")
perm.set_current_user("alice")
local st_plain, o_plain = run("pkg install demo")
check("alice: \"pkg install\" is refused", st_plain == 1, st_plain)
check("alice: the refusal names the missing privilege",
      flat(o_plain):find("must be root", 1, true) ~= nil, o_plain)
check("alice: a user the sudo policy ignores is not sent to sudo",
      flat(o_plain):find("may not use sudo", 1, true) ~= nil and
      flat(o_plain):find("sudo pkg install", 1, true) == nil, o_plain)
check("alice: a refused install never reaches lib/pkg.lua",
      calls.install == nil, tostring(calls.install))

-- phase 2: once sudoers lists her the same refusal points at sudo ------------
-- The fixture, not a user action: /etc/sudoers is root's file, and lib/perm.lua
-- enforces that itself now that it writes the file through the unguarded open.
perm.set_current_user("root")
perm.add_sudoer("alice")
perm.set_current_user("alice")
local st_pkg, o_pkg = run("pkg install demo")
check("alice: \"pkg install\" is still refused", st_pkg == 1, st_pkg)
check("alice: the sudoer is told to rerun the command under sudo",
      flat(o_pkg):find("use sudo: \"sudo pkg install", 1, true) ~= nil, o_pkg)
check("alice: the sudoer refusal still never reaches lib/pkg.lua",
      calls.install == nil, tostring(calls.install))

local st_apt, o_apt = run("apt install demo")
check("alice: \"apt install\" is refused as well",
      st_apt == 1 and calls.install == nil, st_apt)
check("alice: apt and pkg share one message (only the name differs)",
      o_apt == flat(o_pkg):gsub("pkg", "apt"), o_apt)

for _, sub in ipairs({ "remove", "purge", "update", "upgrade" }) do
    local st, o = run("pkg " .. sub .. " demo")
    local st_a, o_a = run("apt " .. sub .. " demo")
    local key = sub == "upgrade" and "install" or sub
    check("alice: \"pkg " .. sub .. "\" is refused with status 1", st == 1, st)
    check("alice: \"apt " .. sub .. "\" is refused with status 1", st_a == 1,
          st_a)
    check("alice: \"pkg " .. sub .. "\" never reaches the library",
          calls[key] == nil)
    check("alice: \"pkg " .. sub .. "\" points at sudo",
          o:find("use sudo", 1, true) ~= nil, o)
end

local st_cl, o_cl = run("pkg clean")
check("alice: \"pkg clean\" is refused with status 1", st_cl == 1, st_cl)
check("alice: the clean refusal names the missing privilege",
      flat(o_cl):find("must be root", 1, true) ~= nil, o_cl)
local st_acl, o_acl = run("apt clean")
check("alice: \"apt clean\" is refused with status 1", st_acl == 1, st_acl)
check("alice: apt and pkg share the clean message too",
      o_acl == flat(o_cl):gsub("pkg", "apt"), o_acl)

-- sudo elevation: the gate reads the identity sudo puts in place -------------
stub_all()
require("sudocache").touch("alice")
local st_el, o_el = run("sudo pkg install demo")
check("alice: \"sudo pkg install\" passes the same gate",
      st_el == 0 and calls.install == "demo", o_el)
check("alice: the elevated run prints no refusal",
      flat(o_el):find("permission denied", 1, true) == nil, o_el)
require("sudocache").clear("alice")

local st_list, o_list = run("pkg list")
check("alice: \"pkg list\" is still allowed and works",
      st_list == 0 and calls.list == true, st_list)
local st_search, o_search = run("apt search demo")
check("alice: \"apt search\" is still allowed and works",
      st_search == 0 and calls.search == "demo", st_search)
check("alice: \"pkg search\" prints the index entries",
      flat(o_search):find("demo 1.0", 1, true) ~= nil, o_search)

local st_usage, o_usage = run("pkg")
check("pkg without a subcommand prints usage and exits 0",
      st_usage == 0 and flat(o_usage):find("usage: pkg", 1, true) ~= nil, o_usage)
check("the usage line lists the gated subcommands",
      flat(o_usage):find("install", 1, true) ~= nil and
      flat(o_usage):find("purge", 1, true) ~= nil, o_usage)
local st_bad, o_bad = run("apt frobnicate")
check("an unknown subcommand prints usage and exits 1",
      st_bad == 1 and flat(o_bad):find("usage", 1, true) ~= nil, st_bad)

local _, o_and = run("pkg install demo && echo reached")
check("a refused write stops the \"&&\" list",
      flat(o_and):find("reached", 1, true) == nil, o_and)
local _, o_or = run("pkg install demo || echo denied")
check("a refused write drives the \"||\" branch",
      flat(o_or):find("denied", 1, true) ~= nil, o_or)
local _, o_q = run("pkg install demo; echo $?")
check("the refusal status reaches \"$?\"",
      o_q:match("1%s*$") ~= nil, o_q)

-- root passes the same gate ------------------------------------------------
perm.set_current_user("root")
stub_all()
local st_ri, o_ri = run("pkg install demo")
check("root: \"pkg install\" runs", st_ri == 0 and calls.install == "demo",
      o_ri)
stub_all()
local st_ar = run("apt remove demo")
check("root: \"apt remove\" runs", st_ar == 0 and calls.remove == "demo")
stub_all()
local st_rp = run("pkg purge demo")
check("root: \"pkg purge\" runs", st_rp == 0 and calls.purge == "demo")
stub_all()
local st_ru = run("apt update")
check("root: \"apt update\" runs", st_ru == 0 and calls.update == true)
stub_all()
local st_rupg = run("pkg upgrade")
check("root: \"pkg upgrade\" refreshes then reinstalls",
      st_rupg == 0 and calls.update == true and calls.install == "demo")
stub_all()
local st_rc = run("pkg clean")
check("root: \"pkg clean\" runs", st_rc == 0, select(2, run("pkg clean")))
stub_all()
local st_ac = run("apt clean")
check("root: \"apt clean\" shares the same path", st_ac == 0)

pkgmod.install = function(n)
    calls.install = tostring(n)
    return false, "no such package"
end
local st_fail, o_fail = run("pkg install nosuch")
check("root: a failing install still exits 1",
      st_fail == 1 and flat(o_fail):find("error: no such package", 1, true) ~= nil,
      o_fail)

-- read only mount ----------------------------------------------------------
stub_all()
mounts.ensure()
local mounted = mounts.mount("/tmp", "/usr/pkgs", "ro")
check("fixture: /usr/pkgs can be mounted read-only", mounted == true,
      tostring(mounted))
check("fixture: the mount is reported read-only",
      mounts.is_readonly("/usr/pkgs") == true)
local st_ro, o_ro = run("pkg install demo")
check("root: a read-only mount blocks the write",
      st_ro == 1 and calls.install == nil, st_ro)
check("root: the read-only refusal names the mount",
      flat(o_ro):find("read-only mount", 1, true) ~= nil, o_ro)
stub_all()
local st_ro_apt, o_ro_apt = run("apt purge demo")
check("the read-only rule applies to apt too",
      st_ro_apt == 1 and flat(o_ro_apt):find("read-only mount", 1, true) ~= nil,
      o_ro_apt)
mounts.umount("/usr/pkgs")
stub_all()
check("after umount the same write is allowed again",
      select(1, run("pkg install demo")) == 0)

-- mode bits ----------------------------------------------------------------
stub_all()
perm.set_mode("/usr/pkgs", "rwxr-xr-x", "root")
check("fixture: /usr/pkgs is writable by root",
      perm.can_write("/usr/pkgs") == true)
perm.set_mode("/usr/pkgs", "r-xr-xr-x", "root")
local st_pw, o_pw = run("pkg install demo")
check("root: the mode bits still block the write",
      st_pw == 1 and calls.install == nil, st_pw)
check("root: the mode refusal is the permission message",
      flat(o_pw):find("permission denied (write)", 1, true) ~= nil, o_pw)
perm.remove("/usr/pkgs")
stub_all()
check("with the mode restored the write works again",
      select(1, run("pkg install demo")) == 0)

-- audit --------------------------------------------------------------------
local tail = table.concat(audit.tail(100), "\n")
check("the audit log records the denial",
      tail:find("action=pkg target=install result=denied", 1, true) ~= nil)
check("the audit log records the grant",
      tail:find("action=pkg target=install result=granted", 1, true) ~= nil)

-- every write subcommand of both front ends goes through the same gate ------
perm.set_current_user("root")
perm.remove_sudoer("alice")
perm.set_current_user("alice")
local WRITE_SUBS = { "install", "remove", "purge", "update", "upgrade", "clean" }
local ungated = {}
for _, cmd in ipairs({ "pkg", "apt" }) do
    for _, sub in ipairs(WRITE_SUBS) do
        local st = select(1, run(cmd .. " " .. sub .. " demo"))
        if st ~= 1 then
            ungated[#ungated + 1] = cmd .. " " .. sub .. " -> " .. tostring(st)
        end
    end
end
check("every write subcommand of pkg and apt is refused for the plain user",
      #ungated == 0, table.concat(ungated, ", "))
check("the same gate answers on both front ends (pkg and apt)",
      flat(select(2, run("pkg clean"))):find("must be root", 1, true) ~= nil and
      flat(select(2, run("apt upgrade"))):find("must be root", 1, true) ~= nil)
perm.set_current_user("root")

perm.remove_sudoer("alice")

-- ============================================================
section("sudoers: exact names, %group entries and wildcards")
-- ============================================================
-- The fixture users: pyam and py2 in the group "py", bob in "users".
perm.add_user("pyam", { password = "pw", groups = "py", level = 1 })
perm.add_user("py2", { password = "pw", groups = "py", level = 1 })
perm.add_user("bob", { password = "pw", groups = "users", level = 0 })

-- ============================================================
section("the machine's directories are read-only for everyone but root")
-- ============================================================
-- Measured on a deployed machine: with no /etc/perm.db, perm.check answered
-- TRUE for every path, so an ordinary account could write /usr/psh.lua or
-- /etc/passwd through any command that asked the database. The rule is now part
-- of perm.check itself: the system directories are writable by root only,
-- readable by all.
do
    local saved = perm.get_current_user()
    perm.set_current_user("bob")
    check("a normal user cannot write into /usr",
          perm.can_write("/usr/psh.lua") == false)
    check("nor into /lib, /etc, /bin or the boot files",
          perm.can_write("/lib/perm.lua") == false and
          perm.can_write("/etc") == false and
          perm.can_write("/etc/passwd") == false and
          perm.can_write("/bin/sh") == false and
          perm.can_write("/startup.lua") == false and
          perm.can_write("/firstboot.lua") == false)
    check("but reading those files is still allowed",
          perm.can_read("/usr/psh.lua") == true and
          perm.can_read("/etc/passwd") == true and
          perm.can_exec("/usr/psh.lua") == true)
    check("and a path that is not a system directory is writable",
          perm.can_write("/home/bob/note.txt") == true)
    check("root writes into every system directory",
          (function()
              perm.set_current_user("root")
              local ok = perm.can_write("/usr/psh.lua") == true and
                         perm.can_write("/etc/passwd") == true and
                         perm.can_write("/lib/perm.lua") == true
              return ok
          end)())
    perm.set_current_user(saved)
end


-- a blank file first, so the checks below start from a known state
write_file("/etc/sudoers", "")
perm.reload()
check("an empty sudoers makes nobody a sudoer",
      not perm.is_sudoer("pyam") and not perm.is_sudoer("bob"))

perm.add_sudoer("pyam")
perm.reload()
check("an exact name is a sudoer", perm.is_sudoer("pyam"))
check("an exact name does not cover another account", not perm.is_sudoer("py2"))

-- "%group" covers every member, and only members
write_file("/etc/sudoers", "%py\n")
perm.reload()
check("a %group entry covers a member of that group",
      perm.is_sudoer("py2"), "py2 is in py")
check("a %group entry leaves other groups alone", not perm.is_sudoer("bob"))
check("a %group entry does not invent a member", not perm.is_sudoer("py3"))

-- the wildcard, written the same way as the command rules in sudo.conf
write_file("/etc/sudoers", "py*\n")
perm.reload()
check("a wildcard covers every matching account",
      perm.is_sudoer("pyam") and perm.is_sudoer("py2"))
check("a wildcard does not cover a name that does not match",
      not perm.is_sudoer("bob"), "bob does not start with py")
check("a wildcard needs the whole name to match",
      not perm.is_sudoer("am"), "the pattern is anchored at both ends")

-- a wildcard is not a user: the management helpers stay literal
write_file("/etc/sudoers", "py*\n")
perm.reload()
perm.add_sudoer("bob")
perm.reload()
check("add_sudoer writes a literal line next to the pattern",
      perm.is_sudoer("bob") and perm.is_sudoer("pyam"))
perm.remove_sudoer("bob")
perm.reload()
check("remove_sudoer drops the literal line and keeps the pattern",
      not perm.is_sudoer("bob") and perm.is_sudoer("pyam"))

-- a literal entry survives alongside a pattern
write_file("/etc/sudoers", "bob\npy*\n")
perm.reload()
check("a literal line next to a pattern is honoured",
      perm.is_sudoer("bob") and perm.is_sudoer("pyam"))

write_file("/etc/sudoers", "")
perm.reload()
check("the sudoers section leaves the file empty for the rest of the suite",
      not perm.is_sudoer("alice"))

-- ============================================================
section("lib/sudorules: the fine grained policy of /etc/sudo.conf")
-- ============================================================
-- The second half of the sudo policy. /etc/sudoers (above) answers "may this
-- account use sudo at all"; /etc/sudo.conf answers "which command, as which
-- user". The three state contract is what the sudo builtin and the pkg gate
-- both rely on:
--
--   true  - a rule allows it
--   false - rules exist for this user, none matches -> deny, do not fall back
--   nil   - no rule mentions the user -> the caller falls back to /etc/sudoers
--
-- Getting nil and false the wrong way round is the failure that matters: a nil
-- treated as a denial locks out every account that only has a sudoers entry.
local sudorules = require("sudorules")
sudorules.reload()

check("pattern_to_lua escapes the dots and slashes literally",
      sudorules.pattern_to_lua("/bin/ls") == "^/bin/ls$",
      sudorules.pattern_to_lua("/bin/ls"))
check("pattern_to_lua turns a star into a wildcard",
      sudorules.pattern_to_lua("/usr/cmd/*") == "^/usr/cmd/.*$",
      sudorules.pattern_to_lua("/usr/cmd/*"))
check("a pattern is anchored at both ends",
      sudorules.pattern_to_lua("py*") == "^py.*$", sudorules.pattern_to_lua("py*"))

-- with no file at all: nothing is known, so every answer is the fallback nil
if fs.exists("/etc/sudo.conf") then fs.delete("/etc/sudo.conf") end
sudorules.reload()
check("no sudo.conf means no rules", #sudorules.rules() == 0, #sudorules.rules())
check("with no file the answer is nil (fall back to sudoers)",
      select(1, sudorules.check("guest", "root", "/bin/ls", "ls", false)) == nil,
      tostring(select(1, sudorules.check("guest", "root", "/bin/ls", "ls", false))))
check("and for_user is empty rather than wrong", #sudorules.for_user("guest") == 0)

-- root never needs a rule
check("root is allowed without any rule",
      select(1, sudorules.check("root", "root", "/bin/ls", "ls", false)) == true)

write_file("/etc/sudo.conf",
           "# a comment line\n" ..
           "guest  ALL=(ALL) /bin/ls\n" ..
           "guest  ALL=(root) /usr/cmd/*, /bin/cat\n" ..
           "helper ALL=(ALL) ALL\n" ..
           "bob    ALL=(adm:adm) /bin/ls\n" ..
           "timeout=300\n" ..
           "not a rule at all\n")
sudorules.reload()

check("a comment is not a rule", #sudorules.rules() == 4, #sudorules.rules())
check("a key=value line is not a rule",
      sudorules.rules()[1] and sudorules.rules()[1].text:find("guest", 1, true) ~= nil,
      sudorules.rules()[1] and sudorules.rules()[1].text)
check("a rule records its user, host and target",
      sudorules.rules()[1].user == "guest" and sudorules.rules()[1].host == "ALL" and
      sudorules.rules()[1].runas[1] == "ALL",
      sudorules.rules()[1].user .. "/" .. sudorules.rules()[1].host)
check("a comma list becomes two commands",
      #sudorules.rules()[2].commands == 2,
      table.concat(sudorules.rules()[2].commands, ","))
check("a target list with a group keeps its colon form",
      sudorules.rules()[4].runas[1] == "adm:adm", sudorules.rules()[4].runas[1])
check("for_user returns the rule text of that user only",
      #sudorules.for_user("guest") == 2 and #sudorules.for_user("nobody") == 0,
      #sudorules.for_user("guest") .. "/" .. #sudorules.for_user("nobody"))

local function rule_of(user, runas, path, name, is_builtin)
    return select(1, sudorules.check(user, runas, path, name, is_builtin))
end

check("a matching path rule allows the command",
      rule_of("guest", "ALL", "/bin/ls", "ls", false) == true)
check("the runas field is enforced, not decorative",
      rule_of("guest", "root", "/bin/cat", "cat", false) == true,
      "guest may run /bin/cat as root")
check("a command outside every rule is denied, not unknown",
      rule_of("guest", "root", "/bin/rm", "rm", false) == false,
      tostring(rule_of("guest", "root", "/bin/rm", "rm", false)))
check("a command the user has no rule for at all answers nil",
      rule_of("nobody", "root", "/bin/ls", "ls", false) == nil,
      tostring(rule_of("nobody", "root", "/bin/ls", "ls", false)))
check("ALL as the command covers anything",
      rule_of("helper", "ALL", "/bin/rm", "rm", false) == true)

-- the wildcard, and the ".lua" suffix the deployed command files carry
check("a path wildcard covers the commands under it",
      rule_of("guest", "root", "/usr/cmd/chmod", "chmod", false) == true)
check("the same command file with its .lua suffix still matches",
      rule_of("guest", "root", "/usr/cmd/chmod.lua", "chmod", false) == true,
      "rules are written the way the user types the command")
check("a wildcard does not reach outside its directory",
      rule_of("guest", "root", "/usr/bin/chmod", "chmod", false) == false,
      tostring(rule_of("guest", "root", "/usr/bin/chmod", "chmod", false)))
check("a builtin has no path, so a path rule cannot match it",
      rule_of("guest", "ALL", nil, "cd", true) == false,
      tostring(rule_of("guest", "ALL", nil, "cd", true)))

-- the target user list, including the user:group form
check("a user:group target is read by its user part",
      rule_of("bob", "adm", "/bin/ls", "ls", false) == true)
check("a target that is not in the list is refused",
      rule_of("bob", "root", "/bin/ls", "ls", false) == false,
      tostring(rule_of("bob", "root", "/bin/ls", "ls", false)))

-- The ".lua" handling has to be pinned on a LITERAL rule: with a wildcard the
-- suffix matches anyway, so a test written that way proves nothing. Here the
-- rule names the command as the user types it and the resolved path carries the
-- deployed file's extension.
write_file("/etc/sudo.conf", "frank ALL=(ALL) /usr/cmd/chmod\n")
sudorules.reload()
check("a literal rule without .lua matches the deployed .lua file",
      rule_of("frank", "ALL", "/usr/cmd/chmod.lua", "chmod", false) == true,
      "bare_path strips the extension before matching")
check("a literal rule still matches the path without the extension",
      rule_of("frank", "ALL", "/usr/cmd/chmod", "chmod", false) == true)
check("stripping the suffix does not turn the match into a free pass",
      rule_of("frank", "ALL", "/usr/cmd/chown.lua", "chown", false) == false,
      tostring(rule_of("frank", "ALL", "/usr/cmd/chown.lua", "chown", false)))

-- a bare command name matches on the name, not the path
write_file("/etc/sudo.conf", "carol ALL=(ALL) ls\n")
sudorules.reload()
check("a bare name matches the command by name",
      rule_of("carol", "ALL", "/bin/ls", "ls", false) == true)
check("a bare name does not match a different command",
      rule_of("carol", "ALL", "/bin/cat", "cat", false) == false)
check("a bare name does not match when there is no name to compare",
      rule_of("carol", "ALL", "/bin/ls", nil, false) == false)

write_file("/etc/sudo.conf", "dave ALL=(ALL) /bin/*\n")
sudorules.reload()
check("a path wildcard is anchored, so a sibling directory is not covered",
      rule_of("dave", "ALL", "/bin/ls", "ls", false) == true and
      rule_of("dave", "ALL", "/usr/bin/ls", "ls", false) == false,
      tostring(rule_of("dave", "ALL", "/usr/bin/ls", "ls", false)))

-- reload is what a caller uses after editing the file
write_file("/etc/sudo.conf", "erin ALL=(ALL) ALL\n")
check("without reload the old rules are still in force",
      rule_of("erin", "ALL", "/bin/ls", "ls", false) == nil,
      "the cache has not been told about the edit")
sudorules.reload()
check("reload picks the new file up",
      rule_of("erin", "ALL", "/bin/ls", "ls", false) == true)

fs.delete("/etc/sudo.conf")
sudorules.reload()
check("the sudorules section leaves no sudo.conf behind",
      not fs.exists("/etc/sudo.conf"))

-- ============================================================
section("pkg / apt: purge at the library level")
-- ============================================================
for _, fn in ipairs({ "install", "remove", "purge", "update", "search",
                      "list" }) do
    pkgmod[fn] = saved[fn]
end

fs.makeDir("/usr/pkgs/foo")
write_file("/usr/pkgs/foo/readme", "hi")
pkgmod._register_bins("foo", { "footool" })
perm.set_mode("/usr/pkgs/foo", "rwxr-xr-x", "root")
check("fixture: the package command is registered",
      pkgmod.get_bins()["foo"] ~= nil)
local ok_purge, msg_purge = pkgmod.purge("foo")
check("pkg.purge removes the package directory",
      ok_purge == true and not fs.exists("/usr/pkgs/foo"), msg_purge)
check("pkg.purge drops the registered commands",
      pkgmod.get_bins()["foo"] == nil)
check("pkg.purge drops the permission record",
      perm.get_mode("/usr/pkgs/foo") == nil)
check("pkg.purge removes the leftover state of a half removed package",
      select(1, pkgmod.purge("foo")) == false and
      select(1, pkgmod.purge("ghost")) == false)
check("pkg.remove agrees on \"not installed\"",
      pkgmod.remove("ghost") == false)
check("pkg.purge without a name prints the usage",
      pkgmod.purge(nil) == false)

-- ============================================================
section(".sh / .psh scripts: shebang, arguments, exit status")
-- ============================================================
write_file("/usr/local/bin/hello.sh",
           "#!/usr/bin/env psh\necho \"hello $1\"\nexit 7\n")
write_file("/usr/cmd/tool.psh", "#!/bin/psh\necho \"tool $# args\"\n")
write_file("/usr/local/bin/plain",
           "#!/usr/bin/env psh\necho plain-tool\n")
write_file("/home/root/rel.sh", "echo relative-script\n")
write_file("/home/root/plain", "#!/usr/bin/env psh\necho plain-tool\n")
write_file("/tmp/noshebang.sh", "echo no-shebang\n")
write_file("/tmp/foreign.sh", "#!/bin/bash\necho nope\n")
write_file("/tmp/exit5.sh", "echo before\nexit 5\necho after\n")
write_file("/tmp/args.sh",
           "echo \"zero=$0 one=$1 two=$2 count=$# all=$@\"\n")
write_file("/tmp/chain.sh",
           "echo alpha | wc -l\necho beta > /tmp/chain_out.txt\ncat /tmp/chain_out.txt\n")
write_file("/tmp/nest.sh",
           "if test 1 = 1; then\n  echo nested-if\nfi\n" ..
           "for i in 1 2; do\n  echo loop-$i\ndone\n")
write_file("/tmp/exit.sh", "exit 9\necho unreachable\n")

local st_sh, o_sh = run("hello.sh world")
check("a .sh file on PATH runs as a script and returns its exit code",
      st_sh == 7 and flat(o_sh):find("hello world", 1, true) ~= nil, o_sh)
local st_psh, o_psh = run("tool.psh a b")
check("a .psh file on PATH runs as a script",
      st_psh == 0 and flat(o_psh):find("tool 2 args", 1, true) ~= nil, o_psh)
local st_cd = select(1, run("cd /home/root"))
check("fixture: the shell can change into /home/root", st_cd == 0)
check("fixture: pwd follows the cd",
      flat(select(2, run("pwd"))):find("/home/root", 1, true) ~= nil)
local st_rel, o_rel = run("./rel.sh")
check("a relative script path runs as a script",
      st_rel == 0 and flat(o_rel):find("relative-script", 1, true) ~= nil, o_rel)
local st_plain, o_plain = run("./plain")
check("a path with no script suffix still runs when its shebang names psh",
      st_plain == 0 and flat(o_plain):find("plain-tool", 1, true) ~= nil, o_plain)
local st_pl2, o_pl2 = run("plain")
check("the same tool is also found by name on PATH",
      st_pl2 == 0 and flat(o_pl2):find("plain-tool", 1, true) ~= nil, o_pl2)
local st_ns, o_ns = run("/tmp/noshebang.sh")
check("a script without a shebang runs all the same",
      st_ns == 0 and flat(o_ns):find("no-shebang", 1, true) ~= nil, o_ns)
local st_fo, o_fo = run("/tmp/foreign.sh")
check("a foreign shebang is refused with status 126",
      st_fo == 126 and flat(o_fo):find("unsupported interpreter", 1, true) ~= nil,
      o_fo)
local st_ex, o_ex = run("/tmp/exit5.sh")
check("exit in a script becomes the status of the command", st_ex == 5, st_ex)
check("exit stops the script at that line",
      flat(o_ex):find("after", 1, true) == nil, o_ex)
check("the script body keeps running the earlier lines",
      flat(o_ex):find("before", 1, true) ~= nil, o_ex)

local st_arg, o_arg = run("/tmp/args.sh one two")
check("arguments reach $1 and $2",
      flat(o_arg):find("one=one two=two", 1, true) ~= nil, o_arg)
check("$# counts the arguments", flat(o_arg):find("count=2", 1, true) ~= nil, o_arg)
check("$0 names the running script",
      flat(o_arg):find("zero=/tmp/args.sh", 1, true) ~= nil, o_arg)
check("$@ joins the arguments", flat(o_arg):find("all=one two", 1, true) ~= nil,
      o_arg)
local _, o_shift = run("/tmp/args.sh one two; echo s=$?")
check("the caller keeps its own parameters after the script",
      flat(o_shift):find("s=0", 1, true) ~= nil, o_shift)

section("positional parameters: shift at script level and inside a function")

write_file("/tmp/shift.sh",
           "echo first=$1 count=$#\nshift\necho second=$1 count=$#\n" ..
           "shift\necho gone=$1 count=$#\n")
local _, o_shift2 = run("/tmp/shift.sh a b")
check("shift drops one positional parameter at a time",
      flat(o_shift2):find("first=a count=2", 1, true) ~= nil and
      flat(o_shift2):find("second=b count=1", 1, true) ~= nil and
      flat(o_shift2):find("gone= count=0", 1, true) ~= nil, o_shift2)

write_file("/tmp/shiftfn.sh",
           "f() {\n  shift\n  echo fn1=$1 count=$#\n}\nf p q r\necho outer=$1\n")
local _, o_sf = run("/tmp/shiftfn.sh x")
check("shift in a function shifts the function's own parameters only",
      flat(o_sf):find("fn1=q count=2", 1, true) ~= nil and
      flat(o_sf):find("outer=x", 1, true) ~= nil, o_sf)

local _, o_chain = run("/tmp/chain.sh")
check("pipes inside a script filter instead of echoing the left hand side",
      flat(o_chain):find("alpha", 1, true) == nil and
      flat(o_chain):match("^1") ~= nil, o_chain)
check("redirections inside a script write real files",
      fs.exists("/tmp/chain_out.txt") and flat(o_chain):find("beta", 1, true) ~= nil,
      o_chain)
local _, o_nest = run("/tmp/nest.sh")
check("control flow inside a script works (if / for)",
      flat(o_nest):find("nested-if", 1, true) ~= nil and
      flat(o_nest):find("loop-1", 1, true) ~= nil and
      flat(o_nest):find("loop-2", 1, true) ~= nil, o_nest)

section("control flow: case / while / until / break / continue / function return")

-- case / while / until / break / continue / functions, and the "&&" - "||"
-- chains that the "stop flag" used to cut short -------------------------------
write_file("/tmp/flow.sh",
           "case abc in\n  a*) echo case-glob ;;\n  *) echo case-any ;;\nesac\n" ..
           "case zzz in\n  a*) echo case-never ;;\n  *) echo case-other ;;\nesac\n" ..
           "while test -f /tmp/flag-w; do\n  echo while-body\n" ..
           "  rm /tmp/flag-w\ndone\n" ..
           "until test -f /tmp/flag-u; do\n  echo until-body\n" ..
           "  touch /tmp/flag-u\ndone\n" ..
           "for n in 1 2 3 4 5; do\n" ..
           "  test $n = 2 && continue\n" ..
           "  test $n = 4 && break\n" ..
           "  echo n=$n\ndone\n" ..
           "greet() {\n  echo fn-$1-$#\n  return 3\n}\n" ..
           "greet a b\necho fn=$?\n" ..
           "false && echo and-skipped || echo or-taken\n" ..
           "true && echo and-taken || echo or-skipped\n")
write_file("/tmp/flag-w", "")
pcall(fs.delete, "/tmp/flag-u")
local _, o_flow = run("/tmp/flow.sh")
check("a case arm with a wildcard matches",
      flat(o_flow):find("case-glob", 1, true) ~= nil and
      flat(o_flow):find("case-never", 1, true) == nil, o_flow)
check("the \"*)\" arm is the fallback of the subject that matches nothing",
      flat(o_flow):find("case-other", 1, true) ~= nil, o_flow)
check("while runs its body while the test holds, then exits",
      flat(o_flow):find("while-body", 1, true) ~= nil, o_flow)
check("until runs its body until the test holds",
      flat(o_flow):find("until-body", 1, true) ~= nil, o_flow)
check("continue skips one iteration and break ends the loop",
      flat(o_flow):find("n=1", 1, true) ~= nil and
      flat(o_flow):find("n=2", 1, true) == nil and
      flat(o_flow):find("n=3", 1, true) ~= nil and
      flat(o_flow):find("n=4", 1, true) == nil and
      flat(o_flow):find("n=5", 1, true) == nil, o_flow)
check("a function sees its own $1 / $#",
      flat(o_flow):find("fn-a-2", 1, true) ~= nil, o_flow)
check("return sets the status of the call", flat(o_flow):find("fn=3", 1, true) ~= nil,
      o_flow)
check("a failing left hand side still reaches the \"||\" branch",
      flat(o_flow):find("or-taken", 1, true) ~= nil and
      flat(o_flow):find("and-skipped", 1, true) == nil, o_flow)
check("a successful left hand side skips the \"||\" branch",
      flat(o_flow):find("and-taken", 1, true) ~= nil and
      flat(o_flow):find("or-skipped", 1, true) == nil, o_flow)
local _, o_status = run("hello.sh x; echo code=$?")
check("the script status survives into the calling shell",
      flat(o_status):find("code=7", 1, true) ~= nil, o_status)
local _, o_log = run("hello.sh x && echo ok")
check("a failing script stops the \"&&\" list",
      flat(o_log):find("ok", 1, true) == nil, o_log)

write_file("/tmp/comment.sh",
           "# a whole line comment\necho first # a trailing comment\n" ..
           "echo second\n")
local st_cm, o_cm = run("/tmp/comment.sh")
check("a comment ends at the end of its own line",
      st_cm == 0 and flat(o_cm):find("second", 1, true) ~= nil, o_cm)
check("a trailing comment is not printed",
      flat(o_cm):find("#", 1, true) == nil, o_cm)
local st_ml, o_ml = run("echo A\nexit 3")
check("a second line at the prompt is a second command, not an argument",
      st_ml == 3 and flat(o_ml):find("exit", 1, true) == nil, o_ml)

-- sourced script: exit leaves the shell, not just the script ----------------
local sourced = psh.feed("source /tmp/exit.sh")
check("source runs the file in the current shell and lets exit leave it",
      not sourced, tostring(sourced))
psh.run("echo after-source")

-- no execute bit -----------------------------------------------------------
perm.set_mode("/usr/local/bin/hello.sh", "rw-r--r--", "root")
check("fixture: the script is not executable by root",
      perm.can_exec("/usr/local/bin/hello.sh") == false)
local st_x, o_x = run("hello.sh x")
check("a script without the execute bit is refused with 126",
      st_x == 126 and flat(o_x):find("permission denied", 1, true) ~= nil, o_x)
perm.remove("/usr/local/bin/hello.sh")
check("with the mode restored the script runs again",
      select(1, run("hello.sh again")) == 7)

-- a script is not confused with a Lua command ------------------------------
write_file("/usr/local/bin/mixed.lua", "return 0\n")
check("a .lua command keeps its Lua path", select(1, run("mixed")) == 0)
local st_nf, o_nf = run("definitely-missing")
check("a missing command still reports 127",
      st_nf == 127 and flat(o_nf):find("command not found", 1, true) ~= nil, o_nf)

-- ============================================================
section("regression: the first three feature groups still behave")
-- ============================================================
local st_df = select(1, run("df"))
check("df still exits 0", st_df == 0, st_df)
local _, o_pipe = run("echo one two three | wc -w")
check("a plain pipeline still works", flat(o_pipe):find("3", 1, true) ~= nil, o_pipe)
local _, o_redir = run("echo hello > /tmp/redir.txt; cat /tmp/redir.txt")
check("plain redirection still works", flat(o_redir):find("hello", 1, true) ~= nil,
      o_redir)
local st_id, o_id = run("whoami")
check("whoami still reports the current user",
      st_id == 0 and flat(o_id):find("root", 1, true) ~= nil, o_id)

-- ============================================================
section("batch 2: grep")
-- ============================================================
-- The whole batch 2 section shares two scratch locals, so the main chunk of the
-- harness does not run into the Lua 5.1 limit of 200 active local slots.
local st, o
local function count(text, sub)
    local n, pos = 0, 1
    while true do
        local hit = text:find(sub, pos, true)
        if not hit then break end
        n = n + 1
        pos = hit + #sub
    end
    return n
end

write_file("/tmp/t1.txt", "alpha\nbeta\ngamma\nalpha\n")
write_file("/tmp/t2.txt", "one two\nthree four\n")
write_file("/tmp/num.txt", "3 charlie\n1 alpha\n2 bravo\n")
write_file("/tmp/csv.txt", "a,1,x\nb,2,y\nc,3,z\n")
write_file("/tmp/rep.txt", "aa\nbb\naa\naa\ncc\n")
fs.makeDir("/tmp/tree")
fs.makeDir("/tmp/tree/sub")
write_file("/tmp/tree/sub/deep.txt", "alpha deep\n")
write_file("/tmp/tree/top.txt", "nothing here\n")

st, o = run("grep alpha /tmp/t1.txt")
check("grep prints every matching line",
      st == 0 and count(o, "alpha") == 2, o)
st, o = run("grep -c beta /tmp/t1.txt")
check("grep -c counts the matching lines", flat(o):find("1") ~= nil, o)
st, o = run("grep -v alpha /tmp/t1.txt | wc -l")
check("grep -v drops the matches and feeds a pipe", flat(o):find("2") ~= nil, o)
st, o = run("grep -n gamma /tmp/t1.txt")
check("grep -n prefixes the line number",
      flat(o):find("3:gamma", 1, true) ~= nil, o)
st, o = run("grep -i BETA /tmp/t1.txt")
check("grep -i folds the case", flat(o):find("beta", 1, true) ~= nil, o)
st, o = run("grep -q alpha /tmp/t1.txt")
check("grep -q is silent with status 0 on a match", st == 0 and flat(o) == "", o)
st = run("grep -q zzz /tmp/t1.txt")
check("grep -q is status 1 without a match", st == 1, st)
st = run("grep zzz /tmp/t1.txt")
check("grep is status 1 when nothing matched", st == 1, st)
st, o = run("grep -l alpha /tmp/t*.txt")
check("grep -l lists the matching file through a glob",
      flat(o):find("/tmp/t1.txt", 1, true) ~= nil and
      flat(o):find("t2.txt", 1, true) == nil, o)
st, o = run("grep -r alpha /tmp/tree")
check("grep -r walks the directory tree",
      flat(o):find("deep.txt:alpha deep", 1, true) ~= nil, o)
st, o = run("grep -E 'a(lp)ha' /tmp/t1.txt | wc -l")
check("grep -E compiles extended regular expressions",
      flat(o):find("2") ~= nil, o)
st, o = run("n=2; grep -c alpha /tmp/t1.txt > /tmp/cnt.txt; cat /tmp/cnt.txt")
check("a grep result lands in a redirection",
      flat(o):find("2", 1, true) ~= nil, o)

-- ============================================================
section("batch 2: sed")
-- ============================================================
st, o = run("sed 's/alpha/ALPHA/' /tmp/t1.txt")
check("sed s/// replaces the first match on every line",
      st == 0 and count(o, "ALPHA") == 2, o)
st, o = run("sed 's/a/z/g' /tmp/t1.txt | head -n 1")
check("sed s///g replaces every match and composes with a pipe",
      flat(o):find("zlphz", 1, true) ~= nil, o)
st, o = run("sed -n '2p' /tmp/t1.txt")
check("sed -n with p prints only the addressed line",
      flat(o):find("beta", 1, true) ~= nil and
      flat(o):find("alpha", 1, true) == nil, o)
st, o = run("sed '2d' /tmp/t1.txt")
check("sed d deletes the addressed line",
      flat(o):find("beta", 1, true) == nil and
      flat(o):find("gamma", 1, true) ~= nil, o)
st, o = run("sed -n '2,3p' /tmp/t1.txt")
check("sed keeps a line range",
      flat(o):find("beta", 1, true) ~= nil and
      flat(o):find("gamma", 1, true) ~= nil and
      flat(o):find("alpha", 1, true) == nil, o)
st, o = run("sed 's/\\(a\\)\\(l\\)/\\2\\1/' /tmp/t1.txt | head -n 1")
check("sed capture groups and back references",
      flat(o):find("lapha", 1, true) ~= nil, o)
st, o = run("sed 's/alpha/[&]/' /tmp/t1.txt | head -n 1")
check("sed & stands for the matched text",
      flat(o):find("[alpha]", 1, true) ~= nil, o)
write_file("/tmp/sed_i.txt", "alpha\nbeta\n")
st = run("sed -i 's/alpha/omega/' /tmp/sed_i.txt")
st, o = run("cat /tmp/sed_i.txt")
check("sed -i rewrites the file in place",
      flat(o):find("omega", 1, true) ~= nil and
      flat(o):find("beta", 1, true) ~= nil, o)

-- ============================================================
section("batch 2: awk")
-- ============================================================
st, o = run("awk '{print $1}' /tmp/t2.txt")
check("awk $1 selects the first field",
      st == 0 and flat(o):find("one", 1, true) ~= nil and
      flat(o):find("three", 1, true) ~= nil, o)
st, o = run("awk -F, '{print $2}' /tmp/csv.txt | tail -n 1")
check("awk -F takes a custom separator", flat(o):find("3", 1, true) ~= nil, o)
st, o = run("awk 'NR == 2 {print NF}' /tmp/t2.txt")
check("awk NR and NF are available", flat(o):find("2", 1, true) ~= nil, o)
st, o = run("awk 'BEGIN {print \"begin\"} {print $0} END {print \"end\"}' /tmp/t2.txt")
check("awk BEGIN and END run around the records",
      flat(o):find("begin", 1, true) ~= nil and
      flat(o):find("end", 1, true) ~= nil and
      flat(o):find("one two", 1, true) ~= nil, o)
st, o = run("awk '$1 > 2' /tmp/num.txt")
check("awk evaluates a condition",
      flat(o):find("charlie", 1, true) ~= nil and
      flat(o):find("bravo", 1, true) == nil, o)
st, o = run("awk '{printf \"%s|\", $2}' /tmp/t2.txt")
check("awk printf keeps its format", flat(o):find("two|four|", 1, true) ~= nil, o)

-- ============================================================
section("batch 2: sort")
-- ============================================================
write_file("/tmp/srt.txt", "banana\napple\ncherry\napple\n")
st, o = run("sort /tmp/srt.txt")
check("sort orders by dictionary",
      st == 0 and flat(o):find("apple banana cherry", 1, true) ~= nil, o)
st, o = run("sort -r /tmp/srt.txt | head -n 1")
check("sort -r reverses the order", flat(o):find("cherry", 1, true) ~= nil, o)
st, o = run("sort -u /tmp/srt.txt")
check("sort -u drops the repeated lines", count(flat(o), "apple") == 1, o)
write_file("/tmp/srtn.txt", "10 ten\n9 nine\n100 hundred\n")
st, o = run("sort -n -k1 /tmp/srtn.txt | head -n 1")
check("sort -n orders numerically", flat(o):find("9 nine", 1, true) ~= nil, o)
write_file("/tmp/srtk.txt", "x,3\nz,1\ny,2\n")
st, o = run("sort -t, -k2 /tmp/srtk.txt")
check("sort -t and -k pick a separator aware key",
      flat(o):find("z,1 y,2 x,3", 1, true) ~= nil, o)

-- ============================================================
section("batch 2: uniq")
-- ============================================================
write_file("/tmp/uniq2.txt", "red\nred\nblue\ngreen\ngreen\n")
st, o = run("uniq -c /tmp/uniq2.txt")
check("uniq -c counts the adjacent runs",
      st == 0 and flat(o):find("2 red", 1, true) ~= nil and
      flat(o):find("1 blue", 1, true) ~= nil, o)
st, o = run("uniq -d /tmp/uniq2.txt")
check("uniq -d keeps only the repeated lines",
      flat(o):find("red", 1, true) ~= nil and
      flat(o):find("green", 1, true) ~= nil and
      flat(o):find("blue", 1, true) == nil, o)
st, o = run("uniq -u /tmp/uniq2.txt")
check("uniq -u keeps only the single lines",
      flat(o):find("blue", 1, true) ~= nil and
      flat(o):find("red", 1, true) == nil, o)

-- ============================================================
section("batch 2: cut")
-- ============================================================
st, o = run("cut -d, -f2 /tmp/csv.txt")
check("cut -d -f selects a field",
      st == 0 and flat(o):find("1 2 3", 1, true) ~= nil, o)
st, o = run("cut -c1-3 /tmp/t2.txt | head -n 1")
check("cut -c selects a character range", flat(o):find("one", 1, true) ~= nil, o)
st, o = run("cut -d, -f1,3 /tmp/csv.txt | head -n 1")
check("cut takes a field list", flat(o):find("a,x", 1, true) ~= nil, o)

-- ============================================================
section("batch 2: tr")
-- ============================================================
st, o = run("tr a-z A-Z < /tmp/t2.txt")
check("tr maps SET1 to SET2 with an input redirection",
      st == 0 and flat(o):find("ONE TWO", 1, true) ~= nil, o)
st, o = run("echo hello | tr -d l")
check("tr -d deletes the characters of SET1",
      flat(o):find("heo", 1, true) ~= nil, o)
st, o = run("echo 'a   b' | tr -s ' '")
check("tr -s squeezes the repeats", flat(o):find("a b", 1, true) ~= nil, o)
st, o = run("echo mixed | tr '[:lower:]' '[:upper:]'")
check("tr expands the [:class:] names", flat(o):find("MIXED", 1, true) ~= nil, o)

-- ============================================================
section("batch 2: head and tail")
-- ============================================================
st, o = run("head -n 2 /tmp/t1.txt")
check("head -n keeps the first lines",
      st == 0 and flat(o):find("alpha beta", 1, true) ~= nil and
      flat(o):find("gamma", 1, true) == nil, o)
st, o = run("head -2 /tmp/t1.txt | wc -l")
check("head accepts the shorthand -N", flat(o):find("2") ~= nil, o)
st, o = run("tail -n 1 /tmp/t1.txt")
check("tail -n keeps the last lines", flat(o):find("alpha", 1, true) ~= nil, o)
st, o = run("tail -n +3 /tmp/t1.txt")
check("tail -n +N starts at the Nth line",
      flat(o):find("gamma", 1, true) ~= nil and
      flat(o):find("beta", 1, true) == nil, o)
st, o = run("head -n 3 /tmp/t1.txt | tail -n 1")
check("head and tail compose in a pipeline",
      flat(o):find("gamma", 1, true) ~= nil, o)

-- ============================================================
section("batch 2: wc, tee and xargs")
-- ============================================================
st, o = run("wc -l /tmp/t1.txt")
check("wc -l counts the lines",
      st == 0 and flat(o):find("4", 1, true) ~= nil, o)
st, o = run("echo one two three | wc -w")
check("wc -w counts the words of the stage input",
      flat(o):find("3", 1, true) ~= nil, o)
st, o = run("wc -c /tmp/t2.txt")
check("wc -c counts the characters", flat(o):find("19", 1, true) ~= nil, o)
st, o = run("wc /tmp/t1.txt")
check("wc without a flag prints the three columns",
      flat(o):find("4 4 23", 1, true) ~= nil, o)
st, o = run("echo aaa > /tmp/tw.txt; echo bbb >> /tmp/tw.txt; wc -l /tmp/tw.txt")
check("wc reads a file written by the redirections",
      flat(o):find("2", 1, true) ~= nil, o)

st, o = run("echo hi | tee /tmp/tee1.txt | wc -l")
check("tee passes the input on while it writes a copy",
      st == 0 and flat(o):find("1", 1, true) ~= nil, o)
st, o = run("cat /tmp/tee1.txt")
check("tee wrote the copy", flat(o):find("hi", 1, true) ~= nil, o)
st, o = run("echo more | tee -a /tmp/tee1.txt > /tmp/tee_sink.txt; cat /tmp/tee1.txt")
check("tee -a appends to the existing file",
      flat(o):find("hi more", 1, true) ~= nil, o)

st, o = run("echo a b c | xargs -n 1 echo | wc -l")
check("xargs -n batches and composes with pipes",
      st == 0 and flat(o):find("3", 1, true) ~= nil, o)
st, o = run("echo one | xargs -I{} echo 'got {}'")
check("xargs -I substitutes the placeholder",
      flat(o):find("got one", 1, true) ~= nil, o)
st, o = run("grep alpha /tmp/t1.txt | xargs -n 1 echo | head -n 1")
check("xargs consumes a pipe from a text filter",
      flat(o):find("alpha", 1, true) ~= nil, o)

-- ============================================================
section("batch 2: combination with the earlier batches")
-- ============================================================
st, o = run("for f in /tmp/t*.txt; do wc -l $f; done")
check("glob and control flow drive a text tool",
      flat(o):find("t1.txt", 1, true) ~= nil and
      flat(o):find("t2.txt", 1, true) ~= nil, o)
st, o = run("n=2; head -n $n /tmp/t1.txt | tail -n 1")
check("a variable feeds an option of a text tool",
      flat(o):find("beta", 1, true) ~= nil, o)
st, o = run("if grep -q alpha /tmp/t1.txt; then echo yes; else echo no; fi")
check("a text tool drives the control flow status",
      st == 0 and flat(o):find("yes", 1, true) ~= nil, o)
st, o = run("cat /tmp/t1.txt | grep -v beta | sort -u | wc -l")
check("the four stage pipeline agrees", flat(o):find("2", 1, true) ~= nil, o)
st, o = run("tr a-z A-Z < /tmp/t2.txt | grep THREE | cut -c1-5")
check("redirection, text filter and cut chain together",
      flat(o):find("THREE", 1, true) ~= nil, o)

-- ============================================================
section("entry point: psh <script> <args>")
-- ============================================================
-- The real entry chunk is started again without the test hook, with argv, the
-- way the console starts it ("psh /tmp/entry.sh E1").
_G.__PSH_TEST = nil
write_file("/tmp/entry.sh", "#!/usr/bin/env psh\necho \"entry=$1\"\nexit 9\n")
clear()
local entry = assert(loadfile(PROJ .. "/usr/psh.lua"))
local code = entry("/tmp/entry.sh", "E1")
check("psh FILE returns the exit code of the script", code == 9,
      tostring(code))
check("psh FILE passes its arguments through",
      out():find("entry=E1", 1, true) ~= nil, out())

clear()
local entry2 = assert(loadfile(PROJ .. "/usr/psh.lua"))
local code2 = entry2("-c", "echo inline; exit 4")
check("psh -c still returns the status of the line", code2 == 4,
      tostring(code2))
check("psh -c runs the line", out():find("inline", 1, true) ~= nil, out())

clear()
local entry3 = assert(loadfile(PROJ .. "/usr/psh.lua"))
local code3 = entry3("/tmp/missing-script.sh")
check("psh FILE reports a missing script with 127", code3 == 127,
      tostring(code3))

-- ============================================================
section("the boot guard: a command may not overwrite a boot file")
-- ============================================================
-- The machine boots by running files in fixed places. Overwriting one either stops
-- the computer booting or makes it boot something else, and the only way back is to
-- reinstall from outside -- so the shell refuses by default, and the refusal is a
-- machine rule (set -o bootguard, /etc/boot.conf) rather than a per-command flag.
do
    local protect = require("protect")
    local function read(path)
        if not fs.exists(path) then return nil end
        local h = fs.open(path, "r")
        if not h then return nil end
        local t = h.readAll()
        h.close()
        return t
    end

    -- the default, on a machine with no /etc/boot.conf
    if fs.exists("/etc/boot.conf") then fs.delete("/etc/boot.conf") end
    protect.reload()
    check("the guard is on by default", protect.enabled() == true)
    check("and the exit rule with it", protect.no_exit() == true)

    -- what is and is not a boot file
    check("startup.lua is a boot file", protect.is_boot_file("/startup.lua") == true)
    check("usr/psh.lua is a boot file", protect.is_boot_file("/usr/psh.lua") == true)
    check("firstboot.lua is a boot file",
          protect.is_boot_file("/firstboot.lua") == true)
    check("anything under lib/ is a boot file",
          protect.is_boot_file("/lib/perm.lua") == true)
    check("a package is NOT a boot file",
          protect.is_boot_file("/usr/pkgs/foo/lib/foo.lua") == false)
    check("an ordinary file is not a boot file",
          protect.is_boot_file("/tmp/x.lua") == false)
    check("a name that merely starts like one is not",
          protect.is_boot_file("/startup.lua.bak") == false)
    check("the path is normalised before the check",
          protect.is_boot_file("/lib/../lib/perm.lua") == true and
          protect.is_boot_file("/lib/./perm.lua") == true)
    check("a relative path is never a boot file",
          protect.is_boot_file("lib/perm.lua") == false)

    -- the check itself
    local okc, why = protect.check("/startup.lua")
    check("the check refuses a boot file", okc == false, tostring(okc))
    check("and the message says how to allow it",
          tostring(why):find("bootguard", 1, true) ~= nil, tostring(why))
    check("the check allows an ordinary file",
          protect.check("/tmp/x.lua") == true)

    -- through the shell: a refused redirect must FAIL, not report success
    perm.set_current_user("root")
    write_file("/tmp/keepme", "original")
    local st_w, o_w = run("echo REPLACED > /startup.lua")
    check("a redirect onto a boot file is refused",
          o_w:find("boot file is protected", 1, true) ~= nil, o_w)
    check("and it FAILS, so a script does not carry on",
          st_w == 1, tostring(st_w))
    check("the boot file was not created",
          fs.exists("/startup.lua") == false)
    local st_c, o_c = run("cp /tmp/keepme /usr/psh.lua")
    check("cp onto a boot file is refused too",
          o_c:find("boot file is protected", 1, true) ~= nil, o_c)
    check("and cp fails as well", st_c == 1, tostring(st_c))
    local st_l, o_l = run("echo x > /lib/perm.lua")
    check("a write under lib/ is refused", st_l == 1 and
          o_l:find("boot file is protected", 1, true) ~= nil, o_l)
    local st_ok = run("echo fine > /tmp/ordinary.txt")
    check("an ordinary write still works", st_ok == 0 and
          fs.exists("/tmp/ordinary.txt") == true, tostring(st_ok))
    check("and the file really holds the text",
          (read("/tmp/ordinary.txt") or ""):find("fine", 1, true) ~= nil,
          tostring(read("/tmp/ordinary.txt")))

    -- the switch is root only
    perm.set_current_user("alice")
    local st_g, o_g = run("set +o bootguard")
    check("a non-root user may not turn the guard off",
          st_g == 1 and o_g:find("only root", 1, true) ~= nil,
          tostring(st_g) .. " " .. o_g)
    check("and it is still on", protect.enabled() == true)
    check("no rule was written", fs.exists("/etc/boot.conf") == false,
          tostring(read("/etc/boot.conf")))

    -- root may, and then the write goes through
    perm.set_current_user("root")
    local st_r, o_r = run("set +o bootguard")
    check("root may turn the guard off", st_r == 0, tostring(st_r) .. " " .. o_r)
    check("the rule is recorded on the machine", protect.enabled() == false)
    check("and it is written to /etc/boot.conf",
          (read("/etc/boot.conf") or ""):find("boot_guard=0", 1, true) ~= nil,
          tostring(read("/etc/boot.conf")))
    local st_rw = run("echo REPLACED > /startup.lua")
    check("with the guard off the write goes through",
          st_rw == 0 and (read("/startup.lua") or ""):find("REPLACED", 1, true) ~= nil,
          tostring(st_rw) .. " " .. tostring(read("/startup.lua")))
    run("set -o bootguard")
    check("and turning it back on clears the rule from the file",
          protect.enabled() == true and
          (read("/etc/boot.conf") or ""):find("boot_guard", 1, true) == nil,
          tostring(read("/etc/boot.conf")))
    if fs.exists("/startup.lua") then fs.delete("/startup.lua") end
    if fs.exists("/etc/boot.conf") then fs.delete("/etc/boot.conf") end
    protect.reload()
end

-- ============================================================
section("the shell may not be left (set -o noexit)")
-- ============================================================
-- "psh cannot be exited" is a rule about the SESSION, and the distinction is load
-- bearing: a script ending in "exit 3", and "psh -c 'exit 3'", both use exit to
-- return a STATUS. Refusing exit in the built-in would break every one of them.
do
    local protect = require("protect")
    if fs.exists("/etc/boot.conf") then fs.delete("/etc/boot.conf") end
    protect.reload()
    perm.set_current_user("root")

    -- a session may not leave
    psh.set_interactive(true)
    local alive = psh.feed("exit")
    check("a session may not be left by 'exit'", alive == true, tostring(alive))
    check("and the shell says why",
          out():find("not allowed to be left", 1, true) ~= nil, out())
    check("the status reports the refusal", psh.vars.get("?") == "1",
          tostring(psh.vars.get("?")))
    local alive2 = psh.feed("exit 3")
    check("nor by 'exit N', which takes the other route",
          alive2 == true, tostring(alive2))
    check("the status of the exit is not the code asked for",
          psh.vars.get("?") == "1", tostring(psh.vars.get("?")))
    local alive3 = psh.feed("logout")
    check("nor by 'logout'", alive3 == true, tostring(alive3))
    psh.set_interactive(false)

    -- a one-shot run is NOT a session: this is the property that keeps scripts
    -- and the watchdog working
    local one_shot = psh.feed("exit 3")
    check("a one-shot run may still exit (scripts return a status this way)",
          one_shot == false, tostring(one_shot))
    check("and it carries the code", psh.vars.get("?") == "3", tostring(psh.vars.get("?")))

    -- root may allow it again
    psh.set_interactive(true)
    local st_off = run("set +o noexit")
    check("root may allow leaving the shell", st_off == 0, tostring(st_off))
    check("the rule is recorded", protect.no_exit() == false)
    local allowed = psh.feed("exit")
    check("with the rule off the session may leave", allowed == false,
          tostring(allowed))
    psh.set_interactive(false)
    run("set -o noexit")
    check("the rule is back on", protect.no_exit() == true)
    if fs.exists("/etc/boot.conf") then fs.delete("/etc/boot.conf") end
    protect.reload()
end

-- ============================================================
section("Ctrl+C stops the running command (lib/interrupt.lua)")
-- ============================================================
-- On Linux Ctrl+C sends SIGINT to the foreground program: the program stops, the
-- shell lives, the prompt comes back with 130. CraftOS is single threaded and
-- cooperative, so there is no signal -- what is possible is to interpose on the
-- one place a cooperative program gives control back, os.pullEvent(Raw). The
-- wrapper raises the same "Terminated" error the ROM raises for Ctrl+T, which the
-- shell already understands.
do
    local interrupt = require("interrupt")
    check("the interrupt layer installs", interrupt.install() == true)
    check("it is installed", interrupt.is_installed() == true)

    -- NOT while the editor owns the keyboard: at the prompt Ctrl+C keeps its old
    -- meaning (discard the half typed line)
    check("nothing is in the foreground to begin with",
          interrupt.in_command() == false)
    os.queueEvent("key", keys.leftCtrl)
    os.queueEvent("key", keys.c)
    local ok_prompt, kind_prompt, code_prompt = pcall(function()
        return os.pullEventRaw()
    end)
    check("with no command running Ctrl+C is a plain key event",
          ok_prompt == true and kind_prompt == "key" and code_prompt == keys.leftCtrl,
          tostring(ok_prompt) .. " " .. tostring(kind_prompt) .. "/" ..
          tostring(code_prompt))
    -- BOTH halves of the chord are consumed here. Ctrl produces two key events,
    -- and leaving the second in the queue makes the next assertion see it instead
    -- of its own event. (The first draft pulled only one and failed for exactly
    -- that reason: the leftover "c" arrived as the next event, so the check below
    -- read code 46 where it wanted 29.)
    local ok_p2, kind_p2 = pcall(function() return os.pullEventRaw() end)
    check("the second half of the chord is delivered too, uninterrupted",
          ok_p2 == true and kind_p2 == "key",
          tostring(ok_p2) .. " " .. tostring(kind_p2))

    -- WHILE a command runs: the second key event raises the interrupt
    interrupt.begin_command()
    check("a command is now in the foreground", interrupt.in_command() == true)
    os.queueEvent("key", keys.leftCtrl)
    os.queueEvent("key", keys.c)
    local ok1, kind1, code1 = pcall(function() return os.pullEventRaw() end)
    check("the Ctrl key event itself is delivered first",
          ok1 == true and kind1 == "key" and code1 == keys.leftCtrl,
          tostring(ok1) .. " " .. tostring(kind1) .. "/" .. tostring(code1))
    local ok2, err2 = pcall(function() return os.pullEventRaw() end)
    check("the C key raises the interrupt instead of being delivered",
          ok2 == false, tostring(ok2) .. " " .. tostring(err2))
    check("the error is the one the shell treats as an interrupt",
          tostring(err2):find("Terminated", 1, true) ~= nil, tostring(err2))

    -- the case that would otherwise be UNINTERRUPTIBLE: a program waiting on a
    -- filter, where the ROM's own filter drops key events before the caller sees
    -- them. The wrapper applies the filter itself for exactly this reason.
    os.queueEvent("key", keys.leftCtrl)
    os.queueEvent("key", keys.c)
    local okf, errf = pcall(function() return os.pullEventRaw("char") end)
    check("a filtered wait is still interruptible",
          okf == false and tostring(errf):find("Terminated", 1, true) ~= nil,
          tostring(okf) .. " " .. tostring(errf))

    -- and the filter still works when nothing is pressed
    interrupt.end_command()
    check("the foreground flag is cleared again",
          interrupt.in_command() == false)
    os.queueEvent("char", "z")
    -- Two return values: the event NAME and its argument. pcall keeps only the
    -- first, so the pull is wrapped to collect both.
    local okc2, ev_name, ev_arg = pcall(function()
        local a, b = os.pullEventRaw("char")
        return a, b
    end)
    check("an ordinary filtered wait still returns its event",
          okc2 == true and ev_name == "char" and ev_arg == "z",
          tostring(okc2) .. " " .. tostring(ev_name) .. "/" .. tostring(ev_arg))

    -- A PULL FROM ANOTHER COROUTINE IS NOT THE COMMAND'S PULL, and getting this
    -- wrong shuts the machine down. Measured on a real machine: bios.lua runs the
    -- shell inside parallel.waitForAny, so while psh waits the ROM's DISPATCHER is
    -- the coroutine calling os.pullEventRaw. Raising there unwound the dispatcher
    -- (interrupt.lua watch -> pullEventRaw -> rom/apis/parallel.lua:76 ->
    -- bios.lua:905), bios printed "Terminated", waited for a key and shut the
    -- computer down -- and the command never saw its interrupt. The wrapper now
    -- fires only for the coroutine that began the command.
    interrupt.begin_command()
    local outside = {}
    local other = coroutine.create(function()
        for i = 1, 2 do
            local kind, code = os.pullEventRaw()
            outside[i] = tostring(kind) .. ":" .. tostring(code)
        end
    end)
    os.queueEvent("key", keys.leftCtrl)
    os.queueEvent("key", keys.c)
    local resumed = coroutine.resume(other)
    check("another coroutine's pull is not turned into an interrupt",
          resumed == true and
          outside[1] == "key:" .. tostring(keys.leftCtrl) and
          outside[2] == "key:" .. tostring(keys.c),
          tostring(resumed) .. " " .. table.concat(outside, ","))

    -- while the command's own coroutine still raises
    os.queueEvent("key", keys.leftCtrl)
    os.queueEvent("key", keys.c)
    local ok_own_a = pcall(function() return os.pullEventRaw() end)
    local ok_own_b, err_own = pcall(function() return os.pullEventRaw() end)
    check("the command's own coroutine is still interrupted",
          ok_own_a == true and ok_own_b == false and
          tostring(err_own):find("Terminated", 1, true) ~= nil,
          tostring(ok_own_b) .. " " .. tostring(err_own))
    interrupt.end_command()

    check("the layer uninstalls", interrupt.uninstall() == true)
    check("and is no longer installed", interrupt.is_installed() == false)
end

-- ============================================================
section("boot order: the ROM's disk startup is turned off")
-- ============================================================
-- CraftOS consults two settings in /.settings BEFORE it runs any startup of ours
-- (host bios.lua -> rom/startup.lua):
--
--   shell.allow_startup       run the machine's own /startup.lua
--   shell.allow_disk_startup  run a startup found on an attached DISK
--
-- The second one is a hijack, not an addition: rom/startup.lua assigns the disk's
-- scripts to tUserStartups, REPLACING what it found in the root, so the shell never
-- starts and nothing in this repository runs. That is why lib/protect.lua cannot
-- defend against it (it runs inside startup.lua, which never gets to run) and why
-- the defence has to be this file, written before the next boot.
do
    local bios = require("bios")
    local function read(path)
        if not fs.exists(path) then return nil end
        local h = fs.open(path, "r")
        if not h then return nil end
        local t = h.readAll()
        h.close()
        return t
    end

    if fs.exists("/.settings") then fs.delete("/.settings") end
    settings.unset("shell.allow_disk_startup")
    settings.unset("shell.allow_startup")

    -- what the ROM would do when the key is absent: its own default
    check("with no setting the ROM's default for a disk startup is reported",
          bios.rom_setting("shell.allow_disk_startup") == true,
          tostring(bios.rom_setting("shell.allow_disk_startup")))
    check("and for the machine's own startup it is true as well",
          bios.rom_setting("shell.allow_startup") == true,
          tostring(bios.rom_setting("shell.allow_startup")))

    -- enforce brings both to what this machine wants
    local changed = bios.enforce_rom_settings()
    check("enforcing changes the disk key", type(changed) == "table" and
          #changed >= 1, tostring(#(changed or {})))
    check("the disk startup is now off in the file the ROM reads",
          bios.rom_setting("shell.allow_disk_startup") == false,
          tostring(bios.rom_setting("shell.allow_disk_startup")))
    check("the machine's own startup is left on",
          bios.rom_setting("shell.allow_startup") == true,
          tostring(bios.rom_setting("shell.allow_startup")))
    check("the file was written", fs.exists("/.settings") == true)

    -- THE FORMAT MATTERS and this is the assertion that pins it: the ROM's reader
    -- (textutils.unserialize) PREPENDS "return ", so /.settings must be a bare
    -- table literal. A file starting with "return", or carrying a comment, parses
    -- to nil and every key silently keeps its ROM default -- a machine that looks
    -- protected and is not. The first attempt at this shipped exactly that file.
    local text = read("/.settings") or ""
    check("the settings file is a bare table, not a return statement",
          text:sub(1, 1) == "{", text:sub(1, 40))
    check("and it carries no comment, which the reader cannot skip",
          text:find("--", 1, true) == nil, text:sub(1, 60))
    check("the ROM's own reader parses it",
          type(textutils.unserialize(text)) == "table",
          tostring(type(textutils.unserialize(text))))

    -- a hand-edited file does not survive a boot: the value is restored
    local data = textutils.unserialize(text) or {}
    data["shell.allow_disk_startup"] = true
    local h = fs.open("/.settings", "w")
    h.write(textutils.serialize(data))
    h.close()
    check("a hand-edited file really does re-open the machine",
          bios.rom_setting("shell.allow_disk_startup") == true)
    local again = bios.enforce_rom_settings()
    check("enforcing closes it again on the next boot",
          bios.rom_setting("shell.allow_disk_startup") == false,
          tostring(bios.rom_setting("shell.allow_disk_startup")))
    check("and it reports what it changed",
          type(again) == "table" and #again == 1 and
          again[1] == "shell.allow_disk_startup", table.concat(again or {}, ","))

    -- deleting the file is the same as hand editing: the ROM default comes back,
    -- so enforcement is what keeps a machine safe, not the file's presence
    fs.delete("/.settings")
    check("with the file gone the ROM default is back",
          bios.rom_setting("shell.allow_disk_startup") == true)
    bios.enforce_rom_settings()
    check("enforcing rewrites it", fs.exists("/.settings") == true and
          bios.rom_setting("shell.allow_disk_startup") == false)

    -- and the switch is settable from the screen, through the same writer
    bios.set_rom_setting("shell.allow_disk_startup", true)
    check("the screen can turn a disk startup back on",
          bios.rom_setting("shell.allow_disk_startup") == true)
    bios.set_rom_setting("shell.allow_disk_startup", false)
    check("and off again", bios.rom_setting("shell.allow_disk_startup") == false)

    -- A CHOICE MADE ON THE SCREEN MUST SURVIVE THE NEXT BOOT.
    -- This is the bug the first version shipped: enforcement restored a hardcoded
    -- policy, so turning the entry ON appeared to work and the next boot silently
    -- set it back -- the menu entry was a lie. The fix separates POLICY (what the
    -- installation insists on, in this file) from CHOICE (what the operator
    -- picked, recorded in /etc/bios.conf).
    if fs.exists("/etc/bios.conf") then fs.delete("/etc/bios.conf") end
    bios.set_rom_choice("shell.allow_disk_startup", nil)
    check("with no choice the installation's policy applies",
          bios.wanted_rom_setting("shell.allow_disk_startup") == false)
    check("and the policy is off for a disk startup",
          bios.rom_default("shell.allow_disk_startup") == true,
          "the ROM's own default is true; the policy deliberately disagrees")

    bios.set_rom_setting("shell.allow_disk_startup", true)
    check("the screen records the choice", bios.rom_choice("shell.allow_disk_startup") == true)
    check("and the choice is what the machine now wants",
          bios.wanted_rom_setting("shell.allow_disk_startup") == true)
    check("the choice is kept in /etc/bios.conf, not in /.settings",
          (read("/etc/bios.conf") or ""):find("rom.shell.allow_disk_startup=1",
                                              1, true) ~= nil,
          tostring(read("/etc/bios.conf")))
    local nochange = bios.enforce_rom_settings()
    check("the NEXT BOOT does not undo the operator's choice",
          #nochange == 0, table.concat(nochange, ","))
    check("the ROM still sees it on", bios.rom_setting("shell.allow_disk_startup") == true)

    -- ... while an edit that bypasses the screen is still repaired
    local d2 = textutils.unserialize(read("/.settings") or "") or {}
    d2["shell.allow_disk_startup"] = false
    local h2 = fs.open("/.settings", "w")
    h2.write(textutils.serialize(d2))
    h2.close()
    check("a hand edit is still overruled by the recorded choice",
          bios.enforce_rom_settings()[1] == "shell.allow_disk_startup",
          tostring(bios.rom_setting("shell.allow_disk_startup")))

    -- and clearing the choice puts the key back on the policy
    bios.set_rom_choice("shell.allow_disk_startup", nil)
    check("clearing the choice returns the key to the policy",
          bios.wanted_rom_setting("shell.allow_disk_startup") == false)
    bios.enforce_rom_settings()
    check("and enforcement closes it again",
          bios.rom_setting("shell.allow_disk_startup") == false,
          tostring(bios.rom_setting("shell.allow_disk_startup")))

    fs.delete("/.settings")
    if fs.exists("/etc/bios.conf") then fs.delete("/etc/bios.conf") end
end

-- ============================================================
section("the BIOS screen can reach every CraftOS setting")
-- ============================================================
-- The ROM's own "set" command is the editor for /.settings, and it needs a
-- working shell. A machine whose shell will not start is exactly when someone
-- needs to read or change one of those settings, so the screen lists and changes
-- ANY setting the ROM knows, through the same settings API "set" uses.
--
-- The distinction the screen has to keep straight: only the keys in ROM_KEYS are
-- POLICY (enforced at every boot, recorded in /etc/bios.conf). Everything else is
-- the ROM's own setting, which this project neither enforces nor records.
do
    local bios = require("bios")
    if fs.exists("/etc/bios.conf") then fs.delete("/etc/bios.conf") end
    if fs.exists("/.settings") then fs.delete("/.settings") end

    local items = bios.list_rom_settings()
    check("the browser lists the ROM's settings", type(items) == "table" and #items > 0,
          tostring(#(items or {})))
    local by_name = {}
    for _, item in ipairs(items) do by_name[item.name] = item end
    -- The lookups below are guarded: a browser that returned nothing would make
    -- by_name["..."] nil, and indexing nil reports a crash rather than a failed
    -- assertion -- which hides the very thing under test behind a stack trace.
    local ac = by_name["shell.autocomplete"]
    local pol = by_name["shell.allow_disk_startup"]
    check("it includes a setting this project does not own", ac ~= nil,
          "shell.autocomplete")
    check("it includes the boot policy key", pol ~= nil)
    check("and marks that one as policy", pol ~= nil and pol.policy == true,
          tostring(pol and pol.policy))
    check("while an ordinary setting is NOT marked policy",
          ac ~= nil and ac.policy == false, tostring(ac and ac.policy))
    check("the list is sorted",
          (function()
              for i = 2, #items do
                  if items[i - 1].name > items[i].name then return false end
              end
              return true
          end)(), table.concat((function()
              local n = {} for _, i in ipairs(items) do n[#n+1] = i.name end
              return n end)(), ","))

    -- changing an ordinary setting, the way the "set" command would
    local ok_set = bios.set_any_rom_setting("shell.autocomplete", "false", "boolean")
    check("an ordinary setting can be changed", ok_set == true, tostring(ok_set))
    check("and it takes the BOOLEAN, not the string",
          settings.get("shell.autocomplete") == false,
          tostring(settings.get("shell.autocomplete")))
    check("it is written to /.settings", fs.exists("/.settings") == true)
    check("the ROM's own reader sees it",
          (textutils.unserialize((function()
              local h = fs.open("/.settings", "r"); local t = h.readAll(); h.close()
              return t end)()) or {})["shell.autocomplete"] == false)

    -- an ordinary setting is NOT enforced: this project does not own it, so a
    -- hand edit must survive a boot
    bios.enforce_rom_settings()
    check("enforcement does not touch a setting this project does not own",
          settings.get("shell.autocomplete") == false,
          tostring(settings.get("shell.autocomplete")))

    -- a policy key changed here goes through the choice path instead
    bios.set_any_rom_setting("shell.allow_disk_startup", "true", "boolean")
    check("a policy key changed here is recorded as a choice",
          bios.rom_choice("shell.allow_disk_startup") == true,
          tostring(bios.rom_choice("shell.allow_disk_startup")))
    check("so the next boot keeps it",
          #bios.enforce_rom_settings() == 0 and
          bios.rom_setting("shell.allow_disk_startup") == true)

    -- resetting puts a key back to the ROM's declared default
    bios.reset_rom_setting("shell.allow_disk_startup")
    check("resetting a policy key clears the choice",
          bios.rom_choice("shell.allow_disk_startup") == nil)
    bios.set_any_rom_setting("shell.allow_disk_startup", "false", "boolean")
    bios.reset_rom_setting("shell.autocomplete")
    check("resetting an ordinary key unsets it, so the ROM default applies",
          settings.get("shell.autocomplete") == true,
          tostring(settings.get("shell.autocomplete")))

    -- a bad value is refused with a reason rather than stored
    local ok_bad, why = bios.set_any_rom_setting("shell.autocomplete", "maybe",
                                                 "boolean")
    check("a value that is not a boolean is refused",
          ok_bad == false and tostring(why):find("boolean", 1, true) ~= nil,
          tostring(ok_bad) .. " " .. tostring(why))
    check("and nothing was stored",
          settings.get("shell.autocomplete") == true,
          tostring(settings.get("shell.autocomplete")))

    if fs.exists("/.settings") then fs.delete("/.settings") end
    if fs.exists("/etc/bios.conf") then fs.delete("/etc/bios.conf") end

    -- THE SCREEN'S EXIT KEY HAS TO BE ONE THE MACHINE CAN DELIVER.
    --
    -- This screen used to leave on Escape, which could never work: Minecraft takes
    -- that key for its own menu and never passes it to the computer, and the ROM's
    -- key table has no escape entry at all (rom/apis/keys.lua ends at "delete") --
    -- so every `a == keys.escape` compared a number with nil and was dead code.
    -- The offline suite could not see it because cc_env_stub invented escape = 1,
    -- the same "the stub is more forgiving than the hardware" trap as fs.makeDir
    -- returning true; CraftOS-PC forwards the key as code 1, so the emulator looked
    -- fine as well. The stub no longer defines it, and the screens leave on "q".
    --
    -- Wrapped in its own function because this main chunk is at the Lua 200-local
    -- limit (the same trap usr/psh.lua hit).
    local function bios_key_checks()
        check("the offline key table has no escape key, like the ROM",
              keys.escape == nil, tostring(keys.escape))
        local text = nil
        local ok_reader, read_back = pcall(function()
            return _G.read_host_file(PROJ .. "/lib/bios.lua")
        end)
        if ok_reader and type(read_back) == "string" then text = read_back end
        check("the BIOS source is readable from the host", type(text) == "string")
        if type(text) == "string" then
            check("the BIOS no longer compares against an escape key",
                  text:find("keys.escape", 1, true) == nil,
                  "keys.escape is nil on this platform")
            check("the menu tells the operator the key it really reads",
                  text:find("Q leaves", 1, true) ~= nil and
                  text:find("Esc leaves", 1, true) == nil)
            check("the value editor cancels on Ctrl+T, not on Escape",
                  text:find("Ctrl+T cancels", 1, true) ~= nil,
                  "the cancel key must be one the operator can press")
        end
    end
    bios_key_checks()
end

-- ============================================================
section("reboot restarts, craftos opens a root-only tab")
-- ============================================================
-- The old "craftos" command dropped to the CraftOS shell by asking startup.lua to
-- stop relaunching psh. It was the only way out and a poor one: the machine was
-- left running something this installation does not manage, so the rules set here
-- (the boot guard, noexit) went with the shell. "reboot" restarts the computer
-- instead, and the new "craftos" opens the ROM shell in a separate multishell tab.
-- ===========================================================================
-- sudo asks for ROOT's password, not the caller's
-- ===========================================================================
-- The machine this was reported on asked for the CALLER's password -- not
-- because this tree did, but because its /usr/psh.lua was an older deployment
-- (measured: that file's prompt was "[sudo] password for " .. actor). The tree
-- asks for root's, and this pin is what keeps it that way: the two strings are
-- the whole difference between "sudo is a root credential" and "sudo is the
-- account's password again".
do
    local src = _G.SH_SRC and (_G.SH_SRC.psh or _G.SH_SRC["usr/psh.lua"]) or ""
    local i = src:find('BUILTINS["sudo"]', 1, true)
    check("the sudo built-in is there", i ~= nil)
    if i then
        local tail = src:sub(i, i + 6000)
        check("its prompt names root, not the caller",
              tail:find("[sudo] password for root: ", 1, true) ~= nil,
              "the prompt does not name root")
        check("and the password it checks is root's",
              tail:find('perm.check_password("root", pwd)', 1, true) ~= nil,
              "the password checked is not root's")
        check("it never builds the prompt from the caller",
              tail:find('"password for " .. actor', 1, true) == nil,
              "the prompt names the caller")
    end
end

-- window. The escape machinery is gone with the command.
do
    local bios = require("bios")
    local protect = require("protect")

    -- The command is gone, and so is the machinery it used. The source is read
    -- from _G.SH_SRC, not from fs: the stub's filesystem is EMULATED, so it cannot
    -- open a host path (fs.exists(PROJ .. "/usr/psh.lua") is false), and the
    -- prelude is how a suite sees the project's own text.
    -- The escape machinery is gone; craftos is an external, root-only command.
    local src = _G.SH_SRC and (_G.SH_SRC.psh or _G.SH_SRC["usr/psh.lua"]) or ""
    local watchdog = _G.SH_SRC and _G.SH_SRC.startup or ""
    check("the shell source is available", #src > 0)
    check("the watchdog source is available", #watchdog > 0)
    check("craftos is not a built-in",
          src:find('BUILTINS["craftos"]', 1, true) == nil)
    local craftos = (_G.SH_SRC and _G.SH_SRC.craftos) or ""
    check("the craftos command source is available", #craftos > 0)
    check("craftos requires root", craftos:find("must be root", 1, true) ~= nil)
    check("craftos opens the ROM shell in a tab",
          craftos:find("/rom/programs/shell.lua", 1, true) ~= nil)
    check("the reboot built-in is there",
          src:find('BUILTINS["reboot"]', 1, true) ~= nil)
    check("nothing writes the escape flag any more",
          src:find(".escape_allowed", 1, true) == nil)
    check("the shell no longer catches an escape error",
          src:find("__escape", 1, true) == nil)
    check("startup no longer reads an escape flag",
          watchdog:find("try_escape", 1, true) == nil)
    -- The CALL is what matters, not the definition: a mutant that leaves the
    -- function in place but never calls it would pass a check that only looked for
    -- the name. So the call is matched on its own line, where the definition
    -- ("local function clear_stale_escape_flag()") cannot satisfy it.
    check("it still clears a stale one from an older install",
          watchdog:find("\nclear_stale_escape_flag()", 1, true) ~= nil)

    -- "reboot" is root only
    perm.set_current_user("alice")
    local st_a, o_a = run("reboot -f")
    check("a non-root user may not reboot",
          st_a == 1 and o_a:find("must be root", 1, true) ~= nil,
          tostring(st_a) .. " " .. o_a)

    -- and "reboot -f" actually calls os.reboot
    perm.set_current_user("root")
    _G.__REBOOTED = nil
    local st_r, o_r = run("reboot -f")
    check("root may reboot", _G.__REBOOTED == 1,
          "rebooted=" .. tostring(_G.__REBOOTED) .. " st=" .. tostring(st_r) ..
          " out=" .. tostring(o_r))
    check("it says what it is doing",
          o_r:find("Restarting", 1, true) ~= nil, o_r)
    check("and it did NOT leave an escape flag",
          fs.exists("/var/lib/.escape_allowed") == false)

    -- the confirmation prompt can be declined. safe_read() reads the event queue,
    -- so the answer is queued as the events a user would produce: the character,
    -- then Enter.
    _G.__REBOOTED = nil
    os.queueEvent("char", "n")
    os.queueEvent("key", keys.enter)
    local st_n, o_n = run("reboot")
    check("declining the prompt does not reboot",
          _G.__REBOOTED == nil and o_n:find("cancelled", 1, true) ~= nil,
          tostring(_G.__REBOOTED) .. " " .. o_n)

    -- "reboot bios" arms the one shot request for the setup screen
    if fs.exists("/var/lib/.bios_setup_requested") then
        fs.delete("/var/lib/.bios_setup_requested")
    end
    check("nothing is armed to begin with", bios.setup_requested() == false)
    _G.__REBOOTED = nil
    local st_b, o_b = run("reboot bios -f")
    check("reboot bios reboots too", _G.__REBOOTED == 1, tostring(_G.__REBOOTED))
    check("and it says it is going to setup",
          o_b:find("BIOS", 1, true) ~= nil, o_b)
    check("the request is armed for the next boot",
          bios.setup_requested() == true)
    check("the request is a marker, and it is not in /etc",
          fs.exists("/var/lib/.bios_setup_requested") == true)

    -- it is one shot: startup consumes it before showing the screen
    bios.disarm_setup()
    check("consuming the request clears it", bios.setup_requested() == false)
    check("a second read finds nothing", bios.setup_requested() == false)

    -- a request written for ANOTHER computer is ignored, so a copied data
    -- directory does not make a different machine open its setup screen
    bios.arm_setup()
    local h = fs.open("/var/lib/.bios_setup_requested", "w")
    h.write("0\n999\n")
    h.close()
    check("a request for another computer is ignored",
          bios.setup_requested() == false)
    fs.delete("/var/lib/.bios_setup_requested")

    -- the noexit rule applies to a reboot as much as to an exit
    _G.__REBOOTED = nil
    psh.set_interactive(true)
    local st_x, o_x = run("reboot")
    check("noexit refuses a reboot from a session",
          _G.__REBOOTED == nil and o_x:find("not allowed to be left", 1, true) ~= nil,
          tostring(_G.__REBOOTED) .. " " .. o_x)
    check("and -f overrides it",
          (function()
              _G.__REBOOTED = nil
              run("reboot -f")
              return _G.__REBOOTED == 1
          end)(), tostring(_G.__REBOOTED))
    psh.set_interactive(false)

    -- shutdown is a different act and is refused rather than guessed
    _G.__REBOOTED = nil
    local st_s, o_s = run("reboot shutdown -f")
    check("reboot refuses to shut the machine down",
          st_s == 1 and _G.__REBOOTED == nil and
          o_s:find("shutdown", 1, true) ~= nil, o_s)

    _G.__REBOOTED = nil
    if fs.exists("/var/lib/.bios_setup_requested") then
        fs.delete("/var/lib/.bios_setup_requested")
    end
end

-- ============================================================
section("batch 9: sha256sum, md5sum and cksum")
-- ============================================================
-- The digest commands are checked against the published vectors, and the exact
-- line is compared, TWO spaces included: that is the format GNU prints and the
-- one a checksum file has to be read back with, so a single space would be a
-- different format that still "contains the digest".
write_file("/tmp/abc.txt", "abc")
write_file("/tmp/nine.txt", "123456789")

local SHA_ABC = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
local MD5_ABC = "900150983cd24fb0d6963f7d28e17f72"

st, o = run("sha256sum /tmp/abc.txt")
check("sha256sum prints the digest of abc, two spaces, then the name",
      st == 0 and (o:gsub("%s+$", "")) == SHA_ABC .. "  /tmp/abc.txt", o)
st, o = run("md5sum /tmp/abc.txt")
check("md5sum prints the digest of abc, two spaces, then the name",
      st == 0 and (o:gsub("%s+$", "")) == MD5_ABC .. "  /tmp/abc.txt", o)

-- A stream has no name of its own, so GNU prints a single "-" for it.
st, o = run("sha256sum < /tmp/abc.txt")
check("sha256sum hashes the standard input and names it -",
      st == 0 and (o:gsub("%s+$", "")) == SHA_ABC .. "  -", o)
st, o = run("md5sum < /tmp/abc.txt")
check("md5sum hashes the standard input and names it -",
      st == 0 and (o:gsub("%s+$", "")) == MD5_ABC .. "  -", o)

st, o = run("sha256sum /tmp/no-such-digest-input")
check("sha256sum reports a missing file and fails",
      st == 1 and (o:gsub("%s+$", "")) ==
      "sha256sum: /tmp/no-such-digest-input: no such file", o)
st, o = run("md5sum /tmp/abc.txt /tmp/no-such-digest-input")
check("one missing operand makes the whole run fail, and the good one is printed",
      st == 1 and o:find(MD5_ABC .. "  /tmp/abc.txt", 1, true) ~= nil and
      o:find("no such file", 1, true) ~= nil, o)

-- cksum is the POSIX checksum, not the zlib CRC-32. The known answer is what
-- tells them apart: 930766865 against 3421780262 for the same nine bytes.
st, o = run("cksum /tmp/nine.txt")
check("cksum prints the POSIX value and the length of 123456789",
      st == 0 and (o:gsub("%s+$", "")) == "930766865 9 /tmp/nine.txt", o)
st, o = run("cksum < /tmp/nine.txt")
check("cksum of the standard input prints value and length, and no name",
      st == 0 and (o:gsub("%s+$", "")) == "930766865 9", o)
check("the zlib CRC-32 of the same bytes is a different number",
      require("checksum").crc32("123456789") == 3421780262,
      tostring(require("checksum").crc32("123456789")))

-- And the module's own table, so a failure names the input that broke.
local cksum_bad = {}
for _, case in ipairs(require("cksum").selftest()) do
    if not case.ok then cksum_bad[#cksum_bad + 1] = case.name .. " got " .. case.got end
end
check("lib/cksum passes every known answer, empty and 256 bytes included",
      #cksum_bad == 0, table.concat(cksum_bad, "; "))

-- ============================================================
section("batch 9: base64 and expr")
-- ============================================================
local b64_bad = {}
for _, case in ipairs(require("base64").selftest()) do
    if not case.ok then b64_bad[#b64_bad + 1] = case.name .. " got " .. case.got end
end
check("lib/base64 passes the RFC 4648 vectors and the round trip",
      #b64_bad == 0, table.concat(b64_bad, "; "))

write_file("/tmp/b64foo.txt", "foo")
st, o = run("base64 /tmp/b64foo.txt")
check("base64 encodes a file onto one line",
      st == 0 and (o:gsub("%s+$", "")) == "Zm9v", o)
st, o = run("base64 < /tmp/b64foo.txt")
check("base64 encodes the standard input", st == 0 and (o:gsub("%s+$", "")) == "Zm9v", o)

write_file("/tmp/b64in.txt", "Zm9vYmFy")
st, o = run("base64 -d /tmp/b64in.txt")
check("base64 -d decodes to the original bytes", st == 0 and o == "foobar", o)
-- Decoded output is bytes, not a line: six encoded characters have to come back
-- as SIX bytes, with no break of the decoder's own added, which would make the
-- same answer seven bytes and would corrupt a file that is piped straight on.
-- The count is taken through a redirection, the place where the extra break
-- would really be written.
st, o = run("base64 -d /tmp/b64in.txt > /tmp/b64raw.txt; wc -c < /tmp/b64raw.txt")
check("base64 -d writes the decoded bytes and adds no line break of its own",
      st == 0 and (o:gsub("%s+$", "")) == "6", o)

write_file("/tmp/b64bad.txt", "Zm9!")
st, o = run("base64 -d /tmp/b64bad.txt")
check("base64 -d refuses an invalid character with status 1",
      st == 1 and o:find("invalid character", 1, true) ~= nil, o)

-- The decoded bytes are written as they are: a break the input did not carry
-- would corrupt a file that is piped straight on. Three encoded bytes have to
-- come back as three characters, not four.
st, o = run("base64 /tmp/b64foo.txt > /tmp/b64back.txt; " ..
            "base64 -d /tmp/b64back.txt > /tmp/b64out.txt; wc -c < /tmp/b64out.txt")
check("a base64 round trip through the shell gives back the same three bytes",
      st == 0 and (o:gsub("%s+$", "")) == "3", o)

st, o = run("expr 3 + 4")
check("expr prints the value of an expression",
      st == 0 and (o:gsub("%s+$", "")) == "7", o)
st, o = run("expr 10 / 3")
check("expr keeps integer arithmetic", st == 0 and (o:gsub("%s+$", "")) == "3", o)
st, o = run("expr 4 == 4")
check("expr of a true comparison is 1 and succeeds",
      st == 0 and (o:gsub("%s+$", "")) == "1", o)
st, o = run("expr 4 == 5")
check("expr of a false comparison is 0 and fails, which is what a script reads",
      st == 1 and (o:gsub("%s+$", "")) == "0", o)
st, o = run("n=$(expr 6 / 2); echo $n")
check("expr runs inside a command substitution", (o:gsub("%s+$", "")) == "3", o)
st, o = run("expr 1 2")
check("expr of a broken expression is status 2 with the reason",
      st == 2 and o:find("expr: ", 1, true) ~= nil and
      o:find("syntax error", 1, true) ~= nil, o)

-- ============================================================
section("batch 9: egrep and fgrep (grep -E and grep -F)")
-- ============================================================
write_file("/tmp/fstr.txt", "a.b\naxb\na+b\nab\naab\n")

st, o = run("grep 'a.b' /tmp/fstr.txt")
check("grep reads . as any character and finds axb",
      st == 0 and o:find("axb", 1, true) ~= nil, o)
st, o = run("fgrep 'a.b' /tmp/fstr.txt")
check("fgrep takes the pattern literally and never finds axb",
      st == 0 and (o:gsub("%s+$", "")) == "a.b", o)

-- "+" is the character that separates the two grammars: escaped in basic syntax
-- it is still a quantifier, so a fixed string compiled as basic would match
-- "ab" and "aab" instead of the literal "a+b".
st, o = run("fgrep 'a+b' /tmp/fstr.txt")
check("fgrep of a plus matches only the literal a+b",
      st == 0 and (o:gsub("%s+$", "")) == "a+b", o)

write_file("/tmp/ere.txt", "alpha\nbeta\n")
st, o = run("egrep 'a(lp)ha' /tmp/ere.txt")
check("egrep reads ( ) as a group, the way grep -E does",
      st == 0 and (o:gsub("%s+$", "")) == "alpha", o)
st, o = run("egrep 'al+pha' /tmp/ere.txt")
check("egrep reads + as one or more", st == 0 and (o:gsub("%s+$", "")) == "alpha", o)
st = run("grep 'al+pha' /tmp/ere.txt")
check("basic grep reads + as a literal, so the same pattern selects nothing",
      st == 1, st)
st, o = run("egrep -c alpha /tmp/ere.txt")
check("egrep carries grep's own options", (o:gsub("%s+$", "")) == "1", o)
st, o = run("fgrep -v alpha /tmp/ere.txt")
check("fgrep -v drops the fixed string and keeps the rest",
      st == 0 and (o:gsub("%s+$", "")) == "beta", o)

-- ============================================================
section("batch 9: printenv, groups, users, tty, nproc")
-- ============================================================
run("export PV=hello")
st, o = run("printenv PV")
check("printenv NAMEs prints the value alone, with no NAME=",
      st == 0 and (o:gsub("%s+$", "")) == "hello", o)
st, o = run("printenv PV NO_SUCH_PRINTENV_NAME")
check("printenv fails when one of the names is not set, and still prints the rest",
      st == 1 and (o:gsub("%s+$", "")) == "hello", o)
st, o = run("printenv NO_SUCH_PRINTENV_NAME")
check("printenv of an unset name prints nothing and fails",
      st == 1 and (o:gsub("%s+$", "")) == "", o)
st, o = run("printenv")
check("printenv with no name prints the exported environment",
      st == 0 and o:find("PV=hello", 1, true) ~= nil, o)

-- The current user is moved to alice first: with root as the shell's user, a
-- groups that ignored the argument and printed a hardcoded root would pass by
-- luck, and the defaulting is exactly what these two assertions are about: the
-- first demands alice's group and the second demands root's, so no constant
-- answer can satisfy both.
perm.set_current_user("alice")
st, o = run("groups")
check("groups with no name prints the groups of the CURRENT user",
      st == 0 and (o:gsub("%s+$", "")) == "users", o)
perm.set_current_user("root")
st, o = run("groups")
check("groups follows the user when the shell changes hand",
      st == 0 and (o:gsub("%s+$", "")) == "root", o)
st, o = run("groups alice")
check("groups USER prints the groups of that user",
      st == 0 and (o:gsub("%s+$", "")) == "users", o)
st, o = run("groups no_such_group_user")
check("groups of an unknown user fails with the message",
      st == 1 and (o:gsub("%s+$", "")) ==
      "groups: no_such_group_user: no such user", o)

-- users follows the live session records, not the account list, so the answer
-- is exactly the account that is logged in and for nobody it is an empty line.
local sessionlog = require("sessionlog")
for _, record in ipairs(sessionlog.online()) do
    fs.delete(sessionlog.session_file(record.tty))
end
sessionlog.login("alice", "test")
st, o = run("users")
check("users lists the account that is logged in",
      st == 0 and (o:gsub("%s+$", "")) == "alice", o)
sessionlog.logout("test")
st, o = run("users")
check("users prints an empty line when nobody is logged in",
      st == 0 and (o:gsub("%s+$", "")) == "", o)

st, o = run("tty")
check("tty prints the one console this machine has",
      st == 0 and (o:gsub("%s+$", "")) == "/dev/console", o)
st, o = run("nproc")
check("nproc prints 1", st == 0 and (o:gsub("%s+$", "")) == "1", o)

-- ============================================================
section("batch 9: tput, realpath and mktemp")
-- ============================================================
fs.makeDir("/tmp/rp")
fs.makeDir("/tmp/rp/a")
fs.makeDir("/tmp/rp/a/b")
st, o = run("realpath /tmp/rp/a/../a/b")
check("realpath folds .. away", st == 0 and (o:gsub("%s+$", "")) == "/tmp/rp/a/b", o)
st, o = run("realpath /tmp/rp/./a")
check("realpath folds . away and makes the path absolute",
      st == 0 and (o:gsub("%s+$", "")) == "/tmp/rp/a", o)
st, o = run("realpath /tmp/rp/missing")
check("realpath of a path that does not exist fails",
      st == 1 and (o:gsub("%s+$", "")) == "realpath: /tmp/rp/missing: no such file", o)

-- tput answers for the terminal the machine has, so the size is compared with
-- the terminal itself rather than with a number written into the test.
st, o = run("tput cols")
check("tput cols is the width of this terminal",
      st == 0 and tonumber((o:gsub("%s+$", ""))) == select(1, term.getSize()), o)
st, o = run("tput lines")
check("tput lines is the height of this terminal",
      st == 0 and tonumber((o:gsub("%s+$", ""))) == select(2, term.getSize()), o)
st, o = run("tput colors")
check("tput colors is the 16 colour palette",
      st == 0 and (o:gsub("%s+$", "")) == "16", o)
st, o = run("tput bold")
check("tput bold writes nothing, because this terminal has no bold attribute",
      st == 0 and (o:gsub("%s+$", "")) == "", o)
st, o = run("tput sgr0")
check("tput sgr0 writes nothing either", st == 0 and (o:gsub("%s+$", "")) == "", o)
-- cup takes ROW then COLUMN while the terminal API takes column then row: a
-- swap would put the cursor on the wrong cell with no other symptom.
term.setCursorPos(1, 1)
st, o = run("tput cup 3 5")
check("tput cup ROW COL moves the cursor to that row and column",
      st == 0 and select(1, term.getCursorPos()) == 5 and
      select(2, term.getCursorPos()) == 3,
      tostring(select(1, term.getCursorPos())) .. "," ..
      tostring(select(2, term.getCursorPos())))
st, o = run("tput no_such_capability")
check("tput reports an unknown capability and fails",
      st == 1 and (o:gsub("%s+$", "")) ==
      "tput: unknown capability: no_such_capability", o)

st, o = run("mktemp")
local first_tmp = (o:gsub("%s+$", ""))
check("mktemp prints a name drawn from the default template in /var/tmp",
      st == 0 and first_tmp:match("^/var/tmp/tmp%.[A-Za-z0-9]+$") ~= nil, o)
check("mktemp created the file", fs.exists(first_tmp) and not fs.isDir(first_tmp),
      first_tmp)
local tmp_mode = perm.get_mode(first_tmp)
check("the temporary file is restricted to its owner",
      tmp_mode ~= nil and tmp_mode.mode == "rw-------",
      tostring(tmp_mode and tmp_mode.mode))
st, o = run("mktemp")
local second_tmp = (o:gsub("%s+$", ""))
check("a second mktemp draws a different name",
      second_tmp ~= first_tmp and fs.exists(second_tmp),
      first_tmp .. " / " .. second_tmp)
st, o = run("mktemp -d /tmp/mt.XXXXXX")
local tmp_dir = (o:gsub("%s+$", ""))
check("mktemp -d creates a directory", st == 0 and fs.isDir(tmp_dir), tmp_dir)
tmp_mode = perm.get_mode(tmp_dir)
check("the temporary directory is restricted to its owner too",
      tmp_mode ~= nil and tmp_mode.mode == "rwx------",
      tostring(tmp_mode and tmp_mode.mode))
st, o = run("mktemp /tmp/noXhere")
check("mktemp refuses a template without a run of X",
      st == 1 and o:find("too few X", 1, true) ~= nil, o)

-- ============================================================
section("stderr redirection: 2>, 2>> and 2>&1 are real")
-- ============================================================
-- The shell had NO second stream: emit_diag wrote where emit writes, so "2>" was
-- neither honoured nor rejected -- it was read as the ARGUMENT "2" followed by a
-- plain stdout redirect. Measured before the fix: `echo hi 2> f` put the text
-- "hi 2" into f and exited 0. Silent wrong output is worse than an error, which is
-- why these assertions read the FILE CONTENTS rather than only the status.
do
    local function read_file(path)
        if not fs.exists(path) then return nil end
        local h = fs.open(path, "r")
        if not h then return nil end
        local t = h.readAll()
        h.close()
        return t
    end
    local function clear(path)
        if fs.exists(path) then fs.delete(path) end
    end

    -- 1. "2>" must NOT put the argument "2" into the file. This is the exact
    --    wrong output the shell used to produce.
    clear("/tmp/e1.txt")
    local _, o1 = run("echo hi 2> /tmp/e1.txt")
    check("a command with clean diagnostics writes nothing to 2>",
          read_file("/tmp/e1.txt") == "",
          "[" .. tostring(read_file("/tmp/e1.txt")) .. "]")
    check("and its stdout still reaches the console",
          o1:find("hi", 1, true) ~= nil and not o1:find("hi 2", 1, true), o1)

    -- 2. A real diagnostic lands in the file, and NOT on stdout.
    clear("/tmp/e2.txt")
    local st2, o2 = run("nosuchcommand_xyz 2> /tmp/e2.txt")
    check("a diagnostic goes to the 2> target",
          (read_file("/tmp/e2.txt") or ""):find("command not found", 1, true) ~= nil,
          "[" .. tostring(read_file("/tmp/e2.txt")) .. "]")
    check("and not to stdout", not o2:find("command not found", 1, true), o2)
    check("the status is still 127", st2 == 127, tostring(st2))

    -- 3. Without a redirection the diagnostic still reaches the console.
    local _, o3 = run("nosuchcommand_xyz")
    check("without 2> the diagnostic is on stdout as before",
          o3:find("command not found", 1, true) ~= nil, o3)

    -- 4. "2>>" appends instead of truncating.
    clear("/tmp/e3.txt")
    run("nosuchcommand_xyz 2> /tmp/e3.txt")
    local first_len = #(read_file("/tmp/e3.txt") or "")
    run("nosuchcommand_xyz 2>> /tmp/e3.txt")
    local second_len = #(read_file("/tmp/e3.txt") or "")
    check("2> truncates and 2>> appends",
          first_len > 0 and second_len == first_len * 2,
          first_len .. " -> " .. second_len)

    -- 5. "2>&1" puts both streams in one place: with "> f 2>&1" the diagnostic
    --    must be IN the file, not on the console.
    clear("/tmp/e4.txt")
    local _, o5 = run("nosuchcommand_xyz > /tmp/e4.txt 2>&1")
    check("2>&1 after > sends the diagnostic into the file",
          (read_file("/tmp/e4.txt") or ""):find("command not found", 1, true) ~= nil,
          "[" .. tostring(read_file("/tmp/e4.txt")) .. "]")
    check("and leaves stdout empty", not o5:find("command not found", 1, true), o5)

    -- 6. The order matters, as in POSIX: with "2>&1 > f" the diagnostic follows
    --    the stdout that existed BEFORE the file was opened.
    clear("/tmp/e5.txt")
    local _, o6 = run("nosuchcommand_xyz 2>&1 > /tmp/e5.txt")
    check("2>&1 BEFORE > keeps the diagnostic on the console",
          o6:find("command not found", 1, true) ~= nil, o6)
    check("and the file holds only stdout",
          (read_file("/tmp/e5.txt") or "") == "",
          "[" .. tostring(read_file("/tmp/e5.txt")) .. "]")

    -- 7. The spaced form is NOT a redirection: "echo 2 > f" is the argument "2".
    clear("/tmp/e6.txt")
    run("echo 2 > /tmp/e6.txt")
    check("a SPACE before > keeps 2 as an argument",
          (read_file("/tmp/e6.txt") or ""):find("2", 1, true) ~= nil,
          "[" .. tostring(read_file("/tmp/e6.txt")) .. "]")

    for _, p in ipairs({ "/tmp/e1.txt", "/tmp/e2.txt", "/tmp/e3.txt",
                         "/tmp/e4.txt", "/tmp/e5.txt", "/tmp/e6.txt" }) do
        clear(p)
    end
end

-- ============================================================
section("the destructive-command blacklist and the OS-level guard")
-- ============================================================
do
    local danger = require("danger")
    check("rm -rf / is refused", danger.check({ "rm", "-rf", "/" }) ~= nil)
    check("rm -rf /* is refused", danger.check({ "rm", "-rf", "/*" }) ~= nil)
    check("rm -rf /usr is refused", danger.check({ "rm", "-rf", "/usr" }) ~= nil)
    check("sudo rm -rf / is looked through",
          danger.check({ "sudo", "rm", "-rf", "/" }) ~= nil)
    check("rm -rf of a user directory is allowed",
          danger.check({ "rm", "-rf", "/home/me" }) == nil)
    check("a plain rm -f of one file is not the blacklist's business",
          danger.check({ "rm", "-f", "/usr/psh.lua" }) == nil)
    local osguard = require("osguard")
    local fake = {
        open = function() return {} end,
        delete = function() return true end,
        makeDir = function() return true end,
        move = function() return true end,
        copy = function() return true end,
    }
    local deny = {
        can_write = function() return false end,
        can_read = function() return true end,
        get_current_user = function() return "bob" end,
    }
    check("the guard installs on a filesystem table",
          osguard.install(fake, deny) == true)
    check("a denied write returns nil", fake.open("/usr/psh.lua", "w") == nil)
    check("a denied delete is false", fake.delete("/usr/psh.lua") == false)
    check("reads still work", fake.open("/usr/psh.lua", "r") ~= nil)

    -- The REASON has to be the reason the operator's command deserves. This was
    -- wrong: wildcard_target() stripped "*" from every token and then asked
    -- whether what was left was a system directory, so "rm -rf /usr" -- a token
    -- with no wildcard in it at all -- was refused as "with a wildcard over
    -- '/usr'" and the "on the system directory" branch below it could never be
    -- reached. Measured on a real machine; the acceptance script could only
    -- assert the two wordings as one loose pattern.
    check("rm -rf /usr names the system directory, not a wildcard",
          danger.check({ "rm", "-rf", "/usr" }) ==
          "refusing 'rm -r' on the system directory '/usr'",
          tostring(danger.check({ "rm", "-rf", "/usr" })))
    check("rm -rf /etc/* still takes the wildcard branch",
          danger.check({ "rm", "-rf", "/etc/*" }) ==
          "refusing 'rm -r' with a wildcard over '/etc/'",
          tostring(danger.check({ "rm", "-rf", "/etc/*" })))
    check("a system subdirectory without a wildcard is named as one too",
          danger.check({ "rm", "-rf", "/usr/lib" }) ==
          "refusing 'rm -r' on the system directory '/usr/lib'",
          tostring(danger.check({ "rm", "-rf", "/usr/lib" })))
    check("a user directory with a wildcard is still allowed",
          danger.check({ "rm", "-rf", "/home/me/*" }) == nil)

    -- ONE LAYER, WHOEVER ASKS. The mark has to live on the fs table: the ROM
    -- gives every program its own package table, so the module-local "installed"
    -- flag belongs to one program while the table it wrapped is the machine's.
    local asks = 0
    local allow = {
        can_write = function() asks = asks + 1 return true end,
        can_read = function() return true end,
        get_current_user = function() return "bob" end,
    }
    local one = { open = function() return {} end }
    check("the guard installs on a second table the first one did not stop",
          osguard.install(one, allow) == true)
    check("and a second install on that table is refused",
          osguard.install(one, allow) == false)
    asks = 0
    one.open("/usr/psh.lua", "w")
    check("one layer asks the permission database once", asks == 1, asks)
    osguard.install(one, allow)                  -- refused: must add no layer
    asks = 0
    one.open("/usr/psh.lua", "w")
    check("the refused second install really added no layer", asks == 1, asks)
    -- What ANOTHER program sees: a fresh module instance, as a program with its
    -- own package table gets, asking about the same machine table.
    package.loaded["osguard"] = nil
    local other = require("osguard")
    package.loaded["osguard"] = osguard
    check("another program's module sees the guard installed",
          other.installed(one) == true)
    check("and does not wrap the same table a second time",
          other.install(one, allow) == false)

    -- THE UNGUARDED OPEN CROSSES PROGRAM BOUNDARIES TOO, for the same measured
    -- reason the mark does. The ROM gives every program its own package table
    -- (rom/programs/shell.lua:50 createShellEnv -> cc/require.lua:120), so the
    -- osguard instance a later program can require is a DIFFERENT instance, with
    -- raw_open = nil in it. Measured on a real machine: startup.lua installed the
    -- guard (the fs table got the mark) and usr/psh.lua -- a different program --
    -- required lib/osguard.lua, found raw_open = nil, fell back to the guarded
    -- open, read /etc/shadow as nil, and refused every password: su and sudo were
    -- unusable from every account while the stored hashes were correct. install()
    -- answering false there was not a second installer; it was this same guard
    -- seen from another program.
    local really_open = function(path) return { path = path } end
    local deny_read = {
        can_write = function() return false end,
        can_read = function() return false end,
        get_current_user = function() return "bob" end,
    }
    local three = { open = really_open }
    check("the guard installs on a third table",
          osguard.install(three, deny_read) == true)
    check("the unguarded open is kept on the fs table, not only in the module",
          rawget(three, other.RAW_OPEN) == really_open,
          tostring(other.RAW_OPEN))
    check("a program that did not install the guard has no module copy of it",
          other.raw_open == nil, tostring(other.raw_open))
    check("the guarded open of that table still refuses the read",
          three.open("/etc/shadow", "r") == nil)
    local primitive = rawget(three, other.RAW_OPEN)
    local through_table = type(primitive) == "function"
                          and primitive("/etc/shadow", "r") or nil
    check("but the table's primitive opens the same file",
          type(through_table) == "table" and through_table.path == "/etc/shadow")

    -- And lib/perm.lua asks the TABLE for it, because the module copy is what was
    -- nil on the machine. A fresh perm module is used, in a program that did not
    -- install the guard, against a filesystem whose guarded open refuses to work.
    local saved_perm_module = package.loaded["perm"]
    local saved_guard_module = package.loaded["osguard"]
    local saved_fs = _G.fs
    local function with_fresh_perm(fakefs, body)
        -- Load the module BEFORE swapping fs: require itself searches through
        -- fs.exists, so a swapped table that knows only /etc/shadow cannot find
        -- lib/perm.lua at all. The module resolves `fs` when it is CALLED, which
        -- is the path under test.
        package.loaded["osguard"] = other          -- did not install the guard
        package.loaded["perm"] = nil
        local ok, fresh = pcall(require, "perm")
        local result
        if ok and type(fresh) == "table" then
            _G.fs = fakefs
            -- nil-safe on purpose: a broken primitive must read as a failed check,
            -- not as a raised error that hides which assertion broke.
            local body_ok, value = pcall(body, fresh)
            if body_ok then result = value end
            _G.fs = saved_fs
        end
        package.loaded["perm"] = saved_perm_module
        package.loaded["osguard"] = saved_guard_module
        return result
    end
    local shadow_line = "root:" .. require("sha256").hex("cc-salt:root")
    local shadow_fs = {
        exists = function(p) return p == "/etc/shadow" end,
        open = function() error("the guarded open was used for /etc/shadow") end,
    }
    shadow_fs[other.RAW_OPEN] = function()
        local done = false
        return {
            readLine = function()
                if done then return nil end
                done = true
                return shadow_line
            end,
            close = function() end,
        }
    end
    local verified = with_fresh_perm(shadow_fs, function(freshperm)
        return freshperm.check_password("root", "root")
    end)
    check("a program that did not install the guard can still verify a password",
          verified == true, tostring(verified))

    -- THE ACCOUNT IS READ FROM /etc/current_user EVERY TIME. The guard keeps the
    -- perm instance of the program that installed it (the boot program) while the
    -- session moves /etc/current_user from another program; a cached name would
    -- keep the guard believing the console still belongs to the boot-time account,
    -- so after "su root" every write to /etc would still be refused. Measured on a
    -- real machine as a second wall, after the shadow read was fixed.
    local who = "pyam"
    local current_fs = {
        exists = function(p) return p == "/etc/current_user" end,
        open = function()
            return { readLine = function() return who end, close = function() end }
        end,
    }
    local seen = with_fresh_perm(current_fs, function(freshperm)
        local first = freshperm.get_current_user()
        who = "root"
        return first .. "|" .. freshperm.get_current_user()
    end)
    check("the account follows /etc/current_user instead of a cached name",
          seen == "pyam|root", tostring(seen))

    -- THE LOGIN DATABASE IS ROOT'S BUSINESS. perm writes /etc/passwd, /etc/group,
    -- /etc/shadow, /etc/sudoers and /etc/current_user through the unguarded open, so
    -- the guard can no longer refuse those writes for it; the rule lives in perm
    -- now. Without it "useradd -u 2 name" from an ordinary account would succeed --
    -- on the guarded filesystem it used to die on a nil handle, a refusal by
    -- accident. Measured on a real machine, where the shell's useradd has no root
    -- check of its own.
    local real_perm = require("perm")
    local saved_actor = real_perm.get_current_user()
    if not real_perm.user_exists("alice") then
        real_perm.set_current_user("root")
        real_perm.add_user("alice", { level = 0, groups = "alice" })
    end
    real_perm.set_current_user("alice")
    local added, why_add = real_perm.add_user("evil", { level = 2, password = "pw" })
    check("a plain account may not add an account", added == false, tostring(added))
    check("and is told permission was denied",
          tostring(why_add):find("permission denied", 1, true) ~= nil, tostring(why_add))
    check("a plain account may not make itself a sudoer",
          real_perm.add_sudoer("alice") == false)
    check("a plain account may not take another account's password",
          real_perm.set_password("root", "new") == false)
    check("and may not set its own without the old one",
          real_perm.set_password("alice", "new") == false)
    real_perm.set_current_user("root")
    check("root may add an account", real_perm.add_user("maker", { level = 0,
          groups = "maker", password = "" }) == true)
    check("root may set its password", real_perm.set_password("maker", "maker-pw") == true)
    check("and the account can use it",
          real_perm.check_password("maker", "maker-pw") == true)
    real_perm.del_user("maker")
    real_perm.set_current_user(saved_actor)
end

-- ============================================================
section("two-part install: the security modules are on the computer")
-- ============================================================
-- A machine built in two parts keeps only what it needs to BOOT on its own 1 MB
-- disk; everything else is on the system module medium (part 2). The tool that
-- draws that line is tools/deploy.py, and it reads it off the COLUMN-0 requires
-- of the boot entry points. Asked here through the deploy module itself
-- (_G.SH_DEPLOY, published by tests/run_all.py) rather than through a copy of
-- its list, so the answer is the one the builder gets.
--
-- The bug these assertions are for was measured on a machine deployed with
-- --part base only, no medium inserted: lib/danger.lua and lib/osguard.lua had
-- been classified as lazy because they were only required inside functions, so
-- they were written onto the medium -- and a machine without the medium had no
-- blacklist (rm -rf / reported a require error, not a refusal) and no guard (a
-- program could fs.open("/usr/psh.lua", "a")). The two modules are what refuse;
-- losing them does not stop the machine, it only stops it saying no.
do
    local split = _G.SH_DEPLOY or { base = {}, modules = {} }
    local base, mods = {}, {}
    for _, rel in ipairs(split.base) do base[rel] = true end
    for _, rel in ipairs(split.modules) do mods[rel] = true end
    check("the base half is the boot path, and it is not empty",
          base["startup.lua"] == true and base["usr/psh.lua"] == true)

    local SECURITY = { "lib/danger.lua", "lib/osguard.lua" }
    for _, rel in ipairs(SECURITY) do
        check(rel .. " is on the computer's own disk", base[rel] == true)
        check(rel .. " is NOT also on the system module medium", mods[rel] ~= true)
    end

    -- BEHAVIOUR, not just the file list. The wrapper below is a base-only
    -- machine: a module that only the medium carries raises "module not found",
    -- exactly as require does when the file is not there. The blacklist is
    -- reachable through the shell, so a base-only machine has to still refuse.
    local real_require = require
    local function base_only(name)
        local rel = "lib/" .. tostring(name) .. ".lua"
        if mods[rel] and not base[rel] then
            error("module '" .. tostring(name) .. "' not found", 2)
        end
        return real_require(name)
    end

    local saved_danger = package.loaded["danger"]
    package.loaded["danger"] = nil
    _G.require = base_only
    local st, o = run("rm -rf /")
    _G.require = real_require
    check("without the medium, the blacklist still refuses rm -rf /", st == 1, st)
    check("and the refusal is the blacklist's, not a missing module",
          flat(o):find("refusing 'rm -r'", 1, true) ~= nil, o)
    package.loaded["danger"] = saved_danger or real_require("danger")

    -- The guard is required from startup.lua and nowhere else, so the same
    -- "module not found" would be swallowed by the pcall there and the boot would
    -- continue without it. Here it must simply be loadable.
    local saved_guard = package.loaded["osguard"]
    package.loaded["osguard"] = nil
    _G.require = base_only
    local loaded = pcall(function() return require("osguard") end)
    _G.require = real_require
    check("without the medium, the guard is still loadable at boot", loaded == true)
    package.loaded["osguard"] = saved_guard or real_require("osguard")
end

-- ============================================================
section("disk space: a write that cannot fit is refused before it starts")
-- ============================================================
-- The criterion is one line: the bytes to write must not be GREATER than the
-- free space, so equality is allowed. The three states that matter are "there is
-- an answer and it fits", "there is an answer and it does not", and "there is no
-- answer at all" -- the third must ALLOW the write, because a machine without
-- fs.getFreeSpace would otherwise be turned read-only by the check itself.
--
-- The numbers are injected by replacing the stub's fs.getFreeSpace, which is what
-- a test has instead of a full disk. Every assertion below also reads the FILE,
-- not only the status: the harm this feature exists to prevent is a truncated
-- target with a status nobody checked.
local space_api = require("space")
local real_get_free_space = fs.getFreeSpace

local function with_free(bytes, fn)
    if bytes == nil then
        fs.getFreeSpace = nil
    elseif type(bytes) == "function" then
        -- a fake API, for the "it raises" and "it answers nonsense" cases
        fs.getFreeSpace = bytes
    else
        fs.getFreeSpace = function() return bytes end
    end
    local ok, a, b = pcall(fn)
    fs.getFreeSpace = real_get_free_space
    if not ok then error(a, 0) end
    return a, b
end

local function file_text(path)
    local h = fs.open(path, "r")
    if not h then return nil end
    local text = h.readAll()
    h.close()
    return text
end

check("the free space of the stub is a number",
      type(space_api.free("/")) == "number", tostring(space_api.free("/")))
check("a write that fits is allowed",
      with_free(1000, function() return space_api.need("/tmp/a", 999) end) == true)
check("a write that exactly fills the disk is allowed (equal is not greater)",
      with_free(1000, function() return space_api.need("/tmp/a", 1000) end) == true)
local room, why = with_free(1000, function() return space_api.need("/tmp/a", 1001) end)
check("a write one byte over the free space is refused", room == false, tostring(room))
check("and the refusal names both numbers",
      why == "not enough space: need 1001 bytes, 1000 free", tostring(why))
-- A byte count is NOT printed with %d: on the real machine (CraftOS-PC 2.8.3)
-- string.format("%d", 224476971009) raises "not a number in proper range", and
-- the PC suite's small numbers never reach that. The failure this pins is the
-- one the probe hit: a refusal that raises instead of naming the numbers is
-- worse than no refusal, because the write has already been stopped.
local huge_free = 224476971008
local huge_ok, huge_why = with_free(huge_free, function()
    return space_api.need("/tmp/a", huge_free + 1)
end)
check("a disk measured in hundreds of gigabytes can be reported",
      huge_ok == false and huge_why ==
      "not enough space: need 224476971009 bytes, 224476971008 free",
      tostring(huge_why))
check("and the count has no exponent and no fraction",
      huge_why ~= nil and huge_why:find("e+", 1, true) == nil and
      huge_why:find(".0 ", 1, true) == nil, tostring(huge_why))
check("the reason helper is what every writer prints",
      space_api.count(huge_free) == "224476971008", space_api.count(huge_free))

check("an unknown size is not guessed at",
      with_free(0, function() return space_api.need("/tmp/a", nil) end) == true)
check("zero bytes need no space even on a full disk",
      with_free(0, function() return space_api.need("/tmp/a", 0) end) == true)

-- No API: free() answers nil and need() allows, which is the "old machine" case.
local no_api_free = with_free(nil, function() return space_api.free("/") end)
check("without fs.getFreeSpace the free space is unknown, not zero",
      no_api_free == nil, tostring(no_api_free))
check("and without it a write is allowed",
      with_free(nil, function() return space_api.need("/tmp/a", 99999999) end) == true)
-- An API that raises or answers nonsense is the same case: an unreadable answer
-- must never be read as "0 free".
check("an API that raises answers nil",
      with_free(function() error("no quota for you") end,
                function() return space_api.free("/") end) == nil)
local nonsense = function() return "plenty" end
fs.getFreeSpace = nonsense
local bad_type = space_api.free("/")
fs.getFreeSpace = real_get_free_space
check("an API that answers a non number answers nil", bad_type == nil, tostring(bad_type))

-- size(): a file is its size, a tree is the sum of its files. This is what cp
-- accumulates before it asks.
write_file("/tmp/space_a.txt", string.rep("a", 300))
fs.makeDir("/tmp/space_tree")
write_file("/tmp/space_tree/one.txt", string.rep("b", 200))
write_file("/tmp/space_tree/two.txt", string.rep("c", 50))
check("the size of a file is its bytes",
      space_api.size("/tmp/space_a.txt") == 300, tostring(space_api.size("/tmp/space_a.txt")))
check("the size of a tree is the sum of its files",
      space_api.size("/tmp/space_tree") == 250, tostring(space_api.size("/tmp/space_tree")))
check("a tree that fits is allowed",
      with_free(1000, function() return space_api.need_tree("/tmp", 1000) end) == true)
check("a tree over the free space is refused",
      with_free(1000, function()
          local ok_tree = space_api.need_tree("/tmp", 1001)
          return ok_tree
      end) == false)

-- cp: the preflight happens before the first byte, so a refusal leaves neither a
-- new file nor a damaged old one.
write_file("/tmp/space_src.bin", string.rep("s", 4000))
write_file("/tmp/space_dst.bin", "keep me")
local cp_st, cp_out = with_free(1000, function()
    return run("cp /tmp/space_src.bin /tmp/space_dst.bin")
end)
check("cp refuses a copy that does not fit", cp_st == 1, tostring(cp_st))
check("cp says how much is missing",
      flat(cp_out):find("not enough space: need 4000 bytes, 1000 free", 1, true) ~= nil,
      flat(cp_out))
check("the destination of the refused cp still holds what it held",
      file_text("/tmp/space_dst.bin") == "keep me", tostring(file_text("/tmp/space_dst.bin")))
local cp_new_st = with_free(1000, function()
    return run("cp /tmp/space_src.bin /tmp/space_new.bin")
end)
check("a refused cp does not create the destination", cp_new_st == 1 and
      not fs.exists("/tmp/space_new.bin"), tostring(cp_new_st))
-- The control: the same copy with room has to work, or the refusal above proves
-- nothing about the amount of space.
local cp_ok, cp_ok_out = run("cp /tmp/space_src.bin /tmp/space_new.bin")
check("the same copy succeeds when there is room", cp_ok == 0, flat(cp_ok_out))
check("and the bytes are there", file_text("/tmp/space_new.bin") ==
      string.rep("s", 4000))
-- A directory tree is measured as a whole: with room for one file but not both,
-- nothing may be written.
fs.makeDir("/tmp/space_out")
local tree_st, tree_out = with_free(150, function()
    return run("cp -r /tmp/space_tree /tmp/space_out")
end)
check("a directory copy that does not fit is refused as a whole", tree_st == 1,
      tostring(tree_st))
check("and its refusal names the tree total, not one file",
      flat(tree_out):find("not enough space: need 250 bytes, 150 free", 1, true) ~= nil,
      flat(tree_out))
check("no part of the refused tree was written",
      not fs.exists("/tmp/space_out/space_tree/one.txt") and
      not fs.exists("/tmp/space_out/space_tree/two.txt"))
-- A disk that fills up WHILE the tree is being walked: the total preflight gets
-- the generous first answer and passes, and the per-file check has to be the one
-- that stops the copy. Without it the tree is written file by file until the
-- volume is full, which is the failure the total check cannot see.
fs.makeDir("/tmp/space_walk")
local walk_calls = 0
local walk_st, walk_out = with_free(function()
    walk_calls = walk_calls + 1
    if walk_calls == 1 then return 1000000 end
    return 10
end, function()
    return run("cp -r /tmp/space_tree /tmp/space_walk")
end)
check("a disk that fills up during a tree copy stops it", walk_st == 1, tostring(walk_st))
check("and the per-file refusal names the file that did not fit",
      flat(walk_out):find("one.txt: not enough space: need 200 bytes, 10 free", 1, true) ~= nil,
      flat(walk_out))
check("the file after the one that failed was not written either",
      not fs.exists("/tmp/space_walk/space_tree/one.txt") and
      not fs.exists("/tmp/space_walk/space_tree/two.txt"))

-- fs.copy on the REAL ROM (CraftOS-PC 2.8.3, measured) returns NOTHING on
-- success and RAISES when the destination exists; the stub returns true and
-- overwrites. "if not fs.copy(...)" therefore made every successful copy on a
-- real machine report status 1. Both shapes have to answer 0, and a raising copy
-- has to be reported instead of unwinding out of the shell.
local real_copy = fs.copy
fs.copy = function(a, b) real_copy(a, b) return nil end
local rom_copy = run("cp /tmp/space_src.bin /tmp/space_romcopy.bin")
fs.copy = real_copy
check("a copy whose fs.copy returns nothing (the real ROM) is a success",
      rom_copy == 0 and fs.exists("/tmp/space_romcopy.bin"), tostring(rom_copy))
fs.copy = function() error("File already exists", 0) end
local raising_st, raising_out = run("cp /tmp/space_src.bin /tmp/space_raise.bin")
fs.copy = real_copy
check("a raising fs.copy is reported, not unwound out of the shell",
      raising_st == 1, tostring(raising_st))
check("and the message names the destination",
      flat(raising_out):find("cp: /tmp/space_raise.bin:", 1, true) ~= nil, flat(raising_out))

-- tee: the input is already in memory, so the number in the message is exact.
write_file("/tmp/space_big.txt", string.rep("t", 5000))
local tee_st, tee_out = with_free(2000, function()
    return run("cat /tmp/space_big.txt | tee /tmp/space_tee.txt")
end)
check("tee refuses to write more than fits", tee_st == 1, tostring(tee_st))
-- cat ends the stream with the break it emits for the last line, so the text tee
-- holds is one byte longer than the file it came from: the refusal names the
-- bytes that are really about to be written, not the file's size.
check("tee's refusal is the text's size",
      flat(tee_out):find("not enough space: need 5001 bytes, 2000 free", 1, true) ~= nil,
      flat(tee_out))
check("the refused tee did not create its file", not fs.exists("/tmp/space_tee.txt"))
local tee_ok = run("cat /tmp/space_big.txt | tee /tmp/space_tee.txt")
check("tee writes it when there is room", tee_ok == 0 and
      fs.getSize("/tmp/space_tee.txt") == 5001, tostring(tee_ok))

-- A redirect is opened before the command has produced anything, so the only
-- honest test there is "not already full". The file must not be created, and an
-- existing one must not be truncated -- that truncation is the whole harm.
local red_st, red_out = with_free(0, function()
    return run("echo x > /tmp/space_red.txt")
end)
check("a redirect onto a full filesystem is refused", red_st == 1, tostring(red_st))
check("the refusal says the filesystem is full",
      flat(red_out):find("not enough space: need 1 bytes, 0 free", 1, true) ~= nil,
      flat(red_out))
check("the refused redirect did not create the file", not fs.exists("/tmp/space_red.txt"))
write_file("/tmp/space_red2.txt", "old contents")
local red2_st = with_free(0, function()
    return run("echo x > /tmp/space_red2.txt")
end)
check("a refused redirect does not truncate an existing file",
      red2_st == 1 and file_text("/tmp/space_red2.txt") == "old contents",
      tostring(file_text("/tmp/space_red2.txt")))
check("an append onto a full filesystem is refused too",
      with_free(0, function()
          return run("echo x >> /tmp/space_red2.txt")
      end) == 1 and file_text("/tmp/space_red2.txt") == "old contents")
check("the redirect works again when there is room",
      run("echo y > /tmp/space_red.txt") == 0 and
      file_text("/tmp/space_red.txt") == "y\n", tostring(file_text("/tmp/space_red.txt")))

-- The diagnostic stream is a writer too ("2>"), and it is opened after stdout.
local err_st, err_out = with_free(0, function()
    return run("echo hi 2> /tmp/space_err.txt")
end)
check("a 2> redirect onto a full filesystem is refused", err_st == 1, tostring(err_st))
check("the 2> refusal names the file", flat(err_out):find("/tmp/space_err.txt", 1, true) ~= nil,
      flat(err_out))
check("the refused 2> did not create the file", not fs.exists("/tmp/space_err.txt"))

-- sed -i writes the same file back, so it is the same trap with a known size.
write_file("/tmp/space_sed.txt", "alpha\nbeta\n")
local sed_st, sed_out = with_free(3, function()
    return run("sed -i 's/alpha/gamma/' /tmp/space_sed.txt")
end)
check("sed -i refuses a write-back that does not fit", sed_st == 1, tostring(sed_st))
check("sed -i says how many bytes the new text takes",
      flat(sed_out):find("not enough space: need 11 bytes, 3 free", 1, true) ~= nil,
      flat(sed_out))
check("the refused sed -i left the file as it was",
      file_text("/tmp/space_sed.txt") == "alpha\nbeta\n",
      tostring(file_text("/tmp/space_sed.txt")))
check("sed -i writes it when there is room",
      run("sed -i 's/alpha/gamma/' /tmp/space_sed.txt") == 0 and
      file_text("/tmp/space_sed.txt") == "gamma\nbeta\n",
      tostring(file_text("/tmp/space_sed.txt")))

-- ============================================================
section("a refusal is a refusal: touch, mkdir, cat, and the status after a crash")
-- ============================================================
-- Found on a deployed machine, where lib/osguard.lua wraps the machine's fs
-- table: a guarded open answers nil, and fs.makeDir answers NOTHING even when it
-- works. Four built-ins read those answers wrongly.
--
--   touch  `local f = fs.open(p, "w"); f.close()` indexed the nil and the whole
--          line died with "attempt to index local 'f'";
--   run()  printed the error but left SHELL.status alone, so "$?" answered what
--          the line BEFORE the crash had answered -- 0;
--   mkdir  threw fs.makeDir's non-answer away and reported success;
--   cat    called a file it had been refused "no such file".
--
-- The permission model is the lever for the first two (an ordinary account may
-- not write /usr or /etc), and a scoped fs function is the lever for the rest:
-- it is the same nil a guard answers, without wrapping the suite's own table for
-- every section that follows.
-- Wrapped in one function on purpose: this file is at Lua's 200-local ceiling
-- (the same ceiling usr/psh.lua hit), and a do-block's locals count towards it.
local function refusal_section()
    local saved_user = perm.get_current_user()
    local real_open = fs.open
    local real_mkdir = fs.makeDir

    -- touch ------------------------------------------------------------------
    perm.set_current_user("bob")
    local st_t, o_t = run("touch /usr/permtest.txt")
    check("touch into /usr is refused for an ordinary account", st_t == 1, st_t)
    check("touch words the refusal as permission denied",
          flat(o_t):find("touch: /usr/permtest.txt: permission denied", 1, true) ~= nil,
          o_t)
    check("touch did not create the file", not fs.exists("/usr/permtest.txt"))
    -- The nil handle below the permission model is a failing status too, not the
    -- Lua error a bare "f.close()" made of it.
    fs.open = function(p, m)
        if p == "/tmp/touch_locked.txt" then return nil end
        return real_open(p, m)
    end
    local st_tn, o_tn = run("touch /tmp/touch_locked.txt")
    fs.open = real_open
    check("a nil handle from touch's own open is a failed command", st_tn == 1, st_tn)
    check("and touch says why instead of raising",
          flat(o_tn):find("attempt to index", 1, true) == nil and
          flat(o_tn):find("/tmp/touch_locked.txt", 1, true) ~= nil, o_tn)
    check("the file the refused open named was not created",
          not fs.exists("/tmp/touch_locked.txt"))
    -- A touch that works still works, and an existing file is left alone.
    local st_to = run("touch /tmp/touch_ok.txt")
    check("touch that works reports success and leaves a file",
          st_to == 0 and fs.exists("/tmp/touch_ok.txt"), st_to)
    local st_te = run("touch /tmp/touch_ok.txt")
    check("touch of a file that is already there succeeds", st_te == 0, st_te)

    -- mkdir ------------------------------------------------------------------
    local st_m, o_m = run("mkdir /etc/permtest.dir")
    check("mkdir in /etc is refused for an ordinary account", st_m == 1, st_m)
    check("mkdir words it as permission denied",
          flat(o_m):find("mkdir: /etc/permtest.dir: permission denied", 1, true) ~= nil,
          o_m)
    check("mkdir did not create the directory", not fs.exists("/etc/permtest.dir"))
    -- fs.makeDir's return value is not success on this platform: the directory
    -- has to be asked for.
    fs.makeDir = function(p)
        if p == "/tmp/silent_dir" then return nil end     -- creates nothing
        return real_mkdir(p)
    end
    local st_ms, o_ms = run("mkdir /tmp/silent_dir")
    fs.makeDir = real_mkdir
    check("a makeDir that created nothing is a failed mkdir", st_ms == 1, st_ms)
    check("and mkdir names what it could not create",
          flat(o_ms):find("/tmp/silent_dir", 1, true) ~= nil, o_ms)
    check("the directory it could not create is still missing",
          not fs.exists("/tmp/silent_dir"))
    local st_mo = run("mkdir /tmp/real_dir")
    check("mkdir that works reports success and leaves a directory",
          st_mo == 0 and fs.exists("/tmp/real_dir") and fs.isDir("/tmp/real_dir"),
          st_mo)
    -- "-p" walks the components; one that cannot be made must fail the command.
    fs.makeDir = function(p)
        if p == "/tmp/deep_one" then return nil end
        return real_mkdir(p)
    end
    local st_mp, o_mp = run("mkdir -p /tmp/deep_one/leaf")
    fs.makeDir = real_mkdir
    check("mkdir -p fails when one component cannot be created", st_mp == 1, st_mp)
    check("mkdir -p names the operand it was asked for",
          flat(o_mp):find("/tmp/deep_one/leaf", 1, true) ~= nil, o_mp)
    local st_mpp = run("mkdir -p /tmp/chain/one/two")
    check("mkdir -p that works creates every component",
          st_mpp == 0 and fs.isDir("/tmp/chain") and fs.isDir("/tmp/chain/one") and
          fs.isDir("/tmp/chain/one/two"), st_mpp)

    -- cat --------------------------------------------------------------------
    write_file("/etc/shadow", "root:not-a-real-hash\n")
    fs.open = function(p, m)
        if p == "/etc/shadow" then return nil end
        return real_open(p, m)
    end
    local st_c, o_c = run("cat /etc/shadow")
    fs.open = real_open
    check("cat of a file it may not open fails", st_c == 1, st_c)
    check("cat calls an unopenable file permission denied, not missing",
          flat(o_c):find("cat: /etc/shadow: permission denied", 1, true) ~= nil, o_c)
    check("cat does not claim a file it was refused is missing",
          flat(o_c):find("no such file", 1, true) == nil, o_c)
    local st_cm, o_cm = run("cat /tmp/really_missing.txt")
    check("cat still calls a missing file missing",
          st_cm == 1 and
          flat(o_cm):find("cat: /tmp/really_missing.txt: no such file", 1, true) ~= nil,
          o_cm)
    local st_cd, o_cd = run("cat /tmp")
    check("cat of a directory says it is one",
          st_cd == 1 and flat(o_cd):find("cat: /tmp: is a directory", 1, true) ~= nil,
          o_cd)
    local st_ck = run("cat /tmp/touch_ok.txt")
    check("cat still reads a file it may read", st_ck == 0, st_ck)

    -- the status a crash leaves behind ---------------------------------------
    perm.set_current_user("root")
    local st_before = run("true")
    check("fixture: the status is 0 before the crash", st_before == 0, st_before)
    local st_crash, o_crash = run("f() { f; }; f")
    check("a command that raises reports status 1", st_crash == 1, st_crash)
    check("and the message still says what happened",
          flat(o_crash):find("psh: ", 1, true) ~= nil, o_crash)
    local _, o_q = run("echo status=$?")
    check("$? is 1 after a command that raised",
          flat(o_q):find("status=1", 1, true) ~= nil, o_q)
    run("true")
    local _, o_q2 = run("echo status=$?")
    check("$? is 0 again after a command that worked",
          flat(o_q2):find("status=0", 1, true) ~= nil, o_q2)
    perm.set_current_user(saved_user)
end
refusal_section()

-- ------------------------------------------------------------- localization
-- lib/lang.lua is the message catalogue and the language switch. Three things
-- have to hold, and each of them failed in some earlier draft of this feature:
--   1. English output is BYTE-FOR-BYTE what it was before the catalogue existed
--      (a translation layer that quietly rewrites English is a regression with
--      no upside);
--   2. switching to a language the machine cannot render is REFUSED with the
--      reason, never accepted and then ignored;
--   3. a Chinese line written to a FILE is UTF-8 bytes, not glyphs -- the shell
--      writes glyphs to the console and bytes everywhere else.
local function lang_section()
    section("lang: the message catalogue, and the language switch")
    local lang = require("lang")

    -- The catalogue itself -----------------------------------------------------
    local keys = lang.keys()
    check("the catalogue has keys", #keys > 10, #keys)
    local missing = {}
    for _, k in ipairs(keys) do
        local e = lang.entry(k)
        if type(e) ~= "table" or type(e.en) ~= "string" or e.en == "" then
            missing[#missing + 1] = k .. " (no en)"
        end
    end
    check("every key has an English sentence", #missing == 0, table.concat(missing, ", "))

    -- An unknown key says its own name instead of printing nothing: a silent
    -- empty line is the one outcome an operator cannot debug.
    check("an unknown key prints the key itself", lang.text("no_such_key") == "no_such_key")

    -- English is the default and must be unchanged -----------------------------
    check("the session starts in English", lang.get() == "en", lang.get())
    check("the banner hint is the English sentence",
          lang.text("banner_hint") == "type 'help' for commands", lang.text("banner_hint"))
    check("an error key is the English sentence",
          lang.text("err_denied") == "permission denied", lang.text("err_denied"))

    -- Chinese is refused when it cannot be drawn -------------------------------
    -- The PC stub has no glyph medium, so this is the "cannot speak it" case.
    local ok_zh, why_zh = lang.available("zh")
    check("zh is unavailable without the glyph medium", ok_zh == false, tostring(why_zh))
    check("and the refusal names the medium",
          type(why_zh) == "string" and #why_zh > 10, tostring(why_zh))
    local set_ok, set_why = lang.set("zh")
    check("setting zh is refused rather than silently ignored", set_ok == false)
    check("the language is still English after the refusal", lang.get() == "en", lang.get())
    check("the refusal carries a reason", type(set_why) == "string" and #set_why > 10)

    local ok_xx, why_xx = lang.available("xx")
    check("an unknown language is refused", ok_xx == false)
    check("and it is called unknown, not unavailable",
          tostring(why_xx):find("unknown", 1, true) ~= nil, tostring(why_xx))

    -- The command ------------------------------------------------------------
    local st_status, o_status = run("lang")
    check("lang with no argument reports the language", st_status == 0, st_status)
    check("the report names the current language",
          flat(o_status):find("language: en", 1, true) ~= nil, o_status)
    check("the report lists both languages",
          flat(o_status):find(" en ", 1, true) ~= nil and
          flat(o_status):find(" zh ", 1, true) ~= nil, o_status)

    local st_en = run("lang en")
    check("lang en succeeds", st_en == 0, st_en)

    local st_zh, o_zh = run("lang zh")
    check("lang zh fails when the glyph medium is out", st_zh == 1, st_zh)
    check("and it says what is missing",
          flat(o_zh):find("font", 1, true) ~= nil, o_zh)

    local st_bad, o_bad = run("lang xx")
    check("lang xx is a failure", st_bad == 1, st_bad)
    check("lang xx says the language is unknown",
          flat(o_bad):find("unknown language", 1, true) ~= nil, o_bad)

    local st_help, o_help = run("lang --help")
    check("lang --help prints the usage", st_help == 0 and
          flat(o_help):find("usage: lang", 1, true) ~= nil, o_help)

    -- Saving is root only: a session may not decide for the next boot ---------
    local saved_user = perm.get_current_user()
    perm.set_current_user("alice")
    local st_save, o_save = run("lang --save en")
    check("a non-root session cannot save the language", st_save == 1, st_save)
    check("and it points at sudo",
          flat(o_save):find("sudo lang --save", 1, true) ~= nil, o_save)
    check("no file was written for the next boot", not fs.exists("/etc/locale.conf"))

    perm.set_current_user("root")
    local st_rsave = run("lang --save en")
    check("root can save the language", st_rsave == 0, st_rsave)
    check("/etc/locale.conf now exists", fs.exists("/etc/locale.conf"))
    local h = fs.open("/etc/locale.conf", "r")
    local conf_text = h.readAll() or ""
    h.close()
    check("the file carries lang=en", conf_text:find("lang=en", 1, true) ~= nil, conf_text)

    -- load() reads it back ---------------------------------------------------
    check("load() reads the saved language", lang.load() == "en", lang.load())
    fs.delete("/etc/locale.conf")
    perm.set_current_user(saved_user)

    -- A Chinese line written to a file is BYTES -------------------------------
    -- The point of the split: emit() gives a redirection bytes, so a file can
    -- carry UTF-8 even on a machine that cannot draw a single glyph of it.
    local cjk = "\228\184\173\230\150\135"      -- U+4E2D U+6587
    local st_w = run("echo " .. cjk .. " > /tmp/cjk.txt")
    check("writing Chinese through a redirect succeeds", st_w == 0, st_w)
    local fh = fs.open("/tmp/cjk.txt", "r")
    local written = fh and (fh.readAll() or "") or ""
    if fh then fh.close() end
    check("the file holds the UTF-8 bytes, not glyphs",
          written:find(cjk, 1, true) ~= nil, written)
    check("the file is exactly one line of six bytes",
          #(written:gsub("%s+$", "")) == #cjk, #written)
    fs.delete("/tmp/cjk.txt")

    -- The decoder must produce REAL codepoints ---------------------------------
    -- This is the assertion that would have caught the first version of say():
    -- it recorded only the LENGTH of a UTF-8 sequence and compared that against
    -- the CJK range, so 0x800 < 0x2E80 classified every three-byte character as
    -- ordinary text. On a machine with the glyph medium mounted that meant the
    -- Chinese went out through term.write (garbage on a CraftOS screen) while
    -- term.blit was never called -- and the PC suite could not see it, because
    -- with no font medium the fallback path is what runs here.
    local dec = lang.decode("\228\184\173")          -- U+4E2D, three bytes
    check("the decoder reads one character from three bytes", #dec == 1, #dec)
    check("and it is the real codepoint, not the byte length",
          dec[1] and dec[1].cp == 0x4E2D, dec[1] and dec[1].cp)
    check("so a Chinese character is classified as CJK", dec[1] and dec[1].cjk == true)
    local dec_ascii = lang.decode("A")
    check("ASCII decodes to itself", dec_ascii[1] and dec_ascii[1].cp == 65)
    check("and ASCII is not CJK", dec_ascii[1] and dec_ascii[1].cjk == false)
    local dec_mix = lang.decode("a\228\184\173b")
    check("a mixed string keeps its three characters", #dec_mix == 3, #dec_mix)
    check("with CJK only in the middle",
          dec_mix[1] and not dec_mix[1].cjk and dec_mix[2] and dec_mix[2].cjk and
          dec_mix[3] and not dec_mix[3].cjk)

    -- The boot screen ---------------------------------------------------------
    -- startup.lua clears the ROM's banner before anything of ours is drawn, and
    -- clears again after the BIOS gate, because that gate draws its own "press DEL
    -- to enter SETUP" prompt AFTER the first clear (measured on the GUI: that one
    -- line survived). Both calls are guarded, because an error on the first
    -- statement of the boot script stops the watchdog from ever starting.
    local boot_src = _G.SH_SRC and _G.SH_SRC.startup or ""
    check("the boot script is available for a source assertion", #boot_src > 1000,
          #boot_src)
    local _, clears = boot_src:gsub('pcall%(shell%.run, "clear"%)', "")
    check("the boot script clears the ROM banner, and again after the BIOS gate",
          clears == 2, clears)
    -- Strip the leading comment lines, then the first statement must be the clear.
    local first_code = boot_src
    while true do
        local rest = first_code:match("^%-%-[^\n]*\n(.*)$")
        if not rest then break end
        first_code = rest
    end
    check("the first thing it does is that clear, not something that can fail",
          first_code:find('pcall(shell.run, "clear")', 1, true) ~= nil,
          first_code:sub(1, 40))
    check("and the clear is guarded so a missing shell cannot brick the boot",
          boot_src:find('type(shell) == "table"', 1, true) ~= nil)

    -- English output is untouched by the writer -------------------------------
    -- emit() only diverts to the renderer for text with multibyte characters, so
    -- an ASCII line takes the same print() path it always did.
    local _, o_plain = run("echo hello")
    check("plain ASCII still prints as plain ASCII",
          flat(o_plain):find("hello", 1, true) ~= nil, o_plain)

    -- The log-out path: a message that was never run by any suite ------------
    -- The desktop's "log out" drops /var/lib/.logout, and the shell honours it at
    -- the session boundary. That branch used to build its message as
    -- "psh: logging out" .. NL, where NL is defined NOWHERE in usr/psh.lua -- and
    -- because the branch is only reachable by clicking log out on a real machine,
    -- no suite ever executed it. Measured on the GUI: leaving the desktop printed
    --   /usr/psh.lua:8747: attempt to concatenate global 'NL' (a nil value)
    -- and the shell died at the moment the operator asked to leave. This assertion
    -- is the regression: the message must be a plain string, and the source must
    -- not mention a bare NL anywhere.
    local psh_src = _G.SH_SRC and _G.SH_SRC.psh or ""
    check("the shell source is available for a source assertion", #psh_src > 1000, #psh_src)
    local has_nl = psh_src:find("%.%.%s*NL%s*%)") or psh_src:find("%.%.%s*NL%s*,?%s*$")
    check("no message concatenates an undefined NL", has_nl == nil, has_nl)
    check("the log-out message is a plain string",
          psh_src:find('write_stdout("psh: logging out")', 1, true) ~= nil)
end
lang_section()

-- The result is published at the END, after every section: it used to be
-- captured before the last two, so the runner's count was smaller than the
-- number of assertions the file really ran (439 against 490 when the disk-space
-- section was added, which hid the new checks from the summary line).
_G.__RESULT = { pass = pass, fail = fail, fails = fails, sections = sections }
say("")
for _, s in ipairs(sections) do
    say(string.format("SECTION %-62s pass=%d fail=%d", s.name, s.pass, s.fail))
end
say(string.format("assertions: %d passed, %d failed", pass, fail))
for _, f in ipairs(fails) do
    say("  FAIL: " .. f)
end
