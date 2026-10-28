"""PC side test runner for the psh project (CC:Tweaked).

One command runs everything:

    python tests/run_all.py

What it does
  gate 1  compile every .lua file of the project under each lupa runtime that
          is installed (luajit21 / lua51 / lua52 / ...), so a syntax error is
          caught without a CraftOS machine;
  gate 2  flag every line that is not plain ASCII in the text files a machine
          can actually receive: the rule is asked of tools/deploy.py, which is
          the one program that decides what is deployed, so the Chinese
          README.md and ROADMAP.zh.md and every .py/.json/.log are outside it;
  gate 3  check the documentation set (README.md) wherever the file is
          present; README.md is PC side documentation and no machine copy
          carries it, so its absence is reported but is not a fault;
  gate 4  check that every shell builtin has a manual page in lib/man.lua;
  suites  batch_check, class3_check, batch3_check, batch4_check, batch5_check,
          batch6_check, batch7_check, each in its own fresh Lua state over
          tests/cc_env_stub.lua;
  gate 7  keep ROADMAP.md and its Chinese translation ROADMAP.zh.md in step:
          same headings, same order, same levels, same section numbers, and
          every word of an English heading named in the matching Chinese one;
  gate 5  self test of tools/deploy.py (differential copy, twice, plus a
          removed target file).

Every result printed here is a PC side simulation result. It is NOT a
CraftOS-PC result: the real machine still has to be used for the final word on
disk events, rednet timing and the boot sequence.

Options
  --list              list the suites and gates and exit
  --suite NAME        run only this suite (repeatable); gates are skipped
                      unless --gates is given as well
  --gates             run the gates (default: on, unless --suite is used)
  --no-gates          skip gates 1..4
  --no-deploy         skip gate 5
  --verbose           print the per suite report on failure as well
"""

import json
import os
import re
import shutil
import subprocess
import sys
import tempfile

sys.stdout.reconfigure(encoding="utf-8", errors="replace")
sys.path.insert(0, os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "tools"))
try:
    import deploy                          # the one authority on what a machine gets
except Exception as exc:                   # pragma: no cover - reported by the gate
    deploy = None
    DEPLOY_IMPORT_ERROR = exc
else:
    DEPLOY_IMPORT_ERROR = None

TESTS = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(TESTS)

SUITES = [
    ("batch", "batch_check.lua", []),
    ("class3", "class3_check.lua", []),
    ("batch3", "batch3_check.lua", ["net_harness.lua"]),
    ("batch4", "batch4_check.lua", []),
    ("batch5", "batch5_check.lua", []),
    ("batch6", "batch6_check.lua", []),
    ("batch7", "batch7_check.lua", []),
    ("batch8", "batch8_check.lua", ["net_harness.lua"]),
    ("batch9", "batch9_check.lua", []),
    # The GNOME-like desktop PACKAGE (tools/pkgs/gnome, installed with
    # "pkg install gnome"). It renders into a gnome.screen buffer rather than a
    # terminal, because term.getLine does not exist on CraftOS-PC 2.8.3 and a
    # drawn cell cannot be read back off a real screen -- without that buffer,
    # "it did not raise" would be the only testable thing.
    ("batch10", "batch10_check.lua", []),
]

TEXT_EXT = (".lua", ".py", ".md", ".txt", ".ps1", ".conf", ".json", ".csv")
# README.md and ROADMAP.zh.md are the Chinese documents of the project. Neither is
# ever copied to a machine (tools/deploy.py skips every .md), so gate 2 leaves them
# alone while gate 3 still checks what the README says and gate 7 keeps the two
# roadmaps in step.
ASCII_EXEMPT = {"README.md", "ROADMAP.zh.md"}
SKIP_DIRS = {".git", "__pycache__", ".tmp", "fontdata"}


def parse_args(argv):
    opts = {"suites": [], "gates": None, "deploy": True, "verbose": False, "list": False}
    i = 0
    while i < len(argv):
        a = argv[i]
        if a == "--list":
            opts["list"] = True
        elif a == "--suite":
            i += 1
            opts["suites"].append(argv[i])
        elif a == "--gates":
            opts["gates"] = True
        elif a == "--no-gates":
            opts["gates"] = False
        elif a == "--no-deploy":
            opts["deploy"] = False
        elif a == "--verbose":
            opts["verbose"] = True
        else:
            raise SystemExit("unknown option: %s" % a)
        i += 1
    if opts["gates"] is None:
        opts["gates"] = not opts["suites"]
    return opts


def load_lupa():
    runtimes = []
    for name in ("luajit21", "lua51", "lua52", "lua53", "lua54", "luajit20"):
        try:
            mod = __import__("lupa." + name, fromlist=["LuaRuntime"])
        except Exception:
            continue
        runtimes.append((name, getattr(mod, "LuaRuntime")))
    if not runtimes:
        raise SystemExit("no lua runtime available: pip install lupa")
    return runtimes


def read_source(rel):
    with open(os.path.join(REPO, rel), "r", encoding="utf-8") as fh:
        return fh.read()


PRELUDE = "_G.SH_SRC = {}\n"
for _name, _rel in (("rget", "usr/cmd/rget.lua"), ("rput", "usr/cmd/rput.lua"),
                    ("rexec", "usr/cmd/rexec.lua"), ("craftos", "usr/cmd/craftos.lua"),
                    ("psh", "usr/psh.lua"),
                    # startup.lua is carried too: it is not a module the shell
                    # loads, but its text is what a test can check for the things
                    # that must NOT be there (a removed escape path, for one).
                    ("startup", "startup.lua")):
    PRELUDE += "_G.SH_SRC['%s'] = [====[\n%s\n]====]\n" % (_name, read_source(_rel))

COMPILE_HELPER = """
function __compile(path)
    local f, err = loadfile(path)
    if f then return true, "" end
    return false, tostring(err)
end
"""


def read_host_file(path):
    """Read one text file of this repository from the PC side, read only.

    The suites run inside the emulated file system of the stub and cannot see
    the repository itself. A suite that has to check a file that ships with the
    project (/etc/theme.conf for example) uses this helper, which is published
    to the Lua state as _G.read_host_file and returns the text or nil.
    """
    try:
        if isinstance(path, (bytes, bytearray)):
            path = bytes(path).decode("utf-8", "replace")
        with open(str(path), "r", encoding="utf-8", errors="replace") as fh:
            return fh.read()
    except (OSError, ValueError):
        return None


def deploy_files(part):
    """Which project relative files tools/deploy.py writes for one --part half.

    Published to the Lua state as _G.SH_DEPLOY.base / .modules (see new_state),
    so a suite can assert on the SPLIT ITSELF rather than on a second list that
    could drift from it. The two halves are decided by the column-0 requires of
    the boot entry points; a module moved from one half to the other is exactly
    the regression those assertions are for, and asking deploy.collect() is the
    same answer the builder gets.

    part is "base", "modules" or "all"; an empty list comes back when the deploy
    module could not be imported (the gate reports that separately).
    """
    if deploy is None:
        return []
    opts = deploy.Options()
    opts.part = str(part)
    return deploy.collect(REPO, opts)


def new_state(LuaRuntime, boot):
    lua = LuaRuntime(unpack_returned_tuples=True)
    lua.execute("PROJ = [[%s]]" % REPO)
    lua.execute("TESTS = [[%s]]" % TESTS)
    lua.execute("TEMP = [[%s]]" % TESTS)
    lua.execute(PRELUDE)
    lua.execute(COMPILE_HELPER)
    lua.execute("dofile(TESTS .. '/cc_env_stub.lua')")
    for extra in boot:
        lua.execute("dofile(TESTS .. '/%s')" % extra)
    lua.globals().read_host_file = read_host_file
    # What tools/deploy.py would put in each half of a two-part install. A suite
    # that asks "is this security module on the computer or on the medium?" has to
    # ask the tool that decides, not a copy of its list. table_from, because a
    # Python list handed to Lua is userdata and not an array.
    lua.globals().SH_DEPLOY = lua.table_from({
        "base": lua.table_from(deploy_files("base")),
        "modules": lua.table_from(deploy_files("modules")),
    })
    return lua


def lua_files():
    out = []
    for root, dirs, files in os.walk(REPO):
        dirs[:] = [d for d in dirs if d not in SKIP_DIRS]
        for name in sorted(files):
            if name.endswith(".lua"):
                out.append(os.path.join(root, name))
    out.sort()
    return out


