# rpv transport inside unixshell

This tree carries the RPV1 network stack (the `rpv/` directory) and a transport layer
(`lib/rpvnet.lua`) that lets the shell, the package manager, the licence client and the
daemons speak either rednet or rpv without changing what they do.

## Where things live

| Path | What it is |
| --- | --- |
| `rpv/` | vendored RPV1 stack: 19 modules, `node.lua`, `loader.lua` (entry point), `node-start.lua` (standalone node bootstrap). See `rpv/MERGE-rpv.md` for the origin and the local changes. |
| `lib/rpvnet.lua` | the transport layer: rednet shaped API, rpv backend, rednet fallback |
| `etc/network.conf` | `transport=`, `rpv_side=`, `rpv_cidr=`, `rpv_channel=`, `rpv_mtu=`, `rpv_peer_<id>=`, `rpv_reasm_bytes=`, `rpv_reasm_entries=`, `rpv_log_max_bytes=` |
| `tests/batch3_check.lua` | the transport assertions (backend choice, port mapping, delegation) |

## What changed in the shell

Every direct `rednet.*` call became `rpvnet.*`: `lib/xfer.lua`, `lib/rexec.lua`,
`lib/pkg.lua`, `lib/netcfg.lua`, `lib/license.lua`, `lib/sysinfo.lua`, `netd.lua`,
`pkgserver.lua`, `authserver.lua` and `usr/ush.lua`. Nothing else about those files
changed, so the commands keep their behaviour, their options and their messages.

## Switching transports

    transport=auto      rpv when the vendored stack loads and the modem side has a modem,
                        rednet otherwise (default)
    transport=rpv       require rpv; a start failure is reported instead of falling back
    transport=rednet    always rednet

rpv needs an address and a channel; both default from the modem side and the computer
id (`rpv_cidr=10.0.4.<id>/24`, `rpv_channel=4700`), so a fleet needs no per machine
configuration. `rpv_peer_<id>=<address>` pins a peer and skips the discovery broadcast.

**rpv and rednet machines cannot talk to each other.** A conversation needs the same
transport on both ends; with `transport=auto` the older machines fall back by
themselves, which is also what keeps the PC side test suite on the rednet path.

## On the wire

One UDP datagram per message on a port derived from the protocol name
(`rpvnet.port_of("pkg-repo")`, stable and in 20000..39999), wrapped as

    RN1|<protocol>|<computer id>|<blob>

so the receiver learns the sender computer id -- the thing the shell addresses -- and
remembers the address it came from. A peer whose id is unknown is found with one
broadcast on the discovery port (19999) before the datagram is sent.

Because the shell owns the only event loop in a CraftOS computer, the transport drives
the stack with a bounded pump (`rpvnet.pump`, `node:pump`): a command lets the stack
make progress while it waits, instead of handing the process to `node:run()`.

## Local changes to the vendored stack

Two, and both are documented where they live:

* **The bounded pump** (`node:pump`, above) -- the shell drives the stack instead of
  handing it the process.
* **A capped node log** (`log_write` in `rpv/node.lua`). The node logs every frame event,
  which is what makes a hardware failure readable, but it also means the log grows for as
  long as the machine is up -- into a disk of about 1 MB. Measured: a 200 KB `rget`/`rput`
  pair writes about 14.5 KB per machine (6490 B live + 8205 B in the kept generation), and
  reading the file back over a Minecraft world file system has timed out while the transfer
  itself was healthy. Once the live log passes `log_max_bytes` it is moved to
  `rpv-log.txt.1` (one generation, replaced on each rotation) and a fresh file is opened
  with a `LOG_ROTATED` line. `0` turns the cap off; the shell reads
  `rpv_log_max_bytes` from `/etc/network.conf` (default 131072). Every step is guarded with
  `pcall`, so a node that cannot rotate keeps logging anyway.

## Verifying

    python tests/run_all.py                 # gates + suites (expect 718+ passed, 0 failed)
    python tests/run_all.py --gates         # only the five gates

The transport assertions live in the `batch3` suite (110 checks after the merge). They
cover two layers:

* the layer itself: it loads, exposes the rednet shape, maps protocols to stable ports
  in 20000..39999, reports its state, and -- in this PC side environment, which has no
  modem -- falls back to rednet and hands `send` to rednet unchanged;
* the vendored stack, in process: two nodes are built in one Lua state, and a hand made
  ethernet frame carrying an IP/UDP datagram reaches the port a node has bound, with the
  expected source address and payload. That exercises `on_frame`, the IP header and the
  UDP checksums, the socket lookup and the payload. (Writing that test found a real trap:
  a packet whose IP header checksum is left at zero is dropped, so the test fills the
  field with `rpv.cksum`.)

