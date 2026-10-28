# psh roadmap

What is planned, what is being worked on, and what is known to be broken. It is written for
whoever picks the project up next: every item says what the state is, how it was measured, and
where the evidence lives. `HANDOFF-rpv.md` is the session handoff; this file is the longer view.

Gates: `tests/run_all.py` runs 8 gates plus 8 suites over six Lua runtimes. Everything below
assumes `ALL GREEN` before a change and after it. This file and `ROADMAP.zh.md` are one document
in two languages: gate 7 fails if they drift apart, so a section added here has to be added there.

---

## 1. rpv file transfer on real hardware

The transport works and a 200 KB file moves **both ways**: the run after the request retry landed
recorded `PUSHED 200000 bytes crc=6f5477e4 same=true` and `PEER_VERDICT PASS` on the peer, with
the client's trace showing `all 49 chunks acknowledged` and `result ok=true`. The control-message
reliability that made every transfer a gamble (1.2) is fixed; the harness story is closed too
(1.3), and so is one defect the network half hid until answers were paired with their requests
(1.4). What remains is the hardware confirmation.

### 1.1 Fixed: a request that arrives mid-transfer was dropped

* **State**: fixed and measured.
* **Cause**: `xfer.serve` runs to completion inside the peer's receive loop, so a request that
  arrives while another transfer is being served was never read. On hardware a push request
  landed in exactly that window and the client waited out its request timeout.
* **Fix**: the waiting loops queue requests seen while waiting for something else
  (`opts.stash`, set by `xfer.serve`), and `xfer.serve_pending(opts)` drains the queue; `netd.lua`
  and the acceptance peer call it after every request.
* **Evidence**: after the fix a hardware run showed the pull finishing at 17 s and the push
  request going out at 17.55 s -- no overlap at all, where before they overlapped.
* **Narrower than it read**: `wait_message` used to accept only messages whose sender was
  `opts.peer`, so while the peer served client A, a request from client B was filtered out before
  the stash branch and still lost. That is fixed too (the stash now takes a request from any
  sender; only the ANSWER is restricted to the peer being served), and `tests/batch8_check.lua`
  covers it.

### 1.2 Fixed: the push no longer waits for a `ready` that can be lost

* **State**: fixed, and now reproducible and verified **off the hardware**, in `tests/batch8`.
* **What it was**: the peer's `ready` was a small control message with no checksum and no
  retransmission. When it went missing, a push paid exactly one request timeout and failed --
  `put request sent (attempt 1/2)`, no answer, `put request sent (attempt 2/2)`, no answer -- while
  a pull survived only because `rget` re-runs the whole command. The same loss in another shape
  arrived as `action` intact with `op` missing (`unsupported operation: nil`), three in a row in
  one run, matching three `rget` attempts.
* **The fix removes the round trip instead of retrying it.** The push now sends its request and
  block 1 back to back (`open_push`), and the answer to that BLOCK -- which the chunk layer already
  protects with CRC32 plus ack/missing -- is the acceptance. A message whose loss is detected and
  repaired replaces one whose loss is silent. An empty file has no block to open with and keeps the
  old request/`ready` shape, so `ready` stays conclusive for it.
* **The three conditions, all in place** (a previous attempt got each wrong and was reverted):
  1. the queue ignores anything that is not a request -- and a block is not dropped either:
     `stash_block` buffers it per sender, and `xfer.serve` returns `"buffered"` instead of
     answering `unsupported operation: nil`;
  2. the receiver accepts a block that arrives early -- `stream_receive` installs the buffer
     before it waits for anything, and acks it the normal way;
  3. the requester does not send block 1 twice -- `stream_send` takes the opener's answer as
     `opts.opener` and skips its own send for that sequence.
* **One more thing the earlier attempt never reached**: the loop below the send/wait pair is
  untouched, because the restructure of that loop (not the missing `ready`) is what regressed the
  pull last time. The only change inside it is that the wait now matches an ack for *this* block
  rather than any ack -- a burst of replies to a hole list used to leave stale acks in the mailbox,
  which the sender then read as "no answer" and spent its retry budget on
  (`tests/batch3_check.lua` caught exactly that, and it is why the hole-list run is in the suite).
* **Evidence**: `tests/batch8_check.lua` -- "a lost ready no longer stops a push": the peer's
  `ready` is held for 30 s, far past both request attempts, and the push still completes with
  block 1 on the wire exactly once. "an opener that outruns its request, against a real netd" drives
  two overlapping pushes through the real daemon and asserts both land and that no block is ever
  answered with `unsupported operation`. Both are deterministic and need no Minecraft.
* **Not yet done**: a Minecraft run. The confirmation below is CraftOS-PC, whose wireless link is
  emulated inside one process; Minecraft is the only place a real modem link is exercised.
  `tools/rpv-verify/ps1/_psh-mc-file.ps1` is the script (it needs the server's
  `computer_space_limit` raised and a restart), and its trace prints the same opening. Nothing in
  the change is specific to the emulator, so this is the last word rather than an open risk.
* **Confirmed on a real CraftOS runtime, and the confirmation is unusually good.**
  `tools/rpv-verify/_psh-rpv-file.sh` (CraftOS-PC 2.8.3, `transport=rpv`, 200 KB, 49 chunks, real
  IP fragmentation) was re-run on this tree, with `xfer.trace` now installed by the script so the
  conversation can be read branch by branch. Both verdicts are PASS -- `CLIENT_VERDICT PASS` /
  `SERVER_VERDICT PASS`, `pushed size=200000 crc=4c790f2d same_as_source=true` -- and **the same
  run caught the very `ready` loss this section is about**:

  ```
  pull   2.68 get request sent (attempt 1/2)
         7.71 get answer: none (attempt 1/2)          <- the ready WAS lost
         8.22 get request sent (attempt 2/2)
         8.42 get answer: ready (attempt 2/2)         <- the retry survived it
        25.64 rget attempts=1 exit=0 in 23.5s
  push  25.86 put request sent (attempt 1/2) with block 1/49
        26.27 put answer: ack reason=nil (attempt 1/2) <- the BLOCK's answer, first try
        26.27 chunk 1/49 was sent with the request; answer=ack
        44.39 rput attempts=1 exit=0 in 18.7s
  ```

  So the loss is still real on a real runtime -- the pull lost its `ready` and only its request
  retry saved it -- while the push, which no longer waits for that message, opened on the first
  attempt. The fix doing exactly what it was designed to do, measured rather than argued.
* **Backward compatible**: a new client still understands `ready` (it just does not wait for it),
  and a peer that answers block 1 with `ready` first is handled -- the wait continues until the
  block's own answer arrives. An old client against a new peer is unaffected, because the peer's
  `ready` is still sent.

### 1.3 Fixed: the PC suite could not reach the network half -- it can

* **State**: fixed. The two claims that kept this open were re-measured and one was wrong.
* **Claim 1, false**: "H.delay/H.drop match on the decoded message, which the suite's peer never
  sees for its own reply." `rednet.send` is handed the packed blob, so a predicate can match the
  peer's OWN reply on `(from, target, decoded t)`. `tests/net_harness.lua` now records every
  datagram in `H.wire` with its direction and decoded body, and exposes `H.wire_matching`,
  `H.by_t`, `H.by_msg` so an assertion can name the datagram it held.
* **Claim 2, half true**: "`xfer.serve_pending` cannot be driven from the test body." Called
  straight from the body it dies -- `attempt to yield from outside a coroutine`, because a test
  body is not one -- but spawned as a harness task it works. That is what `H.pump` names, and
  `H.run_until_blocked` gets a requester to the point where its request is on the wire and it is
  waiting for the answer. No new pump was needed: `H.spawn` + `H.run` already were one.
* **Also fixed while here**: `H.delay(pred)` took its duration ONLY as a second argument, so every
  existing call that returned `1.5`/`2.5` was silently held for the 1 s default. The tests passed
  either way (a hole opened is a hole opened), which is why it went unnoticed. The wrapper now reads
  the second argument explicitly and says so.
* **Consequence**: the end-to-end half of 1.1, the retry path, and the 1.2 regression are all
  verified in the suite now. `tests/batch8_check.lua` went from 45 assertions to 87.

### 1.4 Fixed: a rexec answer belonged to whoever asked last

* **State**: fixed on the machine's own network layer; `lib/rexec.lua` is the only file that
  changed, and the fix is pinned by 16 assertions in `tests/batch3_check.lua`.
* **Cause**: `rexec.run` accepted any message from the target whose `action` was `rexec` and
  whose `t` was `result`, so a result that outlived its own request (the requester had given up
  and moved on) was read as the answer to the NEXT request to that peer: `rexec -t 2 -q echo
  two` printed the output of the earlier `echo one`. It is the same class of defect the package
  manager had (a request id, an echo, and a waiter that ignores what is not its own answer);
  `lib/pkg.lua` does it with an id (the licence client that used a nonce is gone,
  see section 7).
* **Fix**: the request carries `id = "<computerID>-<seq>"`; `reply()` echoes it on EVERY answer
  -- empty command, denied command, success -- because a refusal is an answer too; `rexec.run`
  accepts a result only when `answers(msg, id)`, and a message that is not this request's is
  ignored while the wait goes on under the ONE deadline set before the first receive. A stray
  must not restart the budget, or a channel that keeps producing strays would keep the call
  alive for as long as they keep coming (a mutant that did exactly that is one of the six the
  suite now kills).
* **Compatibility**: a peer that predates ids echoes none, and an id-less result is still
  accepted -- that is what keeps an old daemon working. The limit it leaves is stated in the
  comment at `answers()` and pinned by two assertions of its own: with an id-less peer, two
  requests waiting at the same time cannot be told apart, because nothing on the answer names
  the request it belongs to.
* **Evidence**: `tests/batch3_check.lua`, section "rexec: an answer belongs to the request that
  asked for it" (16 assertions: a stale result carrying the previous request's id `5-1`, a
  result with a foreign id, the id on the wire plus the peer's echo of it, a peer that echoes
  no id, a stale REFUSAL, a refusal that carries the id, the empty-command refusal, a stream of
  three strays arriving at 0.3 / 0.6 / 0.9 s of a 1 s wait ending in a TIMEOUT, and "the stale
  answers did not extend the deadline" measured as exactly 1000 ms). RED before the fix:
  `suite batch3 pass 468 fail 11`, whose first line is the defect itself (the stale
  `STALE-ANSWER-FROM-AN-EARLIER-REQUEST` returned as the answer to `echo fresh-answer`).
  Mutation tested -- 6 of 6 caught: accept the first result regardless of id; do not echo the
  id; give up on the first mismatch instead of waiting; check the id only on the successful
  path so a stale refusal gets through; treat an id-less reply as a mismatch (which breaks old
  peers); restart the deadline after every stray. batch3: 447 -> 463 (the package fetch work in
  section 2) -> 479 (this section).
* **Also recorded, not fixed**: `tests/net_harness.lua` gives the rexec client and the package
  server the same computer id (5), so one mailbox serves both; a rexec task that never
  terminates can therefore eat package requests. That is a coupling of the test rig, not of the
  product, and it is written here rather than papered over.

---

## 2. Package management on removable media

* **State**: done and accepted, and now **two kinds of store**. A medium is a package store
  iff it carries a marker file; markers are the only record, no drive letters are stored
  anywhere.
* **Two markers, because there are two kinds of store.** A machine built in two parts -- the
  shell on its own disk, its own modules on a medium -- has to tell those modules apart from
  ordinary extra packages, because one is part of the installation and the other is not:
  * `.pkgsys` -- the **system module store**: the modules the shell itself needs (the manual
    pages, the file transfer, the services). Losing it costs functionality, so the machine can
    require it (`sys_required=1`, `pkg store sys-required`) and be told when it is missing.
  * `.pkgstore` -- an ordinary **removable package store**: extra packages. Losing it costs
    nothing but those packages.
  A medium cannot be both: claiming one as the system store replaces the ordinary marker.
  `roots()` searches the **system store first**, so a module the shell depends on wins when two
  media carry the same name; `root()` (the write target) is the first **ordinary** store, because
  a system store holds the installation's own modules and new packages must not be mixed into it.
* `pkg store <n>`, `pkg store remove <n>`, `pkg store auto|required|optional`, `pkg store
  sys <n>` / `sys-required` / `sys-optional`, `pkg store --json`, `pkg list -s`,
  `pkg install [--store N] NAME`; `store_required=1` and `sys_required=1` in
  `/etc/pkgstore.conf` are the only machine-side rules.
* **A warning must never mask a refusal.** `check_root()` asks about the required store FIRST:
  an earlier revision asked about the system store first and returned early, so a machine that
  required a medium *and* was missing its system store was told "the system store is missing"
  and the install went ahead. `tests/batch3_check.lua` now pins the precedence.