def machine_wanted(rel):
    """Is this project relative path one a machine ever receives?

    The ASCII rule exists because a ByteString reaching a computer has to survive
    CraftOS, which is not a place for a UTF-8 document. So the rule is asked of
    tools/deploy.py itself, the one program that decides what a machine gets,
    rather than of a second list that could drift away from it. A file
    deploy.py refuses (README.md, ROADMAP.zh.md, every .py, .json, .log and any
    path under tests/ or tools/) may hold any text it likes.
    """
    if deploy is None:
        return True                       # tools/deploy.py missing: stay strict
    return deploy.wanted(rel, deploy.Options())


def text_files():
    out = []
    for root, dirs, files in os.walk(REPO):
        dirs[:] = [d for d in dirs if d not in SKIP_DIRS]
        for name in sorted(files):
            if name in ASCII_EXEMPT:
                continue
            if not name.endswith(TEXT_EXT):
                continue
            path = os.path.join(root, name)
            rel = os.path.relpath(path, REPO)
            if not machine_wanted(rel):
                continue
            out.append(path)
    out.sort()
    return out


# --------------------------------------------------------------------- gates
def gate_syntax(runtimes, quiet):
    files = lua_files()
    problems = 0
    if not quiet:
        print("gate 1: compile %d lua files" % len(files))
    for name, LuaRuntime in runtimes:
        lua = LuaRuntime(unpack_returned_tuples=True)
        lua.execute(COMPILE_HELPER)
        bad = []
        for path in files:
            ok, err = lua.globals().__compile(path)
            if not ok:
                bad.append((path, err))
        problems += len(bad)
        if not quiet:
            print("  %-10s errors: %d" % (name, len(bad)))
        for path, err in bad:
            print("  SYNTAX %s -> %s" % (os.path.relpath(path, REPO), err))
    return problems


def gate_ascii(quiet):
    files = text_files()
    bad = []
    for path in files:
        with open(path, "r", encoding="utf-8", errors="replace") as fh:
            for n, line in enumerate(fh.read().splitlines(), 1):
                if any(ord(ch) > 127 for ch in line):
                    bad.append("%s:%d" % (os.path.relpath(path, REPO), n))
    if not quiet:
        print("gate 2: %d text files, non ascii lines: %d" % (len(files), len(bad)))
        for rel in sorted(ASCII_EXEMPT):
            print("  exempt (Chinese documentation, never deployed): %s" % rel)
    for item in bad[:20]:
        print("  NON-ASCII %s" % item)
    return len(bad)


def gate_docs(quiet):
    """Check the documentation set (README.md).

    README.md is the one Chinese document of the project and tools/deploy.py
    never copies it to a machine, so a deployed copy of the tree (a CraftOS-PC
    computer folder, a floppy mount) has no README at all. Its absence is
    therefore reported as a note, not counted as a problem; the file is
    checked whenever it is there, which is the case in the source tree.
    """
    need = {
        # The Chinese README has to keep naming the deploy tool, the manual
        # page viewer, the test runner and the gates. It used to have to name
        # the AI content notice as well; the owner asked for the generated AIGC
        # labels (the YAML block and the English disclaimer) to be removed on
        # 2026-10-17, so nothing is demanded about them any more.
        "README.md": ["deploy", "man", "run_all.py", "gate"],
    }
    bad = 0
    absent = []
    for rel, words in sorted(need.items()):
        path = os.path.join(REPO, rel)
        if not os.path.isfile(path):
            absent.append(rel)
            continue
        with open(path, "r", encoding="utf-8", errors="replace") as fh:
            text = fh.read()
        for w in words:
            if w not in text:
                print("  %s does not mention %r" % (rel, w))
                bad += 1
    if not quiet:
        print("gate 3: documentation set, problems: %d" % bad)
        for rel in absent:
            print("  note: no %s in this tree (PC side documentation, no "
                  "machine carries it), content check skipped" % rel)
    return bad


def roadmap_headings(path):
    """Every heading of a roadmap, as (line number, level, number, text)."""
    out = []
    with open(path, "r", encoding="utf-8", errors="replace") as fh:
        for n, line in enumerate(fh, 1):
            m = re.match(r"^(#{1,4}) (.+?)\s*$", line)
            if not m:
                continue
            level = len(m.group(1))
            text = m.group(2)
            num = re.match(r"^([0-9]+(?:\.[0-9]+)?)\.\s", text + " ")
            out.append((n, level, num.group(1) if num else "", text))
    return out


def gate_roadmap(quiet):
    """The two roadmaps have to say the same thing.

    ROADMAP.md is the authority and ROADMAP.zh.md is its Chinese translation. They
    are two files, so they can drift apart silently: a section added to one, a
    number reordered in the other, or a title replaced with no counterpart. The
    pairs are checked structurally -- same headings, same order, same levels, same
    section numbers -- and then word by word, because the Chinese headings keep
    the English words in brackets so a reader can find the same section in either
    language.

    Structure is exact. The wording check asks that every word of the English
    heading (letters only, four characters or more, so "the", "and", "of" and
    "a" do not count) appears somewhere in the same Chinese heading; the Chinese
    text is free to add its own words around them.
    """
    pairs = [("ROADMAP.md", "ROADMAP.zh.md")]
    bad = 0
    for primary, translated in pairs:
        p1 = os.path.join(REPO, primary)
        p2 = os.path.join(REPO, translated)
        missing = [rel for rel, p in ((primary, p1), (translated, p2)) if not os.path.isfile(p)]
        if missing:
            if not quiet:
                print("gate 7: roadmaps, problems: %d (missing: %s)"
                      % (len(missing), ", ".join(missing)))
            for rel in missing:
                print("  %s does not exist" % rel)
            bad += len(missing)
            continue
        one = roadmap_headings(p1)
        two = roadmap_headings(p2)
        problems = []
        if len(one) != len(two):
            problems.append("%s has %d headings, %s has %d"
                            % (primary, len(one), translated, len(two)))
        for i in range(min(len(one), len(two))):
            a, b = one[i], two[i]
            where = "%s:%d / %s:%d" % (primary, a[0], translated, b[0])
            if a[1] != b[1]:
                problems.append("%s: heading level %d vs %d" % (where, a[1], b[1]))
            if a[2] != b[2]:
                problems.append("%s: section number %r vs %r (%s / %s)"
                                % (where, a[2], b[2], a[3], b[3]))
            words = [w for w in re.findall(r"[A-Za-z]{4,}", a[3])]
            gone = [w for w in words if w not in b[3]]
            if gone:
                problems.append("%s: %s does not name %s"
                                % (where, translated, ", ".join(gone)))
        for item in problems:
            print("  " + item)
        bad += len(problems)
        if not quiet:
            print("gate 7: roadmaps, problems: %d (%s, %d headings)"
                  % (len(problems), primary, len(one)))
    return bad