What a single computer can and cannot show, measured on a real CraftOS computer: the node
builds correctly (interface address, network, prefix and MAC are all numbers), the stack's
`udp_send` works, and `rpvnet.send` works. A message addressed to the machine's own
computer id, however, is handed to the wire -- only 127/8 is delivered locally -- so one
computer alone cannot prove delivery. Two computers are needed:

    python tools/deploy.py --target "<computer dir>"        # install the shell on both
    # /etc/network.conf: transport=rpv on both, then use netsend / netrecv / rget / rput

On this machine the two computer acceptance has been run on both routes. The dedicated
Fabric Minecraft server uses `rpv1`'s rcon driver:

    pwsh -File <work>\run-mc-verification.ps1      # rpv1's rcon.py drives the server

Result (two real Minecraft computers, wireless modems, `transport=rpv` on both):

    client 20: avail=true transport=rpv   PHASE1 reply from=21 "reply-from-21"
                                          PHASE2 reply from=21 "reply-disc"
    server 21: avail=true transport=rpv   GOT ush-test from=20 "hello-over-rpv"
                                          GOT ush-disc from=20 "hello-discovery"

PHASE1 uses `rpv_peer_21=10.0.4.21` (a static id -> address map), PHASE2 removes it so the
discovery broadcast and its responder are exercised as well. Both directions, both paths,
one acceptance: `verdict=PASS`.

CraftOS-PC does not need a server at all: one emulator process holds both computers when
`ccemux.openEmu` spawns the second one.

    pwsh -File tools\rpv-verify\_ush-rpv-verify3.ps1     # transport round trip
    RESULT ush-rpv-verify3 server=PASS client=PASS

    pwsh -File tools\rpv-verify\_ush-rpv-file.ps1        # chunked rget / rput
    RESULT ush-rpv-file server=PASS

The second one is the file protocol end to end: a 200,000 byte payload, the default 4096 byte
chunk (49 chunks, each a ~6 KB datagram = thirteen fragments at MTU 512), `rget` from the peer
and `rput` back, with the whole-file CRC32 of the delivered copy matching
(`pushed size=200000 crc=4c790f2d same_as_source=true`). Two bugs came out of that run and are
fixed in `lib/xfer.lua`:

* the push request carried the whole file: `xfer.send()` sent the same table it then used as
  the chunk list, so `meta.chunks_data` was serialized into the opening datagram (200 KB ->
  one 218 KB message, 448 fragments, never reassembled, peer silent, client exit 124). The
  request and the sender's meta are two separate tables now.
* the reassembly budget was too small for a burst of 6 KB datagrams: `rpv.node_new` defaults
  to 16 entries / 64 KB, and once the byte cap is hit every further fragment is dropped. The
  limits are configurable now (`reasm_bytes` / `reasm_entries`; from the shell:
  `rpv_reasm_bytes` / `rpv_reasm_entries` in `/etc/network.conf`, default 524288 / 128) and the
  200 KB run reports `REASM_DROP` 0 with `REASM_LIMITS entries=128 bytes=524288`.

A claim worth keeping, because it costs an afternoon to rediscover: **a CraftOS chunk created
by `loadfile` runs without the `package` library**, so a driver cannot be handed to
`loadfile("startup-real.lua")` -- inside it `require` fails with `attempt to call a nil value`
and `package.path` reads nil. Drivers must be top level `startup.lua` code, and shared code
must live in a library (`lib/`), not in a `usr/cmd/` command file, because the command files
call `require` themselves.

Three things a real server needs, all of them found the hard way:

1. **Disk quota.** The full shell tree is 1,037,846 bytes and a CraftOS computer refuses to
   boot when its filesystem is over `computer_space_limit` (1,000,000 by default in
   `config/computercraft-server.toml`). The symptom is nasty: the computer reports as
   turned on but runs nothing at all. Either raise the limit (and restart the server, the
   option is read at startup) or deploy only what is needed -- `lib/` plus `rpv/` is
   704,497 bytes and is enough for the transport itself.
2. **A modem is a peripheral only when it faces the computer.** Placing
   `computercraft:wireless_modem_normal` next to a computer is not enough, and a facing
   that does not point at the computer leaves the block in place but invisible to
   `peripheral.getNames()`. Put one on each side, each turned towards the computer
   (`+X: facing=west`, `-X: facing=east`, `-Z: facing=south`, `+Z: facing=north`), and let
   the program pick the first `modem` it sees.
3. **`periphemu` does not exist on a real computer** (it is a CraftOS-PC API). A program
   that creates its own modem must guard the call, `if periphemu then ... end`, and use the
   peripheral the server actually provides.

One transport bug was found by that run and fixed: the envelope parser matched its tag with
`%a` (letters only) while the tag is `RN1`, so every envelope failed to parse, `receive`
returned nothing and the peer stayed silent -- a case the PC side stub never reaches,
because there the rpv path is skipped.

Restoring the CraftOS-PC plugin (or the two server installs) is enough to rerun the same
acceptance from a different route; the scripts for it are ready.