* **Fixed: an answer was not paired with the request that asked for it.** `pkg.update()`
  sent `list` and then read **the next message on the channel** as the answer. During an
  install a fetch reply can outlive its request (the client times out, the answer arrives
  late and stays queued); it was accepted as the index and cached, so the repository looked
  **empty** -- measured three times on a real machine as `server index shape=a leftover fetch
  reply (ok=true)`, and `tools/rpv-verify/_psh-desktop.sh` had to ask up to three times to get
  past it. Every request now carries an id and `pkgserver.lua` echoes it back; a reply whose id
  is not this request's -- or, from a repository that predates ids, a reply whose *shape* is
  the other action's answer -- is ignored and the wait goes on, under one deadline so skipping
  cannot extend the timeout. The id is stripped before the caller sees the answer, and
  `pkg.update()` refuses a reply that does not have the index shape instead of caching
  "0 packages". One choke point: the four `request()` callers (`pkg.update`, `pkg.depends`,
  `pkg.requires`, the installer's `fetch_cached`) are all paired by the same function.
* **Fixed: an install downloaded the package twice.** `pkg.install` preflights with
  `pkg.requires`, and a `fetch` answer is the WHOLE file set -- files, checksums, digest -- not
  just the manifest, so the install pass's own `fetch_cached` asked for the same bytes a second
  time. It stayed invisible for as long as an unpaired waiter could take the previous waiter's
  late answer (the defect above); pairing made the duplicate real, and the 60 s probe timeout
  was the receipt. `pkg.requires(name, cache)` now hands the preflight's cache to the install
  pass, so one install costs **one fetch per package** (a dependency still asks once, for
  itself). A cached FAILURE is handed over too, so a package the repository does not carry
  still fails with the repository's own reason (`package not found`) instead of being asked
  for a second time. Evidence: `tests/batch3_check.lua`, section "pkg: one install costs one
  fetch per package" (16 assertions: one request per package counted off the wire, a package
  with one dependency costing exactly two in all, each package receiving its OWN file set, a
  refused package costing one request and reporting the repository's reason, and the
  one-argument `pkg.requires` still working and costing its own single fetch), mutation tested
  -- 6 of 6 mutants caught: keep the second download; share the cache but drop a cached failure;
  cache in one direction only; key the cache by something other than the package name (which
  hands a dependency its parent's file set); leave the preflight in place and add a second
  request at another entry point; and cache a failure as a success. The acceptance's own wait
  could then come back down: `tools/rpv-verify/_psh-desktop.sh` writes `timeout=20` instead of
  60, which is twice the slowest single fetch MEASURED on the machine with `os.epoch("utc")`
  (9552 / 9625 / 8133 ms for one fetch of the 167 KB package, 7 ms for a `list` round trip,
  12093 ms for one whole install).
* **Backward compatibility**: the id is additive. A client from before this change sends no id,
  so the reply carries none and everything behaves exactly as before; a new client against an
  old repository falls back to telling the two answers apart by shape (a `list` answer is an
  array of entries, a `fetch` answer carries `ok`), which already covers the leftover case. The
  one case a repository without ids cannot recover is two *list* answers to two different list
  requests; that limit is stated here rather than hidden.
* **Why not drain the channel before sending**: draining would consume whatever sits there, and
  the same channel carries file blocks -- the wound `lib/xfer.lua` documents around
  `stash_block`: a queue may ignore everything that is not its request, **but must not lose a
  block**. Pairing consumes only the messages it has identified as not its own answer, one at a
  time, out of the same single queue the old code read from; nothing in `xfer`'s own buffer is
  touched, and no chunk loop was changed.
* **Evidence**: `tests/batch3_check.lua`, section "pkg: an answer belongs to the request that
  asked for it" (21 assertions: leftover fetch reply with and without an id, a list answer with
  a foreign id, another protocol's block shaped message, one request/one answer/echoed id on
  the wire, a fetch entry point over a leftover, an old repository that echoes no id, and "no
  answer left on the channel"), mutation tested -- 8 of 8 mutants caught (accept the first
  message; never check the id; give up on a mismatch; pair inside `pkg.update` only; server
  does not echo; id left in the cached index; no shape fallback; the shape rule reads any
  table as a list answer). `tools/rpv-verify/_psh-desktop.sh` now asserts the index is read on the
  **first** ask (`server index attempts=1`) and that what came back has the index shape. The
  probe's own `/etc/pkg.conf` first had to raise `timeout` from the machine default (5 s) to
  60 s: the emulator serves a 167 KB package as one message, and that work does not fit 5 s. It
  used to look fine only because `pkg.install` asked for the file set twice (a preflight
  `fetch` and the install's own) and the second wait accepted the first wait's late answer;
  pairing made that accident impossible, so the wait had to be sized for the real answer. That
  60 s was then the receipt for a real duplicate download -- fixed above, and the wait is back
  down to 20 s, twice the measured single fetch.
* **Evidence**: `tests/batch3_check.lua`, section "pkg: two markers, the system module store and
  an ordinary store" (71 assertions, mutation tested -- 9 of 9 mutants caught), plus the
  existing store sections; `tools/rpv-verify/ps1/_psh-disk-store.ps1` (three boots,
  `RESULT psh-disk-store server=PASS`).
* **Not done**: nothing outstanding for this feature. The two-part *installation* (which modules
  go on which medium) is a deployment question, recorded in section 6.7.

---

## 3. Optional A4 bitmap font

* **State**: done. `cc_chinese.lua` plus `cc_font_shards.lua` live outside the repository, in
  `~/.dsh/marvis-export/cc_chinese`, and `pkg` refuses the install without a medium carrying
  `cc_fonts.marker`.
* **Why outside**: the repository is ASCII-only (gate 2) and the glyph data is not.
* **Not done**: nothing outstanding. The glyph generator (`fontgen.py`) is not in the dump, so
  regenerating the shards means writing it again.

---

## 4. Explicitly out of scope

* **REPL integration**: the user has stated the interpreter is not integrated into the shell.
* **Python interpreter**: exported separately at `~/.dsh/marvis-export/pythonlib`. It is not
  part of this project; do not add it to the repository.
* Section 6 lists everything the Marvis project left unfinished, including the parts that are
  out of scope here, so that "not done" and "not doing it" are not confused.

---

## 5. Smaller items, worth doing when the above are quiet

* **`tools/rpv-verify/_psh-mc-server.ps1`**: start/stop/restart/status/logs works, but `-Action
  start` can block longer than it should on its readiness loop, and a server started as a child
  of a killed shell dies with it (the README says so; the script could detach properly).
* **`rpv-log.txt` grows without bound** -- **done.** Measured first: the node logs every frame
  event, so a 200 KB `rget`/`rput` pair writes about **14.5 KB** of log per machine (6490 B live +
  8205 B in the kept generation on the run that measured it), and it otherwise grew for as long as
  the machine was up, into a disk of about 1 MB, while reading it back over the Minecraft world
  file system had timed out with the transfer itself healthy. The vendored stack now caps the live
  log: `log_write` in `rpv/node.lua` counts the bytes it writes and, past `log_max_bytes`, moves
  `rpv-log.txt` to `rpv-log.txt.1` (one generation, replaced each rotation) and opens a fresh file
  that announces the rotation with a `LOG_ROTATED` line. `0` turns the cap off; the shell reads
  `rpv_log_max_bytes` from `/etc/network.conf` (default 131072). Every step is guarded with `pcall`,
  because a node that cannot rotate must still keep logging. **Evidence**: `tests/batch8_check.lua`
  ("rpv: the node log is capped...", 13 assertions, mutation tested); the emulator acceptance
  `tools/rpv-verify/_psh-rpv-file.sh` now sets an 8 KB cap on purpose and its real run shows the
  rotation (`live 6490 B + .1 8205 B`, transfer still `CLIENT_VERDICT PASS` /
  `SERVER_VERDICT PASS`); gate 6 covers the new key.
* **Report tails** -- **done.** The MC acceptance printed the last ten matching lines of each
  machine log, which turned a request that failed three times in a row into a single event: the
  earlier attempts had scrolled out of the window. Both acceptance scripts now report through
  `tools/rpv-verify/log_summary.py`, which groups equal lines with a count **and lists every
  occurrence's timestamp** (a count alone would lose the order, which is what made the original
  failure read as one event), prints the first and last matched line, and prints the verdict lines
  whatever the pattern says. A missing log, an empty log and a log where nothing matched are three
  different messages rather than silence. **A trap found while doing it**: the MC driver logs
  `REQUEST op=nil` while the emulator driver logs `request op=get`, so a pattern written against
  one vocabulary matched **2 of 249 lines** of a real log -- matching is now case insensitive, and
  gate 8 is the self test that would have caught it. `_psh-mc-file.ps1` also gained the xfer trace
  print (first 40 lines, in order) under `-ClientTrace`.
* **The acceptance script can be killed by its own wait**: in the run that finally succeeded, the
  peer reported `PUSHED ... same=true` and `PEER_VERDICT PASS` while the client's own verdict was
  never read, because the client needs minutes to read a 200 KB file back and write its marker
  over the Minecraft world filesystem, and the host script's wait ended first. The transfer was
  complete; only the verdict was lost. The wait should be driven by the two logs reaching their
  verdicts rather than by one clock, and the client-side read-back should be bounded (the trace
  already proves the transfer, so the read-back is a second, slow confirmation).
* **`tools/deploy.py` exit code on Windows** -- **no longer true; the item is stale.** Measured
  directly: a first deploy and a no-op second deploy both exit `0` (`python tools/deploy.py
  --target <dir> --json` -> `exit=0` twice), and gate 5 has reported `problems 0` throughout. The
  script returns 0 from `main` and never adopted the POSIX "non-zero means differences" habit.
* **Configuration keys**: gate 6 requires every documented key to be read somewhere. New keys
  must be added to both the document and a reader, or the gate fails.
* **Rewriting a file on Windows must not add a BOM**: `Set-Content -Encoding utf8` in Windows
  PowerShell writes one, and gate 1 fails with a `UnicodeDecodeError` that points at an unrelated
  line. Use `[System.IO.File]::WriteAllText($path, $text, (New-Object System.Text.UTF8Encoding($false)))`
  and re-check the first three bytes when a Lua file is rewritten by hand.

---

## 6. Unfinished work carried over from the Marvis project

The Marvis session that this project came from ended with its own list of unfinished work (in the
archived dump, the section headed "unfinished / directions that can be continued", around line
89875), and the shell in this repository is only one of the things that session built. This section
records that list and what became of each item, so nothing is silently assumed to be done.

The dump itself is at
`C:\Users\ymd10\AppData\Roaming\Tencent\Marvis\User\BEE8C8819ED0EAC0E38D844A06450AE8\workspace\conv_c761312b431a4aa8935c6961ce2b1767\output\deepseek-share-t7l9c9g3h0h72ijjy2-dialogue-original.md`
(2.86 MB, 89895 lines). The exports taken from it live outside this repository, under
`~/.dsh/marvis-export` (`pythonlib`, `cc_chinese`), each with its own MANIFEST.md.

### 6.1 Python interpreter (outside this repository)

Exported to `~/.dsh/marvis-export/pythonlib` and **not** part of this project. The session's own
list of what is missing, kept here because the export carries no such list:

| item | state per the dump |
| --- | --- |
| `try/except` | not implemented (the dump says "no exception handling") |
| `super()` | not implemented |
| generators / `yield` | not implemented |
| circular imports | not protected: A imports B imports A recurses until the Lua stack overflows |
| `metaclass=` | not implemented ("too large a change for the benefit") |
| descriptor protocol (`__get__` / `__set__` / `__delete__`) | not implemented; entity access is tangled |
| `async` / `await` | not implemented; coroutine semantics collide inside CC |
| full `inspect` | not implemented; needs source position information |
| a real `re` module | not implemented; needs a regex engine of its own |
| `__prepare__` | not implemented |
| performance | AST cache done, constant folding done, **local variable slotting not done** |
| numeric / string limits | integers are Lua doubles (53 bits), strings count bytes, `1e10` prints as `1e+10`, `3.0` prints as `3`, `dict` has no `__hash__`, `raise from` chains do not survive, a `return` inside `finally` overrides imprecisely, closure assignment leaks |

What to do about any of it is out of scope for this repository; it is listed so a future reader
knows the interpreter is a partial implementation, not a Python 3 clone.

### 6.2 REPL (decision: not doing it)

The dump lists "`pyrepl.lua` is written but has not been integrated into `psh` as a command". The
user has since stated explicitly that the interpreter is **not** integrated into the shell, so this
stays open by decision, not by accident. `pyrepl.lua` is exported with the interpreter.

### 6.3 CJK bitmap text, with the glyphs on disks of their own

**Status: done, across two media.** Each terminal cell is 2x3 pixels, so a size 12
glyph is 6 cells wide and 4 tall, and the six sub-pixel flags are packed into one byte
per cell as `string.char(128 + mask)`. **A lit cell is a byte above 128 and a blank cell
is exactly 128**, which is what makes "did it draw?" a question about BYTES rather than
about the absence of an error.

**The glyphs fit neither the computer nor one medium.** A CraftOS computer holds
1,000,000 B and the shell already uses about 74%. The whole of GB2312 is 6,763
ideographs and measures **1,375,263 B** against the 1,228,800 B a floppy holds --
**146,463 B too much** -- so a full set is built as **two media** and the loader unions
them. Media are found by the marker `cc_fonts.marker` at the root, **never by a drive
letter**, because a drive letter is a property of the bay and not of the data.

**Where the glyphs come from.** They are rasterised at size 12 from **Noto Sans SC**
(`C:\Windows\Fonts\NotoSansSC-VF.ttf`, a variable font; the rasteriser selects its
Regular instance) by `tools/fontgen.py`. That font is under the **SIL Open Font
License 1.1**, and the licence text and the attribution are in
`THIRD_PARTY_LICENSES` at the repository root; the generated `fontdata/*.lua` are
bitmap renderings of it and are distributed under the same licence.

**A set is a partition of the glyphs, not a copy of them.** Each part's
`fonts/<base>_index.lua` names **only** the shards beside it, and `fonts/<base>.set.lua`
is the manifest **every** part carries: the set name, the part count, which part this is,
its own shards, and the **whole plan**. The plan is on every part because a machine
holding only part 2 cannot read part 1's manifest to learn that part 1 is what is
missing. A pair is therefore read in **manifest order, not drive order** -- verified with
the two media deliberately mounted the other way round. A medium with no manifest is a
set of one part, so media built before this still work.

* `lib/cc_chinese.lua` draws a string with `term.blit`
* `lib/cc_font_shards.lua` loads one shard at a time from every medium of the set, and reports which part is not inserted
* `lib/cc_fonts.lua` finds the media (`media()`, `bases()`) and the set they make together (`parts()`, `manifest()`)
* `tools/fontgen.py` (`--font`, `--size`, `--shard-size`, `--chars`, `--full`, `--json`, `--probe`)
* `tools/fontdisk.py` (`--out` one medium, `--set-out DIR [--disks N]` a whole set, `--capacity B`)
* the medium also carries `.pkgstore`, because `requires_disk=cc_fonts.marker` is only checked on media the package manager already treats as a store. It must **never** carry `.pkgsys`: that marker claims modules the shell needs in order to boot.

**Four ways for a glyph to be missing, four reasons, no silent blank.** `draw()` returns
`{ok, reason, drawn, missing, absent, missing_parts}` and draws nothing when the font is
gone; `render()` raises one message naming the medium. The reasons are distinct because
the fixes are: no medium carries the marker (insert it); a marked medium has no glyph set
(rebuild it); a pinned set has no index (check the file); **the glyph is on a part that is
not inserted** -- `shards.stats().status` says `set shs12 part 1 of 2, part 2 not
inserted`, and the reason names the part, its shards and its codepoint range. That last
case is deliberately **not** drawn as the fallback box: a box would claim the font does
not have the character, which is false.

**Measured.** `fontgen.py --full --size 12` is 6,786 glyphs in 14 shards = 1,375,263 B.
`fontdisk.py --set-out DIR --disks 2` gives **part 1 713,670 B (58.1% of a floppy,
515,130 B spare, shards 0-6)** and **part 2 672,264 B (54.7%, 556,536 B spare, shards
7-13)**. Two media suffice at size 12, and the number is **computed**: a `--disks` that
cannot hold the set is refused with the measurement rather than squeezed, and a single
medium over `--capacity` is refused and **not written** -- the one failure an operator
cannot see on a finished-looking disk. The 5,400 glyph set still fits one medium:
1,093,371 B = 89.0%. `fontdata/` is a build input, excluded from every deploy (gate 9
checks that): a machine gets glyphs by mounting a medium, never by being copied to.

**Verified on the machine** (`tools/rpv-verify/_psh-font-two-disks.sh`, 52 checks;
`_psh-font-medium.sh`, 26 checks, still green). The probe captures the `term.blit`
payload and asserts on the BYTES: with both media mounted and deliberately at the wrong
drive names, the indexes are still read in manifest order; U+4E00 renders **22** lit
pixels and U+746D renders **61**, each equal to the ink `fontdisk` measured from the
shard file on that medium (the sum of the set bits of `byte - 128`); and with only part 1
inserted the machine answers `set shs12 part 1 of 2, part 2 not inserted`, names part 2
and its range for a character that lives there, and blits **nothing** for it.
`tests/batch9_check.lua` holds 169 assertions; gate 9 self tests the two Python tools,
including that the split is a partition, that each per-disk index claims only its own
shards, that every manifest carries the whole plan, and that an over-capacity medium is
refused.

