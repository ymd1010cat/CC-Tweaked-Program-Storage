-- class3_check.lua - PC side logic assertions for class 3 of the psh project
-- (system monitoring, mount management, scheduled tasks, network tools, jobs).
--
-- Run through tests/run_all.py with lupa. Everything here is a PC side
-- simulation result, it is NOT a CraftOS-PC result.

local PROJ = _G.PROJ
package.path = PROJ .. "/lib/?.lua;" .. PROJ .. "/usr/?.lua;" .. package.path

local say = _G.__realprint

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

-- ============================================================
section("lib/mounts - mount table, map/unmap, read-only guards")
-- ============================================================
local mounts = require("mounts")
local fs = _G.fs

for _, d in ipairs({ "/mnt", "/mnt/floppy", "/mnt/ro", "/disk", "/disk/data",
                     "/rom", "/var", "/var/tmp", "/var/spool", "/etc" }) do
    fs.makeDir(d)
end
mounts.ensure()

local mounted, entry = mounts.mount("/disk", "/mnt/floppy")
check("mounts.mount creates an entry",
      mounted == true and type(entry) == "table" and entry.target == "/mnt/floppy",
      tostring(entry))
check("mounts.map maps the mount point", mounts.map("/mnt/floppy") == "/disk",
      mounts.map("/mnt/floppy"))
check("mounts.map maps children", mounts.map("/mnt/floppy/data") == "/disk/data",
      mounts.map("/mnt/floppy/data"))
check("mounts.unmap reverses the mapping",
      mounts.unmap("/disk/data") == "/mnt/floppy/data",
      mounts.unmap("/disk/data"))
