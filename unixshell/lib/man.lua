-- man.lua - the manual pages of the ush shell.
--
-- The pages are plain data: nothing in this file touches the filesystem, the
-- terminal or any CraftOS API, so man can be read, searched and rendered from
-- a PC side Lua state as well as on the real machine.
--
-- Shape of one page:
--   what  one line description, shown in NAME and in "man -l"
--   syn   array of command lines, shown in SYNOPSIS
--   note  optional array of sentences, shown in DESCRIPTION
--   opts  optional array of { "-x", "what it does" }, shown in OPTIONS
--   sub   optional array of { "name", "what it does" }, shown in SUBCOMMANDS
--   see   optional comma separated list, shown in SEE ALSO
--
-- The project keeps every source file ASCII only, so all text here is plain
-- ASCII without typographic quotes or dashes.

local man = {}

man.pages = {

-- ---------------------------------------------------------------- files
ls = {
    what = "list directory contents",
    syn = { "ls [-a] [-l] [PATH...]" },
    note = { "Directories are listed by name, files with their size unless -l",
             "is given. Without a PATH the current directory is listed." },
    opts = { { "-a", "also show entries whose name starts with a dot" },
             { "-l", "long format: mode, owner, size, name" } },
    see = "stat, du, find, which",
},
pwd = {
    what = "print the absolute path of the current directory",
    syn = { "pwd" },
    see = "cd, path",
},
lang = {
    what = "choose the language of the interface",
    syn = { "lang", "lang en", "lang zh", "lang --save en|zh" },
    note = { "Without an argument it reports the language in use, which",
             "languages this build knows, and -- when one of them cannot be",
             "used -- the reason: either the CJK renderer is not on the",
             "machine (it lives on the system module medium) or the glyph",
             "medium is not inserted. A language is refused rather than",
             "silently ignored, because an operator who believes the switch",
             "worked will blame the screen." },
    opts = { { "--save", "record the choice in /etc/locale.conf for the next" ..
                         " boot; root only, like desktop --autostart" } },
    see = "theme, set, help",
},
cd = {
    what = "change the current directory",
    syn = { "cd [PATH]" },
    note = { "Without a PATH cd goes to /. cd also resets the cwd of every",
             "running script frame, it is the single source of truth for the",
             "shell and for the libraries (lib/cwd.lua)." },
    see = "pwd, path",
},
mkdir = {
    what = "create directories",
    syn = { "mkdir [-p] PATH..." },
    opts = { { "-p", "create missing parents instead of failing" } },
    see = "rmdir, touch",
},
rmdir = {
    what = "remove empty directories",
    syn = { "rmdir PATH..." },
    note = { "A directory that still holds entries is refused, use rm -r." },
    see = "rm, mkdir",
},
cp = {
    what = "copy files and directories",
    syn = { "cp [-r] SRC... DST" },
    note = { "With one source, DST may be a new name or an existing directory.",
             "With several sources, DST must be an existing directory.",
             "The sources are measured before the first byte is written: a copy",
             "whose bytes are more than the destination filesystem has free is",
             "refused (need N bytes, M free) instead of filling the disk." },
    opts = { { "-r, -R", "copy directories recursively" } },
    see = "mv, ln, rm",
},
mv = {
    what = "move or rename a file or directory",
    syn = { "mv SRC DST" },
    note = { "If DST is an existing directory the source keeps its name and is",
             "moved into it, otherwise DST is the new name." },
    see = "cp, ln, rm",
},
rm = {
    what = "remove files and directories",
    syn = { "rm [-r] [-f] PATH..." },
    note = { "Without -f a missing operand is reported and the exit status is",
             "non zero. Directories need -r." },
    opts = { { "-r, -R", "recurse into directories" },
             { "-f", "ignore missing operands, never ask" } },
    see = "rmdir, cp, mv",
},
touch = {
    what = "create an empty file, or refresh an existing one",
    syn = { "touch PATH..." },
    note = { "A new file is created with mode rw-r--r--." },
    see = "mkdir, stat",
},
mktemp = {
    what = "create a unique temporary file or directory and print its name",
    syn = { "mktemp [-d] [TEMPLATE]" },
    opts = { { "-d", "create a directory instead of a file" } },
    note = { "The trailing run of X in TEMPLATE is replaced by random letters",
             "and digits, and the name is drawn again while it is already",
             "taken. The default template is /var/tmp/tmp.XXXXXX, and /var/tmp",
             "is created when it is missing.",
             "The new path is given the restricted mode rw------- (a directory",
             "gets rwx------), because a temporary file is exactly where",
             "another user would listen. A template with no X, or a name that",
             "could not be created, is reported and the status is 1." },
    see = "touch, crontab",
},
ln = {
    what = "link SRC as DST (copy based, CraftOS has no inodes)",
    syn = { "ln SRC DST" },
    note = { "The link is a real copy so that editing one side never changes",
             "the other. The original file is left alone." },
    see = "cp, mv",
},
stat = {
    what = "show mode, owner, size and timestamps of a path",
    syn = { "stat PATH..." },
    see = "ls, du, file",
},
du = {
    what = "summarise disk usage",
    syn = { "du [PATH...]" },
    note = { "Without a PATH the current directory is walked." },
    see = "df, free, stat",
},
file = {
    what = "guess the type of a file",
    syn = { "file PATH..." },
    see = "stat, ls",
},
basename = {
    what = "strip the directory part of a path",
    syn = { "basename PATH..." },
    see = "dirname, pwd",
},
dirname = {
    what = "strip the last part of a path",
    syn = { "dirname PATH..." },
    see = "basename, pwd",
},
realpath = {
    what = "print the canonical absolute path of each path",
    syn = { "realpath PATH..." },
    note = { "The path is made absolute, its . and .. parts are folded away and",
             "the mount table is applied, so the answer is the path this shell",
             "itself would use for the operand rather than a second opinion",
             "about paths. A path that does not exist is reported and the",
             "status is 1." },
    see = "pwd, cd, path, basename",
},
which = {
    what = "show what a command name resolves to",
    syn = { "which CMD" },
    note = { "Reports whether the name is a builtin, an alias or an external",
             "program in /usr/cmd, and prints the path that would be run." },
    see = "help, man, path",
},

-- ---------------------------------------------------------------- text
cat = {
    what = "write files to standard output",
    syn = { "cat [-n] [FILE...]" },
    opts = { { "-n", "number every output line" } },
    see = "head, tail, tee, wc",
},
grep = {
    what = "print the lines that match a pattern",
    syn = { "grep [-ivnclqrEF] PATTERN [FILE...]" },
    note = { "The pattern is a POSIX regular expression: basic by default,",
             "extended with -E, and a fixed string with -F. Without a FILE grep",
             "reads standard input. The status is 1 when no line was selected",
             "and 2 on a usage error." },
    opts = { { "-i", "ignore case" },
             { "-v", "select the lines that do not match" },
             { "-n", "prefix every line with its number" },
             { "-c", "print the number of matching lines only" },
             { "-l", "print the names of the matching files only" },
             { "-q", "quiet, status only" },
             { "-r", "walk directories recursively" },
             { "-E", "read the pattern as an extended regular expression" },
             { "-F", "read the pattern as a fixed string, not a pattern" } },
    see = "egrep, fgrep, sed, awk, sort, uniq",
},
egrep = {
    what = "print the lines that match an extended regular expression",
    syn = { "egrep PATTERN [FILE...]" },
    note = { "The historical spelling of grep -E: ( ) + ? | are operators.",
             "Everything else, including the status, is grep." },
    see = "grep, fgrep, sed",
},
fgrep = {
    what = "print the lines that contain a fixed string",
    syn = { "fgrep PATTERN [FILE...]" },
    note = { "The historical spelling of grep -F, and the pattern is a literal:",
             "every character of it stands for itself. fgrep 'a.b' finds the",
             "text a.b and never axb." },
    see = "grep, egrep",
},
sha256sum = {
    what = "print the SHA-256 digest of each input",
    syn = { "sha256sum [FILE...]" },
    note = { "Each line is the 64 character digest, two spaces and the name of",
             "the file. With no FILE the standard input is hashed and the name",
             "is a single -. A file that cannot be read is reported and the",
             "status is 1, and the status is 0 only when every input was read." },
    see = "md5sum, cksum",
},
md5sum = {
    what = "print the MD5 digest of each input",
    syn = { "md5sum [FILE...]" },
    note = { "The same line as sha256sum, with the 32 character MD5. MD5 is kept",
             "for the checksum files that already use it: it is not a digest to",
             "protect a password with." },
    see = "sha256sum, cksum, passwd",
},
cksum = {
    what = "print the POSIX checksum and the length of each input",
    syn = { "cksum [FILE...]" },
    note = { "The number is the POSIX CRC-32 of cksum(1): the polynomial",
             "0x04C11DB7 used most significant bit first, an initial value of",
             "zero, the length of the input fed through the same loop afterwards",
             "and the result complemented. It is NOT the CRC-32 of zip and PNG,",
             "which prints 3421780262 for 123456789 where cksum prints",
             "930766865.",
             "The line is the value, the length in bytes and the name. With no",
             "FILE the standard input is read and no name is printed." },
    see = "sha256sum, md5sum",
},
base64 = {
    what = "encode data as base64, or decode base64 back to data",
    syn = { "base64 [-d] [FILE]" },
    opts = { { "-d", "decode instead of encode" } },
    note = { "The standard alphabet with + and / and = padding is used, and the",
             "encoded form is one line with no break. Decoding ignores",
             "whitespace, so a blob that arrives with newlines in it is read as",
             "it stands; any other character outside the alphabet is an error",
             "with status 1 rather than a quietly shorter answer. Without a FILE",
             "the standard input is used." },
    see = "cat, sha256sum",
},
expr = {
    what = "evaluate an integer expression and print its value",
    syn = { "expr EXPRESSION" },
    note = { "The words are joined with single spaces and read as a C style",
             "integer expression, the same one the shell accepts in $(( )): the",
             "arithmetic operators, the comparisons == != < <= > >= and the",
             "logical && and ||, whose result is 1 or 0. The value is printed as",
             "a signed decimal number.",
             "The status is what a script reads: 0 when the value is neither 0",
             "nor empty, 1 when it is 0, and 2 when the expression cannot be",
             "parsed, so a broken expression is never mistaken for a false one." },
    see = "test, seq, set",
},
sed = {
    what = "stream editor for simple substitutions",
    syn = { "sed [-n] [-i] 'SCRIPT' [FILE...]" },
    note = { "Supported scripts: s/PATTERN/REPLACEMENT/FLAGS and addresses by",
             "line number or /pattern/. The replacement may use %1..%9." },
    opts = { { "-n", "do not print every line by default" },
             { "-i", "edit the file in place" } },
    see = "grep, awk, tr",
},
ed = {
    what = "line oriented text editor",
    syn = { "ed [FILE]" },
    note = { "Commands are read from the standard input when there is one and",
             "from the console otherwise. An address is a line number, $ for",
             "the last line or . for the current one; a bare address moves the",
             "current line. a appends after it, i inserts before it and c",
             "replaces it, each reading lines until a line that holds only a",
             "period. w writes the buffer to FILE (or the name given at",
             "startup) and reports the byte count; wq writes and quits; q",
             "refuses to quit while changes are unwritten, q! always quits." },
    opts = { { "a", "append lines after the current line" },
             { "i", "insert lines before the current line" },
             { "c", "change the addressed line into the lines typed" },
             { "d", "delete the addressed line" },
             { "p", "print the addressed line" },
             { "n", "print it with its line number" },
             { "=", "print the line number" },
             { "w [FILE]", "write the buffer and report the byte count" },
             { "wq", "write, then quit" },
             { "q", "quit, refusing when changes are unwritten" },
             { "q!", "quit without writing" },
             { "h, ?", "print the one line help" } },
    see = "cat, sed, grep",
},
awk = {
    what = "field oriented text processing",
    syn = { "awk [-F SEP] [-v VAR=VALUE] 'PROGRAM' [FILE...]" },
    note = { "The program is a list of PATTERN { ACTION } rules. Inside an",
             "action $0 is the line and $1..$9 are fields." },
    opts = { { "-F SEP", "field separator (default: spaces)" },
             { "-v K=V", "set a variable before the program runs" } },
    see = "grep, sed, cut",
},
head = {
    what = "print the first lines of a file",
    syn = { "head [-n N] [FILE...]", "head -N [FILE...]" },
    opts = { { "-n N, -N", "print N lines (default 10)" },
             { "-q", "never print file banners" },
             { "-v", "always print file banners" } },
    see = "tail, cat, tac",
},
tail = {
    what = "print the last lines of a file",
    syn = { "tail [-n N] [FILE...]", "tail -N [FILE...]", "tail +N [FILE...]" },
    note = { "+N starts at line N instead of counting from the end." },
    opts = { { "-n N, -N", "print N lines (default 10)" },
             { "+N", "start at line N" },
             { "-q", "never print file banners" },
             { "-v", "always print file banners" } },
    see = "head, cat, logrotate",
},
wc = {
    what = "count lines, words and characters",
    syn = { "wc [-l] [-w] [-c] [FILE...]" },
    opts = { { "-l", "lines only" }, { "-w", "words only" },
             { "-c", "characters only" } },
    see = "cat, grep",
},
sort = {
    what = "sort the lines of the input",
    syn = { "sort [-n] [-r] [-u] [-f] [-k N] [-t SEP] [FILE...]" },
    opts = { { "-n", "numeric order" },
             { "-r", "reverse" },
             { "-u", "drop duplicate lines" },
             { "-f", "ignore case" },
             { "-k N", "sort on field N" },
             { "-t SEP", "field separator for -k (default: blank runs)" } },
    see = "uniq, grep, cut",
},
uniq = {
    what = "collapse runs of equal lines",
    syn = { "uniq [-c] [-d] [-u] [-i] [FILE]" },
    opts = { { "-c", "prefix every line with its repeat count" },
             { "-d", "print repeated lines only" },
             { "-u", "print unique lines only" },
             { "-i", "ignore case" } },
    see = "sort, grep",
},
cut = {
    what = "select columns from every line",
    syn = { "cut -d SEP -f LIST [FILE...]", "cut -c LIST [-s] [FILE...]" },
    note = { "LIST is a comma separated list such as 1,3,5-7." },
    opts = { { "-d SEP", "field separator (default: tab)" },
             { "-f LIST", "keep these fields" },
             { "-c LIST", "keep these character positions" },
             { "-s", "drop lines without a separator" } },
    see = "awk, sort",
},
tr = {
    what = "translate or delete characters",
    syn = { "tr [-d] SET1 [SET2]" },
    opts = { { "-d", "delete the characters in SET1" } },
    see = "sed, awk",
},
tac = {
    what = "print the input with the line order reversed",
    syn = { "tac [FILE...]" },
    see = "rev, tail",
},
rev = {
    what = "reverse the characters of every line",
    syn = { "rev [FILE...]" },
    see = "tac",
},
tee = {
    what = "copy standard input to files and to standard output",
    syn = { "tee [-a] [-i] FILE..." },
    opts = { { "-a", "append instead of replacing" },
             { "-i", "ignore interrupts" } },
    see = "cat, source",
},
xargs = {
    what = "build command lines from standard input",
    syn = { "xargs [-n N] [-I REPL] [COMMAND [ARGS...]]" },
    note = { "The default command is echo. With -I every input line replaces",
             "REPL inside the command line." },
    opts = { { "-n N", "pass at most N arguments per run" },
             { "-I REPL", "replace REPL with one input line at a time" } },
    see = "find, echo",
},
find = {
    what = "walk a directory tree and report matching paths",
    syn = { "find [PATH] [-name PATTERN]" },
    note = { "Without a PATH the current directory is walked. The pattern is a",
             "Lua pattern matched against the file name." },
    opts = { { "-name PATTERN", "keep entries whose name matches" } },
    see = "ls, du, grep",
},
seq = {
    what = "print a sequence of numbers",
    syn = { "seq [FIRST [STEP]] LAST" },
    see = "echo, yes",
},
echo = {
    what = "print the arguments separated by spaces",
    syn = { "echo [ARG...]" },
    note = { "Expansion is done by the shell before echo runs, so $VAR, $1 and",
             "$(cmd) are already substituted." },
    see = "env, set, test",
},
yes = {
    what = "print a line over and over",
    syn = { "yes [STRING]" },
    note = { "Useful to feed a confirmation prompt, for instance",
             "yes | pkg install tool." },
    see = "echo, seq",
},

-- ---------------------------------------------------------------- monitor
df = {
    what = "report the mounted filesystems and their free space",
    syn = { "df [-h] [PATH]" },
    note = { "With a PATH only the filesystem holding it is reported, which is",
             "the usual way to see the space of the disk a path lives on." },
    opts = { { "-h", "human readable sizes" } },
    see = "du, free, mount",
},
free = {
    what = "report used and free memory",
    syn = { "free [-h]" },
    opts = { { "-h", "human readable sizes" } },
    see = "df, top, ps",
},
ps = {
    what = "list running jobs and processes",
    syn = { "ps [-e] [-f]" },
    note = { "Without -e only the jobs of the current shell are listed; -e also",
             "shows the detached daemons." },
    opts = { { "-e, -A", "show every process, not only this shell" },
             { "-f", "full format" } },
    see = "top, jobs, kill",
},
top = {
    what = "snapshot of load, memory and the busiest processes",
    syn = { "top [-n N]" },
    opts = { { "-n N", "show N processes (default 10)" } },
    see = "ps, free, uptime",
},
uptime = {
    what = "show how long the computer has been running",
    syn = { "uptime" },
    see = "date, ps",
},

-- ---------------------------------------------------------------- mounts
mount = {
    what = "manage the user mount table",
    syn = { "mount [-o OPTS] [-r] [SOURCE [TARGET]]" },
    note = { "Without operands the user mount table is printed. A SOURCE and a",
             "TARGET add an entry; a single SOURCE reports its entry." },
    opts = { { "-o OPTS", "comma separated mount options" },
             { "-r", "add the ro (read only) option" } },
    see = "umount, disk, df",
},
umount = {
    what = "remove entries from the user mount table",
    syn = { "umount [-a] TARGET]", "umount [-a] SOURCE" },
    opts = { { "-a", "unmount every entry" } },
    see = "mount, disk",
},

-- ---------------------------------------------------------------- devices
disk = {
    what = "manage removable media and automount",
    syn = { "disk", "disk scan", "disk umount [SOURCE]", "disk on", "disk off" },
    note = { "With no argument the state of every watched source is printed.",
             "scan mounts every medium that is present right now." },
    sub = { { "scan", "mount every medium that is present" },
            { "umount [SOURCE]", "unmount removable media" },
            { "on | off", "switch automount on or off" } },
    see = "mount, df",
},

-- ---------------------------------------------------------------- services
service = {
    what = "control the units in /etc/rc.d",
    syn = { "service", "service NAME start|stop|restart|status",
            "service start|stop|restart|status NAME", "service boot",
            "service shutdown", "service log [N] [FILTER]" },
    note = { "Units are Lua files in /etc/rc.d. boot starts every unit that is",
             "not up yet, shutdown stops every unit in reverse order. A unit",
             "that fails to load is skipped and reported, it never stops the",
             "rest of the boot." },
    opts = { { "start NAME", "start a unit" },
             { "stop NAME", "stop a unit" },
             { "restart NAME", "stop and start a unit" },
             { "status [NAME]", "state of one unit or of all units" },
             { "list", "list the units in /etc/rc.d" },
             { "log [N]", "last N lines of the service log (default 20)" } },
    see = "logrotate, crontab, startup",
},
logrotate = {
    what = "inspect and cut the rotating logs",
    syn = { "logrotate [status]", "logrotate list [PATH]",
            "logrotate show [-a N] [-n N] [PATH]", "logrotate rotate [PATH]" },
    sub = { { "status", "one line per configured target" },
             { "list [PATH]", "archives of a target" },
             { "show [-a N] [-n N] [PATH]", "last N lines of a log or archive N" },
             { "rotate [PATH]", "cut the log now, limits ignored" } },
    see = "service, cronlog",
},
startup = {
    what = "boot watchdog and first boot hook",
    syn = { "startup" },
    note = { "Runs ush and relaunches it whenever it exits, so the shell cannot",
             "be left by accident. It shows the BIOS window first (press DEL for",
             "three seconds) and re-applies the ROM's boot settings before",
             "anything else. On a machine that has not been set up yet it runs",
             "firstboot until setup succeeds. Put it in CraftOS startup." },
    see = "firstboot, reboot, resetfirstboot",
},
firstboot = {
    what = "initial setup of a fresh machine",
    syn = { "firstboot" },
    note = { "Asks for the root password, the primary user, the computer name,",
             "the network settings and the packages to install. The update",
             "server (and the package import) can be skipped and configured",
             "later with 'pkg update'. While a question is waiting, Ctrl+T",
             "skips it, and the words 'skip' and 'later' do the same where",
             "they are offered. It can be replayed after resetfirstboot." },
    see = "startup, resetfirstboot, passwd",
},
bios = {
    what = "open the machine setup screen",
    syn = { "bios" },
    note = { "The same screen the three second window at power on offers",
             "(press DEL before the shell starts), reachable without a reboot.",
             "",
             "BOOT ORDER. The first two entries are the ROM's own boot switches,",
             "kept in /.settings and read by CraftOS BEFORE anything of ours runs:",
             "",
             "  Boot from a disk's startup",
             "    shell.allow_disk_startup. The ROM's default is TRUE. With it on,",
             "    rom/startup.lua looks at the attached drives, and a disk carrying",
             "    a file called \"startup\" REPLACES this machine's own startup",
             "    instead of running alongside it: the shell never starts and",
             "    nothing in this installation runs. THIS MACHINE SHIPS IT OFF.",
             "    Note it cannot be defended against from inside the shell -- the",
             "    shell is exactly what does not get to run -- which is why it is",
             "    a BIOS setting, and why it is re-applied at every boot (deleting",
             "    /.settings does not leave the machine open).",
             "",
             "  Run this machine's startup",
             "    shell.allow_startup. On: without it nothing of ours runs at all.",
             "",
             "ALL CRAFTOS SETTINGS. The last entry lists and changes every setting",
             "the ROM knows -- the same ones the shell's own \"set\" command edits --",
             "through the settings API that command uses. It is here because a",
             "machine whose shell will not start is exactly when someone needs to",
             "read or change one of them.",
             "",
             "The screen marks the keys it ENFORCES with \"*\": those are recorded",
             "in /etc/bios.conf and re-applied at every boot, so a change to one is",
             "kept. Every other setting belongs to the ROM: this project neither",
             "enforces nor records it, and the ROM's own \"set\" command is its",
             "editor. An empty entry unsets a key, so the ROM's declared default",
             "applies again (\"R\" does the same).",
             "",
             "The other entries change the rules that decide how the machine",
             "behaves before anyone logs in: whether a BIOS password is asked for",
             "before booting, whether boot files may be overwritten (the same rule",
             "as \"set -o bootguard\"), and whether the shell may be left (the same",
             "rule as \"set -o noexit\"). Both of those are kept in /etc/boot.conf",
             "and the password in /etc/bios.conf, so the shell and this screen",
             "always report the same thing.",
             "",
             "The BIOS password is SEPARATE from a login password on purpose: it is",
             "checked before the shell starts, so it cannot depend on the user",
             "database the shell reads. Entering the screen asks for it when one is",
             "set, and with ask_password=1 the machine does not start the shell at",
             "all until it is given." },
    see = "settings, passwd, sudo, set",
},
resetfirstboot = {
    what = "erase the first boot markers so setup runs again",
    syn = { "resetfirstboot [-f]" },
    opts = { { "-f", "do not ask for confirmation" } },
    see = "firstboot, passwd",
},

-- ---------------------------------------------------------------- schedule
crontab = {
    what = "edit and inspect the scheduled jobs",
    syn = { "crontab [-u USER] -l", "crontab [-u USER] -r",
            "crontab [-u USER] -e", "crontab [-u USER] FILE" },
    note = { "Five time fields: minute hour day month weekday. The special",
             "value @reboot runs a line when the machine boots, and minutes are",
             "resolved against the wall clock so a job is not run twice." },
    opts = { { "-l", "list the table" },
             { "-e", "edit the table" },
             { "-r", "remove the table" },
             { "-u USER", "operate on another user (root only)" },
             { "FILE", "install FILE as the table" } },
    see = "at, cronlog, service",
},
at = {
    what = "run one command later",
    syn = { "at <-l|-r ID> ...", "at [-f FILE] [-t TIME] WHEN COMMAND..." },
    note = { "WHEN is +N (minutes from now), HH:MM (today or tomorrow), or an",
             "epoch timestamp. Jobs land in the same store as crontab." },
    opts = { { "-l", "list the pending jobs" },
             { "-r ID", "remove a job" },
             { "-f FILE", "read the command from a file" },
             { "-t TIME", "give the time explicitly" } },
    see = "crontab, cronlog",
},
cronlog = {
    what = "read the log of the scheduled jobs",
    syn = { "cronlog [-n N] [-u USER] [--archive N] [FILTER]" },
    opts = { { "-n N", "number of lines (default 20)" },
             { "-u USER", "only the jobs of this user" },
             { "-a N, --archive N", "read archive N instead of the live log" },
             { "FILTER", "substring the lines must contain" } },
    see = "crontab, at, logrotate",
},

-- ---------------------------------------------------------------- network
ping = {
    what = "check whether a computer answers on rednet",
    syn = { "ping [-c COUNT] [-W TIMEOUT] ID" },
    opts = { { "-c COUNT", "number of probes" },
             { "-W TIMEOUT", "seconds to wait for one answer" } },
    see = "netstat, netopen, rednet",
},
netstat = {
    what = "show the state of the rednet interfaces",
    syn = { "netstat" },
    see = "netopen, netclose, ping",
},
netopen = {
    what = "open rednet on a modem",
    syn = { "netopen [SIDE]" },
    note = { "Without a SIDE the first modem found is opened. rednet is opened",
             "automatically by the network commands, so this is only needed to",
             "pick a specific modem." },
    see = "netclose, netstat",
},
netclose = {
    what = "close rednet on every modem",
    syn = { "netclose" },
    see = "netopen, netstat",
},
netsend = {
    what = "send a rednet message",
    syn = { "netsend ID|broadcast MESSAGE..." },
    note = { "The message is joined into one string and sent on the ush-msg",
             "protocol. broadcast, * and -b all mean every computer." },
    see = "netrecv, ping",
},
netrecv = {
    what = "wait for one rednet message",
    syn = { "netrecv [-t TIMEOUT] [PROTOCOL]" },
    opts = { { "-t TIMEOUT", "seconds to wait (default 5)" } },
    see = "netsend, ping",
},
rput = {
    what = "push files to a machine running netd",
    syn = { "rput -t ID [-p PATH] [-c BYTES] [-w SEC] [-r N] [-f] [-q] FILE..." },
    opts = { { "-t ID", "target computer (required)" },
             { "-p PATH", "remote directory (required by netd)" },
             { "-c BYTES", "chunk size" },
             { "-w SEC", "answer timeout" },
             { "-r N", "retries" },
             { "-f", "overwrite an existing remote file" },
             { "-q", "quiet" } },
    see = "rget, rexec, netd",
},
rget = {
    what = "pull files from a machine running netd",
    syn = { "rget -t ID [-o LOCAL] [-c BYTES] [-w SEC] [-r N] [-f] [-q] REMOTE..." },
    note = { "The size arrives with the offer, so a file that does not fit is",
             "refused before the first block (need N bytes, M free) and looked at",
             "again before it is written: no half file is left on the disk." },
    opts = { { "-t ID", "target computer (required)" },
             { "-o LOCAL", "write to this local path" },
             { "-c BYTES", "chunk size" },
             { "-w SEC", "answer timeout" },
             { "-r N", "retries" },
             { "-f", "overwrite an existing local file" },
             { "-q", "quiet" } },
    see = "rput, rexec, netd",
},
rexec = {
    what = "run a command on a machine running netd",
    syn = { "rexec -t ID [-w SEC] [-T SEC] [-n] [-q] COMMAND..." },
    note = { "The remote side must allow the command, see netd --allow." },
    opts = { { "-t ID", "target computer (required)" },
             { "-w SEC", "answer timeout" },
             { "-T SEC", "total time budget" },
             { "-n", "do not wait for the output" },
             { "-q", "quiet" } },
    see = "rput, rget, netd",
},
netd = {
    what = "data channel daemon: file transfer and remote execution server",
    syn = { "netd", "netd --save DIR", "netd --allow LIST", "netd --once" },
    note = { "Speaks the same protocol name and shared key as the package",
             "manager, both read from /etc/pkg.conf. Run it on a machine that",
             "should accept rput, serve rget and answer rexec." },
    opts = { { "--save DIR", "store incoming pushes in DIR instead of /var/net/incoming" },
             { "--allow LIST", "only these commands may be run by rexec" },
             { "--once", "handle a single request and exit" },
             { "--force", "start even if another instance is running" } },
    see = "rput, rget, rexec",
},
pkgserver = {
    what = "package repository server",
    syn = { "pkgserver" },
    note = { "Serves the repository tree over rednet with the shared key from",
             "/etc/pkg.conf, so clients can run pkg update and pkg install." },
    see = "pkg, netd",
},

-- ---------------------------------------------------------------- jobs
jobs = {
    what = "list the background jobs of this shell",
    syn = { "jobs" },
    see = "fg, bg, kill, disown",
},
fg = {
    what = "bring a background job to the foreground",
    syn = { "fg [%JOB]" },
    see = "bg, jobs, kill",
},
bg = {
    what = "continue a stopped job in the background",
    syn = { "bg <%JOB>" },
    see = "fg, jobs",
},
kill = {
    what = "terminate background jobs",
    syn = { "kill <%JOB>..." },
    see = "jobs, disown, ps",
},
disown = {
    what = "forget the jobs that have finished",
    syn = { "disown" },
    see = "jobs, kill",
},

-- ---------------------------------------------------------------- util
env = {
    what = "print the environment",
    syn = { "env" },
    see = "set, export, path",
},
printenv = {
    what = "print the environment, or the values of named variables",
    syn = { "printenv [NAME...]" },
    note = { "With no name every exported variable is printed as NAME=value,",
             "the same set env lists. With names only the values are printed,",
             "one per line: printenv is asked for a value, not for an",
             "assignment. A name that is not set prints nothing and makes the",
             "status 1, which is how a script tests whether a name reached it." },
    see = "env, set, export",
},
path = {
    what = "print or change the command search path",
    syn = { "path", "path DIR...", "path -a DIR" },
    note = { "With no argument the current search path is printed. -a appends a",
             "directory instead of replacing the path." },
    see = "which, env, set",
},
set = {
    what = "set the options of the shell (errexit, nounset, xtrace," ..
           " pipefail), and set or print its variables",
    syn = { "set", "set NAME", "set NAME=value ...", "set -eux", "set +eux",
            "set -o OPTION ...", "set +o OPTION ...", "set -o", "set +o",
            "set -- WORD ..." },
    note = { "set with no word writes every variable of the shell, one",
             "NAME=value per line. A word of the form NAME=value gives a",
             "variable that value, and set NAME with no value writes the one",
             "variable when it is set. A variable set here is seen by child",
             "commands, unlike export which also marks it for scripts.",

             "The options of the shell are set with the same word: -e for",
             "errexit, -u for nounset, -x for xtrace and -o pipefail, the one",
             "option that has no letter of its own. The letters may be written",
             "together, in any number and in any order, so set -ex is the same",
             "as set -e -x, and a plus sign turns an option off again (+e, +u,",
             "+x, +o pipefail). The long name may be used with -o and +o as",
             "well, so set -o errexit and set -e mean the same thing.",

             "Options and assignments may stand in the same line, in any",
             "order, the way POSIX reads them: set -eu NAME=value turns two",
             "options on and gives one variable a value. The word -- ends the",
             "options of the built-in, so no word behind it is ever read as an",
             "option, not even one that begins with a dash.",

             "set -o with no name writes the options, one line for each: the",
             "long name and on or off. set +o writes them as the commands that",
             "put each of them back the way it is now, so the lines may be run",
             "again as they stand.",

             "errexit (-e) ends the shell at once when a command fails, and",
             "the status of the shell is the status of that command. A command",
             "whose status is only read never ends the shell, and neither do",
             "the commands it calls in turn: the left side of && and ||, the",
             "condition of if, while and until, and a command that ! negates.",

             "nounset (-u) makes a variable that is not set a fault: the shell",
             "reports the name, the status is 1 and the command does not run.",
             "A default that the word itself carries, as in ${NAME:-word},",
             "still counts as a value and is not a fault.",

             "xtrace (-x) writes every command to the console before it runs,",
             "after the expansions and with the redirections and the pipes",
             "shown. The report belongs to the shell and not to the command,",
             "so one inside a command substitution is not captured.",

             "pipefail (-o pipefail) makes a pipeline fail with the status of",
             "its first stage that failed, instead of the status of its last",
             "stage. Without it a pipeline reports the status of its last",
             "stage alone.",

             "$- names the letters of the options that are in force, in the",
             "order -e, -u, -x. pipefail has no letter, so a shell reports it",
             "by its long name alone and it never shows up in $-.",

             "The options belong to the shell that sets them. A command that",
             "this shell runs, a script run by its path or a sub shell of a",
             "command substitution, starts with the options its parent has at",
             "that moment and the ones it turns on or off die with it; a",
             "sourced script is a part of this shell and its options last." },
    opts = { { "-e", "errexit: end the shell when a command fails" },
             { "+e", "turn errexit off again" },
             { "-u", "nounset: a variable that is not set is a fault" },
             { "+u", "turn nounset off again" },
             { "-x", "xtrace: write every command before it runs" },
             { "+x", "turn xtrace off again" },
             { "-o pipefail", "a pipeline fails with its first failing stage" },
             { "+o pipefail", "a pipeline reports its last stage again" },
             { "-o / +o NAME", "the long name of any of the options above" },
             { "-o", "the options, one name and on or off per line" },
             { "+o", "the options as the commands that put them back" },
             { "NAME=value", "give a variable a value" },
             { "NAME", "write the one variable, when it is set" },
             { "--", "end the options of the built-in" } },
    see = "export, unset, env, trap, source",
},
export = {
    what = "export a variable to child scripts",
    syn = { "export [-n] NAME[=value]" },
    opts = { { "-n", "unexport, mark the name as internal again" } },
    see = "set, unset, env",
},
unset = {
    what = "remove variables",
    syn = { "unset NAME..." },
    see = "set, export",
},
alias = {
    what = "define an alias, or list them",
    syn = { "alias", "alias NAME=VALUE" },
    see = "unalias, which, help",
},
unalias = {
    what = "remove aliases",
    syn = { "unalias [-a] NAME..." },
    opts = { { "-a", "remove every alias" } },
    see = "alias",
},
history = {
    what = "show the command history of this session",
    syn = { "history [N]" },
    note = { "With a number only the last N entries are printed." },
    opts = { { "N", "show the last N entries" },
             { "-c", "clear the history" } },
    see = "alias, source",
},
source = {
    what = "run a script in the current shell",
    syn = { "source FILE [ARGS...]", ". FILE [ARGS...]" },
    note = { "The script shares the variables, aliases and the working",
             "directory of the caller, unlike an external command." },
    see = "exit, return, set",
},
sleep = {
    what = "wait for some seconds",
    syn = { "sleep [SECONDS]" },
    see = "at, crontab",
},
tar = {
    what = "pack files into an archive, or unpack one",
    syn = { "tar -cf ARCHIVE FILE...", "tar -xf ARCHIVE" },
    note = { "Files are stored with their relative paths, so an unpack keeps",
             "the directory structure." },
    opts = { { "-c", "create" }, { "-x", "extract" },
             { "-f ARCHIVE", "archive file name" } },
    see = "cp, ls",
},
["true"] = {
    what = "do nothing successfully",
    syn = { "true" },
    see = "false, test, if",
},
["false"] = {
    what = "do nothing with a failing status",
    syn = { "false" },
    see = "true, test, if",
},
clear = {
    what = "clear the screen",
    syn = { "clear" },
    see = "echo",
},
date = {
    what = "print the current date and time",
    syn = { "date" },
    see = "uptime, cronlog",
},
uname = {
    what = "print the system name",
    syn = { "uname [-a]" },
    opts = { { "-a", "full line: system, version, CC:Tweaked name" } },
    see = "hostname, id, uptime",
},
hostname = {
    what = "print the computer name",
    syn = { "hostname" },
    see = "uname, ping",
},
whoami = {
    what = "print the name of the current user",
    syn = { "whoami" },
    see = "id, who, su",
},
id = {
    what = "print the user and the group of this shell",
    syn = { "id [USER]" },
    see = "whoami, who, su",
},
tty = {
    what = "print the name of the terminal",
    syn = { "tty" },
    note = { "This machine has exactly one console, so there is nothing to open",
             "and nothing that can fail: the answer is always /dev/console and",
             "the status is always 0." },
    see = "who, users, ps",
},
nproc = {
    what = "print the number of processors",
    syn = { "nproc" },
    note = { "The answer is always 1: CraftOS runs one Lua machine with a",
             "cooperative scheduler, so this shell has exactly one processor",
             "whatever the computer is built from." },
    see = "uptime, ps, top",
},
tput = {
    what = "ask the terminal for a capability",
    syn = { "tput CAP [ARGS...]" },
    note = { "cols and lines are the width and the height of the screen and",
             "colors is 16, the size of the CraftOS palette. cup ROW COL moves",
             "the cursor there and clear clears the screen.",
             "bold, smul, rmul and sgr0 are accepted and write NOTHING. This",
             "terminal has no bold, underline or standout attribute and it does",
             "not read escape sequences at all: the colour of text is set by",
             "calling into the terminal API, which is not something a pipe can",
             "carry. Printing an ANSI sequence here would make the screen show",
             "the sequence itself, so the capability is answered with silence",
             "and status 0 instead.",
             "Any other capability is reported and the status is 1." },
    see = "clear, nproc, uname",
},

-- ---------------------------------------------------------------- control
["["] = {
    what = "test expressions, the bracket form of test",
    syn = { "[ EXPR ]" },
    note = { "The closing bracket is required, it is what makes the builtin",
             "usable inside if. See test for the operators." },
    see = "test, if, true, false",
},
test = {
    what = "evaluate a condition",
    syn = { "test EXPR" },
    note = { "File tests: -e -f -d -r -w -x -s. String tests: -n -z =,",
             "!=. Number tests: -eq -ne -lt -le -gt -ge. Logical: ! -a -o." },
    see = "[, if, while",
},
["if"] = {
    what = "run a block when a condition holds",
    syn = { "if CMD; then LIST; elif CMD; then LIST; else LIST; fi" },
    see = "while, for, case, test",
},
["for"] = {
    what = "loop over words or over a list",
    syn = { "for NAME in WORD...; do LIST; done" },
    see = "while, if, shift",
},
["while"] = {
    what = "loop while a command succeeds",
    syn = { "while CMD; do LIST; done", "until CMD; do LIST; done" },
    see = "for, if, break, continue",
},
["case"] = {
    what = "match a word against several patterns",
    syn = { "case WORD in PAT) LIST ;; esac" },
    see = "if, test",
},
["break"] = {
    what = "leave the innermost loop",
    syn = { "break" },
    see = "continue, for, while",
},
["continue"] = {
    what = "jump to the next iteration of the innermost loop",
    syn = { "continue" },
    see = "break, for, while",
},
["return"] = {
    what = "leave a function or a sourced script",
    syn = { "return [STATUS]" },
    see = "exit, source",
},
["exit"] = {
    what = "leave the shell",
    syn = { "exit [STATUS]" },
    note = { "startup notices the exit and relaunches the shell. On a machine",
             "with noexit on, the shell refuses to be left at all; \"reboot\"",
             "restarts the computer instead of abandoning it." },
    see = "return, reboot, startup",
},
["shift"] = {
    what = "drop the first positional parameters",
    syn = { "shift [N]" },
    see = "for, return",
},
["function"] = {
    what = "define a shell function",
    syn = { "function NAME() { LIST ; }" },
    see = "return, source, export",
},
["{{"] = {
    what = "run a command list in the current shell",
    syn = { "{ LIST ; }" },
    see = "if, function",
},
["."] = {
    what = "run a script in the current shell, the same as source",
    syn = { ". FILE [ARGS...]" },
    see = "source",
},

-- ---------------------------------------------------------------- packages
pkg = {
    what = "install, upgrade and remove packages",
    syn = { "pkg {update|upgrade [-f]|search|install [--store N]|remove|purge|clean|list|requires|store}" },
    note = { "The repository index and its checksums are verified before",
             "anything is written. install, remove, purge, update, store and",
             "upgrade need root, use sudo. A machine may also run with no",
             "update server at all: offline=true in /etc/pkg.conf (or",
             "/etc/network.conf), or no server_id, makes the commands report",
             "that, and how to configure one later, instead of waiting.",
             "",
             "The file set is measured before it is unpacked: a package whose",
             "bytes are more than the install root has free is refused (need N",
             "bytes, M free) rather than written until the medium fills up.",
             "",
             "A package may declare what it needs before it can be installed.",
             "The manifest keys are requires_disk (a mounted medium has to",
             "carry that marker file), requires_file (a file that has to",
             "exist) and requires_feature (a feature this build provides).",
             "install checks them before it downloads anything, so a machine",
             "without the medium is told to insert the disk instead of",
             "fetching a package it cannot use; requires prints the answer",
             "without installing.",
             "",
             "A machine with removable drives makes a medium a package store",
             "by writing the marker .pkgstore on it: \"store 2\" does that for",
             "the medium in drive 2, \"store 2 3\" for two of them, \"store",
             "remove 2\" takes the marker off, \"store\" alone lists the stores",
             "and \"store auto\" removes every marker. The machine records no",
             "drive letter, so a medium that is moved to another drive is still",
             "recognised by the marker it carries.",
             "",
             "A new package is written to the first store the mount table lists,",
             "under <medium>/usr/pkgs, so it takes no room on the computer; a",
             "package is looked for in every store, so one installed on any",
             "medium is found. A medium that is not a store is not searched.",
             "",
             "\"store\" also reports what each root holds (packages, and the",
             "capacity when the filesystem answers for one), \"store --json\"",
             "gives the same answer as JSON for a script, and \"list -s\" lists",
             "the installed packages grouped by the medium they are on.",
             "",
             "\"store required\" makes a store compulsory: from then on an",
             "install that would land on the computer's own filesystem is",
             "refused, and \"store optional\" allows it again. \"install",
             "--store N NAME\" makes a medium a store for one command only and",
             "removes the marker when it is done.",
             "",
             "There are two kinds of store, and a machine built in two parts",
             "(the shell on its own disk, its own modules on a medium) needs",
             "both. .pkgstore marks an ordinary package store: extra packages,",
             "whose absence costs nothing but those packages. .pkgsys marks the",
             "system module store: the modules the shell itself needs, whose",
             "absence costs functionality. \"store sys 2\" makes the medium in",
             "drive 2 the system store, \"store sys\" shows which medium holds",
             "it, and a medium cannot be both -- claiming one as the system",
             "store replaces the ordinary marker.",
             "",
             "The system store is searched first, so a module the shell depends",
             "on wins when two media carry the same name. A new package is never",
             "written into it: it holds the installation's own modules. \"store",
             "sys-required\" makes the system store compulsory for a machine that",
             "cannot work without it; unlike \"store required\" that WARNS rather",
             "than refuses, because a missing system store means the machine is",
             "incomplete rather than that an install is illegal." },
    sub = { { "update", "refresh the index from the repository" },
            { "upgrade [-f]", "upgrade what is out of date, -f reinstalls all" },
            { "search WORD", "search the index" },
            { "install [--store N] NAME", "install or upgrade a package" },
            { "remove NAME", "remove a package, keep its configuration" },
            { "purge NAME", "remove a package and its configuration" },
            { "clean", "drop the downloaded archives" },
            { "list [-u]", "installed packages, -u shows what can be upgraded" },
            { "list -s", "the same, grouped by the medium each package is on" },
            { "requires NAME", "what NAME needs, and whether it is present" },
            { "store [N ...]", "make those media package stores" },
            { "store remove N", "stop treating a medium as a store" },
            { "store sys N", "make that medium the system module store" },
            { "store sys", "which medium holds the system modules" },
            { "store sys-required", "the machine needs its system module store" },
            { "store sys-optional", "it does not" },
            { "store required", "packages must live on a store" },
            { "store optional", "packages may live on this computer" },
            { "store --json", "the store inventory as JSON" } },
    see = "apt, sudo, pkgserver, disk",
},
apt = {
    what = "alias of the package manager",
    syn = { "apt {update|upgrade [-f]|search|install [--store N]|remove|purge|clean|list|requires|store}" },
    see = "pkg, sudo",
},

-- ---------------------------------------------------------------- accounts
passwd = {
    what = "change a password",
    syn = { "passwd [USER]" },
    note = { "A plain user may only change the own password and has to give the",
             "old one first. The new password is checked against the policy in",
             "lib/policy.lua. Everything is written to the audit log." },
    see = "useradd, su, sudo",
},
su = {
    what = "become another user",
    syn = { "su [-] [USER]", "su -c COMMAND [USER]" },
    opts = { { "-", "start a login shell of that user" },
             { "-c COMMAND", "run one command and return" } },
    see = "sudo, whoami, id",
},
sudo = {
    what = "run one command as root",
    syn = { "sudo [-u USER] [-n] [-k] [-l] COMMAND [ARGS...]" },
    opts = { { "-u USER", "run as that user instead of root" },
             { "-n", "never ask for a password" },
             { "-k", "forget the cached password" },
             { "-l", "list what this user may run" } },
    see = "su, passwd, pkg",
},
useradd = {
    what = "create a user",
    syn = { "useradd [-g GROUP] [-p PASSWORD] [-u LEVEL] NAME" },
    opts = { { "-g GROUP", "primary group" },
             { "-p PASSWORD", "set the password" },
             { "-u LEVEL", "privilege level" } },
    see = "userdel, usermod, passwd",
},
userdel = {
    what = "delete a user",
    syn = { "userdel [-r] NAME" },
    opts = { { "-r", "also remove the home directory" } },
    see = "useradd, usermod",
},
usermod = {
    what = "change a user",
    syn = { "usermod [-g GROUP] [-l NEWNAME] [-u LEVEL] NAME" },
    see = "useradd, userdel, gpasswd",
},
groupadd = {
    what = "create a group",
    syn = { "groupadd GROUP" },
    see = "groupdel, gpasswd, useradd",
},
groupdel = {
    what = "delete a group",
    syn = { "groupdel GROUP" },
    see = "groupadd, gpasswd",
},
gpasswd = {
    what = "add or remove a user of a group",
    syn = { "gpasswd {-a|-d} USER GROUP" },
    see = "groupadd, usermod",
},
chmod = {
    what = "change the mode bits of a path",
    syn = { "chmod [-R] MODE PATH..." },
    note = { "MODE is octal, for instance 644 or 755." },
    opts = { { "-R", "recurse into directories" } },
    see = "chown, chgrp, ls",
},
chown = {
    what = "change the owner of a path",
    syn = { "chown [-R] OWNER[:GROUP] PATH..." },
    opts = { { "-R", "recurse into directories" } },
    see = "chgrp, chmod",
},
chgrp = {
    what = "change the group of a path",
    syn = { "chgrp [-R] GROUP PATH..." },
    opts = { { "-R", "recurse into directories" } },
    see = "chown, chmod",
},
groups = {
    what = "print the groups of a user",
    syn = { "groups [USER]" },
    note = { "The groups of the current user are printed when no USER is named,",
             "separated by single spaces on one line. A USER that does not",
             "exist is reported and the status is 1." },
    see = "id, whoami, useradd",
},

-- ---------------------------------------------------------------- session
who = {
    what = "show who is logged in",
    syn = { "who [-H] [-q] [am i]" },
    opts = { { "-H", "print a header" },
             { "-q", "names only" } },
    see = "w, last, whoami",
},
w = {
    what = "show who is logged in and what they run",
    syn = { "w [-H] [-q] [am i]" },
    opts = { { "-H", "print a header" },
             { "-q", "names only" } },
    see = "who, last, ps",
},
last = {
    what = "show the recent logins",
    syn = { "last [-n N] [USER]" },
    opts = { { "-n N", "number of entries (default 10)" } },
    see = "lastlog, who",
},
lastlog = {
    what = "show the last login of every user",
    syn = { "lastlog [-u USER]" },
    opts = { { "-u USER", "only this user" } },
    see = "last, who",
},
users = {
    what = "print the users that are logged in now",
    syn = { "users" },
    note = { "The live sessions are listed, one name each, separated by single",
             "spaces on one line. A computer that reaches this one over rpvnet",
             "holds a session of its own, so the answer is not simply the",
             "current user." },
    see = "who, w, last, groups",
},

-- ---------------------------------------------------------------- prompt
theme = {
    what = "show or change the prompt theme of the shell",
    syn = { "theme", "theme -l", "theme -c [NAME]", "theme NAME",
            "theme -d [NAME]", "theme save [-f]" },
    note = { "A theme is one prompt template. dark is the default, light is the",
             "other built-in one, and /etc/theme.conf may replace both and add",
             "more (man theme.conf). Without an argument the current theme, the",
             "file it was read from and the rendered prompt are printed.",
             "The closing dollar of a template becomes a sharp for the root",
             "account, so the prompt of a session ends in $ or in #, after",
             "the account that owns it.",
             "Selecting a theme lasts for the session, save is the only writer",
             "of the file and asks before it writes." },
    opts = { { "-l", "list every theme, the current one is marked with *" },
             { "-c [NAME]", "print the template of NAME (default: the current)" },
             { "-d [NAME]", "drop the file, use the built-in templates" },
             { "save [-f]", "write /etc/theme.conf, -f skips the question" } },
    see = "PS1, theme.conf, set, export",
},
PS1 = {
    what = "the prompt variable of the shell",
    syn = { "PS1=TEMPLATE", "export PS1=TEMPLATE", "unset PS1" },
    note = { "While PS1 holds a non empty value it is the prompt of the session,",
             "otherwise the template of the current theme is drawn (man theme).",
             "A template expands $USER, $HOST, $PWD, $? and the other variables,",
             "\\e{COLOUR} starts a colour, \\e{} goes back to the default one and",
             "\\$ is a literal dollar sign, so a prompt may end in one; for",
             "the root account that closing dollar is drawn as a sharp (#)." },
    see = "theme, theme.conf, set, export",
},
["theme.conf"] = {
    what = "the prompt themes of the shell",
    syn = { "/etc/theme.conf" },
    note = { "Plain text, one \"key = value\" per line, # starts a comment, the",
             "escapes are written with a backslash and not with real control",
             "bytes, so the file stays ASCII. theme = NAME picks the theme of",
             "the session, NAME.prompt is the template of that theme. A value",
             "in double quotes keeps its blanks, a bare value is trimmed at",
             "both ends. A missing file is not an error, the built-in themes",
             "are used then." },
    see = "theme, PS1, source",
},
keys = {
    what = "the keys the prompt line editor understands",
    syn = { "Enter Backspace Delete Left Right Home End Up Down Tab",
            "Ctrl+A Ctrl+E Ctrl+W Ctrl+C Ctrl+L" },
    note = { "Enter accepts the line, Backspace rubs out the character in",
             "front of the cursor, Delete the one behind it, Left and Right",
             "move the cursor, Home and End jump to the ends of the line, Up",
             "and Down walk the history.",
             "Tab completes the word at the cursor: a command name at the",
             "start of a command, the options of the command in front of it",
             "when the word starts with a dash, a path anywhere else. sudo",
             "hands the completion over to the command it wraps, takes its",
             "own options and names the accounts behind -u. Several",
             "candidates are listed, a single one is inserted.",
             "Ctrl+A is the start of the line, Ctrl+E its end, Ctrl+W rubs out",
             "the word in front of the cursor together with the blanks before",
             "it, Ctrl+C throws the half typed line away and starts a fresh",
             "one without leaving the shell, Ctrl+L clears the screen and",
             "draws the prompt and the line again.",
             "Ctrl+T is the terminate key of the system: it stops a foreground",
             "command and never reaches the editor. In firstboot, where no",
             "command is running, it skips the question that is waiting." },
    see = "history, source, theme, PS1",
},

-- ---------------------------------------------------------------- admin
audit = {
    what = "read the security audit log",
    syn = { "audit [N]" },
    note = { "Every privileged action, granted or denied, is written there:",
             "pkg, sudo, su, passwd, reboot, resetfirstboot and the account",
             "commands. N is the number of lines, default 20." },
    see = "sudo, passwd, cronlog",
},
reboot = {
    what = "restart the computer, optionally into the BIOS setup screen",
    syn = { "reboot [-f]", "reboot bios [-f]" },
    note = { "Restarts the machine through startup.lua, so it comes back up with",
             "the BIOS window in front of it exactly as after a power cycle.",
             "\"reboot bios\" goes straight to the setup screen instead of making",
             "you race the three second DEL window.",
             "",
             "This no longer replaces the old \"craftos\" command: craftos now",
             "opens the ROM shell in a separate multishell tab, so ush and the",
             "boot guard/noexit rules stay in force.",
             "",
             "Only root may do this, the attempt is audited, and \"set -o noexit\"",
             "refuses it like any other way of leaving the session (-f overrides)." },
    opts = { { "-f", "do not ask for confirmation" },
             { "bios", "restart straight into the setup screen" } },
    see = "exit, bios, shutdown, startup",
},
craftos = {
    what = "open a CraftOS shell in a new multishell tab",
    syn = { "craftos" },
    note = { "Runs the ROM shell (/rom/programs/shell.lua) in a new tab, so ush",
             "and its background jobs keep running. This is the safe way to reach",
             "CraftOS commands that ush does not provide.",
             "",
             "Only available when ush itself runs inside multishell (the dcnet",
             "boot layout starts ush that way). Without multishell the command",
             "reports an error instead of replacing the session.",
             "",
             "Only root may run it; denied attempts are audited." },
    see = "reboot, bios, help",
},
help = {
    what = "show the command overview, or one manual page",
    syn = { "help", "help COMMAND" },
    note = { "Without an argument the commands are listed by group. With a",
             "command name the same page is printed as man COMMAND." },
    see = "man, which",
},
man = {
    what = "show a manual page of the shell",
    syn = { "man NAME...", "man -k WORD", "man -l" },
    note = { "The pages live in lib/man.lua and cover the builtins, the",
             "programs in /usr/cmd and the daemons. -k searches the one line",
             "descriptions, -l lists every page." },
    opts = { { "-k WORD", "search the descriptions for WORD" },
             { "-l", "list every page" } },
    see = "help, which",
},

-- ------------------------------------------------------------- expansion
expansion = {
    what = "expand a parameter reference: $NAME, ${NAME}, its operators, the" ..
           " arithmetic $((EXPR)) and the command substitution $(CMD)",
    syn = { "$NAME", "${NAME}",
            "${NAME:-WORD}", "${NAME:=WORD}", "${NAME:+WORD}",
            "${NAME:?WORD}", "${#NAME}",
            "${NAME#PAT}", "${NAME##PAT}", "${NAME%PAT}", "${NAME%%PAT}",
            "$((EXPR))", "$(CMD)", "`CMD`" },
    note = { "NAME is a shell variable, a positional parameter (${1}, ${10})",
             "or one of ? $ ! # @ *. WORD and PAT are expanded themselves, so",
             "${A:-${B}} and ${A:-$B} both work; a quote inside them is an",
             "ordinary character.",

             "The forms with a colon treat an unset and an empty value the",
             "same way, the forms without one only look at an unset NAME.",
             "The operators of # and % take a glob pattern: * and ? match any",
             "character (a separator too), a [ starts a bracket group. # and",
             "% strip the shortest matching prefix or suffix, ## and %% the",
             "longest.",

             "${PATH##*/} is the last part of a path, ${PATH%/*} the",
             "directory above it. A failing ${NAME:?WORD} stops the command",
             "with a non zero status and prints the name and WORD. The fields",
             "of a word are split after the expansion, unless it is quoted.",

             "An arithmetic expansion $((EXPR)) works EXPR out and writes the",
             "result as a decimal number. EXPR may use + - * / % with the",
             "usual precedence, the unary + - ~ !, the comparisons",
             "< <= > >= == !=, the logic && ||, the bits & | ^ << >>, the",
             "grouping ( ) and the ternary ?:, so $(( (1+2)*3 )) is 9 and",
             "$(( 7<9 ? 7 : 9 )) is 7.",

             "A value is a whole number of 64 bits: a sum that runs past the",
             "top wraps around, / truncates towards zero and % keeps the sign",
             "of its left side. A name in EXPR is the text of that variable,",
             "read with an optional sign and base (0x7b is 123, 0b1011 is",
             "11); a value or a name without a number counts as zero, and a $",
             "in front of the name is allowed as well. A division by zero or",
             "a broken expression stops the command with a non zero status.",

             "A command substitution $(CMD) runs CMD in a sub shell and puts",
             "what it writes on the standard output in the place of the",
             "reference. Every newline at the end of that output is dropped,",
             "the ones in its middle are kept: $(seq 2) holds 1, a newline" ..
             " and 2. An unquoted result is split into fields on the blanks",
             "and takes part in the file name expansion of the word it sits",
             "in; inside double quotes the result stays one field and no",
             "pattern is tried on it.",

             "CMD is a command line of its own: a pipeline, a list, a loop",
             "or another substitution all fit in it, so $(echo $(echo a))",
             "and $(echo `echo a`) write a. Inside $( ) the shell follows",
             "the parentheses, a nested reference or a quoted string is read",
             "as a whole, and the ) that closes the reference is the first",
             "one left at the outer level. The old form `CMD` does the same",
             "with backquotes; a backslash keeps its meaning for $, ` and \\",
             "there and is an ordinary character before anything else.",

             "What the sub shell does stays inside it: a variable it sets,",
             "a cd it runs and an exit it ends with are all gone when the",
             "reference is over, and $? of the shell is not touched either.",
             "A substitution that fails - an unknown command, a false - sets",
             "the status of the command, so $(false) and x=$(false) end",
             "with 1 while echo $(false) is still a successful echo." },
    opts = { { ":-WORD", "value of NAME, or WORD when NAME is unset or empty" },
             { ":=WORD", "the same, and WORD is assigned to NAME as well" },
             { ":+WORD", "WORD when NAME is set and not empty, else nothing" },
             { ":?WORD", "stop the command with WORD when NAME is unset or" ..
                         " empty" },
             { "-WORD", "like :-WORD, but an empty value is a real value" },
             { "=WORD", "like :=WORD, but an empty value is a real value" },
             { "+WORD", "like :+WORD, but an empty value counts as set" },
             { "?WORD", "like :?WORD, but an empty value counts as set" },
             { "#PAT", "drop the shortest prefix of the value that matches" },
             { "##PAT", "drop the longest prefix of the value that matches" },
             { "%PAT", "drop the shortest suffix of the value that matches" },
             { "%%PAT", "drop the longest suffix of the value that matches" },
             { "#NAME", "the length of the value of NAME, no WORD is read" },
             { "$((EXPR))", "the value of the arithmetic expression EXPR" },
             { "$(CMD)", "the standard output of CMD, its trailing end of" ..
                         " lines dropped" },
             { "`CMD`", "the same in the old backquote form" } },
    see = "env, path, set, export, unset, heredoc",
},

-- --------------------------------------------------------------- heredoc
heredoc = {
    what = "give a command the lines that follow it as its standard input",
    syn = { "CMD <<WORD", "CMD <<-WORD", "CMD <<'WORD'", "CMD <<\"WORD\"" },
    note = { "A here document takes the lines after the command line as the",
             "standard input of the command. The body runs up to a line that",
             "holds the delimiter WORD and nothing else: after cat <<EOF the",
             "body ends at a line that is just EOF, so a word around it (EOF",
             "and one more) or a blank in front of it is an ordinary line of",
             "the body. The newline in front of the delimiter belongs to the",
             "body, the delimiter line does not, and a body whose delimiter",
             "never comes ends at the end of the text.",

             "The body is text and nothing else: it is not split into",
             "fields, no pattern is tried on it and no command of it is run,",
             "so a line that looks like a command line is just a line of the",
             "input.",

             "A bare WORD leaves the references of the body live. $NAME,",
             "$((EXPR)) and $(CMD) are expanded there as they are inside",
             "double quotes, and the whole body becomes one piece of text.",
             "A backslash keeps the character that follows it, so a body",
             "holding \\$NAME holds the text $NAME and one holding \\\\ holds",
             "a single backslash; a backslash at the end of a line joins",
             "that line with the next one. 'WORD' or \"WORD\" turns the",
             "expansion off: the body is kept exactly as it was typed, back",
             "slashes and all.",

             "<<-WORD does the same and drops the tabs in front of every",
             "line of the body and of the delimiter line, so a script may",
             "indent an unquoted body without changing it; the blanks inside",
             "a line are left alone.",

             "A here document and the input redirection < set the same",
             "thing, the standard input of the command, so the one written",
             "last is the one that counts: cat <<EOF < FILE reads FILE and",
             "cat < FILE <<EOF reads the body. Two here documents on one",
             "line are both read in the order they were written and the last",
             "of them is the input. WORD is needed, so a << with nothing",
             "after it is a syntax error." },
    opts = { { "<<WORD", "the body is the standard input, and its references" ..
                         " are expanded" },
             { "<<-WORD", "the same, with the tabs in front of every line of" ..
                          " the body dropped" },
             { "<<'WORD'", "the body is kept as it was typed, no expansion" },
             { "<<\"WORD\"", "the same as <<'WORD'" } },
    see = "cat, expansion, grep, tr",
},

-- ------------------------------------------------------------------- trap
trap = {
    what = "run a command when the shell is stopped or when it leaves",
    syn = { "trap", "trap -p [SIGNAL ...]", "trap ACTION SIGNAL ...",
            "trap '' SIGNAL ...", "trap - SIGNAL ...",
            "trap -- ACTION SIGNAL ..." },
    note = { "trap waits for a signal and runs a command when it comes. A",
             "signal is named in any of the ways a shell accepts: EXIT, exit,",
             "SIGEXIT and 0 all name the same one. A shell here may wait for",
             "HUP, INT, QUIT, TERM, EXIT and ERR; KILL is known but may never",
             "be caught, ignored or reset.",

             "The first word is the action. A text of any length is what a",
             "delivered signal runs: it is kept as it was typed and read again",
             "when the signal comes, so it may hold a whole command list or a",
             "condition, and the line trap 'echo bye' EXIT installs a trap",
             "that writes bye when the shell leaves. An empty action ignores",
             "the signal and the sign - puts the default disposition back. One",
             "action may be given more than one signal, and all of them then",
             "share it: trap '' INT TERM ignores both of them.",

             "trap with no word, and trap -p, write the traps that are set,",
             "one line for each, in a form that may be run again: the text is",
             "quoted as one word and an ignored signal is written as ''. A line",
             "of trap -p SIGNAL writes the trap of one signal, and nothing at",
             "all when that signal has none. Such a line begins with --, the",
             "word that ends the options of the built-in: an action which",
             "starts with a dash of its own is still read as the action, and",
             "the line may be run again as it stands.",

             "The trap of EXIT runs when the shell leaves, once, with the",
             "status the shell is about to leave with, and the status of the",
             "shell becomes the status the trap ends with, so a trap of EXIT",
             "may change the code of an exit. A sub shell and a command script",
             "carry traps of their own and run the trap of EXIT of that shell",
             "when it is over; the traps of the shell that opened them are not",
             "touched and come back, while the traps of a sourced script",
             "belong to the shell that reads it.",

             "CraftOS is single threaded and has one interrupt: holding Ctrl+T",
             "makes the call that is waiting give up with Terminated. That is",
             "the INT of a command here. The trap of INT runs when a command, a",
             "script or the shell itself is stopped that way, and the status",
             "becomes 130, the status of a command that was interrupted.",

             "The trap of ERR runs for a command that fails: a command that",
             "was found and reports a status that is not 0, a file that may not",
             "be run, a script that cannot be read and a command that raises an",
             "error. A name that is not a command at all is a fault of the",
             "shell and does not run the trap.",

             "A signal that the shell does not know and a missing action are",
             "both faults: the shell reports the word, the status is 1 and no",
             "trap is changed by the line that failed." },
    opts = { { "trap", "the traps that are set, ready to be run again" },
             { "trap -p SIGNAL", "the trap of one signal, nothing when it has" ..
                                 " none" },
             { "trap ACTION SIGNAL", "run ACTION when SIGNAL is delivered" },
             { "trap '' SIGNAL", "ignore the signal" },
             { "trap - SIGNAL", "put the default disposition of the signal" ..
                                " back" },
             { "trap -- ACTION SIGNAL", "the same, for an action that begins" ..
                                        " with a dash" } },
    see = "set, source, kill, env",
},
}