**Not verified, stated plainly**: CraftOS-PC cannot insert a floppy image, so a "medium"
is a `--mount-rw` directory and the fit is arithmetic against 1,228,800 B rather than an
observed floppy write; the half-inserted case is a second boot with one mount, not a
physical ejection; only size 12 was generated; a three-medium build was measured but not
booted; and a mixed pair of media is reported only through
`cc_fonts.parts(...).foreign` / `shards.stats().foreign` -- nothing prints it to a screen
yet.

### 6.4 Package manifests: `depends=` (done -- this entry was stale)

The dump lists "`manifest`'s `depends=` is not resolved", and this file used to repeat that as an
open item. It is not open: **the install path does consume the dependencies.**

* `install_tree(name, ctx, is_dependency)` in `lib/pkg.lua` walks `manifest.depends` recursively,
  is called from `pkg.install` (`lib/pkg.lua`), rejects a self-dependency as
  `circular dependency: <name> depends on itself`, records the first parent's constraint in
  `ctx.want`/`ctx.wanted_by`, skips a dependency that already satisfies it, installs a missing or
  too-old one, wraps a failure as `dependency '<spec>' of '<name>' failed: ...`, and checks the
  fetched version with `pkg.version_satisfies` so the repository cannot silently deliver a version
  the dependent cannot use.
* Version constraints are parsed and compared by `pkg.parse_dependency`, `pkg.version_satisfies`,
  `pkg.describe_dependency`, `pkg.dependency_met`, `pkg.dependencies` and `pkg.depends`, over
  `lib/semver.lua` (so `1.10` is newer than `1.9`).
* `tests/batch3_check.lua`, section `pkg: dependency constraints in the manifest`, asserts the
  behaviour end to end: a package with a dependency installs and pulls the dependency in; the
  report names it; it lands at the repository version; a too-new dependency is replaced
  (`base 2.0.0` -> `1.5.0`); an unsatisfiable constraint (`base>=9.0`) is refused naming `base`
  and `9.0` and leaves the dependency alone; and a dependency the repository does not carry
  (`ghost>=1.0`) is refused naming `ghost` without installing the dependent.

So there is nothing to decide and nothing to write here. The entry is kept, corrected, because a
future reader would otherwise re-implement what already exists.

### 6.5 Shell items from the same list, and their state here

| dump item | state in this repository |
| --- | --- |
| `sudo` wildcard rules (`guest ALL=(ALL) /bin/ls`) | **done**, and this file used to say "not checked". `lib/sudorules.lua` reads the fine-grained `/etc/sudo.conf` policy (`<user> <host>=(<runas>) <command>[, <command>...]`), turns `*` into a pattern via `sudorules.pattern_to_lua`, and answers three-state from `sudorules.check(user, runas, path, name, is_builtin)` (true / false / nil). The coarse side is done too: `lib/perm.lua`'s `name_pattern` + `perm.is_sudoer` honour an exact name, a `%group` entry, and a `*` wildcard, asserted in `tests/batch_check.lua`. **The gap found here is closed**: `lib/sudorules.lua` now has its own section in `tests/batch_check.lua` (31 assertions) covering the three-state contract, the runas field, the command wildcard, the `.lua` suffix, builtins, the bare-name form, the `user:group` target and `reload`. |
| `last` / `lastlog` / `w` / `who` (login history) | present as commands (`usr/cmd/last.lua`, `lastlog.lua`, `w.lua`, `who.lua`) and backed by `lib/sessionlog.lua` (`sessionlog.append`, `sessionlog.history`, `sessionlog.archives`, rotation of `/var/log/wtmp`). **The gap found here is closed**: `tests/batch4_check.lua` now asserts the module (44 assertions) -- login/logout/switch_user/crash-close, the `since` pairing and the logout-only `end`, the live `.dat` records, `online()` ordering with a corrupt record present, and wtmp rotation with `history(true)` vs `history(false)`. |
| `cd` should really change directory | **done**: `cd` affects relative paths (`cwd.resolve`, verified with `cat sub/note.txt` and `ls sub`); the dump's claim is stale |
| `sed` | **done**: a shell builtin in `usr/psh.lua` (`BUILTINS["sed"]`), backed by `lib/sed.lua` |

### 6.6 Other components the same session built

The dump also contains a SQL engine with a long list of unimplemented SQL (unions, subqueries,
`EXISTS`, `CASE`, recursive CTEs, window functions, `ALTER TABLE`, views, triggers, indexes,
foreign keys, `CHECK`, cascades, `EXPLAIN`, date/time and `BLOB` types, `CAST`, `||`, `REGEXP`,
full-text search, stored procedures, engines, partitions, `GRANT` / `REVOKE`) plus a Lua
implementation of RSA and of an SQLite-style database. None of it is in this repository and none
of it is planned here; it is recorded so that "the Marvis project" is not mistaken for "the
shell".

### 6.7 The two-part installation on a 1 MB computer (measured, and now automated)

A CraftOS computer's filesystem is capped by `computer_space_limit` (1,000,000 by default), and
the whole deployed tree, measured on 2026-10-17, is **1,395,636 B (1.40 MB)** -- 395,636 B above
the cap, so it does not fit. The intended shape is therefore two
parts: the shell on the computer, its own modules on a medium marked `.pkgsys` (section 2).
`tools/deploy.py --part base|modules` now produces both halves, and the split has been booted on
CraftOS-PC.

* **The split, measured.** Part 1 (`--part base`) = the boot entry points + the load-time closure
  of `lib/` + `usr/` + `etc/` + the root files = **781,380 B (78.1% of 1 MB)**, 218,620 B to
  spare. Part 2 (`--part modules`) = the lazily-reached `lib/` modules + `rpv/` (244,313 B of
  it, optional: `transport=auto` falls back to rednet) = **614,005 B**. The whole deployed tree
  is 1,395,636 B: that arithmetic is what makes the split necessary. The two halves are
  provably disjoint and their union is exactly the whole tree (`comm -12` shows only the
  manifest, which each half writes for itself).
* **The base half could not start on its own, and nothing noticed for weeks.** This is the
  defect the split produced and the gates could not see, and it was fatal in both directions:
  * `usr/psh.lua` opened the session ledger with an INDENTED `require("sessionlog")` inside the
    function that starts the interactive session. An indented require is lazy by the rule above,
    so `lib/sessionlog.lua` went to the medium -- and login is the LAST step before the prompt.
    Measured on a machine deployed with `--part base` and no medium: `psh 1.0 - type 'help' for
    commands`, then `/usr/psh.lua:8574: module 'sessionlog' not found`, once per turn of the
    session loop, and **no prompt ever appeared**. It is an old defect of the release
    (commit 1515e3e's `usr/psh.lua`, lines 8355-8356, is the same shape), not a
    regression of one commit -- but the split is what made it fatal instead of lazy.
  * `firstboot.lua` was not an entry point of `tools/deploy.py` at all (`ENTRY_POINTS` named
    `startup.lua` and `usr/psh.lua` only), so the split ignored every require it makes.
    `lib/policy.lua` and `lib/time.lua` stayed on the medium, and the set-up wizard died with
    `/firstboot.lua:19: module 'policy' not found` **385 times in 15 seconds** -- the marker is
    only written after the wizard finishes, so the loop could never end and the machine could
    never be set up.
  * Fixed by making both places visible to the rule: `usr/psh.lua` requires `sessionlog` at
    column 0 (beside `space` and `danger`, with the same reasoning), and `firstboot.lua` joins
    `ENTRY_POINTS` (it runs at boot, between `startup.lua` and the shell). Gate 5 pins
    `lib/sessionlog.lua`, `lib/policy.lua` and `lib/time.lua` in the base half with the shared
    acceptance criterion **"a machine with no medium inserted must boot to a prompt AND complete
    first setup"**.
  * Evidence, and the reason this is a real-machine claim rather than a suite result: a fresh
    CraftOS-PC computer deployed with `--part base --with-etc` and no medium at all walked the
    whole wizard (root password, username, label, network, timezone), wrote its own
    `/etc/.configured`, reached `alice@cc-48:/$`, ran `echo hi`, `ls /` and `rm -rf /` (refused,
    status 1, `/usr/psh.lua` unchanged at 334,485 B), and logged **zero** `module ... not
    found`; a second boot of the same disk went straight to the prompt with no wizard. The
    probe lives outside the repository (`Temp/psh-baseonly2/run.sh`), like the other
    acceptance probes.
* **`lib/boot.lua` was on the medium, and the two `pcall`s around it hid both consequences.**
  The boot identity is asked for exactly as `pcall(require, "boot")`: `lib/cron.lua:531`
  (`local first = ok and b and b.begin(REBOOT_MARKER)`) and `lib/services.lua:70`. The split's
  scanner only matches `require("x")`, so the module sat in the modules half -- and because both
  callers guard with `pcall`, the machine kept running and only lost features, which is the
  kind of failure no gate had to notice. Measured on a fresh CraftOS-PC computer deployed with
  `--part base --with-etc` and no medium, before the fix:
  `BOOT require_ok=false`, `CRON reboot_fired=0 output_file=false` (no `@reboot` crontab entry
  ever fired, so the job's output file was never created), and `SERVICES started= skipped=probe`
  -- an rc.d unit carrying a `.started` marker from the PREVIOUS boot was judged "already started
  in this boot" for ever, because the fallback in `started_same_boot` is `return true`. After
  adding `"boot"` to `tools/deploy.py`'s `BOOT_EXTRA`: the same machine reports
  `BOOT require_ok=true`, `CRON reboot_fired=1` with the runner's output file on disk, and
  `SERVICES started=probe`. Gate 5 pins `lib/boot.lua` in the base half. The probe is
  `Temp/psh-two-fixes/run.sh`, outside the repository.
* **The wizard's own default name was on its own blacklist.** A fresh machine could not be set
  up at all: the administrator prompt says "Leave blank for default name 'admin'", a bare Enter
  took that default, and `policy.check_username("admin")` answered
  `Rejected: 'admin' is a reserved name` and asked again, for ever. The contradiction was
  between two files: `firstboot.lua` offered the name, `etc/passwd.policy` listed it as reserved.
  The policy was the wrong side -- `admin` is not a reserved name in this system, it is the
  machine's own administrator account, the level 1 account `lib/perm.lua` seeds
  (`root:2`, `admin:1`, `guest:0`), and `firstboot.lua` KEEPS that account when it is chosen
  (it deletes the seeded one only for a different name). `admin` is gone from the blacklist,
  with the reason written beside the list so it is not put back. Note that the emulated file
  system has no `/etc/passwd.policy` and `lib/policy.lua`'s built-in defaults never listed
  `admin`, so a suite that asked `check_username("admin")` in the emulated file system was green
  while every DEPLOYED machine was stuck: the new assertions read the repository's
  `etc/passwd.policy`, install it, and then drive the wizard with one Enter at the name prompt.
  Real-machine evidence, same base-only machine: before the fix
  `SAW RESERVED-NAME-ERROR` and no `/etc/.configured`; after it `SAW admin-password-prompt`,
  `SAW setup-complete`, `SAW prompt text=[...admin@cc-62:/$ ]` and `/etc/.configured` written
  with `{computerId = "62", setup = true}`.
* **What decides a module's half: the LOAD-TIME closure.** A module belongs in `base` when it is
  reached at load time from something that runs at boot -- `startup.lua`, `usr/psh.lua` and
  `firstboot.lua`, plus
  the `pcall(require, ...)` calls in `startup.lua` (`cron`, `disk`, `services`), which still run
  at load time because `pcall` swallows the failure but the shell still wants the module. A
  `require` inside a function body runs only when that function is called, so such a module can
  live on the medium.
* **CORRECTION to an earlier claim in this section.** An earlier revision of this roadmap said
  `lib/pkg.lua` had to stay on the computer and that moving it failed with
  `module 'pkg' not found`. That was an **artefact of the probe**, not a property of the design:
  the probe started `psh.lua` directly with a hand-written `startup.lua`, so the real boot path
  never ran and `pkg` was reached too early. The real path is `startup.lua` -> `lib/marker.lua`
  and `lib/rpvnet.lua` (the licence module that used to be in this closure was removed on
  2026-10-17), and `pkg` is reached only lazily inside `run_pkg`. So
  `lib/pkg.lua` **belongs in the modules half** and goes on the medium. The constraint is the
  load-time closure, and `pkg` is not in it.
* **The missing piece this exposed: a package's modules were not requirable at all.** A package
  could publish commands (`manifest bin=`) but there was **no mechanism** to put a package's
  `lib/` directory on `package.path`, so a module on a mounted medium was invisible to
  `require()`. Fixed by `mounts.module_dirs()` / `mounts.refresh_module_paths()`, beside the
  existing `mounts.bin_dirs()` (the same idea for commands), wired into `mounts.mount()` and
  `mounts.umount()` and called at boot from `startup.lua`.
* **Why the scan lives in `mounts.lua` and not `pkg.lua`, and this is structural.** On a two-part
  machine `pkg.lua` is *on the medium*. A shell that had to load the package manager in order to
  find the medium's modules could never start: the code that would put the medium on
  `package.path` would itself be on the medium. `mounts.lua` is in the load-time closure and is
  always on the computer, so it owns the scan. `pkg.refresh_module_paths()` / `pkg.module_dirs()`
  delegate to it for callers that hold a `pkg` handle.
* **Evidence**: booted under CraftOS-PC with the medium mounted (`--mount-rw "/disk2=<dir>"`;
  without it `fs.exists("/disk2")` is false, and the `disk` API's drives are always
  `isPresent=false` in this emulator). Part 1 on the computer, Part 2 laid out on the medium as
  `<root>/<name>/lib/<module>.lua`: `mount=true`, `module dirs found=18`,
  **`require mediumonly=true -> loaded from the system module store`** with **no manual
  `package.path` edit anywhere in the probe** -- mounting alone is what wires it -- plus
  `require xfer=true` from the medium, `stores=/disk2`, `roots=/disk2/usr/pkgs,/usr/pkgs`,
  `sys complete=true`, `psh starts=true`, and eight commands running (`echo pwd cat grep sed
  sort wc ls`). `tests/batch3_check.lua` has the section "mounts: modules a package contributes
  to require()" (21 assertions, mutation tested -- 5 of 6 mutants caught; the sixth is a guard
  that cannot be isolated, see the note in that section). This is a CraftOS-PC measurement, not a
  Minecraft one.
* **Not done**: nothing outstanding for the split itself. The next natural step would be a
  `tools/` script that builds both halves and a boot image in one command, rather than the two
  `deploy.py` invocations plus the package layout that `tools/rpv-verify/probe_part.sh`
  currently performs by hand.


* **DONE: one command builds both halves, and the result is booted.**
  `python tools/twopart.py --out DIR` writes `DIR/part1` (the computer),
  `DIR/part2` (the medium) and `DIR/README.txt`. It does not reimplement the
  split: it imports `tools/deploy.py`, calls its `main()` per half, and reads the
  modules half back with `deploy.collect()` to check what it placed. The medium is
  laid out the way `lib/pkg.lua` and `lib/mounts.lua` resolve it -- `.pkgsys` at
  the root, `usr/pkgs/<package>/lib/<module>.lua` below it -- with the modules
  grouped by concern. `rpv` keeps its directory shape inside its own package,
  because `rpv/loader.lua` loads its siblings by path and publishing them flat
  would make `rpv/crypto.lua` answer `require("crypto")` alongside
  `lib/crypto.lua`. A `lib/` module not named in the tool's `GROUPS` table is an
  **error, not a silent omission**: the build stops and names it. The build also
  refuses to call itself done -- it checks that part 1 carries the boot path and
  the whole load-time closure, that the two halves share no module name, and that
  part 1 still fits.
* **Measured, and the number moved for a reason.** part 1 was **808,370 B (80.8%
  of the 1 MB limit, 191,630 B spare)**. It is now **732,919 B (73.3%, 267,081 B
  spare)**; part 2 is 562,632 B. The 75,451 B difference is `lib/man.lua`. Measured again on
  2026-10-17, after the later features and the licence removal: part 1 **732,531 B / 73.3%**,
  267,469 B spare; part 2 **628,773 B**; whole tree **1,361,304 B**. Measured once more the same
  day, after `sessionlog`/`policy`/`time` were pinned onto the computer so that the base half
  can boot on its own: `python tools/twopart.py --out DIR` now reports part 1 **777,712 B in 66
  files (77.8% of 1,000,000 B, 222,288 B spare)** and part 2 **620,572 B in 50 files** (7
  packages, `.pkgsys`, `sys_required` on). The 15,216 B that part 1 grew is accounted for
  exactly: 13,775 B are the three modules, 1,376 B are the comments explaining the two column-0
  requires, and 65 B are the manifest entries. Part 2 shrank by the same 13,775 B. Measured a
  last time after `lib/boot.lua` moved onto the computer, `admin` left the password policy's
  blacklist, and the dead `lib/lineedit.lua` was deleted: part 1 **781,380 B in 67 files
  (78.1% of 1,000,000 B, 218,620 B spare)**, part 2 **614,005 B in 48 files**, whole tree
  **1,395,636 B in 107 files**. Between those two runs part 1 gained `lib/boot.lua` (2,930 B,
  moved off the medium), 734 B of comment in `etc/passwd.policy` explaining why `admin` is not
  a reserved name, and 19 B of manifest entries, and then lost 15 B of comment in `usr/psh.lua`;
  part 2 lost the same 2,930 B in the move and 3,637 B more with `lib/lineedit.lua`, which
  nothing ever required (psh keeps its own editing rules inline), so it was dead weight on the
  medium.
* **The manual pages were on the machine's disk because of a COMMENT.** 76,549 B
  of prose -- the largest library after the shell itself -- was in the base half
  for one reason: `lib/complete.lua` required it at load time, purely so Tab could
  complete a command's options. That require is now lazy (and a machine with no
  medium simply completes no options, rather than the line editor throwing), so
  the pages live on the medium, which is where the system module store was always
  documented to keep them.