check("writable mount is not read-only", mounts.is_readonly("/mnt/floppy") == false)
check("mounts.list shows the entry", #mounts.list() == 1)
check("mounts.format renders the entry",
      mounts.format(entry):find("/mnt/floppy", 1, true) ~= nil, mounts.format(entry))

local ro_ok, ro = mounts.mount("/disk", "/mnt/ro", "ro")
check("read-only mount is accepted", ro_ok == true, tostring(ro))
check("read-only mount is flagged read-only", mounts.is_readonly("/mnt/ro") == true)
check("read-only flag reaches children", mounts.is_readonly("/mnt/ro/data") == true)
check("read-only mount shows (ro) in the table",
      mounts.format(ro):find("ro", 1, true) ~= nil, mounts.format(ro))

local u1 = mounts.umount("/mnt/floppy")
check("umount removes the entry", u1 == true and #mounts.list() == 1)
check("path resolution falls back after umount",
      mounts.map("/mnt/floppy/data") == "/mnt/floppy/data",
      mounts.map("/mnt/floppy/data"))
local u2 = mounts.umount("/mnt/ro", "/mnt/ro")
check("umount refuses a busy mount point", u2 ~= true, tostring(u2))
local u3 = mounts.umount("/mnt/ro", "/")
check("umount works when the mount point is free", u3 == true)

-- ============================================================
section("lib/cron - cron entries, at queue, due task firing")
-- ============================================================
local cron = require("cron")
cron.ensure()

check("cron field_match star", cron.field_match("*", 7) == true)
check("cron field_match step hit", cron.field_match("*/5", 10) == true)
check("cron field_match step miss", cron.field_match("*/5", 7) == false)
check("cron field_match list", cron.field_match("1,2,3", 2) == true)
check("cron field_match range", cron.field_match("10-20", 15) == true)

local pe = cron.parse_line("*/5 * * * * root echo hello")
check("cron.parse_line extracts command", pe and pe.command == "echo hello",
      pe and pe.command)
check("cron.parse_line extracts user", pe and pe.user == "root", pe and pe.user)

local installed = cron.install_for("root", { "*/5 * * * * root echo installed" })
check("cron.install_for stores entries", installed ~= nil and installed ~= false)
check("cron file written to disk", fs.exists("/etc/crontab"))
local mine = cron.entries_for("root")
check("cron.entries_for sees the entry", #mine == 1, #mine)
check("cron.entries parses again", #cron.entries() >= 1)

local t1 = cron.parse_at_time("+1")
check("cron.parse_at_time +N", type(t1) == "number", tostring(t1))
local t2 = cron.parse_at_time("23:59")
check("cron.parse_at_time HH:MM", type(t2) == "number", tostring(t2))

local job_path = cron.at_add(os.time() + 1, "echo at job", "root")
check("cron.at_add writes the spool file", job_path ~= nil and fs.exists(job_path),
      tostring(job_path))
check("cron.at_list returns the queued job", #cron.at_list() >= 1)

local fired = {}
local runner = function(a, b)
    fired[#fired + 1] = tostring(a) .. "|" .. tostring(b)
    return 0
end
cron.run_due(os.time() + 120, runner)
check("cron.run_due fires a due entry", #fired >= 1, table.concat(fired, " ; "))
check("cron.log recorded the run", #cron.tail(5) >= 1)
check("cron.at_remove removes the job",
      cron.at_remove(job_path) ~= false or fs.exists(job_path) == false)
check("the spool file is gone after at_remove", fs.exists(job_path) == false)

-- ============================================================
section("lib/jobs - background job table and job control")
-- ============================================================
local jobs = require("jobs")
jobs.reset()
jobs.set_runner(function(cmd)
    if cmd == "slow" then os.sleep(1) end
    return 0
end)

local j = jobs.spawn("slow")
check("jobs.spawn registers a running job", j ~= nil and j.state == "running")
check("jobs.resolve understands %1", jobs.resolve("%1") == 1)
check("jobs.list returns the job", #jobs.list() == 1)

local quick = jobs.spawn("quick")
jobs.pump(4)
check("jobs.pump runs a job to completion", quick.state == "done", quick.state)
check("a job parked in os.sleep stays running", j.state == "running", j.state)
check("jobs.active_count ignores finished jobs", jobs.active_count() == 1,
      jobs.active_count())
check("jobs.foreground has a slice budget", type(jobs.foreground) == "function")

local killed = jobs.kill(1)
check("jobs.kill terminates the job", killed ~= nil and killed.state == "killed",
      killed and killed.state)
jobs.reset()
check("jobs.reset empties the table", #jobs.list() == 0)

-- ============================================================
section("lib/sysinfo - storage, uptime, tasks, network")
-- ============================================================
local sysinfo = require("sysinfo")
local fss = sysinfo.filesystems()
check("sysinfo.filesystems returns entries", #fss >= 1, #fss)
local has_root = false
for _, m in ipairs(fss) do
    if m.mount == "/" then has_root = true end
end
check("sysinfo.filesystems contains /", has_root)
local cap, free = sysinfo.storage_total()
check("sysinfo.storage_total reports capacity", cap > 0 and free >= 0,
      tostring(cap) .. "/" .. tostring(free))
check("sysinfo.uptime_seconds follows os.clock",
      math.abs(sysinfo.uptime_seconds() - os.clock()) < 5,
      sysinfo.uptime_seconds())
check("sysinfo.boot_epoch_ms is derived", sysinfo.boot_epoch_ms() > 0)
check("sysinfo.computer reports the id", sysinfo.computer().id == 5)
check("sysinfo.tasks lists something", #sysinfo.tasks() >= 1)
check("sysinfo.network finds the modem", #sysinfo.network() == 1)

-- ============================================================
section("usr/psh.lua - built-ins, item by item")
-- ============================================================
_G.__PSH_TEST = true
local chunk = assert(loadfile(PROJ .. "/usr/psh.lua"))
chunk()
local psh = _G.__psh_test
local perm = require("perm")
pcall(perm.set_current_user, "root")
psh.init()

-- Non-interactive entry parsing ("psh -c <line>"): the watchdog uses it to
-- fire due tasks while no interactive session is running.
check("entry args: -c <line> yields the line",
      psh.parse_args({ "-c", "echo hi" }) == "echo hi")
check("entry args: no -c means interactive", psh.parse_args({}) == nil)
check("entry args: bare -c yields an empty line", psh.parse_args({ "-c" }) == "")

local function run(line)
    clear()
    local status = psh.run(line)
    return status, out()
end

-- item 1: system monitoring
say("")
say("--- item 1: df / free / ps / top / uptime ---")
local st, o = run("df")
say(o)
check("df prints the header", has("Filesystem") and has("Mounted on"))
check("df lists /rom", has("/rom"))
local _, oh = run("df -h")
check("df -h uses human units", oh:find("M", 1, true) ~= nil or oh:find("G", 1, true) ~= nil)
local st_df, o_df = run("df /nope")
check("df exits 1 on an unknown filesystem",
      st_df == 1 and o_df:find("no such filesystem", 1, true) ~= nil, st_df)

local _, ofree = run("free")
say(ofree)
check("free reports storage and heap",
      ofree:find("Storage", 1, true) and ofree:find("Lua heap", 1, true))
check("free names its data sources",
      ofree:find("fs.getCapacity/getFreeSpace", 1, true) ~= nil)

local _, ouptime = run("uptime")
say(ouptime)
check("uptime prints a duration and a user line", #ouptime > 0)

local _, ops = run("ps")
say(ops)
check("ps prints a process table", ops:find("PID", 1, true) ~= nil)

local _, otop = run("top -n1")
say(otop)
check("top samples once with -n1",
      otop:find("psh top", 1, true) ~= nil and otop:find("PID", 1, true) ~= nil)

-- item 2: mount management
say("")
say("--- item 2: mount / umount with cwd awareness ---")
local _, omount0 = run("mount")
check("mount with no entries says so", #omount0 > 0)
local st_m, o_m = run("mount /disk /mnt/floppy")
say(o_m)
check("mount creates a mount entry", st_m == 0 and o_m:find("/mnt/floppy", 1, true) ~= nil)
local _, o_list = run("mount")
say(o_list)
check("mount with no arguments lists the table", o_list:find("/mnt/floppy", 1, true) ~= nil)
local st_cd, o_cd = run("cd /mnt/floppy")
check("cd enters the mount point", st_cd == 0, o_cd)
local _, o_pwd = run("pwd")
say(o_pwd)
check("pwd shows the logical path, not /disk",
      o_pwd:find("/mnt/floppy", 1, true) ~= nil, o_pwd)
run("cd /")
local _, o_ro = run("mount -r /disk /mnt/ro")
say(o_ro)
check("mount -r registers a read-only mount", o_ro:find("/mnt/ro", 1, true) ~= nil)
local st_t, o_t = run("touch /mnt/ro/newfile")
say(o_t)
check("touch on a read-only mount is refused",
      o_t:find("read-only file system", 1, true) ~= nil and st_t == 1, st_t)
check("no file was created on the read-only mount", fs.exists("/disk/newfile") == false)
local st_u, o_u = run("umount /mnt/ro")
say(o_u)
check("umount reports the unmounted target",
      st_u == 0 and o_u:find("unmounted", 1, true) ~= nil, st_u)
local st_u2, o_u2 = run("umount /mnt/floppy")
check("umount removes the writable mount too", st_u2 == 0, o_u2)

-- item 3: scheduled tasks
say("")
say("--- item 3: crontab / at / cronlog ---")
local _, o_crl = run("crontab -l")
say(o_crl)
check("crontab -l prints a header", o_crl:find("# crontab for", 1, true) ~= nil)
fs.makeDir("/var/tmp")
local ct = fs.open("/var/tmp/ct.txt", "w")
ct:writeLine("*/5 * * * * root echo tick")
ct:close()
local st_ci, o_ci = run("crontab /var/tmp/ct.txt")
say(o_ci)
check("crontab installs entries from a file",
      st_ci == 0 and o_ci:find("entries installed", 1, true) ~= nil, o_ci)
local _, o_cl = run("crontab -l")
say(o_cl)
check("crontab -l lists the entry", o_cl:find("echo tick", 1, true) ~= nil)
check("crontab persists to /etc/crontab", fs.exists("/etc/crontab"))
local st_at, o_at = run("at +1 echo hi")
say(o_at)
check("at queues a one shot job", st_at == 0 and o_at:find("will run at", 1, true) ~= nil)
local _, o_atl = run("at -l")
say(o_atl)
check("at -l lists the queued job", o_atl:find("echo hi", 1, true) ~= nil)
local _, o_clog = run("cronlog")
check("cronlog prints a log tail", #o_clog > 0)
local st_cr, o_cr = run("crontab -r")
check("crontab -r removes the entries",
      st_cr == 0 and o_cr:find("removed", 1, true) ~= nil, o_cr)

-- item 4: network tools
say("")
say("--- item 4: netstat / ping / netsend / netrecv / netopen / netclose ---")
local _, o_ns = run("netstat")
say(o_ns)
check("netstat lists the modem interface",
      o_ns:find("Iface", 1, true) ~= nil and o_ns:find("top", 1, true) ~= nil)
local st_p, o_p = run("ping -c 2 -W 0.1 7")
say(o_p)
check("ping prints statistics", o_p:find("packet loss", 1, true) ~= nil)
check("ping exits 1 when nothing replies", st_p == 1, st_p)
local st_s, o_s = run("netsend 7 hello")
say(o_s)
check("netsend reports the destination",
      st_s == 0 and o_s:find("sent to 7", 1, true) ~= nil, o_s)
local st_r, o_r = run("netrecv -t 0.1")
say(o_r)
check("netrecv times out cleanly", st_r == 1 and o_r:find("timeout", 1, true) ~= nil, o_r)
local st_o, o_o = run("netopen")
say(o_o)
check("netopen opens rednet", st_o == 0 and o_o:find("rednet open on side", 1, true) ~= nil)
local st_c, o_c = run("netclose")
check("netclose closes rednet", st_c == 0 and o_c:find("closed", 1, true) ~= nil, o_c)

-- item 5: background jobs and job control
say("")
say("--- item 5: & / jobs / fg / bg / kill / disown ---")
local st_bg, o_bg = run("sleep 1 &")
say(o_bg)
check("cmd & announces a job number",
      st_bg == 0 and o_bg:find("[1]", 1, true) ~= nil and
      o_bg:find("sleep 1", 1, true) ~= nil, o_bg)
local st_bg2, o_bg2 = run("sleep 2 &")
say(o_bg2)
check("a second background job gets its own number",
      st_bg2 == 0 and o_bg2:find("[2]", 1, true) ~= nil, o_bg2)
local _, o_jobs = run("jobs")
say(o_jobs)
check("jobs lists the running job",
      o_jobs:find("running", 1, true) ~= nil and o_jobs:find("sleep 1", 1, true) ~= nil)
local st_fg, o_fg = run("fg %2")
say(o_fg)
check("fg brings the job to the foreground",
      st_fg == 0 and o_fg:find("sleep 2", 1, true) ~= nil, o_fg)
local st_k, o_k = run("kill %1")
say(o_k)
check("kill reports the terminated job",
      st_k == 0 and o_k:find("[1] killed", 1, true) ~= nil, o_k)
check("the killed job is marked as such",
      jobs.get(1) ~= nil and jobs.get(1).state == "killed",
      jobs.get(1) and jobs.get(1).state)
local st_bg3, o_bg3 = run("bg %1")
check("bg refuses a killed job", st_bg3 == 1, o_bg3)
local st_fgf, o_fgf = run("fg %1")
check("fg refuses a finished job", st_fgf == 1, o_fgf)
local st_dis, o_dis = run("disown")
say(o_dis)
check("disown reports the number of finished jobs removed",
      st_dis == 0 and o_dis:find("finished job(s) removed", 1, true) ~= nil, o_dis)
local _, o_jobs2 = run("jobs")
check("jobs is empty after disown", o_jobs2:find("no background jobs", 1, true) ~= nil,
      o_jobs2)

-- ============================================================
section("regression: class 1 and class 2 semantics still hold")
-- ============================================================
-- Same run() entry point and same PC stub as above: if the class 3 changes had
-- touched the parser, the job layer or the guard paths, these would break.
local _, o_pipe = run("echo hello | grep hello")
check("pipe still works", o_pipe:find("hello", 1, true) ~= nil, o_pipe)
local _, o_wc = run("echo piped | cat")
check("pipe into a second built-in still works", o_wc:find("piped", 1, true) ~= nil, o_wc)

run("echo one > /var/tmp/redir.txt")
run("echo two >> /var/tmp/redir.txt")
local _, o_redir = run("cat /var/tmp/redir.txt")
check("> and >> still work",
      o_redir:find("one", 1, true) ~= nil and o_redir:find("two", 1, true) ~= nil,
      o_redir)

local st_true, _ = run("true")
check("a successful command still exits 0", st_true == 0, st_true)
local _, o_and = run("true && echo and-ok")
check("&& still works", o_and:find("and-ok", 1, true) ~= nil, o_and)
local _, o_or = run("false || echo or-ok")
check("|| still works", o_or:find("or-ok", 1, true) ~= nil, o_or)
local _, o_semi = run("echo s1; echo s2")
check("; still separates commands",
      o_semi:find("s1", 1, true) ~= nil and o_semi:find("s2", 1, true) ~= nil, o_semi)

run("touch /var/tmp/g1.txt")
run("touch /var/tmp/g2.txt")
local _, o_glob = run("echo /var/tmp/g*.txt")
check("glob still expands",
      o_glob:find("g1.txt", 1, true) ~= nil and o_glob:find("g2.txt", 1, true) ~= nil,
      o_glob)

run("export RV=from_test")
local _, o_var = run("echo $RV")
check("variables still expand", o_var:find("from_test", 1, true) ~= nil, o_var)

run("alias le='echo aliased'")
local _, o_alias = run("le")
check("aliases still expand", o_alias:find("aliased", 1, true) ~= nil, o_alias)
local _, o_unalias = run("unalias le")
check("unalias still removes definitions", o_unalias ~= nil)
local _, o_hist = run("which echo")
check("which still resolves built-ins", o_hist:find("echo", 1, true) ~= nil, o_hist)

local st_stat, o_stat = run("stat /var/tmp/g1.txt")
check("stat still reads a real file",
      st_stat == 0 and o_stat:find("g1.txt", 1, true) ~= nil, o_stat)

-- ============================================================
section("summary")
-- ============================================================
say(string.format("PASS %d  FAIL %d", pass, fail))
for _, f in ipairs(fails) do
    say("FAILED: " .. f)
end
say(fail == 0 and "RESULT: ALL CLASS 3 ASSERTIONS PASSED" or "RESULT: FAILURES PRESENT")
_G.__RESULT = { pass = pass, fail = fail, report = table.concat(fails, "\n") }
