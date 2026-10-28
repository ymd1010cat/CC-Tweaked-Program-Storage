# rpv-verify: the acceptance scripts for the Pyromputer OS rpv transport

These scripts verify the rpv transport of Pyromputer OS. They live here (inside the project) so
they travel with it; the data they create lives outside the repository, in
`%LOCALAPPDATA%\rpv-craftos\work`.

## Scripts

| Script | What it proves | Needs |
| --- | --- | --- |
| `_psh-rpv-probe.ps1` | On one CraftOS-PC computer: the vendored stack builds a node, `udp_send` works, `rpvnet.send` works, and it prints the interface fields and the node log | CraftOS-PC with a modem side, a deployed Pyromputer OS copy |
| `_psh-rpv-verify3.ps1` | Two CraftOS-PC computers exchanging over rpv: a request/answer round trip with a static peer map (phase 1) and then through discovery (phase 2). `RESULT psh-rpv-verify3 server=PASS client=PASS` | CraftOS-PC with the `ccemux` plugin |
| `_psh-rpv-file.ps1` | The file protocol over rpv: a 200 KB payload in 4096 byte chunks (49 chunks, thirteen IP fragments each) pulled with `rget` and pushed back with `rput`, whole-file CRC32 compared on the receiver. `RESULT psh-rpv-file server=PASS` | CraftOS-PC with the `ccemux` plugin |
| `_psh-mc-verify.ps1` | Two real Minecraft computers exchanging over rpv: static map phase and discovery phase, with the node log | The dedicated Fabric server running, `rpv1` (its `poc/mc/rcon.py`) |
| `_psh-mc-file.ps1` | The file protocol on real hardware: the same chunked `rget` + `rput` as `_psh-rpv-file.ps1`, with the full shell deployed into both computers. Raises `computer_space_limit` and restarts the server itself | Same server; read the hardware note below before expecting a large payload to pass |
| `_psh-mc-rawlink.ps1` | Raw modem link only (isolates layer 2 from the rpv stack) | Same server |
| `_psh-mc-probe.ps1` | Whether a computer runs a `startup.lua` written before or after its first boot | Same server |
| `_psh-disk-probe.ps1` | What removable media this emulator can offer: `disk.insert` is nil, `periphemu.insertDisk` is nil, a created drive never holds a medium, so a directory at `/disk2` is the only medium available | CraftOS-PC |
| `_psh-disk-store.ps1` | The removable package store on a real computer, over three boots: a medium is made a store and a package is installed onto it (boot 1), a fresh boot finds the store by the marker and reads the package from the medium (boot 2), and a third boot confirms the marker and the packages are still on the medium (boot 3). `RESULT psh-disk-store server=PASS` | CraftOS-PC |
| `_psh-twopart.sh` | The two-part installation: `deploy.py --part base` on a 1 MB computer and `--part modules` on a medium marked `.pkgsys`. Proves the machine boots with part 2 on the medium, and -- the assertion that matters -- that a module existing ONLY on the medium is requirable **without the boot script touching `package.path`**, so mounting alone is what wires the module half in. `RESULT psh-twopart=PASS server=PASS` | CraftOS-PC (bash; no PowerShell needed) |
| `_psh-twopart-build.sh` | The two-part installation **as the tool builds it**: `tools/twopart.py --out <dir>` produces both halves in one command (part 1 the computer, part 2 the medium as a `.pkgsys` system module store in the package layout), and then that output is booted -- part 1 copied into the computer, part 2 mounted as `/disk2`. Asserts that the computer holds no copy of the module required, that `require("xfer")` and `require("pkg")` load from the medium with **no `package.path` edit in the probe**, that the shell's own commands run, and that the machine reports itself incomplete once the medium is gone. `RESULT psh-twopart-build=PASS server=PASS` | CraftOS-PC (bash; no PowerShell needed) |
| `_psh-perm.sh` | Permission acceptance on a real machine, in two boots (an ordinary account, then root). The shell's own guards come first (`rm` on `/usr/psh.lua`, a redirect into `/etc`, `touch` in `/usr`, `mkdir` in `/etc`, `/etc/shadow` copied out, plus the ordinary-file and root counter-cases), then **osguard** -- a program running ON the machine calls `fs.open("/usr/psh.lua","a")` and `fs.delete("/etc/passwd")`, which must be refused as a guest and allowed as root -- and finally the **destructive-command blacklist** (`rm -rf /`, `rm -rf /usr` and `sudo rm -rf /` refused with a reason while the system files' lengths stay the same, and `rm -rf` of a writable directory still working). Commands are typed by an observer that writes one marker per command, and every verdict is read back from the machine's own files: the emulator's stdout is not trusted, because `write` reaches the terminal word by word. `RESULT psh-perm=PASS` | CraftOS-PC (bash; no PowerShell needed) |
| `_psh-mc-server.ps1` | Start / stop / restart / status / logs for either Minecraft server copy, so a run can be pointed at a server that is already up. `status` prints the game and rcon ports, the mods, the world and the space limit | Java, a server copy |