* **A comment had been deciding the split all along, and the gate could not see
  it.** `tools/deploy.py`'s `_requires` scanned the RAW source and decided
  "top level" from the indentation of the line the match sat on, so a `require()`
  merely NAMED IN A COMMENT counted, and a comment at column 0 counted as load
  time. The first attempt to document the move above -- writing the words
  `local man = require("man")` inside a comment -- put the 76 KB back on the disk,
  with gate 5 reporting `problems 0`. `usr/psh.lua:5` and `startup.lua:8` both
  carry a column-0 comment naming `require("perm")` and `require("cwd")` for the
  same reason. The scanner now blanks comments first (length-preserving, so byte
  offsets and the column-0 test still refer to the real file), and gate 5 writes a
  throwaway file whose comment, block comment and string all name requires that do
  not exist, asserting none of them is reported and that a real one still is.
  **A tool that reads code as text has to know what text is.**
* **The build is booted, not merely read.**
  `tools/rpv-verify/_psh-twopart-build.sh` runs the tool, copies `part1/` onto a
  CraftOS-PC computer, mounts `part2/` with `--mount-rw "/disk2=..."`, and asserts
  in the probe that the computer holds **no copy** of the module it is about to
  require, that mounting alone makes `require("xfer")` and `require("pkg")`
  succeed with **no `package.path` edit anywhere in the probe**, that all six
  packages appear as module directories, that the shell starts from part 1 and
  runs nine commands, and that with the mount entry gone the machine reports
  itself incomplete. `RESULT psh-twopart-build=PASS server=PASS`. Mutating the one
  thing a tree check cannot see -- the marker -- to `.pkgstore` makes the same run
  fail, so the marker's *kind* is load-bearing rather than decoration. The older
  `_psh-twopart.sh` still passes as well (`commands: echo=0 pwd=0 cat=0 grep=0
  sed=0 sort=0 wc=0 ls=0`), and its claim to run eight commands is correct.
* **Not done**: `sys_required=1` has no login-time warning yet -- its consumers are
  `pkg store`, the install preflight and `pkg.completeness_warning()`, and
  `usr/psh.lua` never calls the last one at login, so the machine reports itself
  incomplete rather than printing a line. The acceptance boot replaces
  `startup.lua` with the probe, so the real boot path (`marker`, `bios`,
  bootguard) is exercised only insofar as `shell.run("/usr/psh.lua")` plus nine
  commands reach it. And the medium cannot really be ejected in CraftOS-PC 2.8.3:
  "missing medium" is the mount-table entry being removed, which is what
  `lib/pkg.lua` considers ejection, not the hardware event.
### 6.8 The command set: fifteen additions, and the stub that lied

Fifteen commands were added, chosen from a comparison against the Linux commands a
"kernel only" system would have: `sha256sum`, `md5sum`, `cksum`, `base64`, `expr`,
`egrep`, `fgrep`, `printenv`, `groups`, `users`, `tty`, `nproc`, `tput`,
`realpath`, `mktemp`.

* **Two were deliberately NOT added, and are recorded rather than faked.**
  `readlink` has nothing to do: CraftOS has no symbolic links, so every call would
  exit 1 and print nothing. `timeout` cannot be honoured: the scheduler is
  cooperative, so a command that never calls `pullEvent` cannot be preempted --
  the same limitation Ctrl+C has, and `lib/interrupt.lua` already documents it. A
  command that promised a deadline it could not enforce would be worse than its
  absence.
* **`cksum` is POSIX CRC-32/CKSUM, not the zlib CRC-32 this project already had.**
  Different polynomial, different bit order, and the length is fed through the
  same loop: `cksum("abc")` is `1219131554 3` and `cksum("123456789")` is
  `930766865`, where `checksum.crc32("123456789")` is `0xCBF43926`. Reusing the
  existing helper would have produced a plausible wrong number.
* **`fgrep` compiles its escaped fixed string as EXTENDED syntax.** In this
  project's basic grammar `\+ \? \( \) \|` are operators, so a fixed string
  escaped with `regex.escape()` and compiled as basic matches the wrong text --
  `fgrep 'a+b'` would match `ab` and `aab`. A fixed string has no syntax, so the
  grammar that reads the escapes is an internal detail. Asserted both ways.
* **`tput bold`/`smul`/`rmul`/`sgr0` write nothing and exit 0.** This machine has no
  bold or underline attribute and sets colour by calling `term.setTextColour`, not
  by writing escape bytes. The manual page says so; emitting an ANSI sequence the
  terminal does not interpret would be a quiet lie.
* **The stub that lied, and the bug it hid.** `mktemp -d` asks the filesystem for a
  directory and took `fs.makeDir`'s RETURN VALUE as its success signal. On the real
  ROM `fs.makeDir` returns **nothing** -- measured: `nil` (type nil) for a new
  directory and `nil` for one that already exists -- so every one of its hundred
  attempts looked like a failure and the command exited 1 with `mktemp: cannot
  create a name from '/var/tmp/tmp.XXXXXX'`, while **passing every assertion in the
  suite**, because the test stub's `fs.makeDir` returned `true`. Both halves are
  fixed: `mktemp` confirms the directory with `fs.exists`, and the stub now returns
  nothing like the ROM. The regression is caught -- reverting `mktemp` to the
  return-value check makes the suite fail (416 pass / 2 fail). **The general lesson
  is worth more than the fix: a stub that is more generous than the thing it stands
  in for converts a hardware failure into a green test.** Every other place that
  calls `fs.makeDir` ignores its return value, which is correct.
* **FIXED: stderr redirection is real now.** The shell had no second stream at
  all -- `emit_diag` wrote exactly where `emit` writes -- so `2>` was neither
  honoured nor rejected: it was read as the ARGUMENT `2` followed by a plain
  stdout redirect. Measured on the machine before the fix: `echo hi 2> f` put the
  text `hi 2` into `f` and exited **0**; `echo hi 2> /dev/null` exited 0 having
  discarded `hi 2` instead of the diagnostics; `echo hi > f 2>&1` exited **127**
  with "command not found". Silent wrong output is worse than an error, which is
  why this moved from "recorded for a decision" to done.
  * `2>`, `2>>` and `2>&1` are recognised only when the digit is IMMEDIATELY
    followed by `>` -- `echo 2 > f` is still the argument `2` plus a stdout
    redirect, which is what POSIX does. `1>`/`1>>` are accepted as the spelled-out
    stdout redirection, and `1>&2` is refused rather than read as an argument.
  * The ORDER of the redirections is honoured: `> f 2>&1` sends diagnostics into
    `f`, while `2>&1 > f` leaves them on the console, because the duplication
    captures the stdout that existed when it was parsed. One limitation is named
    in the code rather than hidden: `> a 2>&1 > b` gives `b`, not `a`.
  * Measured after, on CraftOS-PC: `echo hi 2> f` leaves `f` empty; `echo hi > f
    2>&1` writes `hi` and exits 0; `nosuchcmd 2> f` puts the diagnostic in `f` and
    exits 127; `nosuchcmd 2>&1 > f` leaves `f` empty with the diagnostic on the
    console; `2>>` appends; `echo 2 > f` (with the space) still writes `2`.
  * Evidence: `tests/batch_check.lua`, section "stderr redirection: 2>, 2>> and
    2>&1 are real" -- 12 assertions that read FILE CONTENTS rather than only the
    status, because the old bug produced status 0. Mutation tested: ordering
    ignored, diagnostics never redirected, `2>` tokenised as a plain `>`, `2>`
    target dropped, and `2>>` truncating were all caught.
* **Evidence**: `tests/batch_check.lua` went 358 -> 418 assertions, all mutation
  tested (41 mutants tried, every one caught; one assertion was found too weak
  during that pass and strengthened). The fifteen commands were then run on
  CraftOS-PC itself, not only under the PC stub, and the values above are the ones
  the machine printed.


### 6.9 A GNOME-like desktop, as an optional package

**Status: done.** `tools/pkgs/gnome/` is the source of the `gnome` package (`bin=desktop`,
version 1.7.0): Ubuntu's GNOME in a text grid -- a near black one-row top panel (Activities, a
centred clock, a status area), a **permanent dock down the left edge** (three columns by
default, `opts.dock_w`; a gray separator cell, and one running dot under each icon), an
activities overview that is a clickable application grid inside the workspace, a wallpaper
banded from purple to orange, and windows with a title bar, a close control on the right,
click-to-focus, raise-on-click and drag-by-title-bar. The accent colour is **orange**, and it
is used exactly where the picture says "this one": the open activity, the selected card, the
running dot, and one accent cell at the left of the focused window's title bar (the
calculator's pressed key is the same colour, one level down: an application's feedback, not
the desktop's chrome). Six
applications ship with it: a **Terminal that runs the project's shell inside its own window**
(the `>_` favourite, first card), a file browser, a settings panel (sections, a storage bar,
the machine's live numbers -- see 1.7.0), a calculator with a clickable keypad that takes the
keyboard too, a task manager whose own task counts the ticks it was resumed for, and a
**Console**, which is the SAME windowed shell under a second name (see 1.6.0 below). Install
and run: `sudo pkg install gnome`, then `desktop`. Add `--headless
--events FILE --dump FILE` to render into a buffer and print the cells.

The package is genuinely extra: nothing in the base installation names it, and `tools/` is
in `tools/deploy.py`'s `SKIP_DIRS`, so no deploy can put the source on a machine -- which
is also why `tools/pkgs/` is where a host side package source belongs. The acceptance
asserts that the deployed tree has no path named `gnome`, and that the package was absent
before `pkg install` and present after. The package contains no third-party code; the
mechanisms described here are implemented in this repository against CraftOS's own APIs.

**1.3.0: Ubuntu's look, and opening is not a singleton.** `Desktop:open(id)` now creates a
new window on every call; it used to raise the existing copy, which made the desktop a task
switcher and made "two file browsers" impossible. The windows of one application are titled
`Files`, `Files 2`, `Files 3` -- numbered by creation order and renumbered when one closes, so
a lone survivor is `Files` again instead of a `Files 2` with no `Files` -- and the dump's
`WINDOW` lines still carry `id=` and `title=`, so two copies are distinguishable. Every piece
of per-window state is on the window (`win.state`, `win.tasks`, and the ROM window a Console
built), which the suite asserts by moving one file browser into `/demo` and reading the
other's path back: an application module holds no mutable state of its own. The task manager
lists windows, not applications, so it lists both copies.

The **workspace** is the single answer to "where may a window be": `desktop.WORK(w, h, dock_w)`
is everything right of the dock's separator and under the panel (x=5 y=2 47x18 on a 51x19
screen), and `default_geometry`, `move_window`, the overview grid and the drag all measure
against it. A window therefore cannot be parked over the dock or under the panel, and a drag
past the corner clamps to `(5,2)`, not `(1,1)`. The old bottom dash is **gone** --
`desktop.dash()` and `Desktop:dash_layout()` were replaced by `desktop.dock()` and
`Desktop:dock_layout()`, with no alias left behind, so there are not two dashboards to keep in
step. The dock is chrome: it is drawn in the desktop AND in the overview (Ubuntu's overview
keeps its dock), after every window, and it takes the click before any window does. A click on
an icon is a NEW window, and the dot under it is on while the application has at least one
window.

**1.4.0: the desktop can be the session the machine boots into.** psh stays the
default: a machine that sets nothing boots into the shell, and `desktop` inside a
session is the way in, with leaving the desktop giving psh back. `desktop --autostart
on` makes the NEXT boot start the desktop instead, `off` puts psh back, and `status`
says what the next boot will do. It is root only -- it decides what the machine
starts, and an account that could switch it has taken the machine from its owner --
so the console account is refused with a status of 1 and a message naming
`sudo desktop --autostart on`. The mechanism is deliberately small: the command
writes ONE generic key, `command=desktop`, in `/etc/session.conf`, and the base boot
script reads that key -- no package name anywhere in the base installation, which is
why the assertion that no base file names the package still holds -- runs it through
psh (so a package command resolves exactly as it does in a session) and ONCE per
boot, then starts psh as usual. A session command that raises or cannot run is
reported and falls through to the shell, so a removed package cannot leave a machine
that boots to a blank screen. The machine acceptance drives the switch for real: the
console account is refused, root writes the file, `status` reports `desktop`, and
`off` removes it again. The read side -- a machine that boots and really starts the
word in that file -- is verified by `tools/rpv-verify/_psh-boot.sh`, described under
1.5.0 below.