def gate_config(quiet):
    """Every configuration key a document promises has to be read by some code.

    The suites run against an emulated filesystem that holds no project tree, so a
    module's own source is out of their reach; a key that is documented in
    etc/network.conf (or that a machine is told to set) could therefore be renamed
    or dropped without one failure. This gate reads the host files, which is the
    only place where "the option exists" can be checked at all.

    It is deliberately narrow: it checks that each key is read where it is
    documented to be read, not how the value flows afterwards.
    """
    keys = {
        # key in etc/network.conf -> the file that has to read it
        "transport": "lib/rpvnet.lua",
        "rpv_side": "lib/rpvnet.lua",
        "rpv_channel": "lib/rpvnet.lua",
        "rpv_mtu": "lib/rpvnet.lua",
        "rpv_cidr": "lib/rpvnet.lua",
        "rpv_reasm_bytes": "lib/rpvnet.lua",
        "rpv_reasm_entries": "lib/rpvnet.lua",
        "rpv_frag_pace": "lib/rpvnet.lua",
        "rpv_frag_pace_ms": "lib/rpvnet.lua",
        "rpv_log_max_bytes": "lib/rpvnet.lua",
        "disk": "lib/disk.lua",
        "automount": "lib/disk.lua",
        "store_required": "lib/pkg.lua",
        "sys_required": "lib/pkg.lua",
        "pkg_sig_required": "lib/pkg.lua",
        # the machine rules of /etc/boot.conf and the setup screen's own store
        "boot_guard": "lib/protect.lua",
        "no_exit": "lib/protect.lua",
        "ask_password": "lib/bios.lua",
        # the transfer settings are read through netcfg's typed helpers, so the
        # name appears as an argument rather than as a quoted key
        "chunk_size": "lib/netcfg.lua",
        "retries": "lib/netcfg.lua",
    }
    # a few names are read without quotes (netcfg.number("chunk_size")) or from a
    # table of defaults, so the match allows the bare word as well
    bare_ok = {"chunk_size", "retries", "transport"}
    sources = {}
    bad = 0
    for rel in sorted(set(keys.values())):
        path = os.path.join(REPO, rel)
        if not os.path.isfile(path):
            print("  %s is missing" % rel)
            bad += 1
            continue
        with open(path, "r", encoding="utf-8", errors="replace") as fh:
            sources[rel] = fh.read()
    for key, rel in sorted(keys.items()):
        text = sources.get(rel)
        if text is None:
            continue
        # the key is read through a lookup helper, so the bare name has to appear
        if ('"%s"' % key) not in text and ("'%s'" % key) not in text and \
                not (key in bare_ok and key in text):
            print("  %s is documented but %s never reads it" % (key, rel))
            bad += 1
    if not quiet:
        print("gate 6: configuration keys, problems: %d" % bad)
    return bad


def builtin_names():
    text = read_source("usr/psh.lua")
    names = sorted(set(re.findall(r'\nBUILTINS\["([^"]+)"\]\s*=', text)))
    return names


def gate_man(LuaRuntime, quiet):
    """Every builtin must have a page, and lib/man.lua must stay pure data."""
    lua = LuaRuntime(unpack_returned_tuples=True)
    lua.execute("package.path = [[%s/lib/?.lua;]] .. package.path" % REPO)
    names = str(lua.eval("(function() local t = {} "
                         "for _, n in ipairs(require('man').list()) do "
                         "t[#t + 1] = n end "
                         "return table.concat(t, ' ') end)()"))
    pages = sorted(names.split())
    builtins = builtin_names()
    missing = [n for n in builtins if n not in pages]
    extra = sorted(set(pages) - set(builtins))
    text = read_source("lib/man.lua")
    body = "\n".join(l for l in text.splitlines() if not l.strip().startswith("--"))
    impure = [tok for tok in ("fs.", "term.", "rednet.", "os.sleep") if tok in body]
    problems = len(missing) + len(impure)
    if not quiet:
        print("gate 4: man pages %d, builtins %d, missing %d, not builtins %d"
              % (len(pages), len(builtins), len(missing), len(extra)))
    for n in missing:
        print("  NO MAN PAGE for builtin %s" % n)
    for tok in impure:
        print("  lib/man.lua reaches out to %s" % tok)
    if not quiet and extra:
        print("  informational: pages for names that are not builtins: %s"
              % " ".join(extra))
    return problems


def gate_log_summary(quiet):
    """Self test of tools/rpv-verify/log_summary.py, the acceptance report.

    Why this is a gate and not a nicety: the report is the only thing a reader of a
    hardware run sees, so a report that quietly matches nothing is worse than the
    ten line tail it replaced. That already happened once -- the default pattern was
    written against the Minecraft driver's uppercase vocabulary ("REQUEST op=nil"),
    and the emulator driver logs the same events in lowercase ("request op=get"), so
    it matched 2 of 249 lines of a real log and the run looked empty.

    The checks below are the ones that failure would have tripped: a repeated line has
    to be reported with its count and every occurrence, the verdict has to be printed
    whatever the pattern says, both cases of the vocabulary have to match, and a
    missing or empty log has to say so rather than print silence.
    """
    script = os.path.join(REPO, "tools", "rpv-verify", "log_summary.py")
    if not os.path.isfile(script):
        print("  MISSING tools/rpv-verify/log_summary.py")
        return 1

    def summarise(text, extra=None):
        scratch = tempfile.mkdtemp(prefix="psh_logsummary_")
        try:
            path = os.path.join(scratch, "machine.log")
            with open(path, "w", encoding="utf-8") as fh:
                fh.write(text)
            cmd = [sys.executable, script, path] + (extra or [])
            out = subprocess.run(cmd, capture_output=True, text=True)
            return out.returncode, out.stdout
        finally:
            shutil.rmtree(scratch, ignore_errors=True)

    problems = 0

    def expect(label, cond, detail=""):
        nonlocal problems
        if not cond:
            print("  log_summary: %s%s" % (label, (" -- " + detail) if detail else ""))
            problems += 1

    # A repeat, early, with plenty of other matching lines after it: a tail loses it.
    # There are TWO repeats of different sizes on purpose, so "most repeated first" is
    # actually testable -- with one repeat the ordering assertion is vacuous.
    busy = ["2.04 BOOT peer id=20", "8.22 REQUEST op=get from=21",
            "26.58 REQUEST op=put from=21", "26.70 REQUEST op=put from=21"]
    busy += ["34.0%d REQUEST op=nil from=21" % i for i in range(3)]
    busy += ["4%d.10 REQUEST op=nil from=21" % i for i in range(1, 10)]
    busy += ["64.20 SERVED ok=false reason=transfer stalled", "64.21 PEER_VERDICT FAIL"]
    rc, out = summarise("\n".join(busy) + "\n")
    expect("exits 0 on a normal log", rc == 0, str(rc))
    expect("counts the repeated line", "12x" in out and "REQUEST op=nil" in out, out[:200])
    expect("lists every occurrence of a repeat", out.count("34.00") == 1 and
           "34.02" in out, "the timestamps are what make a repeat a sequence")
    expect("reports how many lines matched", "matched" in out and "(18 line(s)" in out,
           out[:120])
    # The verdict is printed as a verdict, not merely present somewhere in a group.
    expect("prints the verdict", "PEER_VERDICT FAIL" in out and "verdict:" in out, out)
    expect("a run that reached a verdict does not claim there was none",
           "none recorded" not in out, "the verdict section must not fall through")
    expect("shows the first and last matched line", "first:" in out and "last:" in out)
    # The most repeated line has to come FIRST: that ordering is the whole point, and
    # first-appearance order would bury a 12x repeat behind a 2x one.
    repeats_at = out.find("12x")
    smaller_at = out.find("2x")
    singles_at = out.find("once:")
    expect("the biggest repeat is listed first, before the singles",
           repeats_at != -1 and singles_at != -1 and repeats_at < singles_at,
           "12x at %s, once: at %s" % (repeats_at, singles_at))
    expect("the 12x repeat is listed before the 2x one",
           smaller_at != -1 and repeats_at < smaller_at,
           "12x at %s, 2x at %s (ordering by count, not first appearance)"
           % (repeats_at, smaller_at))

    # The case trap: the same events in the emulator driver's lowercase spelling.
    lower = ("0.02 peer start id=20\ntransport ok=true backend=rpv\n"
             "2.15 serving /big.bin size=200000 crc=4c790f2d\n"
             "8.23 request op=get from=21\n44.79 served ok=true info=table: 1\n"
             "45.85 pushed size=200000 crc=4c790f2d same_as_source=true\n"
             "45.85 SERVER_VERDICT PASS\n")
    rc, out = summarise(lower)
    expect("matches the lowercase vocabulary too", "6 matched" in out, out[:160])
    expect("a lowercase run still reports its verdict", "SERVER_VERDICT PASS" in out, out)
    expect("a lowercase repeat is still counted",
           "2x" in summarise("request op=put from=1\nrequest op=put from=1\n")[1],
           "two equal lowercase lines must fold into one group")
    expect("a lowercase repeat keeps both timestamps",
           "1.0" in summarise("1.0 request op=put from=1\n2.0 request op=put from=1\n")[1],
           "a count without the occurrences loses the order")

    # A log with nothing recognisable is reported, not printed as silence.
    rc, out = summarise("just some noise\nand more noise\n")
    expect("says when nothing matched", "nothing matched" in out, out[:160])
    expect("still says there is no verdict", "none recorded" in out, out)

    # A missing file and an empty file are different problems, and both are stated.
    scratch = tempfile.mkdtemp(prefix="psh_logsummary_")
    try:
        missing = os.path.join(scratch, "not-there.log")
        out = subprocess.run([sys.executable, script, missing],
                             capture_output=True, text=True).stdout
        expect("a missing log says it is not there", "not there" in out, out[:160])
        empty = os.path.join(scratch, "empty.log")
        open(empty, "w").close()
        out = subprocess.run([sys.executable, script, empty],
                             capture_output=True, text=True).stdout
        # "empty" alone would match the file NAME, so the assertion looks for the
        # sentence the tool prints, not for the word anywhere in the output.
        expect("an empty log says it is empty", "the log is empty" in out, out[:160])
        expect("an empty log does not pretend nothing matched",
               "nothing matched" not in out, "an empty file matched nothing for a reason")
    finally:
        shutil.rmtree(scratch, ignore_errors=True)

    # A bad pattern is a usage error, not a silent empty report.
    rc, out = summarise("anything\n", ["--pattern", "("])
    expect("a bad pattern is refused", rc != 0, str(rc))

    if not quiet:
        print("gate 8: acceptance report self test, problems: %d" % problems)
    return problems