-- ------------------------------------------------------------------ lookup

-- Look a name up. Aliases and the bracket form map onto their page.
local ALIASES = {
    ["["] = "[",
    ["."] = ".",
    ["apt"] = "apt",
}

function man.exists(name)
    return name ~= nil and man.pages[name] ~= nil
end

function man.list()
    local names = {}
    for name in pairs(man.pages) do names[#names + 1] = name end
    table.sort(names)
    return names
end

-- Search the one line descriptions (and the names) for a word. Returns an
-- array of { name, what } pairs, sorted by name.
function man.search(word)
    local needle = string.lower(tostring(word or ""))
    local hits = {}
    for name in pairs(man.pages) do
        local page = man.pages[name]
        local hay = string.lower(name .. " " .. page.what)
        if needle ~= "" and string.find(hay, needle, 1, true) then
            hits[#hits + 1] = { name = name, what = page.what }
        end
    end
    table.sort(hits, function(a, b) return a.name < b.name end)
    return hits
end

-- Render one page into an array of lines.
function man.render(name)
    local page = man.pages[name]
    if not page then return nil end
    local out = {}
    local function put(text) out[#out + 1] = text or "" end

    put("NAME")
    put("  " .. name .. " - " .. page.what)
    put("")
    put("SYNOPSIS")
    for _, line in ipairs(page.syn or { name }) do put("  " .. line) end
    put("")
    put("DESCRIPTION")
    put("  " .. page.what .. ".")
    for _, line in ipairs(page.note or {}) do put("  " .. line) end
    if page.opts then
        put("")
        put("OPTIONS")
        for _, opt in ipairs(page.opts) do
            put(string.format("  %-16s %s", opt[1], opt[2]))
        end
    end
    if page.sub then
        put("")
        put("SUBCOMMANDS")
        for _, sub in ipairs(page.sub) do
            put(string.format("  %-20s %s", sub[1], sub[2]))
        end
    end
    if page.see then
        put("")
        put("SEE ALSO")
        put("  " .. page.see)
    end
    return out
end

-- man(8) command. Handles -k WORD, -l and a list of names. Returns 0 when at
-- least one page was printed, 1 when a name is unknown.
function man.main(args, stage)
    local function emit(text)
        text = text or ""
        if stage and stage._out then
            stage._out.write(text)
            stage._out.write("\n")
        else
            print(text)
        end
    end

    local names, words, listing = {}, {}, false
    local i = 1
    while i <= #(args or {}) do
        local a = args[i]
        if a == "-h" or a == "--help" then
            emit("usage: man NAME...")
            emit("       man -k WORD")
            emit("       man -l")
            return 0
        elseif a == "-k" or a == "--search" then
            words[#words + 1] = args[i + 1] or ""
            i = i + 1
        elseif a == "-l" or a == "--list" then
            listing = true
        elseif a:sub(1, 1) == "-" then
            emit("man: unknown option " .. a)
            return 1
        else
            names[#names + 1] = a
        end
        i = i + 1
    end

    if listing then
        for _, name in ipairs(man.list()) do
            emit(string.format("%-12s %s", name, man.pages[name].what))
        end
        return 0
    end

    if #words > 0 then
        local status = 1
        for wi, word in ipairs(words) do
            local hits = man.search(word)
            if wi > 1 then emit("") end
            for _, hit in ipairs(hits) do
                emit(string.format("%-12s - %s", hit.name, hit.what))
                status = 0
            end
            if #hits == 0 then
                emit("man: nothing appropriate for " .. word)
            end
        end
        return status
    end

    if #names == 0 then
        emit("What manual page do you want?")
        emit("  man -l          list every page")
        emit("  man -k WORD     search the descriptions")
        emit("For example, try 'man ls' or 'man pkg'.")
        return 1
    end

    local status = 0
    for ni, name in ipairs(names) do
        local page = man.pages[name]
        if page then
            if ni > 1 then emit("") end
            for _, line in ipairs(man.render(name)) do emit(line) end
        else
            emit("man: no manual entry for " .. name)
            status = 1
        end
    end
    return status
end

return man