**1.5.0: many consoles, one terminal, one read.** The pump used to be a single
slot: a second Console's shell was refused with "a program is already being
pumped", so the desktop could run one windowed shell at a time. It is now a
**registry** (`desktop.pumps`, in registration order) and the machine's one
`os.pullEvent` is wrapped ONCE -- installed when the first pump starts anywhere in
the Lua state and restored when the last one ends -- with each call answered by the
pump whose coroutine is calling, and passed to the real machine for a puller that
belongs to no pump. `#desktop.pumps` is therefore how many programs are being
pumped right now, and each entry is that program's state (coroutine, task, window,
terminal target, request, answer, event count).

An event goes to exactly ONE pump, and the rule is stated in the code and pinned
by the suite: (1) the focused window's pump, if it is waiting for that event -- the
keyboard belongs to the window the operator is looking at, and a pump in a
background window is offered no key or char at all; (2) otherwise the other pumps
in registration order (oldest first), which is how a background shell still gets
its timers and rednet messages. A click stays the focused window's, and with the
overview up nothing is pumped.

`term.redirect` is global too, so the pump takes a terminal target (`opts.term`)
and re-asserts it before every slice of the program -- the terminal is one piece
of machine state that every coroutine shares, and a target set once at the start
would be replaced by another pump's redirect in between. Without it, console 1's
command output would
land in console 2's window as soon as console 2 redirected term last: the second
console would be a view of the first shell rather than a shell. Two consequences
are in the code as well: the Console creates its ROM window under the **desktop's**
terminal (`d.term_target`), never under `term.current()` -- which is the other
console's window once one is open -- and a pump that ends hands the terminal to the
most recently registered pump that still has a target, or back to the desktop when
none is left. Closing a window drops that window's pump, so a closed Console cannot
leave a wrapper installed for the rest of the session. The **Terminal** app was
deliberately unchanged in 1.5.0 (its meaning was then the whole-screen handover,
exclusive by definition, "the honest other shape rather than a second
implementation"); 1.6.0 replaces it with the same windowed shell as the Console --
see below.

One consequence an operator will meet, stated rather than hidden: while a
Console's shell has the focus, a key -- Escape, or the desktop's F10 -- goes to
the SHELL, not to the desktop, so a console window is closed with its `[x]`
control (a click is the desktop's event, keys are the focused shell's). The
machine acceptance closes the two consoles exactly that way.

The 1.5.0 round: `tests/batch10_check.lua` went 412 -> 451 assertions (a section
that opens two real Consoles over a faked ROM window API, drives keys to the
focused one, proves the background one is not fed, finishes one program while the
other keeps pumping, checks the wrapper was installed once and is restored only
when the last pump ends, and opens three Consoles for the numbering/titles). Ten
mutants were tried and **all ten were caught**: delivery ignoring the focus,
broadcasting to every pump, the fallback in reversed registration order, keys
reaching a background pump, the wrapper restored at the first pump end, the wrapper
installed per pump, a finished pump left in the registry, the per-slice terminal
re-assert removed, and the console's window built under `term.current()`. On the
machine, `tools/rpv-verify/_psh-desktop.sh` grew 89 -> 106 checks, including **two
Consoles at once**: both prompts drawn, `echo two` typed into the focused one and
`echo one` into the other, each ROM window read back with `getLine` and each
containing only its own command -- two independent shells in two windows with the
panel and the dock still on the screen. The dump line `PUMP active=` became
`PUMPS n active=.. peaks` plus one `PUMP <i> ...` line per program (the acceptance
greps `PUMP 1 active=true`).

**1.6.0: the window edge, and a Terminal that is a window.** One reported bug and
one design change.

*The clip.* Applications draw through `api.write/cell/fill`, and those used to call
the screen directly. The screen clips at the DISPLAY, not at the window, so a line
wider than the interior painted over the window's border, the window behind it and
the dock -- reported on a machine as "the text ran out of the window". The Console
was safe only because it sliced every line to its own width itself; every other app
was one long string away from the same bug. The clip now lives in
`Desktop:app_api()`, in the one function every app draws through, so a new app
cannot forget it: `write` keeps the columns inside the interior and drops the rest
(including a run that starts left of it), `cell` drops a cell outside the interior,
`fill` intersects its rectangle with the interior, and every dropped cell is counted
in `stats.clipped` -- also in the dump, appended after `term_asserts` so the STATS
line's prefix is unchanged. The window's own chrome was checked in the same pass:
the bottom border is cut to the window's width (so a window narrower than three
cells cannot draw its right end on the cell after it), a window with no cells draws
nothing, and `paint_error` writes only inside the interior with each line cut to its
width.

*The Terminal.* Through 1.5.0 the Terminal was the whole-screen handover: the
desktop released the display, `psh` owned it, and the desktop repainted when the
shell exited. That is honest and it is not a window -- the panel and the dock
vanish for the length of the session, nothing can be used next to it, and a full
screen program a shell starts owns the machine. The mechanism to do better already
existed, because it is the one the Console uses: a ROM window under the desktop's
terminal, plus the event pump answering the shell's blocking read, with
`term.redirect` re-asserted before every slice -- one global terminal is shared
by every pump, so it must be reclaimed for each program in turn. The shared
implementation is
`lib/gnome/apps/shellwin.lua` (`main(api, win, opts)` and `draw(api, win, opts)`,
with `opts.title` and `opts.banner`); `terminal.lua` and `console.lua` are thin
wrappers over it, so there is one shell, one pump and one "the shell left" state to
fix. The Terminal keeps its `>_` icon, its name and the first overview card, it no
longer writes "press ENTER to start a session", and it no longer calls
`handover()`: ENTER is the shell's own key, and when the shell leaves (when the
machine allows leaving) the window says "the shell left" instead of handing the
desktop away. `Desktop:handover` is KEPT -- a program that needs the whole terminal
still has that shape to ask for -- and the suite exercises it through a synthetic
application, so no shipped app is needed for that API to stay tested. One limit is
stated rather than hidden: the interactive shell refuses `exit` while `noexit` is
on (the default), so the machine acceptance proves the shell runs in the window and
a command typed there executes there, while "the window says the shell left" is
pinned on the PC side with a runner that returns.

*Terminal and Console are one mechanism with two names, and that is stated rather
than implied.* Keeping both was the deliberate choice over deleting the Console and
giving its card to the Terminal: the sixth card is what 1.5.0 shipped and what the
machine acceptance's two-console scenario (C2, C3) drives, which is how "two shells,
two windows, one event each" is proven on a real machine, while the Terminal is the
traditional name for the machine's shell, the dock favourite and the first card.
Deleting the Console would change labels, not behaviour, and would weaken that
evidence; the cost of keeping both is one name, not a copy of the code.

*The 1.6.0 round.* `tests/batch10_check.lua` went 453 -> 494 assertions: a section
of 17 on the clip (the body's last column still written, the cells right of the
window untouched, a cell one past the edge dropped, a write starting left of the
body losing only its outside part, a fill past either edge stopping at the edge, a
write and a fill below the body not reaching the bottom border or the desktop, the
same again at the screen's bottom right corner, `stats.clipped` growing for the
overflowing app and staying at 0 for one that draws exactly to its edges, and the
counter in the dump), the handover section rewritten (its 15 checks now run through
a synthetic app) plus 3 that pin "the Terminal does not hand the screen over", and
19 on the windowed Terminal (the pump is that window's, its ROM window is built
under the desktop's terminal, the pump is told which terminal it owns, two shells
side by side feed only the focused window, a backspace reaches the shell as a key
event, ENTER ends one and its window says "the shell left" while the other keeps
pumping, no handover anywhere, and the two app modules are wrappers over one shared
module that differ only in the name and banner they pass). Ten mutants were tried
and all ten
were caught: no x clip, no y clip, no clip in `cell`, no clip in `fill`, the clipped
counter never raised, the Terminal back to `handover()`, the shared module running
the shell without the pump, the pump not told its terminal, the "the shell left"
line dropped, and the Terminal wearing the Console's name and banner. On
the machine, `tools/rpv-verify/_psh-desktop.sh` went 106 -> 110 checks: the old
handover scenario is replaced by C1, which drives a real `psh` in the Terminal
window (a command typed at its prompt runs in that window's ROM window, read back
with `getLine`, with the panel and the dock still on the display, and
`screen handovers=0`), while C2 and C3 -- two consoles at once -- are unchanged.
Nothing in that acceptance calls `Desktop:handover`; the API is tested on the PC
side, where a synthetic app can be registered.

**1.7.0: readable units, a settings panel and a calculator that is a calculator.**
The report that started this round was "the settings and the calculator are a bit
abstract, the free space should pick its own unit, and the calculator UI needs
work" -- which was fair: the settings window was six lines of strings with two
clickable rows, and the calculator was a grid of labels that said 2097152 B on
one side of the machine and 320239B on the other.

*One kilobyte ladder, in one module.* `lib/gnome/fmt.lua` owns the unit
arithmetic: base 1024, B/KB/MB/GB, **no decimal on a byte** and exactly one on
every larger unit (`0 B`, `1 B`, `1023 B`, `1.0 KB`, `1025 B` -> `1.0 KB`,
`732.9 KB`, `1.0 MB`), and a value that would ROUND to `1024.0` is promoted
instead of printed, so one byte under a megabyte reads `1.0 MB` and not
`1024.0 KB`. Missing or impossible numbers are `?`, never 0, because 0 is a
claim. It also carries `percent` (one decimal, clamped, `?` when there is
nothing to divide by) and the three alignment helpers the two windows needed
(`fit` keeps the head with `>` for the tail, `fit_left` keeps the tail with `>`
for the head, `pad` widens without cutting). The settings panel's total/free and
the file browser's size column both go through it; no application appends `" B"`
by hand any more. The first version of the ladder was one unit behind (it
indexed the label table by the power of 1024 and not by the label), so 4 MB
printed as `4.0 KB`; the suite's known answers caught it before the round
ended, and the boundary values are now assertions: 0, 1, 1023, 1024, 1025, one
byte under a megabyte, a megabyte, five megabytes, a gigabyte, plus "no byte
count under a kilobyte has a decimal point" as a claim of its own.

*The settings window is a panel.* Three sections -- `System` (hostname, the
session's user, the screen, the clock), `Storage` (total, free, a bar, the
installed package count) and `About` (this package's version, the shell's) --
as key/value rows with one label column and one value column. Everything is
live and pcall'd: `os.getComputerLabel`, `perm.get_current_user`,
`fs.getCapacity`/`fs.getFreeSpace`, `pkg.list`, and the package version read
from the installed manifest (`?` / the source tree's constant when there is
none). The shell has no version module at all, so its version is read off the
banner line in the tail of its own source, once per window; not finding the file
is `?`. A body that is at least 36 cells wide puts the two halves of a section
side by side (ten rows, which is exactly the default window's interior); a
narrow one stacks the fields and scrolls them with the arrow and page keys, so a
12 column interior still reads and every field is still reachable. The bar is
drawn `[####----] 50.0%`: the filled cells are counted FROM the percentage the
line prints, so the bar and its number cannot disagree, and the suite reads both
off the screen and re-derives the length from the percentage. Two actions stay,
on the panel's last row: the panel colour (a real change of the desktop's own
palette) and log out. Nothing in the module is mutable at module level -- the
scroll position lives in the window's state, and two settings windows are
asserted to scroll independently.

*The calculator is a calculator.* A display row, right aligned, overlong input
cut from the LEFT (the newest digits are the ones that matter) with a `>` marker;
then AC and a backspace on a row of their own, then the 4x4 grid -- `7 8 9 /`,
`4 5 6 *`, `1 2 3 -`, `0 . = +`. Every key is an inverse block of cells two rows
tall, so a key is visible even where its label is not, and the key under the
pointer is drawn in the palette's brown while a key that was just pressed wears
the accent orange and goes out on its own (the desktop's clock is what expires
it, which is why a test can watch it happen). The geometry is one function of
the body size that drawing and hit testing both call; a narrow body shrinks the
keys to two cells instead of pushing them out of the window. The mouse and the
keyboard are the same presses: digits, `.`, the four operators, ENTER for `=`,
backspace, and `c`/`C` for AC, with the desktop's back-out key (F10) deliberately left to it. The
semantics are immediate execution, left to right: **2 + 3 * 4 is 20, not 14** --
no operator precedence, stated in the header comment, in this paragraph and
pinned by an assertion that checks the 20 and the absence of the 14. Dividing by
zero shows `error: divide by zero` in the error colour and stays usable (AC or a
digit starts again), and a digit typed after `=` starts a new number rather than
appending to the answer.

*One capability the desktops needed for this.* A pointer move used to be ignored
outside a drag, so a hover could not exist. `mouse_move` is now offered to the
focused window's application (`stats.moves`, appended to the STATS line after
`clipped`, so the line's prefix is unchanged); it is not a drag, it does not
move the focus, and an application that does not care ignores it.

The round: `tests/batch10_check.lua` went 494 -> 582 assertions. The old
calculator/settings checks were re-pointed at the new layout (the display's `10`
moved from column 6 to 42, the `7` key from row 7 to row 6, the `+` key from
(10,24) to (12,33), the settings title row from `System settings` at 4 to the
`System` section at 4 and the two actions from rows 8/9 to the last row), and
the new sections are the unit ladder (23), the settings panel (35) and the
calculator (29). Ten mutants were tried and **all ten were caught**: the
kilobyte boundary moved to 1000, a byte printed with a decimal, the free space
printed as raw bytes, the bar always full, the bar counted from a different
percentage than it prints, divide-by-zero answering instead of reporting, `=`
leaving the answer in the digits, no hover highlight, no pressed highlight, and
a section title dropped. One of them exposed dead code rather than a test gap:
the first "=" mutant survived because the calculator carried a `fresh` flag that
nothing could observe -- the digits being emptied is what starts a new number --
so the flag was deleted and the mutant that keeps the answer in the digits is
the one that bites. `tools/rpv-verify/_psh-desktop.sh` went from 111 checks to
**136**, and the machine now drives both windows ITSELF: the Settings card is
clicked in the machine's own overview and the panel is read off the window's
cells -- the three section titles, `total` and `free` with a unit, the bar and
the percentage it is counted from, the installed package's version and the action
row -- and the window closes with its own `[x]`; the Calculator card is clicked
and the machine's keypad is typed at, so `2+3=` answers 5, a mouse click on the 7
key puts 7 in the display, `1/0=` reports the division and a digit typed after
`=` starts a new number. Both read the window's own BODY (columns 6..43 of the
default window), so the dock's icon beside it is never mistaken for the answer.
That closes the gap this paragraph used to admit: before it, every settings and
calculator cell had only ever been asserted through the PC suite's buffer.

