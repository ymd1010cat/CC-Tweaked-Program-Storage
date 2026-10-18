#!/usr/bin/env python3
"""log_summary.py - report an acceptance log by pattern, not by tail.

Why this exists
---------------
The Minecraft acceptance used to print the last ten matching lines of each machine
log. On a busy run that hides the beginning of a sequence: a request that failed
three times in a row and then got through was reported as a single failure, because
the earlier attempts had already scrolled out of the window. The question a reader
actually has is "what happened, and how often", and a tail answers it only when the
log is short.

So this prints, per machine:

  * how many lines the log holds and how many matched the pattern;
  * the matched lines GROUPED, with a count for each, so a repeat is impossible to
    miss -- and with the timestamps of every occurrence, so the ORDER is kept too
    (grouping alone would lose it, which is what made the original failure read as
    one event);
  * the first and last matched line, so the window is visible;
  * the verdict lines verbatim, always, whatever the pattern says.

Usage
-----
    log_summary.py <logfile> [--title TITLE] [--pattern RE]... [--max-groups N]

The default pattern is the acceptance vocabulary of the file transfer runs. A
missing or empty log is reported as such rather than as silence, because "the file
is not there" and "the file has nothing to say" are different problems.
"""

import argparse
import re
import sys

# The default vocabulary: what a file transfer run says about itself. Kept in one
# place so the bash and PowerShell scripts report the same things.
#
# Matching is CASE INSENSITIVE on purpose, and that is not a nicety: the Minecraft
# driver and the CraftOS-PC driver log the same events in different cases. The MC
# driver writes "REQUEST op=nil from=21" / "PEER_VERDICT FAIL"; the emulator driver
# writes "request op=get from=21" / "server verdict PASS". A pattern tuned to one of
# them matches almost nothing in the other, which is how a summariser can quietly
# become worse than the tail it replaced -- measured: an uppercase pattern matched 2
# of 249 lines in a real emulator log.
DEFAULT_PATTERN = (r"boot|backend|payload|hello|request|served|pushed|pulled|"
                   r"rget|rput|marker|verdict|rotated|transport=|unsupported|"
                   r"stalled|missing chunk|malformed|serving|trace")

# Never folded into a group, never omitted: the answer to "did it work".
VERDICT_RE = re.compile(r"verdict|RESULT", re.IGNORECASE)


def strip_prefix(line):
    """Drop the leading clock so equal events group together."""
    return re.sub(r"^\s*\d+(\.\d+)?\s+", "", line)


def normalise(line):
    """Replace the varying parts (numbers, hex) so repeats become one group."""
    text = strip_prefix(line)
    text = re.sub(r"0x[0-9a-fA-F]+", "0x#", text)
    text = re.sub(r"\d+", "#", text)
    return text.rstrip()


def stamp(line):
    """The leading clock of a line, or None."""
    m = re.match(r"^\s*(\d+(?:\.\d+)?)\s", line)
    return m.group(1) if m else None


def main(argv):
    ap = argparse.ArgumentParser(description="summarise an acceptance log by pattern")
    ap.add_argument("logfile")
    ap.add_argument("--title", default=None)
    ap.add_argument("--pattern", action="append", default=None,
                    help="regex a line has to match (repeatable; default: the transfer vocabulary)")
    ap.add_argument("--max-groups", type=int, default=25,
                    help="how many groups to print before saying 'and N more'")
    opts = ap.parse_args(argv)

    title = opts.title or opts.logfile
    patterns = opts.pattern or [DEFAULT_PATTERN]
    try:
        matcher = re.compile("|".join("(?:%s)" % p for p in patterns), re.IGNORECASE)
    except re.error as exc:
        print("log_summary: bad pattern: %s" % exc)
        return 2

    try:
        with open(opts.logfile, "r", encoding="utf-8", errors="replace") as fh:
            lines = fh.read().splitlines()
    except OSError:
        print("----- %s -----" % title)
        print("  (no log: the file is not there)")
        return 0

    if not lines:
        print("----- %s -----" % title)
        print("  (the log is empty)")
        return 0

    matched = [ln for ln in lines if matcher.search(ln)]
    verdicts = [ln for ln in lines if VERDICT_RE.search(ln)]

    print("----- %s (%d line(s), %d matched) -----" % (title, len(lines), len(matched)))
    if not matched:
        print("  (nothing matched the pattern: %s)" % "|".join(patterns))
    else:
        groups = {}
        order = []
        for ln in matched:
            key = normalise(ln)
            if key not in groups:
                groups[key] = []
                order.append(key)
            groups[key].append(ln)
        # most repeated first, then by first appearance: a repeat is the thing a
        # reader needs to see, and a stable order keeps two runs comparable
        ranked = sorted(order, key=lambda k: (-len(groups[k]), order.index(k)))
        repeats = [k for k in ranked if len(groups[k]) > 1]
        singles = [k for k in ranked if len(groups[k]) == 1]

        if repeats:
            print("  repeated (this is what a tail hides):")
            for key in repeats:
                items = groups[key]
                times = [t for t in (stamp(i) for i in items) if t]
                when = ("  at " + ", ".join(times)) if times else ""
                print("    %3dx  %s%s" % (len(items), key, when))
        if singles:
            shown = singles[:max(0, opts.max_groups - len(repeats))]
            print("  once:")
            for key in shown:
                print("     1x  %s" % key)
            rest = len(singles) - len(shown)
            if rest > 0:
                print("    ... and %d more distinct line(s)" % rest)

        print("  first: %s" % matched[0].strip())
        print("  last:  %s" % matched[-1].strip())

    # The verdict is never left to the pattern: it is the answer, not a detail.
    if verdicts:
        print("  verdict:")
        for ln in verdicts:
            print("    %s" % ln.strip())
    else:
        print("  verdict: (none recorded: the run did not reach a verdict)")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