### What the disk run showed (2026-10-10)

`_psh-disk-probe.ps1` answers the question a store acceptance depends on, and the answer is
not the one CraftOS documents: in CraftOS-PC 2.8.3 `disk.eject`, `disk.isPresent`,
`disk.getMountPath` and `disk.setLabel` exist, but **`disk.insert` does not** (and neither does
`periphemu.insertDisk`). A drive peripheral can be created on any side and reports
`isPresent=false` forever, so a floppy image cannot be inserted at all. The only removable
medium left is a plain directory at a path `lib/disk.lua` treats as a drive (`/disk`, `/disk0`,
...), which is what `_psh-disk-store.ps1` uses. It is a real filesystem, so the parts of the
store mechanism that matter are exercised for real; the insert/eject event path stays covered
by the PC side suites.

The run also settled the persistence question the whole design rests on: a directory at
`/disk2` survives a reboot, so the marker written on boot 1 was still there on boot 2 and boot
3, the package installed under `/disk2/usr/pkgs` was still readable from a fresh boot, and
`pkg.store_release(2)` removed only the marker while the packages stayed on the medium.

The shell is deliberately not driven from that script: `dofile("/usr/psh.lua")` runs without the
package library (bios.lua only builds it for a program started through the shell), and
`shell.run("/usr/psh.lua", "-c", ...)` works but leaves through `os.shutdown()`, taking the
emulator down before the driver can log. What the shell prints for `pkg store` is covered by
`tests/batch3_check.lua` instead.

### What the real hardware run showed (2026-10-10)

The real Minecraft route behaves differently from the emulator, and the difference matters
before trusting a large `chunk_size`:

| run | payload | chunk | result |
| --- | --- | --- | --- |
| CraftOS-PC | 200,000 B | 4096 | PASS, 49 chunks, CRC matched both ways, `REASM_DROP` 0 |
| Minecraft | 50,000 B | 256 | PASS both directions, `same=true` (each way took a few minutes) |
| Minecraft | 200,000 B | 4096 | FAIL: the peer logged `FRAGMENTED` 144 times and `REASSEMBLED` 0 times, so every ~6 KB datagram (thirteen IP fragments) was lost at the receiver, and the transfer ended with `no acknowledgement for chunk 21 after 6 retries` |
| Minecraft | 200,000 B | 4096 | PASS with the larger reassembly caps the scripts now write (`rpv_reasm_bytes=524288`, `rpv_reasm_entries=128`), unpaced; the pull reproduced on every later run, the push did not (see below) |

So on a real computer a ~6 KB datagram (a 4096 byte chunk, base64 expanded) does not survive.
Keep `chunk_size` small on real hardware (256 or 512) and expect a few hundred KB to take a
long time: the data channel is stop-and-wait, and a 256 byte chunk is roughly two seconds per
block on a real server.

### Fragment pacing: implemented, measured, not the fix (2026-10-10)

The failure above was attributed to the modem being handed thirteen fragments back to back, so
`rpv/node.lua` grew a pacing knob (`rpv_frag_pace=1`, `rpv_frag_pace_ms=<gap>`): the first
fragment of a fragmented datagram goes out immediately and the rest follow on the node's timer.
It is implemented and covered by `tests/batch8_check.lua` (a paced datagram leaves one fragment
per step, every fragment still goes out, and a second queued datagram does not wait for the
first). On real hardware it did **not** improve things, and the measurements say the pacing was
never what made 4096 byte chunks fail:

| run | chunk | pacing | result |
| --- | --- | --- | --- |
| earlier (before either change) | 4096 | off | FAIL: peer `FRAGMENTED` 144, `REASSEMBLED` 0, `no acknowledgement for chunk 21 after 6 retries` |
| control, current tree | 4096 | off | **PASS both ways**, `200000 bytes crc=6f5477e4 same=true` |
| paced | 4096 | 10 ms | pull PASS on the third attempt, push never finished: the client stopped logging at 200 s and the peer kept answering malformed requests until its deadline |
| paced | 4096 | 50 ms | FAIL: `no acknowledgement for chunk 17 after 6 retries`, and `FRAG_PACED=0` on the client, so the run was not even consistently paced |

The control run is the interesting one: with `rpv_reasm_bytes=524288` and
`rpv_reasm_entries=128` set (which the scripts write) the same 200 KB at 4096 bytes passes
unpaced, so the earlier failure was the **reassembly budget**, not the burst. Pacing, as it
stands, is a regression at 10 ms (it hangs the push) and at 50 ms (it breaks the pull), so it
is **off by default** and the MC script takes `-FragPace 1` to try it. Anyone revisiting this
should start by comparing paced and unpaced runs at the same chunk size with the reasm limits
in place, and should check `FRAG_PACED` in `rvp-log.txt` before believing a paced run was
paced at all -- two runs here were not, because the drivers rewrote `/etc/network.conf` on boot
and threw the setting away (that is fixed: the drivers now keep the file and only complete it).