**1.7.1: leaving the desktop ends at psh.** The report was concrete: on a machine
whose boot script starts the desktop directly, leaving it -- F10 with nothing
open, or the settings panel's log out -- ended at the **CraftOS prompt**: the
machine's own system gone, which is exactly what "log out" must not do.
`Desktop:quit` was and remains the single exit; what was missing was the
landing. `desktop.landing` decides it from a FACT instead of from a guess about
the caller: psh marks every command chunk it runs with `__psh_command`
(`usr/psh.lua`, in the same fresh command table the require fix introduced), so
a desktop that IS a shell command returns to that prompt -- starting another
shell there would nest one inside another -- and a desktop started by a boot
script, or from the CraftOS prompt, gets `/usr/psh.lua` started for it. A shell
that cannot start is reported as `shell-failed` and the command exits 1 rather
than pretending to have landed, and the same landing runs after an INTERRUPTED
desktop: Ctrl+T ends a desktop too, and the operator must not fall out of the
system by that door either. The settings panel keeps its log out action -- it
leaves the desktop, its `Desktop:quit("settings")` is pinned -- and now lands at
psh; no window has a way to shut the machine down or reboot it (`batch10` scans
the package for `os.shutdown` / `os.reboot` / `os.exit`). `tests/batch10_check.lua`
582 -> 595: the landing's seven answers, the command's four wiring facts (it asks
the landing, passes the shell's mark, names `/usr/psh.lua`, and asks on both exit
paths), and the scan. Measured end to end on
the machine the report came from -- a demo boot script that starts the desktop
directly, with the F10 an operator would press queued at boot: the log reads
"the desktop was left" and then psh's banner and `admin@cc-0:/$`, where the same
leave used to end at the ROM prompt.

**1.7.2: log out ends the psh session, and nothing ends the machine.** The
settings panel's log out action used to quit the desktop the way F10 does, so
the operator was back at the same psh prompt, still logged in. It now asks the
shell for what a typed `logout` does: `bin/desktop.lua` writes
`/var/lib/.logout` (only when a SHELL started the desktop; started anywhere else
there is no session to end), the interactive loop in `usr/psh.lua` honours it at
the session boundary -- the same place a typed `logout` is decided -- deletes the
request and ends the session, and the boot script's watchdog starts a fresh psh.
That is what "any exit ends at psh" means: no path out of the desktop can leave
the machine outside its own system. `tests/batch10_check.lua` 595 -> 598 pins the
three facts (the action quits with reason `logout`, the request is written and
guarded, the shell looks for it). **1.7.3** takes the product name off the
wallpaper: the background keeps its one shortcut line ("press o for the
overview") and no longer says what the software is called.
`tests/batch10_check.lua` stays at 598 (the old title assertions became "no
product name on the wallpaper" and "the hint is on its own row"), and the
machine acceptance asserts the hint column instead of the title.

**1.7.4 to 1.7.6: the wallpaper is a real sweep.** The owner asked for a smoother
background. Four flat bands of ROM colours are all the stock palette can say, so
the wallpaper now redefines the six slots no chrome uses -- purple, magenta,
green, pink, lightBlue and brown -- with `term.setPaletteColour`, to six real RGB
points of Ubuntu's purple to orange sweep. Measured on the machine around a
desktop run: while it is up the six slots read back
`0.294/0.165/0.388` ... `0.976/0.502/0.114`, and after it is gone they are the
native colours again (`0.698/0.400/0.898` ...). One redefined slot per row and no
dithering: the 4x2 cell blend of 1.7.4/1.7.5 was still visible as a pattern,
because one cell on a 51x19 screen is a large block. The slots are put back when
the desktop is left (quit, an interrupt, or a handover), and the restore reads
`nativePaletteColour` rather than `getPaletteColour`: on CraftOS-PC 2.8.3 an
unset slot answers the latter with `#191919` (0.098), so restoring from it would
have painted the shell's prompt slots dark grey -- a machine that looks broken
after leaving the desktop. That was found by reading the palette off the real
terminal, not by the suite; `tests/batch10_check.lua` 599 -> 612 (six slots
defined, one install per run, a row is one slot, the fallback for a screen with
no palette, restore on quit, and the native-colour restore),
`_psh-desktop.sh` 137 -> 139 (top and bottom rows are different slots, a row is
one slot), and `_psh-boot.sh` still passes 27 checks.

**1.7.7: the Terminal bug, and a text editor.** Two things the owner asked for in
one round. The bug first: on a graphical machine opening the Terminal showed a
COPY OF THE DESKTOP inside its window and typing looked dead. It was not the
shell. Since 1.6.0 a pumped shell redirects the global `term` to its own
invisible window, and the term API's blit follows that redirect -- while the
desktop was painting through the API. So every frame the desktop drew after the
shell had been fed went into the shell's window (measured: its lines were screen
rows 1..10 -- "Activities", the dock, the title bar) and the shell's prompt was
overwritten. The headless suite could not see it: it renders into a buffer and
never touches term. `desktop.new` now builds the screen on the TERMINAL OBJECT
(`screen.term(d.term_target)`), so the desktop's drawing is independent of who
redirected the API. `tests/batch10_check.lua` pins it by sabotaging the global
term and demanding the desktop still paint its own terminal, and the machine
acceptance gained C1R: the same shell on the REAL terminal, asserting that the
shell window holds "echo hi"/"hi" and NOT the panel.
The editor: a new `gnome.apps.editor` window over a line buffer -- arrows,
Home/End, PageUp/PageDown, Enter, Backspace, Delete, Tab and printable `char`
input; Ctrl+S or F2 saves (F2 because a build cannot always tell that Ctrl is
held). The window names the file, shows row:col, marks unsaved changes, and says
what it saved or why it could not. Files gained a selection row, with Enter
acting on it; on a file it calls ONE documented seam,
`api.open("editor", { path = ... })`, which `Desktop:open(id, opts)` now passes to
the app's open hook. The machine acceptance writes a file, lists it in Files,
presses Enter on it, types a character, saves with F2 and asserts the file's own
bytes; `tests/batch10_check.lua` 613 -> 629 and `_psh-desktop.sh` 141 -> 144.

**1.7.8: one desktop at a time.** The Terminal and the Console run the shell in a
window, so `desktop` typed at that prompt started a second desktop inside that
window -- its frame was drawn into an invisible window of the outer desktop, two
pumps competed for one event stream, and there was no way back the operator could
see. The command now refuses when its terminal is not the machine's own screen:
`desktop.needs_whole_screen(term.current())` asks the one fact that separates a
window from the machine's screen: measured on CraftOS-PC 2.8.3, the machine's own
terminal has no `getLine` (nil on `term.native()` and on `term.current()` when that
is the screen), while every `window.create` window has one -- so a terminal that
answers `getLine` is refused with the reason and status 1. Identity would have been
wrong: also measured, `term.current()` is NOT `term.native()` even on the machine's
own screen, and the first version of this guard refused the desktop everywhere (the
boot path caught it at once). A machine where nothing answers is allowed, because a
wrong refusal would make the desktop unreachable. `tests/batch10_check.lua`
635 = 629 + 6 pins the decision (window, own screen, no-answer) and the command
source order (the guard is before `run_interactive`); the machine acceptance types
`desktop` into the Terminal window and asserts the refusal, no second desktop
window, and that the window keeps its one shell (`_psh-desktop.sh` 147).

**1.7.9: Files scrolls, and the editor wraps, undoes and finds.** Two things the
owner asked for after using 1.7.7. Files showed ten rows of a directory and the
rest was unreachable: it now has a scroll offset that follows the selection
(arrows, PageUp/PageDown, Home/End), `files.visible` is the single function that
keeps the selection on screen, the path line carries `sel/total` when there is
more than a windowful, and a click is resolved through the same offset (the
`<..>` row included). The editor gained the three things a text window needs:
*soft wrap* -- `wrap_layout` turns the logical lines into display rows and
inserts nothing, so a 100 character line in a 38 column body is three display
rows while saving writes the characters that were typed, and arrows move by
DISPLAY row so a wrapped line behaves like the eye expects; *undo* -- one
snapshot per edit, capped at 200, Ctrl+Z or F4 (F4 because a build cannot always
tell that Ctrl is held); *find* -- Ctrl+F or F3 opens a prompt that takes the
characters (they do not reach the buffer), Enter finds the first occurrence, F3
the next and wraps. `tests/batch10_check.lua` 635 -> 656 (the wrap layout and the
cursor mapping, F4/Ctrl+Z undo with the empty stack, the find prompt/first/next/
wrap, and Files scrolling: the selection past the window, `sel/total`, a click on
a scrolled row, end and home); `_psh-desktop.sh` 147 -> 152 drives the real
machine: 60 typed characters are 38+22 cells on two display rows and all 60 are
in the file, F4 undoes before F2 saves, and F3 + a query + Enter puts the cursor
on `world` at row 2 column 1 without touching the document.

**1.8.0: one click selects, two clicks open.** Clicking a folder in Files used
to descend immediately, so a double click descended twice and a second click on a
file was a no-op -- the row just stayed a selection block. The convention is now
the desktop one: one click selects the row, two clicks within half a second OPEN
it (a folder is entered, a file opens in the editor, `<..>` goes back), and the
time source is the desktop clock (`api.desktop.now`, which only moves on ticks),
so a headless run drives two clicks without waiting. Enter still opens the
selected row. `tests/batch10_check.lua` 656 -> 665 (one click selects without
entering, a second click much later does not open, two quick clicks enter, one
click on a file opens nothing, two open the editor, `<..>`), and the machine
acceptance now double clicks both the folder and the file.

**1.8.1: the selection is readable, and the wallpaper hint is legible.** Two
cosmetic reports. The Files selection was black text on an orange bar, and the
owner could not read the names through it: it is a gray band behind white now,
and -- the reason the first attempt at this looked broken -- the background is
passed to the text write as well, because api.write with no bg paints the DEFAULT
background and punched black holes in the band behind every character. The
wallpaper hint ("press o for the overview") was gray on a coloured band: it uses
the wallpaper's own foreground (white) now, the one colour already known to be
legible on every band. `tests/batch10_check.lua` 665 -> 666 (the hint's colour,
and the band: gray behind white with the name still in the row).

**1.8.2: the double-click window is two seconds.** A double click stopped opening
anything on the machine: the window was half a second of the DESKTOP clock, and how
many ticks pass between two human clicks depends on the machine -- enough of them
in the slow case and the pair fell outside. The window is 2s now, which still
cannot confuse two separate clicks (one click only selects, and moving to another
row resets the pair); `tests/batch10_check.lua` 666 -> 667 adds the slow (one
second) double click that must still enter the folder.

**1.8.3: the pair is consecutive clicks, not a time window.** Going back up with
`<..>` still failed on the machine: the 2s window was measured on the desktop
clock, and how many ticks pass between two clicks of one double click is not
something this app can know (it was 0.5s, then 2s, and the second click still
fell outside on a slow machine). The rule is now what it should have been from the
start: the SAME ROW clicked twice with nothing else in between -- any click on
another row, any key, and entering or leaving a directory reset the pair, and no
clock is read. Two clicks on different rows can never pair, so navigation cannot
open something by accident. `tests/batch10_check.lua` stays 667, with the two
window-era checks replaced: "a click on another row in between starts the pair
over" and "a slow second click still enters the folder (no clock is consulted)".

**1.8.5: the back-out key is F10, because Escape never reaches the machine.** The
desktop's one "back out" key -- leave the overview, close the focused window,
leave the desktop -- was the ROM's Escape code (1), and the editor leaned on the
same key to leave its find prompt. On the platform this package actually runs on
that key does not exist: Minecraft keeps ESC for its own menu and never delivers
it to the computer, so `keys.escape` is nil and both branches were dead code (the
lesson the BIOS menus learned, in `lib/bios.lua`). The key is now **F10 (LWJGL
code 68)**: one of the function keys the ROM does deliver, unbound in vanilla
Minecraft, and letterless, so it cannot be typed into a text field by accident.
The editor leaves its find prompt with **F9 (67; an empty query plus Enter still
closes it)**, because F10 is consumed by the desktop before an application sees
it. `tests/batch10_check.lua` 677 -> 689 pins the three depths, the `f10` exit
reason, the desktop consuming the key instead of forwarding it, the editor's F9,
and a source scan that no package file still compares against `KEYS.escape` or
the ROM's escape code. On the machine, `_psh-desktop.sh` drives the same ladder
with key 68.


One defect was found while doing this and it lives outside this package:
`pkg.update` in `lib/pkg.lua` took the next message on the channel as the answer
to its "list" request, so a reply the install's FETCH left in the queue was
accepted as an index and saved as "0 packages" (measured three times as
`server index shape=a leftover fetch reply (ok=true)`). It is fixed now: every
request carries an id, the repository echoes it, and an answer that is not this
request's is ignored while the wait goes on under one deadline -- the acceptance
asks ONCE (`server index attempts=1`) instead of up to three times. Section 2 has
the mechanism, and the duplicate download that pairing exposed is fixed there
too.

**The boot read is verified now, not only pinned as source text.**
`tools/rpv-verify/_psh-boot.sh` deploys the project's own tree with
`tools/deploy.py --with-etc`, so `/startup.lua` on the machine is the real file
(asserted byte for byte), boots it twice, and reads the screen through an observer
passed with CraftOS-PC's `--script`: a file that runs **before** `/startup.lua` in
the same Lua state, wraps `term.write`/`term.blit` to record every string with its
row, column and colours, and queues one F10 key event once the desktop has
painted (a headless machine's stdin is not a keyboard -- measured; an event queued
from inside the machine is the only way to type into it). Boot one, with no
`/etc/session.conf`, lands on psh's banner and prompt and never draws a panel. Boot
two, with the one key `--autostart on` writes, paints the panel at row 1 column 1
and the dock's `>_` at row 2 column 1, then the F10 leaves the desktop, the boot
script prints "the session ended; starting psh", and psh's banner and prompt follow
-- 27 checks, `RESULT psh-boot=PASS`. The gnome package is pre-staged into
`/usr/pkgs` (with the bins registry the installer writes) because a headless boot
cannot run `pkg install`; the install path itself is `_psh-desktop.sh`'s subject.

**Everything it draws goes through an injectable screen** (`lib/gnome/screen.lua`), because
**`term.getLine` does not exist on CraftOS-PC 2.8.3**: a cell cannot be read back off a
real screen, so both the PC suite and the machine acceptance render into a buffer that
keeps character, foreground and background per cell. The headless path is a documented
mode, not a test hook, and `desktop.run(screen, events)` returns the screen it drew into.
`tests/batch10_check.lua` holds 689 assertions and `tools/rpv-verify/_psh-desktop.sh` runs
152 checks on the machine: it builds a repository directory from the package source, serves
it with `pkgserver.lua`, installs it on a second computer with the machine's own
`sudo pkg install`, drives the desktop with synthetic mouse events and asserts on the
dumped cells, and proves the Terminal runs a real `psh` **inside its window** (a command
typed at that window's prompt is in that window's own ROM window, read back with `getLine`,
with the panel and the dock still on the display). The 1.3.0 rework
tried 17 mutations against the suite: 16 were caught, and the one that survived was
**equivalent rather than a gap** -- filling the overview across the whole screen instead of
the workspace changes no cell at all, because the dock and the panel are drawn over every
cell that could differ -- so it was replaced with one that moves the grid origin, which is
caught. The earlier round of 43 mutants on the 1.1/1.2 features still stands: 42 caught, and
the one that escaped -- a tick resuming a pumped program -- was caught only after an
assertion was added that counts the resumes, which is the honest way to say that the guard
existed before its test did.

**It schedules its own tasks, and it has an overlay layer.** CraftOS is single threaded and
its `parallel` API is itself a coroutine scheduler, so "another process" on this machine can
only mean another coroutine: an application that defines `main` (or `task`) is run as one,
started when its window opens and resumed by the desktop when it is due. A task yields
through `api.task`: `sleep(s)` waits for the clock, `wait_event()` waits for an event,
`yield()` waits for the next tick, `spawn(fn)` starts a second task for the same window.
**The clock is injectable for the same reason the screen is** -- a sleep that can only be
observed by waiting is not testable -- so `now` moves only on a tick: the interactive loop
arms `os.startTimer(step)`, and a headless run is handed `tick` events (`tick`, or
`tick 0.5`, in the event file the acceptance already writes). A raise inside a task is
answered by `coroutine.resume` and recorded -- on the task, on its window and in a counter --
rather than ending the loop, and closing a window stops its tasks, so a resumed task cannot
draw into a window that is gone. An application that only defines `main` is an application:
the registry accepts any of `open`, `draw`, `event`, `main`, `task` as "the spec IS the app".

An **overlay** is a per-frame hook with its own event hook: drawn after the panel -- so a
modal can cover row 1, which no application can do, because the frame paints the dock and the
panel after every window -- and offered every event before the desktop sees it, topmost
first, eating it only by answering truthy. A raise inside an overlay is contained like an
app's, and an overlay is owned by the window that asked for it, so closing that window drops
it. The layer is this project's answer to a property of the frame: the frame paints the dock
and the panel after every window, so no application can cover row 1, and a menu or a modal
that must sit above everything needs a hook that runs after the panel and sees events before
the windows do. The task manager that ships with the package is what makes the scheduler
visible -- its body prints `windows`, `tasks` and the tick count its own task was resumed
for -- so "the machine multitasked" is a cell on the machine's screen and not a claim about
the PC suite.

**A blocking program and the desktop share one run (the pump), and the desktop takes its
terminal back.** Both follow from the machine having one global read and one global
terminal. The **pump** runs a program
that blocks -- one that calls `os.pullEventRaw` for a line, which is exactly what `psh` does
-- as a task: the wrappers are installed for the length of the call, answer only the pumping
coroutine, and the program runs in a coroutine of its own, because a yield inside a `pcall`
is "attempt to yield across C-call boundary" on 5.1/LuaJIT; the waiting is done by the pump
loop at the task's level, and the program's raises come back through `coroutine.resume`,
which the scheduler already contains. A pumped program is offered an event only while its own
window has the focus and -- unless it asks -- never a mouse event, so another window stays
reachable while a shell sits at a prompt; the overview takes the keyboard back while it is
up, so one window cannot hold the desktop hostage. `reclaim_terminal()` is the other
mechanism: a program that redirected `term` and then died would leave the desktop writing
into a window that is gone, so the desktop puts its own target back after a pumped program,
after the full-screen handover, and at the top of every interactive iteration.

With those, the sixth application is real: **Console** creates an invisible ROM window under
its interior, redirects the shell's `term` into it and copies its cells out with
`window.getLine` every frame. The machine acceptance proves it end to end -- it clears the
project's `_G.__PSH_TEST` hook (which makes `psh` publish its test table and return instead
of entering a session), types `echo hi` into the window and asserts that the output reached
row 6 **while the panel and the dock are still on the screen**: a real shell, a real command,
inside a window, with the desktop alive. Bounded by the machine and stated, not smoothed
over: the pump may run many programs at once, but the machine has one global read and one
global terminal, so the pump hands the terminal to a program before each of its slices,
keys only reach the focused window, and a command that blocks without reading (`sleep`)
still stops the frame for as long as it runs.

 The ROM keeps
