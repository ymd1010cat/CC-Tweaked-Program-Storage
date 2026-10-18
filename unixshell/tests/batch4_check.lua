-- batch4_check.lua - PC side logic assertions for the fourth batch, group C of
-- the ush project (disks and devices, logs, service boot, scheduled tasks).
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

-- ------------------------------------------------------------------ helpers
local function ensure_dir(path)
    if fs.exists(path) then return end
    local acc = ""
    for seg in path:gmatch("[^/]+") do
        acc = acc .. "/" .. seg
        if not fs.exists(acc) then fs.makeDir(acc) end
    end
end

local function write_file(path, text)
    local dir = path:match("^(.*)/[^/]+$")
    if dir and dir ~= "" then ensure_dir(dir) end
    local f = fs.open(path, "w")
    if not f then return false end
    f.write(text)
    f.close()
    return true
end

local function read_file(path)
    if not fs.exists(path) then return "" end
    local f = fs.open(path, "r")
    if not f then return "" end
    local text = f.readAll()
    f.close()
    return text or ""
end

local function count_lines(path)
    if not fs.exists(path) then return 0 end
    local f = fs.open(path, "r")
    if not f then return 0 end
    local n = 0
    while true do
        local line = f.readLine()
        if line == nil then break end
        n = n + 1
    end
    f.close()
    return n
end

local function first_line(path)
    if not fs.exists(path) then return nil end
    local f = fs.open(path, "r")
    if not f then return nil end
    local line = f.readLine()
    f.close()
    return line
end

for _, d in ipairs({ "/mnt", "/mnt/floppy", "/mnt/floppy2", "/mnt/floppy3",
                     "/mnt/mydisk", "/mnt/mydisk2", "/etc", "/etc/rc.d",
                     "/var", "/var/log", "/var/lib", "/var/tmp", "/var/spool",
                     "/tmp", "/home", "/rom" }) do
    ensure_dir(d)
end

-- ============================================================
section("lib/boot - boot identity and the once per boot marker")
-- ============================================================
local boot = require("boot")

local e1 = boot.epoch()
local e2 = boot.epoch()
check("boot.epoch returns a number", type(e1) == "number")
check("boot.epoch is stable inside one boot", math.abs(e1 - e2) <= 60,
      tostring(e1) .. "/" .. tostring(e2))
check("boot.id is the same instant as text", tonumber(boot.id()) == e1,
      boot.id())
check("boot.marker is nil for a missing file",
      boot.marker("/var/lib/absent.marker") == nil)
check("boot.same_boot is false without a marker",
      boot.same_boot("/var/lib/absent.marker") == false)

local first, id = boot.begin("/var/lib/markers/a.marker")
check("boot.begin reports the first call of this boot", first == true)
check("boot.begin writes the marker", boot.marker("/var/lib/markers/a.marker") == tostring(id),
      boot.marker("/var/lib/markers/a.marker"))
local again = boot.begin("/var/lib/markers/a.marker")
check("boot.begin reports later calls as not first", again == false)
check("boot.same_boot accepts the running boot",
      boot.same_boot("/var/lib/markers/a.marker") == true)

boot.write_marker("/var/lib/markers/b.marker", -1000)
check("a marker from another boot is not same_boot",
      boot.same_boot("/var/lib/markers/b.marker") == false)
check("boot.begin reruns for a marker from another boot",
      boot.begin("/var/lib/markers/b.marker") == true)
check("boot.begin makes the marker directory",
      boot.write_marker("/var/lib/markers/deep/c.marker", 7) == true
      and fs.exists("/var/lib/markers/deep/c.marker"))

-- ============================================================
section("lib/disk - media events drive the mount table")
-- ============================================================
local disk = require("disk")
local mounts = require("mounts")
mounts.ensure()

local function source_watched(path)
    for _, s in ipairs(disk.sources()) do
        if s == path then return true end
    end
    return false
end

check("disk watches the default sources", source_watched("/disk"))
check("disk.removable is true for a watched source", disk.removable("/disk") == true)
check("disk.removable is false for /rom", disk.removable("/rom") == false)
check("disk.removable is false for a random path", disk.removable("/home") == false)

fs.makeDir("/disk")
check("disk.present is true while the medium is there", disk.present("/disk") == true)
check("disk.present is false for an empty bay", disk.present("/disk2") == false)
check("disk.base_name falls back to the floppy convention",
      disk.base_name("/disk") == "floppy", disk.base_name("/disk"))
check("disk.base_name keeps the drive number",
      disk.base_name("/disk2") == "floppy2", disk.base_name("/disk2"))
check("disk.label is nil without the label file", disk.label("/disk") == nil)

write_file("/disk/.label", "MYDISK\n")
check("disk.label reads the label in lower case", disk.label("/disk") == "mydisk",
      tostring(disk.label("/disk")))
check("disk.base_name prefers the label", disk.base_name("/disk") == "mydisk",
      disk.base_name("/disk"))

local rep = disk.on_event("disk", "left")
check("a disk event mounts the medium",
      #rep == 1 and rep[1] and rep[1]:find("/mnt/mydisk", 1, true) ~= nil,
      rep[1])
check("the disk event report carries the side",
      rep[1] and rep[1]:find("(side left)", 1, true) ~= nil, rep[1])
check("the mount table holds the new entry",
      disk.mounted("/disk") ~= nil and disk.mounted("/disk").target == "/mnt/mydisk")