def gate_fonttools(quiet):
    """Self test of tools/fontgen.py and tools/fontdisk.py.

    WHY THIS IS A GATE AND NOT A NICETY
    The glyph generator and the medium builder are the two programs with no Lua
    part: their output is data, so a bug in them produces a medium that looks
    finished and a screen with nothing on it. Two of the bugs below were real and
    both were silent -- the codepoint parser split "U+4E2D" on the "-" in its own
    spelling and drew the letter D, and the placeholder-box rule was stated as a
    list of non-graphic categories, which turned every UNASSIGNED codepoint into a
    box. Neither made any tool fail; both were found by looking at output.

    The checks are the shapes a wrong answer has:
      * every spelling of a codepoint names the SAME codepoint (the parser);
      * the default set is the size it says and its first entries are the
        punctuation a CJK document needs before its 3000th ideograph;
      * an unassigned or control codepoint is NOT drawn (the box rule);
      * the generated files are ASCII, so the ROM's loadstring can read them;
      * the marker written onto the medium names the marker lib/cc_fonts.lua
        reads, and the store marker is never the SYSTEM one;
      * a set split over two media is a PARTITION of it: each medium's index
        names only the shards beside it, each codepoint is on exactly one medium,
        each manifest says which part it is, and a medium over its stated
        capacity is refused rather than written;
      * tools/deploy.py refuses to put fontdata/ on a machine, which is the
        difference between the glyphs living on a medium and on the disk they
        overflow.
    """
    problems = 0

    def expect(label, cond, detail=""):
        nonlocal problems
        if not cond:
            print("  fonttools: %s%s"
                  % (label, (" -- " + str(detail)) if detail != "" else ""))
            problems += 1

    tools_dir = os.path.join(REPO, "tools")
    fontgen_path = os.path.join(tools_dir, "fontgen.py")
    fontdisk_path = os.path.join(tools_dir, "fontdisk.py")
    for path in (fontgen_path, fontdisk_path):
        if not os.path.isfile(path):
            print("  MISSING %s" % os.path.relpath(path, REPO))
            return problems + 1

    import importlib.util

    def load(name, path):
        spec = importlib.util.spec_from_file_location(name, path)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        return module

    try:
        fontgen = load("_gate_fontgen", fontgen_path)
        fontdisk = load("_gate_fontdisk", fontdisk_path)
    except Exception as exc:
        print("  a font tool cannot be imported: %s" % exc)
        return problems + 1

    # ---- the codepoint parser -------------------------------------------
    # Every PREFIXED spelling of U+4E2D must give exactly [0x4E2D]. The old parser
    # split on "-", found none, and fell through to "literal text", so it returned
    # the seven characters of the SPELLING -- and the run that did it succeeded.
    #
    # "4E2D" is deliberately NOT in this list: without a prefix it is the literal
    # text 4E2D, which is what a user typing a short label means, and that is the
    # next check.
    for spelling in ("U+4E2D", "u+4e2d", "u4e2d", "0x4e2d", "20013"):
        got = fontgen.parse_range(spelling)
        expect("parse_range(%r) names U+4E2D and nothing else" % spelling,
               got == [0x4E2D], repr(got))
    expect("parse_range of a range is inclusive",
           fontgen.parse_range("U+4E00-U+4E03") == [0x4E00, 0x4E01, 0x4E02, 0x4E03],
           repr(fontgen.parse_range("U+4E00-U+4E03")))
    try:
        fontgen.parse_range("U+4E03-U+4E00")
        expect("parse_range refuses a backwards range", False, "no error raised")
    except fontgen.FontgenError:
        expect("parse_range refuses a backwards range", True)
    # A bare string of letters is still literal text, which is what a user typing
    # a short label means.
    expect("parse_range of plain text is its codepoints",
           fontgen.parse_range("ABC") == [0x41, 0x42, 0x43],
           repr(fontgen.parse_range("ABC")))

    # ---- the default set ------------------------------------------------
    wanted = fontgen.default_charset(None)
    expect("the default set is %d glyphs" % fontgen.DEFAULT_GLYPHS,
           len(wanted) == fontgen.DEFAULT_GLYPHS, len(wanted))
    expect("it starts with the CJK punctuation a document needs",
           ord(fontgen.PUNCTUATION[0]) == 0x3000 and 0x3002 in wanted[:24],
           "first %d: %s" % (len(wanted[:24]), wanted[:6]))
    expect("the ideographic space is in it", 0x3000 in wanted)
    expect("it holds no duplicate codepoints",
           len(set(wanted)) == len(wanted))
    level1 = fontgen.gb2312_level1()
    expect("GB2312 level 1 is the standard's 6763 characters",
           len(level1) == 6763, len(level1))
    # The cap is a CAP on the standard and not a selection from it, so the set is
    # the first (DEFAULT_GLYPHS - punctuation) characters of level 1 in the
    # standard's own order. Stating it as the prefix is what makes the shape of
    # the set checkable: a "selection" would need a word list, and this project
    # does not ship one.
    drawn_ideographs = fontgen.DEFAULT_GLYPHS - len(fontgen.PUNCTUATION)
    expect("the default set is the first %d characters of level 1, in order"
           % drawn_ideographs,
           wanted[len(fontgen.PUNCTUATION):] == level1[:drawn_ideographs],
           "%d ideograph(s) after the punctuation"
           % (len(wanted) - len(fontgen.PUNCTUATION)))

    # ---- an unassigned codepoint must not be drawn ------------------------
    # An UNASSIGNED codepoint has category Cn. It must NOT be drawn as a box: the
    # rule used to be stated as a list of non-graphic categories, with Cn in it,
    # and every unassigned slot in a font's cmap then became a visible
    # placeholder. A REAL font is opened here because glyph_rows reads the glyph
    # after the category test -- with no font it would fail before reaching the
    # behaviour under test.
    import unicodedata
    # A codepoint that is genuinely UNASSIGNED. The search covers the small blocks
    # where unassigned slots are common -- the reserved gap at the end of
    # Kangxi Radicals, the CJK Compatibility Ideographs gap, and the first rows of
    # plane 3 -- because a single range is not enough: U+30000, which looks
    # unassigned, is Lo in this Unicode version and made the first version of this
    # check test nothing at all.
    unassigned = None
    for cp in ([c for c in range(0x2FE0, 0x2FF0)] +
               [c for c in range(0x9FFF, 0xA000)] +
               [c for c in range(0x30000, 0x30020)] +
               [c for c in range(0x0870, 0x08A0)]):
        if unicodedata.category(chr(cp)) == "Cn":
            unassigned = cp
            break
    expect("there is an unassigned codepoint to test with", unassigned is not None,
           repr(unassigned))
    try:
        probe_font, _p, _f, _n, _i = fontgen.load_face(fontgen.DEFAULT_FONT, 12)
    except fontgen.FontgenError as exc:
        probe_font = None
        print("  fonttools: no font for the glyph-rule checks: %s" % exc)
    if probe_font is not None and unassigned is not None:
        expect("an UNASSIGNED codepoint is not drawn",
               fontgen.glyph_rows(probe_font, unassigned, 12) is None,
               "U+%04X" % unassigned)
        # The control on the other side: a real character of the same range IS
        # drawn, so the check above is not passing because glyph_rows says None to
        # everything.
        expect("a real CJK character IS drawn",
               fontgen.glyph_rows(probe_font, 0x4E2D, 12) is not None)
        for cp in (0x00, 0x0A, 0x00AD, 0x3000, 0x20):
            expect("U+%04X is not drawn (it has no ink on purpose)" % cp,
                   fontgen.glyph_rows(probe_font, cp, 12) is None,
                   "U+%04X" % cp)

    # ---- the writer, end to end -----------------------------------------
    # The generated files are written and read BACK, because the property that
    # matters -- ASCII with LF endings -- is a property of the bytes on disk and
    # cannot be seen by reading the generator's source. A regression in write_text
    # (the newline="" argument) turns every file into CRLF, which the machine's
    # loadstring would see as a stray byte inside the first line.
    scratch = tempfile.mkdtemp(prefix="psh_fontgen_")
    try:
        report = fontgen.generate(fontgen.DEFAULT_FONT, 8, scratch,
                                  ["U+4E00-U+4E0F"], 4, "shs8", True, False, None)
        names = sorted(os.listdir(scratch))
        expect("the generator wrote an index and shards", len(names) >= 2, names)
        expect("every name has the documented shape",
               all(n.endswith(".lua") and "_shard" in n or n.endswith("_index.lua")
                   for n in names), names)
        crlf, nonascii = [], []
        for name in names:
            with open(os.path.join(scratch, name), "rb") as fh:
                data = fh.read()
            if b"\r" in data:
                crlf.append(name)
            if any(b > 127 for b in data):
                nonascii.append(name)
        expect("the generated files have LF endings", not crlf, crlf)
        expect("the generated files are ASCII", not nonascii, nonascii)
        # And the shard holds the 8 x 8 matrices the run was asked for.
        shard = [n for n in names if "_shard" in n][0]
        with open(os.path.join(scratch, shard), "r", encoding="ascii") as fh:
            body = fh.read()
        expect("the shard's matrices are 8 rows of 8 characters",
               '"00000000"' in body, body[:120])
        # The codepoint is written as a DECIMAL NUMBER and the rows as plain
        # "0"/"1" strings: no \u escape and no packed byte, because the machine
        # reads this file with the ROM's loadstring and knows neither. The check
        # looks at the DATA rows and not at the whole file, which has a comment
        # naming the font.
        index_name = [n for n in names if n.endswith("_index.lua")][0]
        with open(os.path.join(scratch, index_name), "r", encoding="ascii") as fh:
            index_body = fh.read()
        index_rows = [l for l in index_body.splitlines() if l.startswith("[")]
        expect("the index names codepoints by number, not by escape",
               bool(index_rows) and
               all(l.split("=")[0].strip("[]").isdigit() for l in index_rows) and
               not any("\\" in l for l in index_rows),
               index_rows[:4])
        expect("and the numbers are the codepoints of the range asked for",
               all(0x4E00 <= int(l.split("=")[0].strip("[]")) <= 0x4E0F
                   or int(l.split("=")[0].strip("[]")) == 0xFFFD
                   for l in index_rows), index_rows[:4])
        # U+FFFD is always in a set even when the caller named its codepoints --
        # it is the glyph a missing character falls back to, and a set without one
        # has no answer for a character it does not have.
        expect("the fallback box is in the set even for a named range",
               any(int(l.split("=")[0].strip("[]")) == 0xFFFD for l in index_rows),
               index_rows[-3:])
        # The glyph count is the number of glyphs the font actually HAD for the
        # range: the ones with no ink are dropped (and not replaced, because this
        # run named its codepoints and asked for those). So the count is checked
        # as "at most one per codepoint, and at least the ones known to be there",
        # which is what a report has to be able to say.
        expect("the report's glyph count is the glyphs the font had",
               1 <= report["glyphs"] <= 17 and report["size"] == 8,
               "%s glyph(s) at size %s" % (report["glyphs"], report["size"]))
        expect("the report's count is the index's own row count",
               report["glyphs"] == len([l for l in index_body.splitlines()
                                        if l.startswith("[")]),
               "%s glyph(s) vs %d index row(s)"
               % (report["glyphs"],
                  len([l for l in index_body.splitlines() if l.startswith("[")])))
    except fontgen.FontgenError as exc:
        print("  fonttools: the generator could not run: %s" % exc)
        problems += 1
    finally:
        shutil.rmtree(scratch, ignore_errors=True)

    # ---- the medium, end to end -----------------------------------------
    # FONT_MARKER's VALUE is not enough: what matters is WHERE the marker lands
    # and that the glyphs end up in fonts/. So a medium is built from a synthetic
    # set and its tree is inspected.
    scratch = tempfile.mkdtemp(prefix="psh_fontdisk_")
    try:
        data_dir = os.path.join(scratch, "fontdata")
        out_dir = os.path.join(scratch, "medium")
        os.makedirs(data_dir)
        with open(os.path.join(data_dir, "shs8_index.lua"), "w", encoding="ascii",
                  newline="") as fh:
            fh.write("return {\n[65]=0,\n[66]=0,\n}\n")
        with open(os.path.join(data_dir, "shs8_shard0.lua"), "w", encoding="ascii",
                  newline="") as fh:
            fh.write('return {\n[65]={"10","01"},\n[66]={"01","10"},\n}\n')
        medium = fontdisk.build(out_dir, data_dir, True, True)
        expect("the medium carries the font marker at its ROOT",
               os.path.isfile(os.path.join(medium["out"], fontdisk.FONT_MARKER)))
        expect("and the glyphs under fonts/",
               os.path.isfile(os.path.join(medium["out"], fontdisk.FONTS_DIR,
                                           "shs8_index.lua")))
        expect("it carries the store marker inside the root",
               os.path.isfile(os.path.join(medium["out"], fontdisk.STORE_MARKER)))
        expect("and NOT the system store marker, which would claim the shell "
               "needs these glyphs to boot",
               not os.path.isfile(os.path.join(medium["out"], ".pkgsys")))
        expect("it writes its own notes", os.path.isfile(
            os.path.join(medium["out"], fontdisk.NOTES)))
        expect("and the notes are ASCII", all(
            ord(ch) < 128 for ch in open(
                os.path.join(medium["out"], fontdisk.NOTES),
                encoding="ascii").read()))
        with open(os.path.join(medium["out"], fontdisk.FONT_MARKER), "rb") as fh:
            marker_bytes = fh.read()
        expect("the marker has LF endings and no BOM",
               b"\r" not in marker_bytes and not marker_bytes.startswith(b"\xef\xbb\xbf"))
        # The size report has to describe the tree that was written, which is the
        # one number an operator plans a medium around.
        measured, files = fontdisk.tree_measure(medium["out"])
        expect("the reported size is the tree's actual size",
               medium["bytes"] == measured, "%s vs %s" % (medium["bytes"], measured))
        expect("and the glyph count is the index's", medium["glyphs"] == 2,
               medium["glyphs"])
        expect("the build reported every check as passing", medium["ok"])

        # A medium that is not one of ours is not overwritten, and the glyphs are
        # not put on a machine: both are answered by a "no" that has to be loud.
        stranger = os.path.join(scratch, "stranger")
        os.makedirs(stranger)
        with open(os.path.join(stranger, "keep.txt"), "w") as fh:
            fh.write("mine\n")
        try:
            fontdisk.build(stranger, data_dir, False, True)
            expect("a directory this tool did not write is refused", False,
                   "it was replaced")
        except fontdisk.FontdiskError:
            expect("a directory this tool did not write is refused", True)
        expect("and the directory is untouched",
               os.path.isfile(os.path.join(stranger, "keep.txt")))
    except Exception as exc:
        print("  fonttools: the medium builder could not run: %s" % exc)
        problems += 1
    finally:
        shutil.rmtree(scratch, ignore_errors=True)

    # ---- a set split over two media, end to end --------------------------
    # The whole of GB2312 at size 12 is 1,375,263 B and a CraftOS floppy holds
    # 1,228,800 B, so the shipped set is built as TWO media: the operator's
    # instruction was "the Chinese shards do not fit on one drive, so use two".
    # What has to be true of that build is that the media are a PARTITION of the
    # set and not two copies of it:
    #   * the index is SPLIT with the glyphs. A part whose index named a shard on
    #     another medium would send a lookup to a file that is not there, and the
    #     machine would draw nothing and raise nothing -- the exact failure this
    #     whole gate is about.
    #   * every codepoint is on exactly one medium, so the two indexes union to
    #     the source index and not to something larger or smaller.
    #   * every medium is inside the capacity it was fitted to, and a medium over
    #     it is REFUSED rather than written: "written and reported as 130%" is not
    #     a refusal, and it is the one failure an operator cannot see on a disk
    #     that looks finished.
    scratch = tempfile.mkdtemp(prefix="psh_fontdisk_set_")
    try:
        data_dir = os.path.join(scratch, "fontdata")
        set_dir = os.path.join(scratch, "set")
        os.makedirs(data_dir)
        shards, per = 4, 60
        cps, index_rows = [], []
        for shard in range(shards):
            body = []
            for n in range(per):
                cp = 0x4E00 + shard * per + n
                body.append('[%d]={"10","01"},\n' % cp)
                cps.append(cp)
                index_rows.append("[%d]=%d,\n" % (cp, shard))
            fontdisk.write_text(os.path.join(data_dir, "shs8_shard%d.lua" % shard),
                                "return {\n" + "".join(body) + "}\n")
        fontdisk.write_text(os.path.join(data_dir, "shs8_index.lua"),
                            "return {\n" + "".join(index_rows) + "}\n")

        # A capacity that fits the set on two media and not on one. The numbers
        # are chosen from the measurements (about 1.2 KB a shard, about 10 B an
        # index entry), not from the reserve constants, because a check that read
        # the constant would pass for any value of it. 15000 is also loose enough
        # that an UNEVEN split (three shards on one medium and one on the other)
        # fits both media, which is what makes the evenness check below the
        # assertion that catches a builder that fills the first medium first.
        capacity = 15000
        report = fontdisk.build_set(set_dir, data_dir, True, True, capacity, 2)
        expect("the set was split over the number of media asked for",
               report["disks"] == 2, report["disks"])
        expect("each medium is inside the capacity it was fitted to",
               all(part["spare"] >= 0 for part in report["parts"]),
               [(part["part"], part["bytes"], part["spare"])
                for part in report["parts"]])
        expect("and the total is the sum of the media, not of a directory walk",
               report["bytes"] == sum(part["bytes"] for part in report["parts"]),
               "%s vs %s" % (report["bytes"],
                             sum(part["bytes"] for part in report["parts"])))

        # THE PARTITION, read back out of the media that were written.
        per_part, on_medium = {}, {}
        for part in report["parts"]:
            fonts_dir = os.path.join(part["out"], fontdisk.FONTS_DIR)
            _header, _shape, part_entries = fontdisk.read_index(
                os.path.join(fonts_dir, "shs8" + fontdisk.INDEX_SUFFIX))
            per_part[part["part"]] = part_entries
            ids = set()
            for name in os.listdir(fonts_dir):
                shard = fontdisk.shard_id_of(name, "shs8")
                if shard is not None:
                    ids.add(shard)
            on_medium[part["part"]] = ids
        over_parts = [cp for entries in per_part.values() for cp, _s in entries]
        expect("every codepoint of the set is on exactly one medium",
               sorted(over_parts) == sorted(cps) and
               len(over_parts) == len(set(over_parts)),
               "%d codepoint(s) over the parts vs %d in the set"
               % (len(over_parts), len(cps)))
        # EVENLY, and not "the first medium takes what it can hold". The four
        # shards here are the same size, so an even split is a known answer: two
        # shards and 120 glyphs each. A tool that filled the first medium first
        # would answer 180 and 60 and still fit both, which is why this is not a
        # size check.
        expect("the shards are dealt out evenly over the media",
               [part["glyphs"] for part in report["parts"]] == [per * 2, per * 2],
               [part["glyphs"] for part in report["parts"]])
        # THE PER-DISK INDEX. This is the assertion that a part's index does not
        # claim a shard that is not on that medium -- the media's own files are
        # the authority, not the report.
        claims = dict((number, sorted(set(s for _cp, s in entries)))
                      for number, entries in per_part.items())
        expect("each part's index names only the shards on that medium",
               all(set(claims[number]) <= on_medium[number] for number in per_part),
               "; ".join("part%d claims %s, has %s"
                         % (number, claims[number], sorted(on_medium[number]))
                         for number in sorted(per_part)))
        expect("and no shard is on two media or on none",
               sorted(s for ids in on_medium.values() for s in ids) == list(range(shards)),
               sorted(s for ids in on_medium.values() for s in ids))
        # THE MANIFEST is what the machine believes about which part it is holding.
        for part in report["parts"]:
            text = open(os.path.join(part["out"], fontdisk.FONTS_DIR,
                                     "shs8" + fontdisk.MANIFEST_SUFFIX),
                        encoding="ascii").read()
            fields = fontdisk.manifest_fields(text)
            expect("part %d's manifest names shs8 part %d of 2"
                   % (part["part"], part["part"]),
                   fields is not None and fields["name"] == "shs8" and
                   fields["part"] == part["part"] and fields["parts"] == 2, fields)
            expect("part %d's manifest lists the shards that are on it"
                   % part["part"],
                   fields is not None and
                   set(claims[part["part"]]) == on_medium[part["part"]],
                   "%s vs %s" % (claims[part["part"]], sorted(on_medium[part["part"]])))
            # THE WHOLE PLAN is on EVERY part, not only on the first: a machine
            # holding only part 2 has to be able to name part 1, and part 1's
            # manifest is not in that machine to be read.
            expect("part %d's manifest carries the whole plan of the set"
                   % part["part"],
                   text.count("{part=") == 2, text.count("{part="))
            # A probe character per medium: what an acceptance run draws to prove
            # that a glyph on medium A and one on medium B both render.
            expect("part %d has a probe character in its own index" % part["part"],
                   any(cp == part["sample"] for cp, _s in per_part[part["part"]]),
                   "U+%04X" % part["sample"] if part["sample"] else "none")
        expect("the two probe characters are on different media",
               report["parts"][0]["sample"] != report["parts"][1]["sample"],
               "%s vs %s" % (report["parts"][0]["sample"],
                             report["parts"][1]["sample"]))
        expect("the set directory says how to mount the parts",
               os.path.isfile(os.path.join(set_dir, fontdisk.SET_NOTES)))

        # A set that does not fit the number of media asked for is refused, with
        # the measurement in the message: the alternative is a medium an operator
        # builds and cannot use.
        try:
            fontdisk.build_set(os.path.join(scratch, "toosmall"), data_dir, True,
                               True, capacity, 1)
            expect("a set that does not fit the media asked for is refused", False,
                   "the build succeeded")
        except fontdisk.FontdiskError as exc:
            expect("a set that does not fit the media asked for is refused",
                   "does not fit 1 medium" in str(exc), str(exc))

        # A medium over its stated capacity is refused AND NOT WRITTEN.
        over = os.path.join(scratch, "over")
        try:
            fontdisk.build(over, data_dir, True, True, 3000)
            expect("a medium over its stated capacity is refused", False,
                   "the medium was written")
        except fontdisk.FontdiskError as exc:
            expect("a medium over its stated capacity is refused",
                   "does not fit" in str(exc), str(exc))
        expect("and nothing was left in its place", not os.path.exists(over))
        expect("and no half-built directory was left beside it",
               not os.path.exists(over + ".staged"))

        # The control on the other side: the same set IS built when the capacity
        # says it fits, so the two refusals above are not passing because this
        # tool refuses everything.
        fits = fontdisk.build(os.path.join(scratch, "fits"), data_dir, True, True,
                              20000)
        expect("the same set is built when the capacity allows it", fits["ok"])
        expect("and a set that fits one medium is one part, with a manifest "
               "that says so",
               fits["parts"] == 1 and fits["part"] == 1,
               "%s of %s" % (fits["part"], fits["parts"]))
    except Exception as exc:
        print("  fonttools: the set builder could not run: %s" % exc)
        problems += 1
    finally:
        shutil.rmtree(scratch, ignore_errors=True)

    # ---- deploy.py keeps the glyphs off a machine ------------------------
    # THE POINT OF THE WHOLE DESIGN. If fontdata/ is deployable, "--part base"
    # puts about 1 MB of glyphs on a computer with a 1,000,000 B filesystem --
    # the overflow the separate medium exists to avoid -- and nothing else in
    # this project would notice.
    if deploy is None:
        print("  fonttools: tools/deploy.py is not importable, so the glyphs' "
              "absence from a machine cannot be checked")
        problems += 1
    else:
        opts = deploy.Options()
        for rel in ("fontdata/shs12_index.lua", "fontdata/shs12_shard0.lua"):
            expect("deploy.py refuses to copy %s" % rel,
                   not deploy.wanted(rel, opts))
        # And a control: a real module IS wanted, so the check above is not
        # passing because wanted() answers False for everything.
        expect("deploy.py still wants a real module",
               deploy.wanted("lib/cc_chinese.lua", opts))

    if not quiet:
        print("gate 9: font tools, problems: %d" % problems)
    return problems