`require`, `package` and `shell` in the environment it hands a program
(`rom/programs/shell.lua`, `createShellEnv`) and **not in `_G`**, while `loadfile` gives a
chunk the default environment. So measured on CraftOS-PC 2.8.3 an external command loaded
by the shell saw `require` as **nil**:

```
psh: w: runtime error: /usr/cmd/w.lua:12: attempt to call global 'require' (a nil value)
```

**Every external command of this project that loads a module was therefore broken on a real
machine** -- `usr/cmd/w.lua`, `who.lua`, `last.lua`, `lastlog.lua`, `chmod`, `chown` and
`chgrp` -- while the PC suite stayed green, because `tests/cc_env_stub.lua` provides a
global `require`. That is the same trap as `fs.makeDir` returning `true` where the ROM
returns nothing: **a stub more generous than the hardware turns a machine failure into a
green test.** `usr/psh.lua` now runs a command file in a fresh environment whose `__index`
is the shell's own (`setmetatable({}, { __index = getfenv(1) })`), which is what the ROM
does for a program it starts and which also keeps a command's own globals out of the
shell. Gate-verified: `tests/batch10_check.lua` pins those lines, and the machine
acceptance asserts both that a command chunk sees the ROM's `require` and that `w` runs.

* **A check worth repeating**: CraftOS-PC 2.8.3 reports `_VERSION = Lua 5.2`, and
  `setfenv`/`getfenv` were REMOVED in 5.2 -- so the fix was expected to be a no-op until
  measured. They are present, as a 5.1 compatibility layer, and `pcall` guards the call
  anyway. The lesson stands: on this platform, `_VERSION` does not tell you which
  functions exist.

**Not verified, stated plainly**: the interactive desktop was never driven by real
keyboard or mouse input (the acceptance injects synthetic events, and `term_resize` on the
machine is covered only by the buffer test); the `pkg install` ran as root through a primed
sudo cache (`lib/sudocache.lua`) rather than a typed password, because a headless boot has
no keyboard -- the refusal for an ordinary account IS verified; installing a *second*
package, upgrading or removing `gnome`, and installing on a 1 MB machine were not tried
(the acceptance raises `computerSpaceLimit` to 8 MB for tree plus package); and one mutant
was equivalent rather than killed (`if ok and type(mod) == "table"`, because a failed
`require` returns a string either way), so it was replaced with one that bites.

### 6.10 Disk space preflight for every write

A writer asks how much room the target filesystem has BEFORE it creates or
truncates anything. The criterion is one line: refuse when the bytes to write are
GREATER than the free space reported for the target; equal is allowed. The
refusal names both numbers -- `not enough space: need 48000 bytes, 1000 free` --
and the command fails with status 1, the file untouched.

* **No API, no refusal.** `fs.getFreeSpace` is not in every CraftOS build and a
  program can take it off the table. A machine that cannot answer the question
  must not be turned read-only, so a missing or broken answer means "allow" and
  the writer behaves exactly as it did before this check existed. The module says
  so at the top (`lib/space.lua`).
* **Measured, not assumed.** On CraftOS-PC 2.8.3 (2026-10-17, probe script via
  `--headless --script --mount-rw`) `fs.getFreeSpace` exists, accepts a
  directory, a file, a path that does not exist or `""`, and answers the FREE
  BYTES of the volume: 224410443776 for the emulator's host disk, 0 for `/rom`.
  It is not KiB and it is not per directory. `/rom` answering 0 is why a
  never-written path still gets a truthful answer.
* **What is wired**: both shell redirections (`>`/`>>`, `2>`/`2>>`; the size of a
  stream is unknown when it is opened, so the honest test there is "not already
  full", one byte), `cp` (all sources measured first, one tree total, so a tree
  that cannot fit writes nothing), `ln` (a byte copy on CraftOS), `sed -i` and
  `tee` (the new text is known exactly), `tar` create and extract, the package
  unpacker (`lib/pkg.lua`, the moment a fetched set reaches the disk), the three
  transfer landing sites (`rget`/`rpush` receiver and `netd`: the size is in the
  ready/request, so a transfer that cannot fit is refused before the first block,
  and again with the bytes that actually arrived before the file is truncated),
  and the desktop's editor save.
* **Two limits, stated rather than hidden.** It is a PREFLIGHT, not a
  reservation: CraftOS cannot hold the space, so another program can take it
  between the answer and the write and the write can still fail. And a copy that
  overwrites existing files is counted at its full size, which can refuse a copy
  that would have fitted once the old bytes were freed -- refusing is
  recoverable, half a tree is not.
* **Why it is worth the code**: on a full disk `fs.open(path, "w")` SUCCEEDS and
  truncates, and the following write fails. The old file is gone and the new one
  was never written, with no message that says why.

* **Two things the PC suite could not see, found by the probe.** A byte count
  cannot be printed with `%d` on this build: `string.format("%d", 224476971009)`
  raises "bad argument #2 (not a number in proper range)", so a free space above
  2^31 bytes -- every real disk -- would have turned a refusal into an error. The
  message uses `%.0f` now. And `fs.copy` on this ROM returns NOTHING on success
  (the stub returns true) and RAISES when the destination exists, so
  `if not fs.copy(...)` made every SUCCESSFUL copy report status 1 on a real
  machine; cp now pcall's it. Neither was visible to the emulated filesystem --
  the same "the stub is more permissive than the hardware" shape as `fs.makeDir`.