### The push is not reliably reproducible yet

The pull reproduced every time once the reassembly caps were in place (200 KB at 4096 bytes,
one attempt, `crc=6f5477e4` both sides). The **push** did not: some runs completed it
(`PUSHED 200000 bytes crc=6f5477e4 same=true`, the peer's verdict `PASS`) and others left the
peer waiting for chunks that never came (`transfer stalled (timeout): missing chunk(s) 1..49`).

`-ClientTrace` wraps `rpvnet.send`, `rpvnet.receive` and `rpvnet.pump` on the client and writes
`/mcfile-trace.log` on the computer. The hook has to go on `rpvnet`, not on `xfer`: xfer's
message helpers are module locals, so assigning `xfer.send_message` silently wraps nothing (that
was the first attempt, and it produced a trace with only its own "armed" line). What the trace
showed on a failing run:

    0.45 RECV proto=psh-mc-hello ok=true sender=20 bytes=9      -- the hello phase worked
    0.45 SEND to=20 proto=psh-mc-file bytes=120 ok=true res=true -- the pull request went out
    ...  PUMP 0.20s ok=true, every 0.25s, for the whole pull   -- the pull itself is healthy
    30.70 RECV proto=psh-mc-file ok=true sender=nil bytes=nil  -- one receive returned nothing
    30.70 <nothing further, for more than seven minutes>
    peer, 42.55: SERVED ok=nil info=transfer stalled (timeout): missing chunk(s) 1..49

Two things follow from that. The client goes quiet **after the peer has already told it the
first attempt was missing, and before a single chunk leaves**: no `SEND` line for a chunk ever
appears, so the stall is on the client, inside the push, before its first send -- not on the
wire. And the client's `os.clock()` stops advancing at the same moment (the trace is written
with `os.clock()`), so the computer stops running events rather than looping: something in the
push path blocks it. The pull exercises the same protocol, chunking and transport, so the
difference to look for is in the push half specifically: what the client does with the peer's
`missing` list (an empty list from an incomplete first attempt is the interesting case), and
whether the retry path can leave the client waiting on a message the peer will never send
because the peer has already stored the transfer as stalled.

Where to instrument next: log inside `xfer.send` (and `xfer.stream_send`) at each state change --
request, ready, each chunk, and each branch on a `missing` or `ack` message. The trace above only
sees the datagrams; the state transitions inside the sender are what the log cannot show yet.

**That instrumentation now exists and it named the cause.** `xfer` takes an optional
`opts.trace` sink (and a module level `xfer.trace` default), and every state change of both the
sender and the receiver reports itself: `send start`, `sending chunk n/N`, `chunk n answer=...`,
`missing list of N answered`, `no answer for chunk n (attempt i/r)`, `gave up on chunk n`,
`receive start`, `receive got t=... seq=...`, `silence <reason>: n/N received, m missing`, and
`put request sent` / `put answer`. The MC client installs that sink with `-ClientTrace`, next to
the `rpvnet` hook, so one log holds both the datagrams and the branches.

The failing run reads like this (`X` lines are `xfer`, the rest is `rpvnet`):

    X put request sent: 200000 bytes, 49 chunk(s) of 4096     client 78.55
    X put answer: none reason=nil                             client 95.85 (15 s timeout)
    REQUEST op=nil from=21 / unsupported operation: nil       peer 36.70 (peer clock runs ahead)
    REQUEST op=get from=21 / no acknowledgement for chunk 31  peer 39.65, 166.10
    no pushed file arrived / PEER_VERDICT NO-PUSH             peer 604.55

So the push never starts: the peer never answers the `put` request with `ready`, the client
waits out its request timeout, and `stream_send` is never entered (no `sending chunk` line ever
appears). The peer, meanwhile, is still finishing the *pull* -- its `SERVED ... no
acknowledgement for chunk 31` line lands after the client has already sent the push request. The
push request and the peer's blocking `xfer.serve` for the pull overlap, and the request is lost
rather than queued: `xfer.serve` runs inside the receive loop and only returns after the whole
transfer, so a request that arrives during it is never read.

The earlier `REQUEST op=nil` is the same shape for the first pull attempt: a request arrived
with `action` intact and `op` missing, so a datagram was lost or truncated in flight. `op=nil`
is therefore not a mystery in the sender -- it is what a damaged request looks like when it is
decoded -- but it is worth logging the keys present, which the peer driver now does
(`MALFORMED op=nil keys=...`).