def gate_deploy(quiet):
    """Differential deploy self test in a scratch directory."""
    script = os.path.join(REPO, "tools", "deploy.py")
    if not os.path.isfile(script):
        print("  MISSING tools/deploy.py")
        return 1
    scratch = tempfile.mkdtemp(prefix="psh_deploy_selftest_")
    problems = 0
    try:
        def run(extra=None):
            cmd = [sys.executable, script, "--target", scratch, "--json"] + (extra or [])
            out = subprocess.run(cmd, capture_output=True, text=True)
            if out.returncode != 0:
                print("  deploy.py failed: %s" % (out.stderr or out.stdout))
                return None
            start = out.stdout.index("{")
            return json.loads(out.stdout[start:])

        first = run()
        second = run()
        if first is None or second is None:
            return 1
        if not first["added"] and not first["updated"]:
            print("  first run copied nothing")
            problems += 1
        if second["added"] or second["updated"]:
            print("  second run was not a no-op: +%d ~%d"
                  % (len(second["added"]), len(second["updated"])))
            problems += 1
        victim = os.path.join(scratch, "usr", "psh.lua")
        if os.path.isfile(victim):
            os.remove(victim)
            third = run()
            if third is None or not third["added"]:
                print("  a deleted target file was not restored")
                problems += 1
        else:
            print("  scratch copy has no usr/psh.lua")
            problems += 1

        # ---- --part: the two halves of a two-part install -------------------
        # A 1 MB computer cannot hold the whole tree, so deploy.py can write either
        # half. The two properties that matter are that the halves do not overlap
        # (or a file would be written twice and the sizes would be wrong) and that
        # together they are exactly the whole tree (or a file would go missing from
        # both, and the machine would not boot).
        base_dir = tempfile.mkdtemp(prefix="psh_part_base_")
        mod_dir = tempfile.mkdtemp(prefix="psh_part_mod_")
        whole_dir = tempfile.mkdtemp(prefix="psh_part_whole_")
        try:
            def run_part(target, part=None):
                cmd = [sys.executable, script, "--target", target, "--json"]
                if part:
                    cmd += ["--part", part]
                out = subprocess.run(cmd, capture_output=True, text=True)
                if out.returncode != 0:
                    print("  deploy.py --part %s failed: %s"
                          % (part, out.stderr or out.stdout))
                    return None
                return json.loads(out.stdout[out.stdout.index("{"):])

            def names(report):
                return set(report["added"]) | set(report["updated"])

            rb = run_part(base_dir, "base")
            rm = run_part(mod_dir, "modules")
            # A FRESH directory for the whole tree: reusing `scratch` would report only
            # what that run changed, and the earlier runs already pruned files from it.
            ra = run_part(whole_dir)
            if rb is None or rm is None or ra is None:
                return 1
            base, mods, whole = names(rb), names(rm), names(ra)
            both = base & mods
            if both:
                print("  the two parts overlap: %s" % sorted(both)[:5])
                problems += 1
            if base | mods != whole:
                missing = sorted(whole - (base | mods))
                extra = sorted((base | mods) - whole)
                print("  the two parts are not the whole tree: missing %s extra %s"
                      % (missing[:5], extra[:5]))
                problems += 1

            # PROSE MUST NOT DECIDE THE SPLIT.
            #
            # The halves are chosen by the load-time closure, which is built from
            # _requires. That used to match the RAW source, and to decide
            # "top level" from the indentation of the line the match sat on -- so a
            # require() merely NAMED IN A COMMENT counted, and a comment at column 0
            # counted as load time. Measured cost: writing the sentence
            # `local man = require("man")` inside a comment in lib/complete.lua put
            # lib/man.lua -- 76,549 B of manual pages -- into the base half, i.e.
            # onto a 1 MB computer's disk, and this gate still reported
            # `problems 0`. The project is comment-heavy by house style, so the
            # trap was easy to walk into and invisible afterwards.
            #
            # deploy.py strips comments before scanning. This checks that it does,
            # on a file written for the purpose, so the property cannot be lost by
            # a later edit to the scanner.
            import importlib.util
            probe_spec = importlib.util.spec_from_file_location("_deploy_probe", script)
            probe = importlib.util.module_from_spec(probe_spec)
            probe_spec.loader.exec_module(probe)
            probe_dir = tempfile.mkdtemp(prefix="psh_deploy_comment_")
            try:
                sample = os.path.join(probe_dir, "sample.lua")
                with open(sample, "w", encoding="utf-8") as fh:
                    fh.write('-- prose at column 0: require("comment_only")\n'
                             '--[[ a block comment naming require("block_only") ]]\n'
                             'local real = require("real_module")\n'
                             'local s = "a string naming require(\'in_a_string\')"\n')
                found = dict(probe._requires(sample))
                for ghost in ("comment_only", "block_only", "in_a_string"):
                    if ghost in found:
                        print("  %s was counted as a require (it is only text)"
                              % ghost)
                        problems += 1
                if not found.get("real_module"):
                    print("  a real top-level require was not reported as top level")
                    problems += 1
                with open(sample, "r", encoding="utf-8") as fh:
                    text = fh.read()
                if len(probe._strip_comments(text)) != len(text):
                    print("  stripping comments changed the source length")
                    problems += 1
            finally:
                shutil.rmtree(probe_dir, ignore_errors=True)

            # The entry points and the module the boot path requires must be in base.
            # This list is not decoration: a module required at boot that landed in
            # the modules half would be on the medium, and the machine would not
            # start. lib/bios.lua and lib/interrupt.lua were exactly that bug --
            # they are required from startup.lua and from shell_init(), and the
            # closure only counted column-0 requires until BOOT_FUNCTIONS was added.
            #
            # lib/sha256.lua is pinned for a DIFFERENT reason, which is worth saying
            # because the failure it prevents is silent. It is not needed to boot;
            # it is needed to hash a password the SAME WAY every time. It sat in the
            # modules half at first, so the stored hash depended on whether the
            # medium was inserted -- alice:0fbcae8a2053... with it, alice:1265856734
            # without, and check_password returned false. A password set with the
            # medium in place could not be verified without it, which on a two-part
            # install locks the operator out of their own machine. lib/perm.lua and
            # lib/bios.lua require it at column 0 so the closure puts it here.
            # lib/space.lua is pinned for a THIRD reason, and it is the same shape of
            # failure as sha256's: a machine whose system module store (part 2) is
            # not inserted must still be able to REFUSE a write it has no room for.
            # If the module sat on the medium, `echo x > f` on such a machine would
            # raise "module not found" instead of failing the write -- and the
            # machine with the least room is exactly the one that misses it.
            #
            # The two SECURITY modules are pinned for the sharpest reason in this
            # list: without them the machine still boots and still runs commands, it
            # just stops REFUSING. Measured on a machine deployed with --part base
            # only (no system module medium inserted):
            #   * lib/danger.lua on the medium left `rm -rf /` unrefused --
            #     run_stage's indented require("danger") raised "module not found"
            #     instead of answering with the blacklist's reason;
            #   * lib/osguard.lua on the medium made startup.lua's
            #     pcall(require, "osguard") fail silently, so a program could
            #     fs.open("/usr/psh.lua", "a"): the permission model was gone from
            #     the program layer while the shell's own checks still ran.
            # Both are required at column 0 now (startup.lua and usr/psh.lua), which
            # is what the load-time closure reads. They must not ALSO be on the
            # medium -- a file in both halves would be written twice, and the second
            # copy could be the older one.
            #
            # Beyond all of the above, three modules are pinned for the reason that
            # takes a machine furthest down: WITHOUT THE MEDIUM IT MUST STILL BOOT
            # TO A PROMPT AND FINISH FIRST SETUP. Two things broke exactly that,
            # both of them asked for in a place the split could not see:
            #   * lib/sessionlog.lua was required with an INDENTED require inside
            #     the function that starts the interactive session. Login is the
            #     last step before the prompt, so on a machine deployed with
            #     --part base only the session opened its ledger file and died:
            #     `/usr/psh.lua:8574: module 'sessionlog' not found`, once per
            #     turn of the loop, and there was never a prompt. usr/psh.lua now
            #     requires it at column 0.
            #   * lib/policy.lua and lib/time.lua are required at column 0 by
            #     firstboot.lua -- and firstboot.lua was not in deploy.py's
            #     ENTRY_POINTS, so the split ignored every require it makes. On a
            #     fresh base-only machine the settings wizard died with
            #     `/firstboot.lua:19: module 'policy' not found` 385 times in 15
            #     seconds and the setup marker was never written. firstboot.lua is
            #     an entry point now (it runs at boot, between startup.lua and the
            #     shell), which is what pulls these two onto the computer.
            # The three are pinned together because they share one acceptance
            # criterion: a machine with no medium inserted must boot to a prompt
            # AND complete first setup.
            bootable = ("lib/sessionlog.lua", "lib/policy.lua", "lib/time.lua")
            security = ("lib/danger.lua", "lib/osguard.lua")
            # lib/boot.lua is pinned for the reason a SILENTLY degraded feature
            # names. It is reached only as pcall(require, "boot") -- from cron's
            # @reboot pass (lib/cron.lua:531, `local first = ok and b and
            # b.begin(REBOOT_MARKER)`) and from the services runner's once-per-boot
            # check (lib/services.lua:70) -- and that pcall is what keeps the
            # require invisible to the split's scanner. Measured on a machine
            # deployed with --part base only, lib/boot.lua on the medium:
            #   * no @reboot crontab entry fired at all: `first` was false, so the
            #     whole specials loop was skipped and the job's output file never
            #     appeared;
            #   * services.started_same_boot returned true for any existing
            #     .started file, so an rc.d unit ran on the first boot and never
            #     again -- "already started in this boot" for ever.
            # Both are features the machine simply stops having, which is why the
            # pin is here and not only in the source: tools/deploy.py's BOOT_EXTRA
            # is what puts it in this half.
            boot_features = ("lib/boot.lua",)
            # lib/lang.lua is pinned for a reason of its own: it is not needed to
            # boot, it is needed to SAY WHAT THE MACHINE CANNOT DO. The lang
            # built-in and the console writer both live in the session, so a
            # machine without the system module medium must still be able to
            # report "zh is unavailable because the glyph medium is not inserted"
            # rather than answer "module 'lang' not found". The Chinese sentences
            # themselves cost nothing here: the file is ASCII, the CJK is written
            # as UTF-8 byte escapes, and the glyphs are on their own medium.
            interface = ("lib/lang.lua",)
            for rel in ("startup.lua", "usr/psh.lua", "lib/mounts.lua", "lib/marker.lua",
                        "lib/perm.lua", "lib/protect.lua", "lib/bios.lua",
                        "lib/interrupt.lua", "lib/path.lua", "lib/sha256.lua",
                        "lib/bitops.lua", "lib/space.lua") + bootable + security \
                    + boot_features + interface:
                if rel not in base:
                    print("  %s is not in the base part" % rel)
                    problems += 1
            # The negative half: the security modules are base ONLY. Without this
            # the pin above would still pass if the module were duplicated, and a
            # duplicated module means the machine may load the medium's copy.
            for rel in security:
                if rel in mods:
                    print("  %s is in the modules part as well" % rel)
                    problems += 1
            # pkg is reached lazily, so it belongs on the medium -- the correction to
            # an earlier claim that it had to stay on the computer (ROADMAP 6.7).
            if "lib/pkg.lua" not in mods:
                print("  lib/pkg.lua is not in the modules part")
                problems += 1
        finally:
            shutil.rmtree(base_dir, ignore_errors=True)
            shutil.rmtree(mod_dir, ignore_errors=True)
            shutil.rmtree(whole_dir, ignore_errors=True)

        if not quiet:
            print("gate 5: deploy self test, first +%d ~%d, second +%d ~%d, "
                  "part base %d / modules %d, problems %d"
                  % (len(first["added"]), len(first["updated"]),
                     len(second["added"]), len(second["updated"]),
                     len(base), len(mods), problems))
    finally:
        shutil.rmtree(scratch, ignore_errors=True)
    return problems