Verified by `tests/batch_check.lua` (the three states of the check with an
injectable `fs`, `cp`/`tee`/redirect refusals that leave the file untouched),
`tests/batch10_check.lua` (the editor's status line) and `tests/batch8_check.lua`
(a transfer whose receiver has room for half a block), 9 mutants, and a
machine-side probe.

---
---

## 7. Machine behaviour before and around the shell

Five properties of the machine itself, all added in one batch. What they have in
common is that they decide how the computer behaves when the shell is not the thing
in charge -- at power on, while a command runs, and when someone tries to leave.

* **The boot sequence is wrapped in `xpcall`, so a crash is contained and
  explained.** `startup.lua` ran `shell.run` under `pcall`, which reports only the
  error message. The handler now adds a `debug.traceback` (guarded by `pcall`,
  because `debug` is optional in the ROM -- the same guard `lib/rpvnet.lua` uses),
  so `/var/log/watchdog.log` names the line and module that raised instead of just
  the message. The handler is written to be incapable of failing: it runs while the
  stack unwinds, so an error inside it would replace the real error with a
  confusing one.
* **A BIOS-style setup screen, opened by DEL in the three seconds before boot.**
  `lib/bios.lua` follows the firmware shape: a short window ("Press DEL to enter
  SETUP"), then the boot carries on. Missing the window is the normal case.
  BACKSPACE opens it as well as DEL, because the CraftOS console often has no full
  keyboard and refusing it would make the screen unreachable on the hardware that
  needs it most. The same screen is reachable from the shell as `bios`.
  * The password is **separate from a login password**, in `/etc/bios.conf`, and
    that is load bearing rather than tidy: this module runs *before* the shell and
    before the user database is necessarily parseable, so depending on
    `/etc/passwd` here would make the setup screen unavailable exactly when the
    machine is broken.
  * `ask_password=1` makes the machine refuse to start the shell at all until the
    password is given. Off by default: a machine that will not boot without a
    password is one that cannot be recovered by reinstalling the shell, which is a
    serious thing to turn on by accident.
  * The screen changes the two rules below, writing through `lib/protect.lua`, so
    the screen and `set -o` cannot disagree.
* **`set -o noexit`: the shell may not be left, by default.** Enforced at the
  SESSION boundary (`execute_line`), not in the `exit` built-in, and the
  distinction is load bearing: a script ending in `exit 3`, and `psh -c 'exit 3'`,
  both use `exit` to return a STATUS, and the watchdog fires scheduled tasks that
  way. Refusing exit in the built-in would break every one of them. What is refused
  is a session ending; the flag is set only by the interactive loop, and the test
  hook lets a suite say which of the two it is simulating.
* **Ctrl+C stops the running command, the way it does on Linux.** CraftOS is single
  threaded and cooperative, so there is no signal to deliver; what is possible is to
  interpose on the one place a cooperative program gives control back,
  `os.pullEvent`/`os.pullEventRaw` (`lib/interrupt.lua`). While a command is in the
  foreground, a Ctrl+C key event raises the same `"Terminated"` error the ROM raises
  for Ctrl+T, which `is_interrupt_error()` already matches -- so the existing INT
  trap and the 130 status work with no second code path. At the prompt the layer is
  off, so Ctrl+C keeps its old meaning (discard the half typed line).
  * The filter is applied by the wrapper, not passed through to the real function,
    and that is the point: `os.pullEvent("char")` drops key events before the caller
    sees them, so a program waiting on characters would be uninterruptible
    otherwise. There is an assertion for exactly this case.
  * **What it cannot do, stated plainly**: a tight CPU loop that never calls
    `pullEvent` cannot be interrupted. That is a property of a cooperative
    scheduler, not a gap here -- the interpreter is inside the loop and nothing else
    can run. Linux can interrupt such a loop because the kernel preempts it;
    CraftOS has no kernel.
* **Boot files are protected by default (`set -o bootguard`).** `lib/protect.lua`
  refuses a write to `/startup.lua`, `/firstboot.lua`, `/usr/psh.lua` or anything
  under `/lib/` unless the operator has turned the guard off. The list is explicit
  rather than "all of /lib", because a package upgrade is legitimate and installs
  into `/usr/pkgs`. The check runs in `guard_write`, the one path every writer goes
  through, so no individual command can forget it.
  * A refused write **fails** (status 1) instead of reporting success. That was a
    real bug found by the probe: the message was printed but the status stayed 0, so
    a script carried on as if the write had happened. The same gap existed in `cp`,
    which returned nothing at all on a refusal.
  * Both `bootguard` and `noexit` are machine rules in `/etc/boot.conf`, changed by
    a root-only `set -o`/`set +o`, and they persist across a reboot. A persistent
    option is deliberately **not** saved and restored around a script: its authority
    is the file, and a script that turned the guard off as root must not have it
    silently turned back on at the end.
* **A refusal is a refusal: ask before opening, and a crash is a failing status.**
  Measured on a guarded machine, where the fs table is wrapped and a refused
  `fs.open` answers nil: four built-ins read that answer wrongly. `touch` did
  `local f = fs.open(p, "w"); f.close()` and the whole line died with "attempt to
  index local 'f'"; `run()` printed the error but left the status alone, so `$?`
  still answered what the line *before* the crash had answered (0); `mkdir` threw
  `fs.makeDir`'s answer away (it returns nothing even when it works) and reported
  success; and `cat` called a file it had been refused "no such file". All four now
  ask first and then report: `touch` and `mkdir` consult `perm.can_write` and answer
  "permission denied" with status 1, `mkdir` judges success by `fs.exists`, `cat`
  separates "exists but cannot be opened" from "really absent", and `run()` sets
  status 1 for a command that raised (the interrupt's 130 and exit/return keep
  their own statuses). `lib/danger.lua` now only takes the wildcard branch for a
  token that really carries `*` or `?`, so `rm -rf /usr` names the system directory
  with the branch that was unreachable before. `lib/osguard.lua` marks the fs table
  it wrapped, because the ROM gives every program its own package table: a second
  program's `osguard.installed()` used to answer false on a machine where the guard
  was demonstrably installed, and its `install()` wrapped a second layer.
  * Evidence: `tests/batch_check.lua`, section "a refusal is a refusal" plus the
    blacklist section (39 assertions; 11 mutants, all caught -- each built-in's old
    behaviour, the missing status, `fs.makeDir`'s return value, the wildcard strip
    and both osguard regressions). On CraftOS-PC, a probe typed the commands at a
    real prompt: `touch /usr/x` and `mkdir /etc/x` answer "permission denied" with
    status 1, `cat /etc/shadow` says "permission denied" (not "no such file"), `$?`
    is 1 after a command that raised, and `rm -rf /usr` says "on the system
    directory".
  * The acceptance script had a stale assumption this exposed: `usr/psh.lua` hands
    a console that was left as root back to the machine's level 1 account
    (`console.claim`), so writing `root` into `/etc/current_user` did **not** make
    a root session, and the two "root can create ..." checks were passing only
    because `touch` never asked the permission database (the guarded fs had cached
    root at boot). `_psh-perm.sh` now gives that account level 0 for its second
    boot -- the claim looks for a non root level 1 account -- so the boot really is
    root, and its prompt ends with `#`.
* **Boot order: the ROM's "boot from a disk's startup" is turned off.** This is a
  ROM-level hazard that `lib/protect.lua` **cannot** defend against, and finding it
  corrected an earlier claim in this roadmap. CraftOS reads `/.settings` at power
  on, and `rom/startup.lua` consults two keys *before* running anything of ours:
  `shell.allow_startup` (run the machine's own startup) and
  `shell.allow_disk_startup` (run a startup found on an attached disk). Both default
  to true. The second is not an addition but a **replacement** -- the ROM assigns
  the disk's scripts to `tUserStartups`, overwriting what it found in the root:
  * the shell never starts and nothing in this repository runs, so `bootguard`
    (which lives inside `startup.lua`) is not on the path at all;
  * the defence is therefore the ROM's own switch, written to `/.settings` **before
    the next boot**. `/.settings` ships with the installation so the *first* boot is
    safe, and `bios.enforce_rom_settings()` re-applies it at every boot, so deleting
    the file or hand-editing it does not leave the machine open. The BIOS screen
    exposes both keys.
  * The ROM's real default for `shell.allow_disk_startup` is `commands == nil`
    (CraftOS-PC `bios.lua`), so a Command Computer defaults it OFF. `bios.rom_default`
    checks the same global, and reports what the ROM *would* do rather than what the
    file says -- an absent key means "wide open", not "not set".
  * **The file format is not negotiable, and the first attempt got it wrong.**
    `textutils.unserialize` prepends `"return "`, so `/.settings` must be a bare
    table literal: a file starting with `return`, or carrying a comment, parses to
    `nil`, the load reports failure, and every key silently keeps its ROM default.
    A file that looks right and does nothing is the worst outcome here, because the
    machine appears protected. This was caught only by running it on the emulator;
    the assertions now pin the shape (`{` first, no `--`).
* **The whole CraftOS settings API is reachable from the screen.** The ROM's own
  `set` command is the editor for `/.settings`, and it needs a working shell --
  which is exactly what a broken machine does not have. The screen's "All CraftOS
  settings" entry lists and changes **every** setting the ROM knows, through the
  same API, with the same type coercion and the same "empty = unset" rule.
  * It marks the keys it **enforces** with `*`. Only the keys in `ROM_KEYS` are
    policy; everything else is the ROM's, which this project neither enforces nor
    records. The distinction is on screen because a reader who cannot tell them
    apart would expect a setting to survive a boot that will not touch it.
  * **POLICY and CHOICE are two different things, and conflating them was a bug
    this batch shipped and then fixed.** The first version had one field, `want`,
    doing both jobs, so enforcement restored a hardcoded value and a menu entry was
    a **lie**: turning "boot from a disk" ON appeared to work, and the next boot
    silently set it back. Enforcement now writes the operator's **choice** from
    `/etc/bios.conf` when there is one, and the installation's **policy** otherwise.
    A key never touched keeps the policy; a key they changed keeps their change
    across reboots; and deleting `/.settings` is still repaired from that same
    source of truth. The regression is pinned by an assertion ("the NEXT BOOT does
    not undo the operator's choice").
  * `settings.save()` defaults to a path **relative to the current directory**, so
    every write here passes the absolute `/.settings`: a caller whose cwd is not
    `/` would otherwise write the settings where the ROM never reads them.
* **`reboot` replaces `craftos`.** The old command dropped to the CraftOS shell by
  writing `/var/lib/.escape_allowed` for `startup.lua` to find and break out of its
  relaunch loop. It was the only way out of the shell and a poor one: the machine
  was left running something this installation does not manage, so the rules set
  here (the boot guard, noexit) went with it. `reboot` restarts the computer
  through `startup.lua` instead, so it comes back under this installation's control
  with the BIOS window in front of it, exactly as after a power cycle.
  * `reboot bios` writes a **one shot marker** that `startup.lua` consumes before
    showing the screen, so reaching setup does not mean racing the three second DEL
    window. The marker carries the computer id, so a data directory copied to
    another machine does not make that machine open its setup screen, and it is
    consumed rather than left, so an unattended machine does not come up in setup
    after an unrelated reboot.
  * Root only and audited, like the command it replaced. `set -o noexit` refuses it
    too -- a reboot ends the session, so the rule has to apply -- and `-f` overrides.
    `reboot shutdown` is refused rather than guessed: shutting down is a different
    act with a different outcome.
  * **The escape machinery is gone, not just unused.** `try_escape` and
    `ESCAPE_FLAG` are out of `startup.lua`, `__escape` is out of the shell, and
    nothing writes `.escape_allowed`. `startup.lua` does delete a stale flag left by
    an older install, so an upgrade does not leave a request nobody can honour.
  * `os.reboot()` was confirmed to really restart on CraftOS-PC: a startup script
    that calls it runs a second time on the same data directory ("boot 1: calling
    os.reboot()" then "boot 2: the machine came back up").
* **Evidence**: `tests/batch_check.lua`, sections "the boot guard", "the shell may
  not be left", "Ctrl+C stops the running command", "boot order: the ROM's disk
  startup is turned off", "the BIOS screen can reach every CraftOS setting" and
  "reboot replaces craftos" (123 assertions, mutation tested -- every mutant caught:
  guard always allows, directory rule dropped, `no_exit` ignored, `boot_guard` not
  read, Ctrl+C never raises, wrapper passes the filter through, `cp` reports success
  on refusal, `enforce_rom_settings` does nothing, `want` flipped to allow disk boot,
  `rom_setting` ignores the file, default reported as false, `set_rom_setting` does
  not write, enforce ignores the choice, the choice is not recorded/read/written,
  the browser marks everything as policy, it lists nothing, a boolean is stored as
  the string, a policy key bypasses the choice path, reset does not unset, reboot
  allows non-root, noexit does not block reboot, reboot never calls `os.reboot`, the
  setup request ignores the computer id, the setup request is not consumed, and the
  stale-flag cleanup is defined but never called). The settings browser, the ROM's
  reading of `/.settings`, the one shot marker and `os.reboot` itself were confirmed
  on CraftOS-PC.
* **Not done**: the BIOS screen has no PC-side test of its *rendering* -- the
  assertions cover the password store, the switches, the DEL window's decision, the
  ROM settings and the browser's data, not the drawing. A CraftOS-PC run would
  confirm what it looks like; there is no script for that yet.
* **The digest this project called SHA-256 was not one.** Found while adding a
  `sha256sum` command, and recorded in full because it is the shape of failure this
  project is worst at: it produced a plausible answer, nothing failed, and the tests
  agreed.
  * `lib/crypto.lua` asked the ROM for `cc.crypto` and fell back to a 64-bit
    arithmetic fold (`h1 = h1 * 31 + byte`) when that library was absent. **It is
    absent on CraftOS-PC 2.8.3** -- measured, `require "cc.crypto"` fails -- so on
    that machine `crypto.sha256("abc")` returned `0001786200021546`, 16 characters
    where the real digest is 64. Everything built on it was weaker than it claimed:
    the login password hash, the BIOS password hash, and the package signature check.
  * **The test is why it survived.** `crc32` had a standard vector (`0xCBF43926`);
    `sha256` had `digest == checksum.sha256("abc") and #digest > 0` -- "is it
    stable", which a fold satisfies. A known-answer test is the only kind that can
    tell a digest from a fold, and there is now one for the empty string and `abc`.
  * `lib/sha256.lua` is a real SHA-256 (FIPS 180-4, verified against four vectors
    including the 112-byte case that exercises the extra padding block). It is
    copied from `rpv/crypto.lua` rather than required from it: `rpv/` is on the
    medium, and the base half may not depend on the medium.
  * **`bit32` is variadic and three separate copies of it were not.** The
    compression function calls `bxor(a, b, c)`; a two-argument shim drops the third.
    My first fallback had this bug, the manual `bit32` branch had it too, and so did
    the shim in `tests/net_harness.lua` -- which is why the suite could not have
    caught it. All three are fixed, and both `lib/sha256.lua` and the shim now carry
    a known-answer test on **both** paths.
  * **A second, independent bug in the same place: the stored password moved with
    the medium.** `lib/crypto.lua` and `lib/checksum.lua` are in the modules half
    (the removable medium) while `lib/perm.lua` is in the base half (the computer),
    and `perm.hash_password` pcall-required crypto with a fold as the fallback.
    Measured: `alice:0fbcae8a2053...` with the medium and `alice:1265856734`
    without, with `check_password` returning **false**. A password set with the
    medium in place could not be verified without it -- on a two-part install, where
    Part 2 is a handheld you can take away, that locks the operator out of their own
    machine. `lib/perm.lua` and `lib/bios.lua` now require `lib/sha256.lua` at
    column 0, which both fixes the hash and puts sha256 in the **base** half (gate 5
    pins it). Measured after the fix, on a base-only machine with no medium at all:
    the stored hash is the real SHA-256 and verifies.
  * **Migration is not free and is not hidden**: passwords set before this are
    fold-based and will not verify. There is no single "old hash" to preserve -- the
    old value depended on whether the medium was inserted -- so the honest answer is
    that a machine upgrading across this change needs its passwords reset.
* **Evidence** for both: `tests/batch3_check.lua` (413 assertions). The new ones are
  mutation tested, and two mutants **escaped the first version of the test and
  forced it to be rewritten**: an assertion that merely compared "hash with crypto"
  to "hash without crypto" passes a restored pcall-and-fold, because in the suite
  crypto is always loadable and both branches then compute the real digest. The test
  now sets a password **while `require("crypto")` is made to fail** and asserts the
  stored bytes equal `sha256.hex("cc-salt:...")`. Mutants caught: two-argument `bxor`
  on the bit32 path, two-argument `bxor` on the fallback path, a non-variadic
  fallback `band`, `crypto` silently folding, the padding length halves swapped, the
  padding boundary off by one, a round constant changed, a removed vector, perm
  folding again without the medium, and the salt prefix changed. Confirmed on
  CraftOS-PC: `crypto.sha256("abc")` is the 64-character vector, `has bit library`
  is true, the selftest is empty, and a password set on a base-only machine stores
  and verifies the real digest.

* **The licence gate is gone (2026-10-17): the machine is SET UP, not licensed.**
  For a while the first boot asked a second server for a signed licence:
  `authserver.lua` signed `computerId:nonce` with a 512-bit RSA key, `lib/license.lua`
  verified it with the matching public key, and `startup.lua` would not start the
  shell without it. The owner asked for the mechanism to be retired, and the reason
  is worth writing down: **the private key shipped inside the same installation as
  the public one** (`authserver.lua` was part of part 1 and of the release), so the
  signature never proved anything a user could not produce themselves -- it only put
  a second daemon, a second config file and a second failure mode in front of every
  first boot. Its client and server did not even agree on a channel with each other
  and with the shipped `/etc/network.conf`, so a configured machine would have
  waited 30 s for nothing. What replaced it is one marker: `lib/marker.lua` writes
  `{computerId, setup, at}` to the same four paths, bound to this computer
  (`marker.done()` refuses a marker taken from another machine), and `startup.lua`
  runs `firstboot` until that marker exists. `authserver.lua`, `lib/license.lua`,
  `lib/rsa.lua` and `tools/gen_rsa.py` are **deleted**, not deprecated; the licence
  keys in `/etc/network.conf` (`placeholder_ids`) went with them and the file now
  describes only the package server. Evidence: `tests/batch4_check.lua` (12
  assertions: the marker round trip, the computer binding, `--clean-firstboot`'s
  `exists()`, no signature field, and the boot gate asking `marker.done()` while it
  no longer requires a licence module); gates and suites green; gate 1 compiles 117
  Lua files (three fewer), gate 4 holds 145 manual pages (the `authserver` page is
  gone) and part 1 of the two-part install is three files smaller. Gate 3 no longer
  demands that README.md mention "AI": the owner had the generated AIGC labels
  removed, so nothing about them is required any more.

---

## 8. How to verify a change

```
python tests/run_all.py                    # gates + all suites, expects ALL GREEN
bash tools/rpv-verify/_psh-perm.sh         # permission acceptance on a real machine
powershell -File tools/rpv-verify/_psh-mc-server.ps1 -Action status
powershell -File tools/rpv-verify/_psh-mc-file.ps1 -Server <server dir> -RconPort <port> ^
    -ServerAlreadyRunning -ClientTrace
```

The hardware script writes, per machine: `mcfile-client.log` / `mcfile-peer.log` (the driver's
own log), `mcfile-trace.log` / `mcfile-peer-trace.log` (rpvnet datagrams and the xfer state
machine), and `rpv-log.txt` (the node's frame level log). Read those files directly rather than
the script's tail, and check each `startup.lua` mtime against the run before believing what a
log says about the code.

**Do not draw conclusions from a run started on a half-finished tree.** Two of the runs behind
section 1.2 were started while the code was still being edited, and their failures (a pull that
stalled at 17 of 49 blocks, a push with no opener answer) say nothing about either the before or
the after state. Before a hardware run: finish the edit, run `tests/run_all.py` to `ALL GREEN`,
then start the run. Keep a baseline run of the direction being changed on the last known good
tree, so a new failure can be attributed rather than guessed at. The hardware loop is one
20-minute round trip per attempt, so one clean measurement is worth more than three fast ones.