How often that happens is worth knowing, because it is not rare: a run with the trace in place
logged **three** such requests in a row, matching the client's first three `rget` attempts at
15 s apart (`REQUEST op=nil` at 34.20, 35.45, 36.70 on the peer, then the fourth attempt got
through). A small request datagram is damaged often enough to burn most of a retry budget on
its own, which is a second problem riding on the same transport as the push stall -- fixing the
peer's one-transfer-at-a-time behaviour will not make that go away.

One trap while reading these logs: the runner prints only the last ten lines of each log, so a
sequence like those three requests can be cut down to its last entry and look like a single
event. Read the log files in `world\computercraft\computer\<id>\` directly, and check the
`startup.lua` mtime against the run before drawing a conclusion -- an edit made after a run
started is not in that run's machines (that is how a `MALFORMED` line that should have been
there was missing).

The pull side is traced too now (`get request sent` / `get answer` on the client, `get served`
on the peer, through the same `xfer.trace` sink), so a run reads from both ends:

    client  mcfile-trace.log        rpvnet datagrams + xfer branches (requester side)
    peer    mcfile-peer-trace.log   xfer branches (peer side)
    both    rpv-log.txt             the node's own frame-level log

What to do about it is a design decision, not a bug fix: either the client waits for the peer to
finish (`netd` is the real server and it serves one request at a time), or the peer must read the
next request while it serves one (a queue in the driver/receive path), or the client retries the
request until it gets an answer -- which it partly does, since `rput` retries, but each attempt
only pays one request timeout and the pull can hold the peer for minutes.

**That second cause is now fixed, driver side (2026-10-11).** The fix is in `lib/xfer.lua` and is
not a protocol change:

* The waiting loops now hand a request they see while waiting for something else to a queue
  instead of ignoring it, when the caller asks for it (`opts.stash`, which `xfer.serve` sets for
  its own transfer).
* `xfer.serve_pending(opts)` drains that queue, serving whatever arrived. That is the whole
  change a driver needs:

      local serve_opts = { save_dir = ..., root = ..., overwrite = true }
      local ok, info = xfer.serve(sender, msg, serve_opts)
      xfer.serve_pending(serve_opts)

* `netd.lua` does that now, and so does the acceptance peer in this directory.
* `xfer.next_request`, `xfer.pending_requests` and `xfer.clear_requests` are there for a driver
  that wants to drive the queue itself.

`tests/batch8_check.lua` covers what the PC side can cover: the queue accepts requests (not acks
or replies), the drain takes each entry exactly once, an empty drain is a no-op, and clearing
works. The end-to-end half -- `xfer.serve_pending` serving a real requester while another transfer
finishes -- is **not** in the suite: it blocks on the network, and a task that both sends and
receives through that harness yields across the C boundary when it is driven from the test body.
A hardware run is what confirms that half, and the corrupted-request problem above is still open.

### What the queue fix did and did not change, measured (2026-10-11)

The next hardware run with the queue in place separated the two causes cleanly. The pull finished
in 17 s (one attempt, `crc=6f5477e4`) and the push request went out at 17.55 s, so the two no
longer overlap at all -- the overlap the queue was built for is gone:

    client  X put request sent: 200000 bytes, 49 chunk(s) of 4096
    client  X put answer: none reason=nil                    15 s later
    peer    REQUEST op=put from=21                           arrived (259 byte datagram on the wire)
    peer    SERVED ok=nil info=transfer stalled (timeout): missing chunk(s) 1..49
    peer    rpv-log: the last datagram it SENT is the last pull chunk, nothing after it

So the push still fails, and the trace says why: the peer received the request and entered
`stream_receive` (it reports the stall, which only happens after `ready` was sent), but the
client never saw that `ready` and gave up after one request timeout. **The peer's `ready` was
sent and lost in flight** -- the peer's own wire log has no transmission after the request
arrives, and a small control message travels as two fragments plus a `FRAGMENTED` line that
never appears. That is the same lossy-small-message problem as `op=nil`, now measured from the
other end, and it is why `rget` only succeeded on its second or third attempt while `rput`
gives up: the pull retries the whole request, the push pays exactly one request timeout.

That leaves the corrupted/lost control message as the single open cause of the failing push, and
it also explains why every attempt to fix it by making the *data* path more robust missed: the
chunk layer is fine, the control messages are what go missing.

### The request retry, measured (2026-10-11)

Both directions now send their request through one opener that retries it (2 attempts by
default, `opts.request_tries` / `opts.request_timeout`), because a pull only ever survived a
lost `ready` by having `rget` re-run the whole command. The trace prints the attempt number, and
a hardware run showed two things at once:

    client  X get request sent (attempt 1/2)
    client  X get answer: ready (attempt 1/2)          -- the pull's answer came back at once
    client  X put request sent (attempt 1/2)
    client  X put answer: none (attempt 1/2)           -- 15 s, nothing
    client  X put request sent (attempt 2/2)
    client  X put answer: none (attempt 2/2)           -- 7.7 s, nothing
    peer    REQUEST op=put from=21                     -- it did arrive
    peer    SERVED ok=nil info=transfer stalled (timeout): missing chunk(s) 1..49
    peer    DRAINED 1 queued request(s)                -- the queue fix working

So the retry fires and is not enough: the message is lost every time in this run, and the two
directions behaved differently (the pull answered first try). The queue is confirmed working on
hardware -- the second attempt's request was queued and drained by the peer rather than dropped.

### The push succeeds on the current tree (2026-10-11)

The run after the request retry landed -- on the tree with the queue fix and the request retry,
and with the reverted attempt out of it -- completed both directions:

    client  X all 49 chunks acknowledged, sending done
    client  X result ok=true
    peer    REQUEST op=put from=21
    peer    SERVED ok=true
    peer    PUSHED 200000 bytes crc=6f5477e4 same=true
    peer    PEER_VERDICT PASS

The client's own `CLIENT_VERDICT` line was never read by the host script: reading the 200 KB back
and writing the marker takes minutes over the world filesystem, and the script's wait ended first
(the same effect is noted in `ROADMAP.md` section 5). The transfer itself is proven by the peer's
verdict and by the client's trace, so what remains is intermittent control-message loss (1.2),
not a broken path.

The next move is a protocol change rather than another retry, written up in `ROADMAP.md` section
1.2: the push does not need the `ready` round trip at all. Let the requester send its first chunk
right after the request and let the peer answer with the `ack` the chunk layer already protects.
That was attempted and reverted once -- the roadmap records the three things it must do together.

The server's `config/computercraft-server.toml` needs `computer_space_limit` raised for any run
that deploys the full shell (about 1.1 MB). The script does that and writes a `.bak` next to
the file; rewriting that file needs care, because saving it with a BOM makes the server fail
to start with `Invalid bare key: '#Require'`.

The two CraftOS-PC scripts take `-Bytes` / `-Chunk` (`_psh-rpv-file.ps1`) and `-TimeoutSec`.
They create their data directory under `%LOCALAPPDATA%\rpv-craftos\work\<script name>`; run
them with `powershell.exe -NoProfile -ExecutionPolicy Bypass -File <script>` when `pwsh` is not
on PATH or script execution is restricted. Every script takes parameters for the paths it
needs; the defaults assume this machine.

### Two server copies, and how to point a script at either

There are two copies of the same Fabric server, and the MC scripts take `-Server` (the directory
holding `fabric-server-launch.jar`) plus `-RconPort` / `-RconPassword`, so either one can be
driven:

| copy | game | rcon | notes |
| --- | --- | --- | --- |
| `<rpv1>\mc-server-fabric` | 25566 | 25576 | the original, with its played-in world |
| `<cc_tweaked>\mc-server` | 25566 | 25586 | a workspace copy, world generated fresh on first start |

The workspace copy keeps a run out of the original world. It is a robocopy of the server
directory without `world/`, with `rcon.port` changed to 25586 (two copies cannot share a port,
and the scripts are also used against a server that is already running) and its own motd. A
fresh world needs no preparation: the MC scripts create `world\computercraft\computer\<id>\`
before the computers boot, and CraftOS adopts a directory that is already there -- verified
both ways by `_psh-mc-probe.ps1`, which reports ORDER A (write first, boot after) as the order
that works.

    powershell -File tools\rpv-verify\_psh-mc-verify.ps1 -Server <cc_tweaked>\mc-server -RconPort 25586
    powershell -File tools\rpv-verify\_psh-mc-file.ps1   -Server <cc_tweaked>\mc-server -RconPort 25586

Both MC scripts restart the server unless `-ServerAlreadyRunning` is passed; the server is a
child of the caller, so killing the caller's process tree takes the server with it.

### A reliable control channel was attempted and reverted (2026-10-11)

The corrupted requests above (`op` missing from a request that arrived otherwise intact) were
attacked directly: every control message (request/ready/result/done) gained a sequence number,
a crc32 over its own fields and the sender id, and the receiver answered `ack` (or `nak` when
the crc failed) while the sender retransmitted a bounded number of times. The protocol logic
worked when tested on its own -- an intact message is accepted, a duplicate is recognised and
re-acknowledged, a message whose body was altered is refused and answered with a `nak` -- and it
was reverted anyway, for a reason worth recording:

* The acknowledgement has to be sent from inside the peer's own receive loop, so every driver
  that reads requests off the wire (`netd.lua`, the acceptance peers, the PC side test peer)
  must call a new `xfer.acknowledge(sender, msg)` before serving. That is a protocol change to
  every peer, and it broke the whole of `tests/batch8_check.lua` (21 assertions) before the
  drivers were updated.
* Once they were updated the PC side test still failed, and the reason is the transport split:
  the test peer reads with `rednet.receive` (the rednet fallback) while `xfer` sends its
  acknowledgements through `rpvnet`, and in the harness the two are not the same wire, so the
  requester never saw its acknowledgement and timed out. The envelope is therefore not
  verifiable in that harness without more work on the harness itself.

So the tree is back to the pre-attempt state (documented in `lib/xfer.lua`'s header: chunk CRCs,
whole-file CRC, ack/missing per chunk) and the corrupted-request problem is still open. What the
attempt established, and what the next one should start from:

* The failure is real and reproducible: a request arrives with `action` intact and `op` missing,
  the peer rejects it (`unsupported operation: nil`), and the client spends its retry budget.
* The fix has to cover the driver side at the same time, or install the acknowledgement in the
  shared receive path of `netcfg`/`rpvnet` rather than in `xfer`, so no driver has to know.
* A cheaper alternative, not tried: have the peer answer a request it could not decode with a
  bare "resend your request" (no envelope, no sequence), which the requester honours by
  retransmitting. That needs no per-message checksum and no driver change beyond answering.

Two traps these scripts exist to avoid, both of which cost real debugging time:

* **A chunk created by `loadfile` has no `package` library in CraftOS.** A driver must be top
  level `startup.lua` code. `loadfile("startup-real.lua")` from inside a spawner makes
  `require` fail with `attempt to call a nil value` and `package.path` read nil.
* **Two CraftOS-PC processes each get their own modem medium**, so wireless traffic does not
  cross processes: the second computer has to be spawned inside the same process with
  `ccemux.openEmu`. Two computers in one process also share no filesystem, so a handshake
  between them has to go over the network, not through a marker file.

## Where the machine local pieces live

    %LOCALAPPDATA%\rpv-craftos\plugin\src\        ccemux.cpp, the SDK headers and the built ccemux.dll
    %LOCALAPPDATA%\rpv-craftos\plugin\headers\    Lua 5.2.4 headers and SDL2 headers (for rebuilds)
    %LOCALAPPDATA%\rpv-craftos\backup-283\        a copy of the CraftOS-PC 2.8.3 install
    %LOCALAPPDATA%\rpv-craftos\work\              probe data directories used by the scripts
    %LOCALAPPDATA%\rpv-craftos\install-283-with-plugin.ps1
                                                  restores 2.8.3 and installs the plugin (needs elevation)

The plugin (CCEmuX, providing `ccemux.openEmu` for multi computer spawning) is not shipped
in any CraftOS-PC release; the prebuilt DLL in the plugins repository is a Lua 5.1 build and
will not load in 2.8.3. The one installed here was compiled from the updated source against
the v2.8.3 SDK headers; the full recipe is in `rpv/MERGE-rpv.md` and in `HANDOFF-rpv.md`.

## Notes

* CraftOS-PC computers refuse to boot when their filesystem is over `computer_space_limit`
  (1,000,000 by default), and the failure is silent: the computer reports as on but runs
  nothing. Each script raises the limit in its data directory's `config\global.json` before
  deploying, because the full shell tree is about 1.0 MB and `_psh-rpv-file.ps1` deploys all of
  it (the transport only scripts could get away with `lib/` and `rpv/`, 704 KB).
* A modem becomes a peripheral only when it faces the computer; the Minecraft scripts place
  one on each side for that reason. On CraftOS-PC, create one with `periphemu` **only when the
  side does not already answer with a modem**: creating one where one exists replaces the
  peripheral the computer booted with, and the peer then fails with
  `no modem could be opened (side back)`.
* `periphemu` exists only in CraftOS-PC, so the drivers guard it with `if periphemu then`.

## bash versions (2026-10-11)

The working shell on this machine is Git for Windows bash (MINGW64) and `pwsh` is not
installed, so the acceptance scripts were ported to bash and are the ones to run here:

    _psh-rpv-probe.sh      single computer transport probe          -> bash _psh-rpv-probe.sh
    _psh-rpv-verify3.sh    two computer acceptance on CraftOS-PC    -> bash _psh-rpv-verify3.sh
    _psh-mc-verify.sh      two computer acceptance on Minecraft     -> bash _psh-mc-verify.sh
    _psh-mc-rawlink.sh     raw modem link only (isolates layer 2)   -> bash _psh-mc-rawlink.sh
    _psh-mc-probe.sh       write/boot order probe for computers     -> bash _psh-mc-probe.sh

All five pass `bash -n`. Two of them were run end to end here:

    _psh-rpv-probe.sh   -> BACKEND rpv, interface fields numeric, udp_send and rpvnet.send ok
    _psh-rpv-verify3.sh -> RESULT psh-rpv-emu verdict=PASS phase1=yes phase2=yes server_got=yes

The PowerShell originals now live in `ps1/` and still work with
`powershell -File "ps1\<script>.ps1"` (Windows PowerShell 5.1 is present; `pwsh` is not).
That folder also holds five scripts that have no bash twin yet, all of them PowerShell
only: `_psh-mc-file.ps1` and `_psh-rpv-file.ps1` (the chunked `rget`/`rput` acceptance, i.e.
the remaining open item), `_psh-disk-probe.ps1` and `_psh-disk-store.ps1` (removable media
and the package store) and `_psh-mc-server.ps1` (start/stop the Fabric server).

Trap found while porting: a driver loaded with `loadfile("startup-real.lua")` cannot see the
shell's `package` table, so `package.path = ...` inside it dies with
`attempt to index a nil value (global 'package')`. `_psh-rpv-verify3.sh` therefore writes the
client driver straight into `startup.lua`. Use `cygpath -w` for paths handed to Windows
executables (the emulator's `-d`, for instance).

Correction to the paragraph above: the chunked `rget`/`rput` acceptance is **not** still open.
It was already run and passed (`RESULT psh-rpv-file server=PASS`, 200,000 bytes each way with
matching CRC32, plus two `lib/xfer.lua` bug fixes) and the results are recorded in
`rpv/MERGE-rpv.md` and `HANDOFF-rpv.md`. Those two PowerShell scripts therefore describe
finished work; porting them to bash is optional convenience, not a pending item.

## bash port status (2026-10-11)

All five acceptance scripts were run end to end after porting, all PASS:

    _psh-rpv-probe.sh    backend rpv, interface fields numeric, udp_send and rpvnet.send ok
    _psh-rpv-verify3.sh  RESULT psh-rpv-emu verdict=PASS phase1=yes phase2=yes server_got=yes
    _psh-mc-verify.sh    RESULT psh-rpv-mc  verdict=PASS phase1=yes phase2=yes server_got=yes
    _psh-mc-rawlink.sh   RESULT psh-mc-rawlink verdict=PASS (both computers heard each other)
    _psh-mc-probe.sh     RESULT psh-mc-probe orderA=yes orderB=yes verdict=PASS

A sixth script was ported as well, since the acceptance runs need a server:

    _psh-mc-server.sh    status | start | stop for the Fabric server, verified as a full
                         cycle here (status -> start "RUNNING after 5s" -> status -> stop
                         "stopped after 3s" -> status). Java is discovered rather than hard
                         coded (JAVA, then JAVA_HOME, then the known install roots).

Four PowerShell-only scripts still have no bash twin: `ps1/_psh-mc-file.ps1` and
`ps1/_psh-rpv-file.ps1` (the chunked `rget`/`rput` acceptance, which already PASSED as
PowerShell) and `ps1/_psh-disk-probe.ps1` / `ps1/_psh-disk-store.ps1` (removable media and
the package store). Porting them is the remaining optional work.

## bash port status, second batch (2026-10-11)

`_psh-rpv-file.sh` -- the chunked file transfer acceptance on CraftOS-PC, ported from
`ps1/_psh-rpv-file.ps1` and run here:

    RESULT psh-rpv-file server=PASS
    peer   : serving /big.bin size=200000 crc=4c790f2d
             op=get served ok, op=put served ok (file and marker),
             pushed size=200000 crc=4c790f2d same_as_source=true -> SERVER_VERDICT PASS
    client : rget attempt 1 exit=0 in 24.6s, pulled size=200000 crc=4c790f2d,
             rput attempt 1 exit=0 in 17.6s, marker rput exit=0 -> CLIENT_VERDICT PASS

It raises `computerSpaceLimit` to 8000000 in the data directory's `config/global.json`
before deploying, because the full shell tree is about 1.0 MB and a computer over the limit
refuses to boot silently. Paths handed to the Windows Python (`tools/deploy.py`, the payload
generator) go through `cygpath -w`.

Remaining PowerShell-only scripts, no bash twin yet: `ps1/_psh-mc-file.ps1` (the same
acceptance on Minecraft, 527 lines), `ps1/_psh-disk-probe.ps1` (139) and
`ps1/_psh-disk-store.ps1` (304). All three already run through
`powershell -File "ps1\<script>.ps1"`.

bash twins to date: _psh-rpv-probe, _psh-rpv-verify3, _psh-mc-verify, _psh-mc-rawlink,
_psh-mc-probe, _psh-mc-server, _psh-rpv-file (seven, all run end to end and passing).

## bash port status, third batch (2026-10-11)

`_psh-disk-probe.sh` -- what removable media CraftOS-PC can actually provide, ported from
`ps1/_psh-disk-probe.ps1` and run here. Same findings as the PowerShell version:

    disk.insert=nil  disk.eject/isPresent/getMountPath present  periphemu.insertDisk=nil
    six drive peripherals can be created, every one isPresent=false
    (a drive exists but can never hold a medium, so there is no image-file route)
    a directory at a removable-looking path works: /disk2 exists=true isDir=true
    fs.exists('/disk')=false (this build does not bleed the /disk2 prefix into /disk)

One deliberate change against the original: the scratch computer is **id 22** instead of 7,
because this machine reserves 20-30 and 100-300 for this work.

bash twins to date (eight, all run end to end): _psh-rpv-probe, _psh-rpv-verify3,
_psh-mc-verify, _psh-mc-rawlink, _psh-mc-probe, _psh-mc-server, _psh-rpv-file,
_psh-disk-probe.

Still PowerShell only: `ps1/_psh-disk-store.ps1` (304 lines, the removable package store
acceptance) and `ps1/_psh-mc-file.ps1` (527 lines, the chunked file acceptance on Minecraft,
which needs the server's `computer_space_limit` raised and a restart). Both run as is with
`powershell -File "ps1\<script>.ps1"`.

## The push no longer waits for `ready` (2026-10-11)

Everything above about the lost `ready` is now history rather than an open bug. The push
was changed to open with its first block instead of waiting for the peer's `ready`, so the
message that kept disappearing is no longer on the critical path at all.

What the trace prints now, for a push:

    put request sent (attempt 1/2) with block 1/N
    put answer: ack reason=nil (attempt 1/2)        <- the answer to that block, not a ready
    send start chunks=N bytes=...
    chunk 1/N was sent with the request; answer=ack  <- it is not sent a second time

A peer that still answers with `ready` first is handled: the wait continues until the
answer to block 1 arrives. An empty file has no block to open with and keeps the old
request/ready shape.

This is covered without hardware now, in `tests/batch8_check.lua`: the peer's `ready` is
held for 30 s past both request attempts and the push still completes. Two overlapping
pushes through a real `netd` are driven there too, which is the case the old code answered
with `unsupported operation: nil`.

So the next Minecraft run is a confirmation rather than a diagnosis. Read the trace for
the three lines above; if the opening reads `put answer: ack` and block 1 appears once,
the change did what it was meant to.

## The new opener, measured on a real CraftOS runtime (2026-10-11)

`_psh-rpv-file.sh` was re-run on the tree that carries the block-opener push, with
`xfer.trace` now installed by the script (it writes `trace| ...` lines into `cli.log`, so
a run is readable branch by branch instead of only pass/fail).

    RESULT psh-rpv-file server=PASS     CLIENT_VERDICT PASS / SERVER_VERDICT PASS
    pulled size=200000 crc=4c790f2d
    pushed size=200000 crc=4c790f2d same_as_source=true

Both directions needed **one attempt** of the command. What makes this run worth keeping is
that it also caught the `ready` loss the fix is about, in the same session:

    pull   2.68 get request sent (attempt 1/2)
           7.71 get answer: none (attempt 1/2)          <- the ready WAS lost
           8.22 get request sent (attempt 2/2)
           8.42 get answer: ready (attempt 2/2)         <- the request retry survived it
          25.64 rget attempts=1 exit=0 in 23.5s
    push  25.86 put request sent (attempt 1/2) with block 1/49
          26.27 put answer: ack reason=nil (attempt 1/2) <- the BLOCK's answer, first try
          26.27 chunk 1/49 was sent with the request; answer=ack
          44.39 rput attempts=1 exit=0 in 18.7s

So the control message still goes missing on a real runtime -- the pull lost it and only
its retry saved the transfer -- while the push, which no longer waits for it, opened on the
first try. The loss is not hypothetical; it is simply no longer on the push's critical path.

## Reports are summaries now, not tails (2026-10-11)

Both acceptance scripts report through `log_summary.py`. The reason is a real mis-reading: the
Minecraft script printed the last ten matching lines of each machine log, and on a busy run that
turned a request which failed three times in a row into a single event -- the earlier attempts had
already scrolled out of the window.

    log_summary.py <logfile> [--title TITLE] [--pattern RE]... [--max-groups N]

What it prints, per machine: how many lines the log holds and how many matched; the matched lines
**grouped with a count, each group listing every occurrence's timestamp** (a count alone loses the
order, and the order is what makes three attempts read as three); the first and last matched line;
and the verdict lines verbatim, whatever the pattern says. A missing log, an empty log and a log
where nothing matched are three different messages, because they are three different problems.

Two things learned while writing it, both worth keeping:

* **The two drivers spell the same events differently.** The MC driver logs `REQUEST op=nil from=21`
  and `PEER_VERDICT FAIL`; the emulator driver logs `request op=get from=21` and
  `server verdict PASS`. A pattern written against one vocabulary matched **2 of 249 lines** of a
  real emulator log -- a summariser that matches nothing is worse than the tail it replaced.
  Matching is case insensitive now, and gate 8 in `tests/run_all.py` is the self test that fails if
  that regresses.
* **`-ClientTrace` now also prints the xfer trace**, first 40 lines, in order. For a push the
  opening line reads `put request sent (attempt 1/2) with block 1/N` -- the shape ROADMAP section
  1.2 introduced -- so the first thing to read after a run is whether that line is there.