# -------------------------------------------------------------------- suites
def run_suite(LuaRuntime, name, script, boot, verbose):
    lua = new_state(LuaRuntime, boot)
    res = lua.execute("local ok, err = pcall(dofile, TESTS .. '/%s'); return ok, err" % script)
    ok, err = res[0], res[1]
    if not ok:
        return False, 0, 0, "raised an error: %s" % err
    try:
        raw = lua.eval(
            "tostring(__RESULT and __RESULT.pass or 0) .. '|' .. "
            "tostring(__RESULT and __RESULT.fail or 1) .. '|' .. "
            "tostring(__RESULT and __RESULT.report or '')"
        )
    except Exception as exc:
        return False, 0, 1, "reading __RESULT failed: %s" % exc
    parts = str(raw).split("|", 2)
    while len(parts) < 3:
        parts.append("")
    passed, failed, report = int(parts[0]), int(parts[1]), parts[2]
    return failed == 0, passed, failed, report


def main(argv):
    # Two suites (batch3, batch8) build the vendored rpv stack with
    # loadfile("rpv/<module>.lua"), i.e. a path relative to the PROCESS working
    # directory and not to this file. Run from anywhere else -- `python
    # pyromputer-os/tests/run_all.py` from the repository root, a CI step, a
    # debugger -- and those loadfile() calls return nil, the stack is empty and
    # the suites fail for a reason that has nothing to do with the code. The
    # runner therefore owns the working directory: every gate and suite below
    # resolves project relative paths against REPO.
    os.chdir(REPO)
    opts = parse_args(argv)
    if opts["list"]:
        print("suites: " + ", ".join(n for n, _, _ in SUITES))
        print("gates:  1 syntax, 2 ascii, 3 docs, 4 man coverage, 5 deploy self test, "
              "6 configuration keys, 7 roadmap sync, 8 acceptance report self test, "
              "9 font tools")
        return 0

    runtimes = load_lupa()
    print("repo:    %s" % REPO)
    print("runtimes: %s" % ", ".join(n for n, _ in runtimes))
    primary = runtimes[0][1]

    problems = 0
    if opts["gates"]:
        problems += gate_syntax(runtimes, False)
        if DEPLOY_IMPORT_ERROR is not None:
            print("gate 2: cannot ask tools/deploy.py what a machine gets: %s"
                  % DEPLOY_IMPORT_ERROR)
            problems += 1
        problems += gate_ascii(False)
        problems += gate_docs(False)
        problems += gate_man(primary, False)
        problems += gate_deploy(False)
        problems += gate_config(False)
        problems += gate_roadmap(False)
        problems += gate_log_summary(False)
        problems += gate_fonttools(False)

    selected = SUITES
    if opts["suites"]:
        want = set(opts["suites"])
        selected = [s for s in SUITES if s[0] in want]
        unknown = want - {s[0] for s in SUITES}
        if unknown:
            raise SystemExit("unknown suite: %s" % ", ".join(sorted(unknown)))

    failed_suites = []
    for name, script, boot in selected:
        ok, passed, failed, report = run_suite(primary, name, script, boot, opts["verbose"])
        print("suite %-7s pass %-4d fail %-4d" % (name, passed, failed))
        if not ok:
            failed_suites.append(name)
            problems += max(failed, 1)
            if report:
                print(report)

    if opts["gates"] and opts["deploy"]:
        problems += gate_deploy(False)

    print("")
    if problems == 0:
        print("ALL GREEN (gates + %d suite(s))" % len(selected))
    else:
        print("FAILED: %d problem(s), suites: %s"
              % (problems, ", ".join(failed_suites) or "none"))
    print("reminder: everything above is a PC side result, not a CraftOS-PC result")
    return 0 if problems == 0 else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