local rep_same = disk.on_event("disk", "left")
check("a repeated event does not mount twice", #rep_same == 0, #rep_same)

fs.makeDir("/disk2")
write_file("/disk2/.label", "MYDISK\n")
local rep2 = disk.on_event("disk", nil)
check("a second medium with the same label gets a free target",
      #rep2 == 1 and rep2[1] and rep2[1]:find("/mnt/mydisk2", 1, true) ~= nil,
      rep2[1])

-- take the first medium out again
fs.delete("/disk/.label")
fs.delete("/disk")
check("disk.lost reports the medium that disappeared", #disk.lost() == 1,
      #disk.lost())
local rep3 = disk.on_event("disk_eject")
check("a disk_eject event unmounts the lost medium",
      #rep3 == 1 and rep3[1] and rep3[1]:find("unmounted", 1, true) ~= nil,
      rep3[1])
check("the mount table drops the entry", disk.mounted("/disk") == nil)

disk.set_automount(false)
fs.makeDir("/disk3")
local rep_off = disk.on_event("disk", "left")
check("automount off leaves a new medium alone", #rep_off == 0, #rep_off)
disk.set_automount(true)
local rep_on = disk.on_event("disk", "left")
check("automount on mounts it again",
      #rep_on == 1 and rep_on[1] and rep_on[1]:find("/mnt/floppy3", 1, true) ~= nil,
      rep_on[1])

local rows = disk.status()
check("disk.status has one row per watched source", #rows == #disk.sources(), #rows)
local seen_mounted = false
for _, r in ipairs(rows) do
    if r.source == "/disk2" and r.target == "/mnt/mydisk2" and r.present then
        seen_mounted = true
    end
end
check("disk.status shows the mounted medium", seen_mounted)

clear()
local rc_status = disk.main({ "status" })
local o_status = out()
check("disk(8) status reports the automount flag",
      o_status:find("automount: on", 1, true) ~= nil, o_status)
check("disk(8) status prints a table header",
      o_status:find("SOURCE", 1, true) ~= nil and o_status:find("MOUNTED ON", 1, true) ~= nil)
check("disk(8) status exits 0", rc_status == 0)

clear()
local rc_scan = disk.main({ "scan" })
check("disk(8) scan prints a report and exits 0",
      rc_scan == 0 and out() ~= "", out())

clear()
local rc_umount = disk.main({ "umount" })
check("disk(8) umount takes every removable mount down",
      rc_umount == 0 and has("unmounted"), out())
check("no removable mount is left", #disk.lost() == 0)

check("disk keeps a log file", fs.exists(disk.log_file))
local disk_log = read_file(disk.log_file)
check("the log records the mount action", disk_log:find("action=mount", 1, true) ~= nil)
check("the log records the umount action", disk_log:find("action=umount", 1, true) ~= nil)

-- the event pump used by scripts and the watchdog
fs.makeDir("/disk")
local ok_drain, drain_rep = pcall(disk.drain, 4, 0.2)
check("disk.drain returns a report list",
      ok_drain and type(drain_rep) == "table", tostring(drain_rep))
os.queueEvent("disk", "left")
local ok_drain2, drained = pcall(disk.drain, 4, 0.2)
check("disk.drain picks up a queued disk event",
      ok_drain2 and type(drained) == "table" and #drained >= 1
      and tostring(drained[1]):find("/mnt/floppy", 1, true) ~= nil,
      ok_drain2 and table.concat(drained, " / ") or tostring(drained))
disk.main({ "umount" })

-- ============================================================
section("lib/logrotate - limits, rotation and the archive chain")
-- ============================================================
local lr = require("logrotate")

check("parse_size reads plain bytes", lr.parse_size("1024") == 1024)
check("parse_size reads k", lr.parse_size("256k") == 256 * 1024)
check("parse_size reads M", lr.parse_size("2M") == 2 * 1024 * 1024)
check("parse_size reads g", lr.parse_size("1g") == 1024 * 1024 * 1024)
check("parse_size accepts a number", lr.parse_size(2048) == 2048)
check("parse_size rejects junk", lr.parse_size("abc") == nil)

local targets, bad = lr.parse_config(
    "/var/log/a.log max_lines=100 keep=2\n" ..
    "/var/log/b.log max_size=1k bogus=7\n" ..
    "# comment\n" ..
    "\n")
check("parse_config reads both targets", #targets == 2, #targets)
check("parse_config reads max_lines and keep",
      targets[1] and targets[1].max_lines == 100 and targets[1].keep == 2)
check("parse_config reads max_size through parse_size",
      targets[2] and targets[2].max_size == 1024)
check("parse_config reports the unknown key",
      #bad == 1 and bad[1] == "bogus", table.concat(bad, ","))

-- rotation driven by the line limit
write_file("/var/log/rot.log", ("line\n"):rep(120))
local rotated, rec = lr.check("/var/log/rot.log", { max_lines = 100, keep = 2 })
check("check rotates a log over the line limit",
      rotated == true and rec ~= nil and rec.reason == "lines",
      rotated and rec and rec.reason or tostring(rotated))
check("the live log is emptied", lr.count_lines("/var/log/rot.log") == 0,
      lr.count_lines("/var/log/rot.log"))
check("the first generation holds the old lines",
      lr.count_lines("/var/log/rot.log.1") == 120)
check("archives lists the first generation",
      #lr.archives("/var/log/rot.log", { keep = 2 }) == 1)

write_file("/var/log/rot.log", ("two\n"):rep(120))
lr.check("/var/log/rot.log", { max_lines = 100, keep = 2 })
check("the second rotation pushes .1 down to .2",
      lr.count_lines("/var/log/rot.log.2") == 120)
check("the first generation holds the new lines",
      first_line("/var/log/rot.log.1") == "two", tostring(first_line("/var/log/rot.log.1")))
check("archives lists two generations",
      #lr.archives("/var/log/rot.log", { keep = 2 }) == 2)

write_file("/var/log/rot.log", ("three\n"):rep(120))
lr.check("/var/log/rot.log", { max_lines = 100, keep = 2 })
check("keep=2 stores exactly two generations",
      fs.exists("/var/log/rot.log.2") and not fs.exists("/var/log/rot.log.3"))
check("read_archive reads generation 2",
      lr.read_archive("/var/log/rot.log", 2, 1)[1] == "two",
      tostring(lr.read_archive("/var/log/rot.log", 2, 1)[1]))

-- an explicit rotate ignores the limits
write_file("/var/log/rot.log", "small\nsmall\nsmall\n")
local forced = lr.rotate("/var/log/rot.log", { keep = 3 }, true)
check("an explicit rotate archives a small log", forced ~= nil)
check("the live log is emptied by the explicit rotate",
      lr.count_lines("/var/log/rot.log") == 0)
check("the explicit rotate produced a 3 line generation",
      lr.count_lines("/var/log/rot.log.1") == 3)

-- merged limits: caller option, then configuration, then defaults
local m1 = lr.merged("/var/log/rot.log", { max_lines = 7 })
check("merged prefers the caller option", m1.max_lines == 7, m1.max_lines)
check("merged falls back to the default keep", m1.keep == lr.defaults.keep,
      tostring(m1.keep))
write_file("/etc/logrotate.conf", "/var/log/cfg.log max_lines=11 keep=1\n")
local m2 = lr.merged("/var/log/cfg.log", {})
check("merged prefers the configuration over the defaults",
      m2.max_lines == 11 and m2.keep == 1, tostring(m2.max_lines) .. "/" .. tostring(m2.keep))
check("targets uses the configuration when there is one",
      #lr.targets() == 1 and lr.targets()[1].path == "/var/log/cfg.log")

-- audit.log rotates through logrotate
local audit = require("audit")
write_file("/var/log/auth.log", ("x\n"):rep(6000))
audit.log({ actor = "root", action = "test", target = "/etc", result = "ok" })
check("audit.log appends through its own limits",
      read_file("/var/log/auth.log"):find("action=test", 1, true) ~= nil,
      read_file("/var/log/auth.log"))
check("audit rotates the log when it grew past the limit",
      fs.exists("/var/log/auth.log.1"))
check("the live audit log holds only the new line",
      lr.count_lines("/var/log/auth.log") == 1, lr.count_lines("/var/log/auth.log"))
check("audit.archives reports the generation",
      #audit.archives() >= 1, #audit.archives())

fs.delete("/etc/logrotate.conf")

clear()
local rc_lr = lr.main({ "status" })
local o_lr = out()
check("logrotate(8) status lists the watched logs",
      o_lr:find("/var/log", 1, true) ~= nil, o_lr)
check("logrotate(8) status exits 0", rc_lr == 0)

clear()
local rc_show = lr.main({ "show", "/var/log/rot.log", "-n", "1" })
check("logrotate(8) show prints something for a live log",
      rc_show == 0 and out() ~= "", out())

-- ============================================================
section("lib/sessionlog - login accounting behind last / lastlog / who")
-- ============================================================
-- Two data sets: /var/log/wtmp (append only events, rotated through
-- logrotate) and /var/lib/sessions/*.dat (one live record per console). The
-- readers are last/lastlog (history) and who/w (live). The pairing rule is
-- what matters for "last": a logout carries the "since" of its login, and the
-- "end" of a logout is only on the logout line.
local sessionlog = require("sessionlog")

-- a clean slate: a previous suite may have left a session record behind
if fs.exists(sessionlog.session_file()) then fs.delete(sessionlog.session_file()) end
if fs.exists("/var/log/wtmp") then fs.delete("/var/log/wtmp") end
if fs.exists("/var/log/wtmp.1") then fs.delete("/var/log/wtmp.1") end
if fs.exists("/var/log/wtmp.2") then fs.delete("/var/log/wtmp.2") end
if fs.exists("/var/log/wtmp.3") then fs.delete("/var/log/wtmp.3") end

check("the tty name is derived from the computer id",
      sessionlog.tty() == "tty" .. tostring(os.getComputerID()), sessionlog.tty())
check("the live record of a console lives under /var/lib/sessions",
      sessionlog.session_file() == "/var/lib/sessions/" .. sessionlog.tty() .. ".dat",
      sessionlog.session_file())
check("session_file takes an explicit tty too",
      sessionlog.session_file("tty9") == "/var/lib/sessions/tty9.dat",
      sessionlog.session_file("tty9"))

check("with nothing logged there is no current session", sessionlog.current() == nil)
check("with nothing logged nobody is online", #sessionlog.online() == 0)
check("with nothing logged the history is empty", #sessionlog.history(false) == 0)
check("logging out with no session is a no-op", sessionlog.logout() == nil)

-- a login writes both data sets
local rec = sessionlog.login("admin", "console")
check("login returns the session record", type(rec) == "table" and rec.user == "admin",
      tostring(rec and rec.user))
check("the record carries the tty and the computer id",
      rec.tty == sessionlog.tty() and rec.cid == tostring(os.getComputerID()),
      tostring(rec.tty) .. "/" .. tostring(rec.cid))
check("the record carries a login timestamp", type(rec.since) == "number" and rec.since > 0,
      tostring(rec.since))
check("login wrote the live session record",
      sessionlog.current() ~= nil and sessionlog.current().user == "admin",
      tostring(sessionlog.current() and sessionlog.current().user))
check("login appended to the event log", count_lines("/var/log/wtmp") == 1,
      count_lines("/var/log/wtmp"))
check("the event line is a login with the same timestamp",
      read_file("/var/log/wtmp"):find("type=login", 1, true) ~= nil and
      read_file("/var/log/wtmp"):find("since=" .. tostring(rec.since), 1, true) ~= nil,
      read_file("/var/log/wtmp"))
check("the note is recorded", read_file("/var/log/wtmp"):find("note=console", 1, true) ~= nil,
      read_file("/var/log/wtmp"))
check("who lists the live session", #sessionlog.online() == 1 and
      sessionlog.online()[1].user == "admin", #sessionlog.online())

local events = sessionlog.history(false)
check("history parses the login event",
      #events == 1 and events[1].type == "login" and events[1].user == "admin",
      #events .. " " .. tostring(events[1] and events[1].type))
check("a login event has no end time", events[1].finish == nil,
      tostring(events[1].finish))
check("the parsed timestamp is a string",
      type(events[1].time) == "string" and #events[1].time > 0, tostring(events[1].time))

-- su: the console changes hands, so the old login is closed and a new one opens
local sw = sessionlog.switch_user("other", "su")
check("switch_user returns the new record", sw.user == "other", tostring(sw.user))
check("switch_user leaves exactly one live session",
      #sessionlog.online() == 1 and sessionlog.online()[1].user == "other",
      #sessionlog.online())
local after_switch = sessionlog.history(false)
check("switch_user closed the old login and opened the new one",
      #after_switch == 3, #after_switch)
check("the closure is a logout of the previous user",
      after_switch[2].type == "logout" and after_switch[2].user == "admin",
      after_switch[2].type .. "/" .. after_switch[2].user)
check("the logout carries the since of its login",
      after_switch[2].since == rec.since,
      tostring(after_switch[2].since) .. " vs " .. tostring(rec.since))
check("only a logout line carries an end time",
      after_switch[2].finish ~= nil and after_switch[1].finish == nil,
      tostring(after_switch[1].finish) .. "/" .. tostring(after_switch[2].finish))
check("switch_user records the note on both lines",
      after_switch[2].note == "su" and after_switch[3].note == "su",
      tostring(after_switch[2].note) .. "/" .. tostring(after_switch[3].note))

-- a login on top of a live session means the previous shell died
local rec2 = sessionlog.login("third", "console")
check("a login over a live session is accepted", rec2.user == "third")
local after_crash = sessionlog.history(false)
check("the abandoned session is closed as a crash",
      after_crash[4].type == "logout" and after_crash[4].note == "crash",
      after_crash[4].type .. "/" .. after_crash[4].note)
check("the crash logout belongs to the user who was on the console",
      after_crash[4].user == "other", after_crash[4].user)
check("the console now belongs to the new user",
      sessionlog.current() and sessionlog.current().user == "third",
      tostring(sessionlog.current() and sessionlog.current().user))

-- logout closes the record and removes the live file
local gone = sessionlog.logout("bye")
check("logout returns the closed record", gone and gone.user == "third",
      tostring(gone and gone.user))
check("logout removes the live session record",
      not fs.exists(sessionlog.session_file()))
check("after logout nobody is online", #sessionlog.online() == 0, #sessionlog.online())
check("after logout there is no current session", sessionlog.current() == nil)
local final = sessionlog.history(false)
check("the logout was appended with its note",
      final[#final].type == "logout" and final[#final].note == "bye",
      final[#final].type .. "/" .. tostring(final[#final].note))
check("a second logout is a no-op", sessionlog.logout("again") == nil)
check("the history is unchanged by the no-op logout",
      #sessionlog.history(false) == #final, #sessionlog.history(false))

-- two consoles at once: online() is per file, oldest first. The tty names are
-- deliberately in the OPPOSITE order to the login times, so a missing sort is
-- visible: alphabetical order (tty8, tty9) is not the order to report.
write_file(sessionlog.session_file("tty9"),
           textutils.serialize({ user = "early", tty = "tty9", cid = "9",
                                 since = 100, note = "console" }))
write_file(sessionlog.session_file("tty8"),
           textutils.serialize({ user = "later", tty = "tty8", cid = "8",
                                 since = 200, note = "console" }))
local both = sessionlog.online()
check("online reports every live console", #both == 2, #both)
check("online is sorted by login time, oldest first",
      both[1].user == "early" and both[2].user == "later",
      tostring(both[1].user) .. "/" .. tostring(both[2].user))
check("online reports the oldest session first even when the tty sorts later",
      both[1].tty == "tty9", tostring(both[1].tty))
check("a record without a user is not reported as a session",
      (function()
          write_file(sessionlog.session_file("tty7"), "{ this is not a table }")
          local ok, list = pcall(sessionlog.online)
          return ok and #list == 2
      end)(), "a corrupt .dat must not break who")
fs.delete(sessionlog.session_file("tty7"))
fs.delete(sessionlog.session_file("tty8"))
fs.delete(sessionlog.session_file("tty9"))

-- rotation: wtmp goes through logrotate like the other logs
write_file("/var/log/wtmp",
           ("[2026-01-01 00:00:00 UTC] type=login user=x tty=tty5 cid=5 since=1 note=n\n"):rep(5001))
sessionlog.login("after-rotation", "console")
check("an over-long wtmp is rotated away",
      fs.exists("/var/log/wtmp.1"), "logrotate keeps the generation")
check("the live wtmp only holds the new login",
      count_lines("/var/log/wtmp") == 1, count_lines("/var/log/wtmp"))
check("archives reports the generation",
      #sessionlog.archives() == 1 and sessionlog.archives()[1].index == 1,
      #sessionlog.archives())
check("history(true) reads the rotated generation as well",
      #sessionlog.history(true) > #sessionlog.history(false),
      #sessionlog.history(true) .. " vs " .. #sessionlog.history(false))
check("history(false) ignores the rotated log",
      #sessionlog.history(false) == 1, #sessionlog.history(false))

-- the readers the commands use agree with the library
sessionlog.logout("exit")
fs.delete("/var/log/wtmp.1")
if fs.exists("/var/log/wtmp") then fs.delete("/var/log/wtmp") end

-- ============================================================
section("lib/services - /etc/rc.d units, markers and boot order")
-- ============================================================
local services = require("services")

write_file("/etc/rc.d/10-net.sh", [[
name = "net"
description = "simulated network"
function start() print("net: up") end
function stop() print("net: down") end
function status() return "running" end
]])

write_file("/etc/rc.d/20-clock.sh", [[
name = "clock"
function start()
    local ok = pcall(fs.open, "/tmp/sandbox.txt", "w")
    print("clock: write blocked=" .. tostring(not ok))
    local st = service.start("net")
    print("clock: net=" .. tostring(st))
end
function stop() print("clock: down") end
function status() return "ok" end
]])

write_file("/etc/rc.d/30-broken.sh", [[
name = "broken"
function start() error("boom") end
]])

write_file("/etc/rc.d/40-syntax.sh", "function start( \n")

local units = services.list()
check("services.list reads every unit file", #units == 4, #units)
check("services.list parses name and order",
      units[1].name == "net" and units[1].order == 10,
      units[1].name .. "/" .. tostring(units[1].order))
check("services.list keeps the file name order",
      units[4].name == "syntax", units[4].name)

local parsed = services.parse_name("20-clock.sh")
check("parse_name reads the order and the name",
      type(parsed) == "table" and parsed.name == "clock" and parsed.order == 20)
check("parse_name rejects a file that does not match",
      services.parse_name("README.md") == nil)
check("path_of accepts a bare name",
      services.path_of("net") == "/etc/rc.d/10-net.sh", tostring(services.path_of("net")))
check("path_of returns nothing for an unknown unit", services.path_of("nope") == nil)

local env = services.load("/etc/rc.d/10-net.sh")
check("load returns an environment with start()",
      type(env) == "table" and type(env.start) == "function")
check("the sandbox has no shell", env and env.shell == nil)
check("the sandbox has no write side of fs",
      env and env.fs and env.fs.write == nil and env.fs.open ~= fs.open)
local bad_env, bad_err = services.load("/etc/rc.d/40-syntax.sh")
check("a unit with a syntax error does not load",
      bad_env == nil and tostring(bad_err):find("syntax error", 1, true) ~= nil,
      tostring(bad_err))

clear()
local ok_start, started_name = services.start("net")
check("start brings the unit up and names it",
      ok_start == true and started_name == "net", tostring(started_name))
check("start writes the this boot marker",
      fs.exists("/etc/rc.d/run/net.started"))
check("the unit output reaches the terminal", has("net: up"), out())

local ok_twice, why_twice = services.start("net")
check("start skips a unit that is already up",
      ok_twice == false
      and tostring(why_twice):find("already started", 1, true) ~= nil,
      tostring(why_twice))
local ok_force = services.start("net", { force = true })
check("force starts the unit again", ok_force == true)

clear()
local ok_clock, clock_name = services.start("clock")
local o_clock = out()
check("start runs a unit that uses the control API",
      ok_clock == true and clock_name == "clock", tostring(clock_name))
check("the sandbox blocks writes from a unit",
      o_clock:find("clock: write blocked=true", 1, true) ~= nil, o_clock)
check("service.start is reachable from a unit",
      o_clock:find("clock: net=true", 1, true) ~= nil, o_clock)
check("the cross call started net again",
      o_clock:find("net: up", 1, true) ~= nil, o_clock)

local ok_broken, why_broken = services.start("broken")
check("start fails when start() raises",
      ok_broken == false and tostring(why_broken):find("boom", 1, true) ~= nil,
      tostring(why_broken))
check("a failed unit leaves no marker",
      fs.exists("/etc/rc.d/run/broken.started") == false)

clear()
local ok_stop = services.stop("clock")
check("stop runs stop() and clears the marker",
      ok_stop == true and fs.exists("/etc/rc.d/run/clock.started") == false)
check("stop output reaches the terminal", has("clock: down"), out())

clear()
local ok_restart = services.restart("net")
check("restart stops and starts the unit",
      ok_restart == true and has("net: down") and has("net: up"), out())

local state_net = services.state("net")
check("state reports an up unit with its status string",
      state_net and state_net.up == true and state_net.state == "running",
      state_net and tostring(state_net.state))

local rows_svc = services.status()
local row_of = {}
for _, r in ipairs(rows_svc) do row_of[r.name] = r end
check("service status has one row per unit", #rows_svc == 4, #rows_svc)
check("service status marks the live unit up",
      row_of.net and row_of.net.up == true)
check("service status marks a broken unit down",
      row_of.broken and row_of.broken.up == false)
check("service status flags a unit that cannot load",
      row_of.syntax and row_of.syntax.loaded == false and row_of.syntax.state == "broken",
      row_of.syntax and tostring(row_of.syntax.state))

services.stop("net")
services.stop("clock")
clear()
local boot_res = services.boot()
check("boot starts the good units in order",
      #boot_res.started == 2 and boot_res.started[1] == "net"
      and boot_res.started[2] == "clock",
      table.concat(boot_res.started, ","))
check("boot records the two broken units and carries on",
      #boot_res.failed == 2, #boot_res.failed)
check("boot leaves net up", services.state("net").up == true)

local boot_res2 = services.boot()
check("a second boot starts nothing", #boot_res2.started == 0, #boot_res2.started)
check("a second boot skips the units that are up",
      #boot_res2.skipped == 2, #boot_res2.skipped)

clear()
local done, stop_failed = services.shutdown()
check("shutdown stops the units in reverse order",
      #done == 2 and done[1] == "clock" and done[2] == "net",
      table.concat(done, ","))
check("shutdown reports the unit that cannot be stopped",
      #stop_failed == 1 and stop_failed[1].name == "syntax",
      stop_failed[1] and stop_failed[1].name)
check("no unit is left up", services.state("net").up == false)

local service_log = read_file(services.log_file)
check("service.log records the actions",
      service_log:find("unit=net", 1, true) ~= nil
      and service_log:find("action=start", 1, true) ~= nil, service_log)
check("service.log records the failures",
      service_log:find("result=error", 1, true) ~= nil)
check("services.logs filters by unit",
      #services.logs(20, "unit=broken") >= 1, #services.logs(20, "unit=broken"))

clear()
local rc_svc = services.main({ "list" })
local o_svc = out()
check("service(8) lists the units",
      o_svc:find("net", 1, true) ~= nil and o_svc:find("broken", 1, true) ~= nil, o_svc)
check("service(8) list exits 0", rc_svc == 0)
clear()
services.main({ "help" })
check("service(8) help prints the usage", has("usage: service"), out())
clear()
services.main({ "log", "3" })
check("service(8) log prints the tail", has("unit="), out())

-- status() has to hand back the entries that /etc/rc.d could not use, so that
-- "service list" can explain the units it skipped instead of blowing up on an
-- ipairs(nil) when a stray file or directory sits in /etc/rc.d.
local rows_clean, bad_clean = services.status()
check("status returns the rows and the skipped list",
      type(rows_clean) == "table" and type(bad_clean) == "table",
      type(bad_clean))
check("the skipped list is empty on a clean /etc/rc.d", #bad_clean == 0, #bad_clean)

write_file("/etc/rc.d/README.md", "notes\n")
fs.makeDir("/etc/rc.d/50-tools")
local rows_dirty, bad_dirty = services.status()
check("status reports every entry it skipped", #bad_dirty == 2, #bad_dirty)
local why = {}
for _, b in ipairs(bad_dirty) do why[b.file] = b.reason end
check("a stray file is skipped with the naming rule",
      why["README.md"] == "expected NNN-name.sh", tostring(why["README.md"]))
check("a directory is skipped as a directory",
      why["50-tools"] == "directory", tostring(why["50-tools"]))
check("the skipped entries do not change the unit rows", #rows_dirty == 4, #rows_dirty)

clear()
local ok_list = pcall(services.main, { "list" })
local o_list = out()
check("service(8) list survives an unusable entry", ok_list == true)
check("service(8) list still prints the table",
      o_list:find("SERVICE", 1, true) ~= nil
      and o_list:find("net", 1, true) ~= nil, o_list)
check("service(8) list explains the skipped file",
      o_list:find("README.md: skipped (expected NNN-name.sh)", 1, true) ~= nil, o_list)
check("service(8) list explains the skipped directory",
      o_list:find("50-tools: skipped (directory)", 1, true) ~= nil, o_list)

clear()
local rc_s_named = services.main({ "status", "net" })
check("service(8) status NAME exits 0 for a known unit",
      rc_s_named == 0 and has("net"), out())
clear()
local rc_s_bare = services.main({ "status" })
check("service(8) status without a name falls back to the listing",
      rc_s_bare == 0 and has("SERVICE"), out())

fs.delete("/etc/rc.d/README.md")
fs.delete("/etc/rc.d/50-tools")

clear()
local rc_boot = services.main({ "boot" })
local o_boot = out()
check("service(8) boot starts the units that work",
      o_boot:find("service: net started", 1, true) ~= nil
      and o_boot:find("service: clock started", 1, true) ~= nil, o_boot)
check("service(8) boot names the units that failed",
      o_boot:find("service: broken failed", 1, true) ~= nil, o_boot)
check("service(8) boot exits 1 when a unit failed", rc_boot == 1, rc_boot)

clear()
local rc_shut = services.main({ "shutdown" })
local o_shut = out()
check("service(8) shutdown stops the units that are up",
      o_shut:find("service: clock stopped", 1, true) ~= nil
      and o_shut:find("service: net stopped", 1, true) ~= nil, o_shut)
check("service(8) shutdown exits 1 when a unit failed", rc_shut == 1, rc_shut)

clear()
local rc_shut2 = services.main({ "shutdown" })
local o_shut2 = out()
-- stop() of a unit that has one is called again (the marker is simply cleared),
-- the run stays quiet only for the units that have no stop() function.
check("a second shutdown reports the units as stopped again",
      o_shut2:find("service: clock stopped", 1, true) ~= nil
      and o_shut2:find("service: net stopped", 1, true) ~= nil, o_shut2)
check("a second shutdown still names the unit that cannot load",
      o_shut2:find("service: syntax failed", 1, true) ~= nil, o_shut2)
check("a second shutdown exits 1 while a unit is stuck", rc_shut2 == 1, rc_shut2)
check("the units stay down after the second shutdown",
      services.state("net").up == false and services.state("clock").up == false)

-- ============================================================
section("lib/cron - @reboot entries and per user tables")
-- ============================================================
local cron = require("cron")

local rb, rb_err = cron.parse_line("@reboot alice echo hello")
check("parse_line recognises @reboot",
      rb ~= nil and rb.special == true and rb.alias == "@reboot",
      tostring(rb_err))
check("@reboot carries the owner and the command",
      rb and rb.user == "alice" and rb.command == "echo hello",
      rb and tostring(rb.user))
check("@reboot does not occupy time fields",
      rb and rb.minute == nil and rb.hour == nil and rb.dow == nil)

local rb_bad, rb_bad_err = cron.parse_line("@reboot onlyuser")
check("@reboot without a command is rejected",
      rb_bad == nil and tostring(rb_bad_err):find("need", 1, true) ~= nil,
      tostring(rb_bad_err))

local plain = cron.parse_line("*/5 * * * * root echo tick")
check("a plain line still parses", plain ~= nil and plain.minute == "*/5",
      plain and tostring(plain.minute))
local daily = cron.parse_line("@daily root echo d")
check("@daily expands to a midnight spec",
      daily ~= nil and daily.alias == "@daily" and daily.hour == "0",
      daily and tostring(daily.hour))

cron.install_for("root", { "*/5 * * * * root echo r" })
cron.install_for("alice", { "@reboot alice echo a" })
check("install_for keeps one table per user",
      #cron.entries_for("root") == 1 and #cron.entries_for("alice") == 1,
      #cron.entries_for("root") .. "/" .. #cron.entries_for("alice"))
check("@reboot survives the round trip through /etc/crontab",
      cron.entries_for("alice")[1].special == true)

cron.install_for("alice", { "0 1 * * * alice echo new" })
check("re-installing replaces the lines of that user",
      #cron.entries_for("alice") == 1
      and cron.entries_for("alice")[1].command == "echo new",
      cron.entries_for("alice")[1] and cron.entries_for("alice")[1].command)
check("re-installing leaves the other users alone",
      #cron.entries_for("root") == 1)
check("remove_for clears one user only",
      (function()
          cron.remove_for("alice")
          return #cron.entries_for("alice") == 0 and #cron.entries_for("root") == 1
      end)())

-- @reboot fires once per boot, and the boot identity is a marker file
cron.remove_for("root")
cron.install_for("root", { "@reboot root echo booted" })

local fired = {}
local function runner(...)
    local parts = {}
    for i = 1, select("#", ...) do
        parts[#parts + 1] = tostring((select(i, ...)))
    end
    fired[#fired + 1] = table.concat(parts, " ")
    return 0
end

local now = os.time()
local s1 = cron.run_due(now, runner)
check("run_due fires the @reboot entry once",
      s1 and s1.reboot and #s1.reboot == 1, s1 and #s1.reboot)
check("the runner saw the reboot command",
      fired[1] ~= nil and fired[1]:find("echo booted", 1, true) ~= nil,
      fired[1])
check("run_due reports a summary table", s1 and type(s1.errors) == "table")

local s2 = cron.run_due(now + 60, runner)
check("the @reboot entry does not fire twice in one boot",
      s2 and s2.reboot and #s2.reboot == 0 and #fired == 1, #fired)

local marker = cron.reboot_marker
check("cron exposes the @reboot marker path", type(marker) == "string",
      tostring(marker))
if type(marker) == "string" then
    boot.write_marker(marker, -1000)
    local s3 = cron.run_due(now + 120, runner)
    check("a marker from another boot fires @reboot again",
          s3 and s3.reboot and #s3.reboot == 1, s3 and #s3.reboot)
end

cron.log({ user = "alice", command = "echo hi", level = "crontab" }, "ok", "assert",
         { exit = 0 })
local alice_logs = cron.logs(10, "user=alice")
check("cron.logs filters on the user field",
      #alice_logs >= 1 and alice_logs[1]:find('command="echo hi"', 1, true) ~= nil,
      alice_logs[1])

-- ============================================================
section("usr/ush.lua - crontab with -u and the root gate")
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

perm.add_user("alice")
perm.add_user("guest")

local st_l, o_l = run("crontab -l")
check("crontab -l lists the table of the caller",
      st_l == 0 and o_l:find("crontab for root", 1, true) ~= nil, o_l)
check("crontab -l shows the @reboot line",
      o_l:find("@reboot root echo booted", 1, true) ~= nil, o_l)

local st_u, o_u = run("crontab -u alice -l")
check("root may read another user table",
      st_u == 0 and o_u:find("crontab for alice", 1, true) ~= nil, o_u)

local st_nu, o_nu = run("crontab -u nobody -l")
check("an unknown user is rejected",
      st_nu == 1 and o_nu:find("unknown user", 1, true) ~= nil, o_nu)

write_file("/var/tmp/alice.cron", "*/10 * * * * echo hi\n@reboot echo boot\n")
local st_i, o_i = run("crontab -u alice /var/tmp/alice.cron")
check("a file installs into the table of that user",
      st_i == 0 and o_i:find("installed for alice", 1, true) ~= nil, o_i)
local alice_entries = cron.entries_for("alice")
check("both lines landed in the table of alice", #alice_entries == 2, #alice_entries)
check("the @reboot line gets the caller as owner",
      alice_entries[2] and alice_entries[2].user == "alice"
      and alice_entries[2].command == "echo boot", alice_entries[2] and alice_entries[2].line)
check("the plain line got a user as well",
      alice_entries[1] and alice_entries[1].user == "alice", alice_entries[1] and alice_entries[1].line)

local st_d, o_d = run("crontab -u alice -r")
check("crontab -u USER -r removes that table",
      st_d == 0 and #cron.entries_for("alice") == 0, o_d)

perm.set_current_user("guest")
local st_g, o_g = run("crontab -u alice -l")
check("a plain user may not use -u",
      st_g == 1 and o_g:find("only root may use -u", 1, true) ~= nil, o_g)
local st_g2, o_g2 = run("crontab -l")
check("a plain user still sees the own table",
      st_g2 == 0 and o_g2:find("crontab for guest", 1, true) ~= nil, o_g2)
perm.set_current_user("root")

-- ============================================================
section("regression: the earlier batches still hold on this build")
-- ============================================================
local st_e, o_e = run("echo smoke")
check("ush still runs a built-in", st_e == 0 and o_e:find("smoke", 1, true) ~= nil, o_e)
local _, o_df = run("df")
check("df still prints its header", o_df:find("Filesystem", 1, true) ~= nil, o_df)
local st_m, o_m = run("mount /disk /mnt/floppy")
check("mount still writes the table",
      st_m == 0 and o_m:find("/mnt/floppy", 1, true) ~= nil, o_m)
local _, o_dm = run("df /mnt/floppy")
check("df still follows a mount point", o_dm:find("/mnt/floppy", 1, true) ~= nil, o_dm)
local st_p, o_p = run("mount | grep floppy")
check("the pipe still works", st_p == 0 and o_p:find("floppy", 1, true) ~= nil, o_p)
write_file("/etc/rc.d/stray.txt", "not a unit\n")
local st_svc, o_svc = run("service list")
check("service list survives a stray file in /etc/rc.d",
      st_svc == 0 and o_svc:find("stray.txt: skipped", 1, true) ~= nil, o_svc)
check("service list still shows the real units",
      o_svc:find("net", 1, true) ~= nil and o_svc:find("SERVICE", 1, true) ~= nil, o_svc)
fs.delete("/etc/rc.d/stray.txt")

-- ============================================================
section("lib/marker - the setup marker, and the gate it replaced")
-- ============================================================
-- The licence gate is gone (2026-10-17): no authserver, no RSA, no license.lua.
-- lib/marker.lua is the setup marker now -- firstboot writes it, startup asks
-- marker.done() before the shell starts -- and these assertions are about the
-- two things the gate still has to get right: the marker is bound to THIS
-- computer, and nothing signs it, so "a signed licence" cannot be claimed again.
do
    local marker = require("marker")
    marker.clear()
    check("a fresh machine has no setup marker", marker.done() == false)
    check("and nothing for --clean-firstboot to erase", marker.exists() == false)

    marker.write({ computerId = tostring(os.getComputerID()) })
    check("writing it makes the machine set up", marker.done() == true)
    check("and it is written where the tooling looks", marker.exists() == true)
    local m = marker.read()
    check("the marker names this computer",
          m ~= nil and tostring(m.computerId) == tostring(os.getComputerID()),
          m and tostring(m.computerId))
    check("and says the machine is set up", m ~= nil and m.setup == true)
    check("there is no signature in it", m ~= nil and m.signature == nil)

    -- bound to the machine: a marker written for another computer does not count
    marker.clear()
    marker.write({ computerId = "999999" })
    check("a marker written for another computer does not count", marker.done() == false)
    check("but it is still something to erase", marker.exists() == true)
    marker.clear()
    check("clearing leaves nothing behind",
          marker.exists() == false and marker.done() == false)

    local src = (_G.SH_SRC or {}).startup
    if type(src) ~= "string" then
        say("  SKIP the setup gate source (startup.lua is not in SH_SRC)")
    else
        check("the boot gate asks the setup marker", src:find("marker.done()", 1, true) ~= nil)
        check("and no longer requires a licence module",
              src:find('require("license")', 1, true) == nil)
    end
end

-- ============================================================
say("")
say("=== batch 4 (group C) summary ===")
say(string.format("passed: %d  failed: %d", pass, fail))
if fail > 0 then
    for _, name in ipairs(fails) do
        say("  FAIL " .. name)
    end
end

_G.__RESULT = { pass = pass, fail = fail, report = table.concat(fails, "\n") }
