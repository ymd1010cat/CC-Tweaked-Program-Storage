# RPV1 library API (Rednet Protocol Version 1)

Everything here is the **public, stable surface**: an external CC:Tweaked program
may depend on these names. Anything not listed (module internals, `M.*_input`,
`Conn:_*`, functions ending in `_tick`/`_loop`) is internal and may change.

Version label: `rpv.version` / `rpv.RPV_VERSION` = **RPV1**. Code, paths and config
keys keep the historical `rpv` prefix.

## Installing / loading

Layout inside a computer:

```
/rpv.lua          <- entry point (this library's only required file)
/rpv/*.lua        <- the modules
/your-program.lua
```

```lua
local rpv = require("rpv")     -- or: local rpv = dofile("rpv.lua")
```

`rpv.lua` finds its own directory (`/`, `/lib/`, the cwd, …) and loads the
modules in dependency order, so it works from any install path and any cwd.

Other entry-point members:

| Name | Meaning |
| --- | --- |
| `rpv.version`, `rpv.RPV_VERSION` | `"RPV1"` |
| `rpv.modules` | ordered module names that were loaded |
| `rpv.lib` | `true` when loaded through this entry point |
| `rpv.new_node(cfg)` | alias of `rpv.node_new` |
| `rpv.install_rednet_shim(node, opts)` | load `compat/rednet.lua` and install the shim (`opts = { dir_ip, port=4100, install_global=true }`) |

## Creating a node

```lua
local node = rpv.node_new({
    role = "host",                       -- "host" | "router"
    ifaces = {
        { side = "left", name = "LAN", cidr = "10.0.1.2/24",
          channel = 4001, mtu = 256, linktype = "wireless" },
    },
    gw      = "10.0.1.1",                -- optional default route
    routes  = { { net = "10.0.2.0", prefix = 24, gw = "10.0.1.1" } },  -- optional
    fabric  = { side = "top", channel = 5000, mtu = 1024 },           -- optional cluster
    echo_icmp = 1,                       -- 0 disables ICMP echo service
    icmp_port_unreachable = 0,           -- 1 answers with ICMP port unreachable
    capture  = 0,                        -- 1 records the last 64 frames
    stats_at = 30,                       -- seconds; log a stats snapshot once
})
node:setup()
node:run()                               -- event loop (never returns)
```

`rpv.node_new("role.txt")` is also accepted: the classic line-based file
(`role=`, `iface=side|name|cidr|channel|mtu|linktype`, `fabric=side|channel|mtu`,
`gw=`, `map=`, …). Keys from the table form are stringified into `node.cfg`, so
any role.txt key works as a table field too.

### Interface fields

| Field | Meaning |
| --- | --- |
| `side` | peripheral side of the modem (`"left"`, `"back"`, …) |
| `name` | interface name used in routes (`dev <name>`) |
| `cidr` | `"10.0.1.2/24"` |
| `channel` | modem channel (= the wire) or `"rednet"` for a rednet WAN interface |
| `mtu` | L3 MTU (default 256); fragmentation/reassembly honours it |
| `linktype` | free-form label used for the declared-vs-reported warning (`"wireless"`, `"wired"`, …); omit to skip the check |

## Node methods

| Method | Purpose |
| --- | --- |
| `node:setup()` | opens modems, builds interfaces, installs connected/default routes, starts the housekeeping tick, audits channels |
| `node:run()` | main loop: dispatches modem, rednet and timer events to the stack and to tasks |
| `node:bind(port, cb)` | bind a UDP port; `cb(data, src_ip, src_port)` |
| `node:add_task(name, fn)` | run a blocking-style coroutine (`os.sleep`/`os.pullEvent` work inside) |
| `node:after(sec, fn)` | one-shot timer |
| `node:resolve(dst_ip)` | route lookup incl. fabric/WAN (returns path or nil) |
| `node:pick_src(dst_ip)` | source address selection for a destination |
| `node:load_routes(path)` / `node:reload_routes(why)` | load/reload a routes file (hot reload is automatic for `routes.txt`) |
| `node:dump_stats()` | log forwarding, ARP, socket and PMTU telemetry |
| `node:log(fmt, ...)` | write one flushed line to `rpv-log.txt` (and the screen) |
| `node:capture(count)` | return the last captured frames (needs `capture=1`) |
| `node:send_ip(dst, proto, payload, ttl, src, df)` | send a raw IP payload |
| `node:effective_mtu(iface, dst)` | MTU after PMTU discovery |
| `node:on_echo_reply` | callback `(src, seq, rtt_us, bytes)` for ICMP echo replies |
| `node.on_icmp_error` | callback `(src, type, code, inner, qseq, mtu)` |
| `node.stats` | counters: `frames_tx/rx`, `bytes_tx/rx`, `ip_rx`, `ip_bad`, `fwd`, `ttl_drop`, `no_route`, `frags`, `reasm_drops`, `icmp_*` |
| `node.ifaces`, `node.routes`, `node.arp`, `node.udp`, `node.cfg`, `node.mac`, `node.id` | state (read-only by convention) |

## Module functions

### addressing / checksums (`util`)
`rpv.u8/u16/u32(v)`, `rpv.r16/r32(s, i)`, `rpv.rawsum(s)`, `rpv.cksum(s)`,
`rpv.ip2int("10.0.0.1") -> n`, `rpv.int2ip(n) -> "10.0.0.1"`,
`rpv.masked(ip, prefix)`, `rpv.hex(s)`, `rpv.MAC_BCAST`, `rpv.IP_BCAST`.

### IPv4 (`ip`)
`rpv.ip_build(src, dst, proto, ttl, id, mf, offset8, payload, df)`,
`rpv.ip_parse(str) -> hdr[, payload]`, `rpv.ip_max_payload(mtu)`,
`rpv.reasm_new(max_entries, max_bytes)`, `rpv.reasm_push(r, hdr, payload)`,
`rpv.reasm_expire(r)`.

### routing (`route`)
`rpv.route_new()`, `rpv.route_add(rt, prefix, net, iface, gw, kind)`,
`rpv.route_connected(rt, iface)`, `rpv.route_default(rt, gw)`,
`rpv.route_lookup(rt, dst)`, `rpv.route_path(rt, dst)`, `rpv.route_list(rt)`.

### ARP (`arp`)
`rpv.arp_new()`, `rpv.arp_send(node, iface, op, tmac, tip)`,
`rpv.arp_input(node, iface, frame)`, `rpv.arp_resolve(node, iface, ip, cb)`,
`rpv.arp_tick(node)`.

### link layer (`link`)
`rpv.link_open(iface)`, `rpv.link_send(node, iface, dstmac, etype, body)`,
`rpv.link_parse(frame)`. Frame layout: `dstMAC(4) | srcMAC(4) | ethertype(2) | body`.

### ICMP (`icmp`)
`rpv.icmp_echo(node, dst, seq, data, ttl, id)` (records the send time itself, so
`on_echo_reply` gets `rtt_us`), `rpv.icmp_send(node, dst, type, code, rest, ttl)`,
`rpv.icmp_error(...)`, `rpv.icmp_frag_needed(...)`.

### UDP (`udp`)
`rpv.udp_new()`, `rpv.udp_send(node, dst, sport, dport, data, ttl, src, df)`,
`rpv.udp_bind(node, port, cb)`, `rpv.udp_input(...)`.

### crypto (pure-Lua primitives, `rpv/crypto.lua`)
Generated from `poc/security/crypto.lua` by `poc/build-crypto.ps1` (single source of
truth), so every library user gets:
`rpv.sha256(msg)`, `rpv.hmac_sha256(key, msg)`, `rpv.hkdf_sha256(ikm, salt, info, len)`,
`rpv.pbkdf2_sha256(pass, salt, iters, dklen, yield_every)`,
`rpv.chacha20_block(key, nonce12, counter)`, `rpv.chacha20_xor(key, nonce12, counter, data)`,
`rpv.random_bytes(n)`, `rpv.seed_entropy()`, `rpv.add_entropy(s)`, `rpv.hex`/`rpv.unhex`,
`rpv.equals(a, b)` (constant-time-ish), `rpv.selftest()` (RFC KATs: SHA-256, HMAC-SHA256,
PBKDF2, HKDF, ChaCha20).
Measured budget: ChaCha20 ≈**215 KB/s**, SHA-256 ≈180 KB/s, one 128 B AEAD ≈2.75 ms ⇒ use
it for control flow, not for bulk data (link isolation serves that).

**P3 transport polish** (all optional, per node config):
* **Selective ACKs** — `conn_sack` (default on): the receiver buffers out-of-order
  segments and reports the blocks it holds in a `T_SACK` segment (`u8 count | (u32 left |
  u32 right)*`, `CONN_SACK_SENT`); the sender marks those records as delivered and
  retransmits **only the lowest hole** (`CONN_SACK_RETX`) instead of guessing from three
  duplicate ACKs. `conn_sack=0` restores the classic behaviour.
* **Window scaling** — `conn_wscale=N` (must match on both ends): the advertised window is
  sent as `rwnd >> N` and the peer shifts it back, so receive windows above 65535 work.
  The sender also honours the peer's window (`peer_rwnd`) in `pump`.
* **Slow start curve** — `conn_slow_start=1` gives proper slow start (`cwnd += 1 MSS` per
  ACK, i.e. doubling per RTT) instead of the legacy per-ACK doubling, which overshoots on a
  50 ms-tick link; `conn_iw` sets the initial window (default 2 segments).
* **Multi-flow fairness** — `conn_global_max_inflight=N` caps the segments in flight
  *across all connections of the node* (a flow with nothing in flight may always send one
  segment, so a new flow cannot be starved); `conn.cwnd_limited` counts how often the cap
  held a flow back.
* **Keepalive** — `conn_keepalive=<sec>`: an idle connection sends an empty `T_SACK` probe
  (`CONN_KEEPALIVE`) which the peer answers with a plain ACK; 3 unanswered probes abort the
  connection (`CONN_KEEPALIVE_TIMEOUT`). `conn.keepalives`, `conn.ka_miss` report state.
* Test hooks: `drop_every=N` (drop every Nth first-transmit) and `block_egress=1` (the node
  sends nothing at all — simulates a dead peer/link).
`conn:log_stats()` also emits `CONN_P3 sack_rx= sack_sent= sack_retx= ooo_buffered=
ooo_bytes= keepalives= rwnd= wscale= peer_rwnd= gmax=`.
Measured (`poc/run-p3.ps1`): under deterministic loss (`drop_every=3`) the SACK path did 11
targeted hole retransmissions with no more retransmits than the classic path; two 4 KB
flows both completed with and without `conn_global_max_inflight=2` (the cap arbitrated:
`cwnd_limited=18/20`); keepalive probed 3× while the peer was alive and hit
`CONN_KEEPALIVE_TIMEOUT` (ka_miss=4) 7.5 s after the peer went dark.

### topology discovery + network map (`topo.lua`)
`rpv.topo_setup(node)`, `rpv.topo_report_text(node)`, `rpv.topo_send(node)`,
`rpv.topo_input(node, text, src)`, `rpv.topo_rebuild(node)`, `rpv.topo_expire(node)`,
`rpv.topo_text(node)`, `rpv.topo_dump(node[, path])`, `rpv.topo_map(node)`,
`rpv.topo_stats(node)`.
Every node reports, in one small text datagram (`topo_interval`, default 5 s), only what it
already knows: its id/role/version, its interfaces (`IFACE name= cidr= ch= mtu= kind=`),
its neighbours (`PEER ip= kind=arp|dv|fabric|wan [id=]` — from the ARP cache, DV routes,
fabric peers and WAN peers) and the services it runs (`SVC dhcp= leases= dns= nat= mcast=
qos= dv=`). Reports go to `topo_server` (a collector) or to a limited broadcast.
The collector (`topo_collect=1`, port `topo_port`, default 6900) merges them by node id,
resolves each peer address to the node that owns it (so it can draw **links**), expires
nodes that stop reporting (`topo_ttl`, default 20 s), and can write the map
(`topo_dump=1`, `topo_dump_every=10`):
```
NETMAP_BEGIN nodes=5 links=5 at=12
NODE id=21 role=router addrs=10.0.1.1/24,10.0.2.1/24 peers=3
LINK 21<->22 kind=arp
NETMAP_END
```
The same text is written to `netmap.txt` and logged line by line. Logs: `TOPO_START`,
`TOPO_SENT`, `TOPO_REPORT_RX`, `TOPO_STATE nodes= links= reports_rx= reports_sent= dumps=`.
Measured (`poc/run-topo.ps1`): a 2-router + 3-host network (routers running DV) discovered
**5 nodes and 5 links** (router↔router plus every host↔router) in ~12 s, with the map
written and framed; `tests/t_topo.lua` covers the parsing/link/expiry logic offline.

### compatibility + operations (`compat.lua`, node hot reload)
`rpv.compat_check()` → `ok, missing, optional`; `rpv.compat_setup(node)` logs
`COMPAT ok=... os=... missing=... optional=...` at boot (called automatically by
`node:setup`), so an unsupported host is reported instead of failing mysteriously.
See [COMPAT.md](COMPAT.md) for the version matrix and degradation behaviour.

**Hot reload** — the node's tick watcher (every 2 s, needs `fs.attributes`) reloads:
* `routes.txt` → `ROUTES_RELOADED n=N (file change)` (routes are replaced, non-file kinds kept)
* `role.txt` → `CFG_RELOAD changed=N restart_required=M`; each applied key logs
  `CFG_CHANGED key=old->new` and each key that cannot be applied live logs
  `CFG_RELOAD_RESTART_REQUIRED key=<name>`. Immutable-while-running keys: `role`, `iface`,
  `wan`, `fabric`, `app`, `spawn`, `dhcp`, `dhcp_pool`, `nat_out`, `rpv_host`.
  Applied keys with side effects are pushed into running services (`dv_interval`,
  `dv_timeout`, `dv_port`, `qos_budget`, `qos_budget_bytes`, `qos_max_queue`, `mcast_rate`,
  `bcast_rate`); new connections pick up `conn_*` changes at creation.
* `hosts.txt` → `HOSTS_RELOADED` (static name mappings for `rpv.lookup`).
API: `node:reload_cfg(why)`, `node:reload_routes(why)`, `node:reload_routes` also used by
the caller-supplied `load_routes`.

### connections (`conn`)
`rpv.conn_connect(node, ip, port, opts) -> conn`,
`rpv.conn_listen(node, port, on_accept)`, `rpv.conn_parse(data)`,
`rpv.CONN_TYPES`, `rpv.conn_psk_derive(node)`.
Connection object: `conn:send(data)`, `conn:close()`, `conn:abort(why)`,
`conn:log_stats(tag)`, `conn:on_open(fn)`, `conn:on_data(fn)`, `conn:on_close(fn)`,
fields `cwnd`, `ssthresh`, `srtt`, `rto`, `mss`, `tx`, `retx`, `bytes_tx`, `bytes_rx`,
`peer_ip`, `peer_port`, `secure`, `sec_drops`.
Tuning keys (in the node config): `conn_mss`, `conn_rwnd`, `conn_rto`,
`conn_rto_min` (default **0.2**, i.e. 4 server ticks — measured optimum),
`conn_rto_max`.

**Secure mode (control-plane AEAD)** — `conn_secure=1` with `conn_psk=<hex|passphrase>`:
SYN/SYN-ACK carry authenticated nonces (`HMAC(k_ctrl, ...)`), per-direction session keys
come from `HKDF(psk, nonce_c|nonce_s, "rpv-conn-c2s"/"-s2c")`, and every segment is
encrypt-then-MAC: `header(13) | ChaCha20(payload, nonce_dir, counter=seq) | tag(16)`.
A wrong PSK cannot complete the handshake (`CONN_SEC_SYN_REJECT` on the server) and a
secure node refuses a plaintext peer (`CONN_SEC_PEER_PLAINTEXT` + abort = fail closed).
`CONN_STATS ... secure=true sec_auth_fail=0 sec_ctrl=0 sec_plaintext=0` reports the audited
counters. Extra keys: `conn_psk_iter` (PBKDF2 rounds for a passphrase), `conn_sec_mac_len`
(tag length, default 16). Measured overhead (CraftOS-PC, 4.4 KB over `conn`):
**0.837 s plain → 1.383 s secure** (~1.65x, matching the ~215 KB/s crypto budget).

### WAN tunnel AEAD (`wansec.lua`)
`rpv.wansec_setup(node, w)` (or `wan_secure=1`), `rpv.wansec_hello`, `rpv.wansec_wrap`,
`rpv.wansec_unwrap`, `rpv.wansec_sign_table`, `rpv.wansec_verify_table`, `rpv.wansec_stats`.
The rednet WAN is the least private link in a CC network (any modem on the channel hears
it), so with `wan_secure=1` + `wan_psk=<hex|passphrase>`:
* every node broadcasts `rpv-sec-hello` = mac + nonce + `HMAC(k_ctrl, "HELLO"|mac|nonce)`;
  on a valid hello both sides derive **per-peer session keys** from the ordered
  (mac, nonce) pair — one round of hellos is enough, no extra handshake state;
* data frames become `"S" | counter(4) | ChaCha20(frame) | tag(16)` (tag over
  `counter|ciphertext`; retransmissions reuse the counter → identical ciphertext);
* control tables (`rpv-advert`, `rpv-who-has`, `rpv-is-at`) are signed over a canonical
  field list with `k_ctrl`;
* **replay window**: per-peer monotonic counter + 64 entries (`WANSEC_REPLAY`), and the
  session state is *kept* across repeated hellos (re-deriving would reset the window and
  make a captured frame replayable);
* **fail closed**: with `wan_secure=1` a plaintext frame, an unsigned table, a hello with
  a bad tag, or a peer we have no keys for is dropped and counted
  (`WANSEC_AUTH_FAIL`/`WANSEC_PLAINTEXT`/`WANSEC_NO_KEYS`).
Keys: `wan_psk_iter`, `wan_sec_mac_len`, `wan_replay_window`, `wan_hello_interval`.
Measured evidence (`poc/run-wansec.ps1`, which runs a real eavesdropper on the WAN):
plaintext baseline — the sniffer **sees** the marker; secure — end-to-end ping + marker
still work, the sniffer sees only `"S"…` ciphertext, and its spoofed verbatim replay is
dropped (`WANSEC_REPLAY from=21 counter=1 top=2`); wrong PSK — no tunnel, `auth_fail>0`.

### QoS egress queues (`qos.lua`) — control traffic in front of bulk
`rpv.qos_setup(node)` (or `qos=1`), `rpv.qos_enqueue(...)` (called from `link_send` when
enabled), `rpv.qos_classify(body, etype)`, `rpv.qos_flush(node)`, `rpv.qos_stats(node)`.
Frames are queued per interface in three priorities:
**0 control** (ARP/ICMP, **conn pure ACKs** — segment type 3 with length 0, DV/announce),
**1 interactive** (UDP ≤ `qos_small`, default 96 B), **2 bulk** (everything else). A tick
task drains them: all of priority 0 first, then weighted rounds (`qos_weights=4,2,1`)
within a per-tick budget (`qos_budget` frames / `qos_budget_bytes`). A full queue
(`qos_max_queue`) drops the least urgent frame first, so bulk pays for congestion and
control does not. `qos_stats()` returns `tx/high/mid/low/dropped/queued/depth`.
Measured (`poc/run-qos.ps1`): the same 4 KB conn transfer under the same 120-packet flood
took **319 ms without QoS and 276 ms with QoS on the receiver**, both with 0 retransmits,
receiver counters `high=11 mid=1 low=66 dropped=54` — i.e. the ACKs (priority 0) passed
the 66 bulk echo replies and the drop policy hit bulk frames only.

### NAT-lite (`nat.lua`) — port forwarding + masquerade
`rpv.nat_setup(node)`, `rpv.nat_new(node, opts)`, `rpv.nat_input_hook(node, iface, h, payload)`
(wired into `ip_deliver`, so it applies before local delivery *and* forwarding).
Config: `nat=1`, `nat_out=<external iface>`, `nat_forward=7000>10.0.1.2:7000,...`,
`nat_port_base=40000`, `nat_max_flows=64`, `nat_timeout=60`.
Outbound traffic gets its source rewritten to the external address plus a pool port
(UDP checksum recomputed; ICMP echo requests are translated by id) and a flow entry maps
replies back; inbound traffic to a forwarded port is redirected to the internal host
(the mapping is remembered so the reply leaves on the same external port). Anything
inbound to the external address without a rule or flow is logged `NAT_DROP` and silently
dropped (no ICMP unreachable, like a dark NAT). Counters in `NAT_STATE`:
`flows/xlate/fwd/drops/expires/exhausted/icmp`; also `NAT_POOL_EXHAUSTED`.

### multicast groups + broadcast domains (`mcast.lua`)
`rpv.mcast_setup(node)`, `rpv.mcast_join(node, group)`, `rpv.mcast_leave`,
`rpv.mcast_joined`, `rpv.mcast_send(node, group, dport, data[, sport, iface])`,
`rpv.mcast_test(ip)`, `rpv.mcast_input_hook(...)`.
A multicast packet is an IP datagram to `224.0.0.0/4` sent as an L2 broadcast on the local
segment; each node keeps only the groups it joined (`mcast_groups=239.1.1.1,...`).
Routers forward group traffic only across allowed `mcast_domains=LAN-A>LAN-B` pairs and
rate-limit it (`mcast_rate`, default 20/s) — a packet arriving on an interface with no
rule is `MCAST_DENY`ed. `bcast_relay=LAN-A>LAN-B` (plus `bcast_rate`) does the same for
limited broadcast, which the IP layer never forwards by default.
Logs: `MCAST_START`, `MCAST_JOIN`, `MCAST_SEND`, `MCAST_LOCAL`, `MCAST_FORWARD`,
`MCAST_DENY`, `MCAST_RATE_DROP`, `MCAST_NOJOIN`, `BCAST_FORWARD`, `BCAST_RATE_DROP`,
`MCAST_STATE joined= sent= local= forwarded= denied= rate_drops= bcast_fwd= bcast_drops=`.

### dynamic routing (`dv` — distance vector, RIP-lite)
`rpv.dv_setup(node, opts)` (also triggered by `dv=1` in the config), `rpv.dv_new(node, opts)`,
`rpv.DV_INFINITY` (16 = unreachable).
Routers announce `(net, prefix, metric)` over UDP `dv_port` (default 6800) on every
non-WAN interface every `dv_interval` seconds (default 3); a neighbour's announcement
installs `net -> via neighbour` with metric + 1. Loop suppression: **split horizon with
poisoned reverse** (back to the neighbour a route came from it is announced as infinity),
**hop limit** 16, and **hold-down expiry** (`dv_timeout`, default 12 s → `DV_EXPIRE`).
Installed routes use kind `dv`. Preference is enforced **at install time** (not by
reordering `route_lookup`, which stays first-added-wins): a DV entry that would shadow a
route of the same prefix with a higher rank is skipped (`DV_SHADOWED`), and
`rpv.ROUTE_RANK` documents the order (`connected`/`fabric` 4 > `file`/`static`/`api`/`dhcp` 3
> `dv` 2 > `default` 1).
Logs: `DV_START`, `DV_TX`/`DV_RX` (with `dv_debug=1`), `DV_INSTALL`, `DV_UPDATE`,
`DV_REMOVE`, `DV_EXPIRE`, `DV_ROUTE` (one line per learned route each interval),
`DV_STATE learned= neighbors= installs= updates= removes= expires= poisoned= announces=`.
`route_upsert(rt, prefix, net, iface, gw, kind[, drop])` is the helper that keeps
repeated announcements from duplicating entries.

### services — DHCP-lite + lookup-lite (`services.lua`)
Address autoconfiguration and name resolution, both plain rpv UDP services (so they
work across routers and the rednet WAN).

| Function | Purpose |
| --- | --- |
| `rpv.dhcp_server_start(node, opts)` | serve leases from `dhcp_pool=start-end` (`dhcp_gw`, `dhcp_dns`, `dhcp_lease`, `dhcp_port` default 6700). Replies are unicast when the client is routable, broadcast otherwise (a client without an address is not routable) |
| `rpv.dhcp_client_start(node, iface, opts)` | broadcast DISCOVER → OFFER → REQUEST → ACK, then adopt the lease (re-address the interface, replace its connected route, install the default route) and register the name |
| `rpv.dhcp_apply(node, iface, lease)` | apply an OFFER/ACK by hand |
| `rpv.dns_server_start(node, opts)` | answer REGISTER/QUERY on `dns_port` (default 6701); also resolves names learned from its own DHCP leases |
| `rpv.dns_register(node, name)` | announce `name -> my address` to the name server (`dns_server`, else the default gateway) |
| `rpv.lookup(node, name, timeout, cb)` | name → IP: static `hosts.txt` first, then a QUERY. Blocking-style (use inside a task) or pass `cb` |
| `rpv.hosts_load(node, path)` | load `<name> <ip>` lines (default `hosts.txt`) |
| `rpv.services_setup(node)` | called by `node:setup()`; starts whatever the config asks for (`dhcp=1`, `dhcp_pool=`, `dns=1`, `name=`) |

Config keys: client `dhcp=1` + `name=<host>` + `dns_server=<ip>` (the interface starts
with a placeholder address, convention `10.254.0.0/16`); server `dhcp_pool=`, `dhcp_gw=`,
`dhcp_dns=`, `dhcp_lease=`, `dns=1`. Node conveniences: `node:dns_register(name)`,
`node:lookup(name, timeout, cb)`, plus `node.dhcp`, `node.dhcp_client`, `node.dns`,
`node.hosts`.

### cluster fabric (`fabric`)
`rpv.fabric_new(side, channel, mtu)`, `rpv.fabric_setup(node, f)`,
`rpv.fabric_send_frame(node, f, dstmac, body)`, `rpv.fabric_announce(node, f)`,
`rpv.fabric_forward(...)`, `rpv.fabric_input(node, f, body, srcmac)`,
`rpv.fabric_rebuild_routes(node, f)`, `rpv.fabric_tick(node, f)`, `rpv.ET_FABRIC`.

### Address semantics (`ip.lua`)

`rpv/ip.lua` classifies every address the way IPv4 does (RFC 6890 style) and the data path
enforces it:

| Class | Blocks | Behaviour |
| --- | --- | --- |
| `loopback` | 127/8 | stays on the node: delivered through the receive path with **zero** modem traffic; never forwarded, never accepted from a modem |
| `private` (LAN) | 10/8, 172.16/12, 192.168/16 | what an interface is expected to use; forwardable |
| `cgnat` | 100.64/10 | forwardable |
| `linklocal` | 169.254/16 | usable on a segment, never forwarded by a router |
| `unspecified` | 0/8 | valid as a source only; a destination is dropped |
| `multicast` | 224/4 | group traffic (see `mcast.lua`); never forwarded by the plain router path |
| `reserved` | 240/4 | never forwarded |
| `protocol` / `testnet` / `benchmark` | 192.0.0/24, 192.0.2/24, 198.51.100/24, 203.0.113/24, 198.18/15 | accepted locally, never forwarded |
| `broadcast` | 255.255.255.255 | limited broadcast, stays on the segment (see `mcast.lua` for relaying) |
| `public` | everything else | forwardable |

* **Every node owns 127.0.0.0/8** (`node.lo`, deliberately kept out of `node.ifaces`: no
  modem, no channel, never announced by DV, never a broadcast target). Ping or send to
  127.0.0.1 and it round-trips locally: `node.stats.lo_sent` counts it while
  `node.stats.tx` does not move.
* **Directed broadcast**: an address whose host bits are all 1 inside the interface subnet
  (`10.0.1.255/24`) is delivered to that segment only (L2 broadcast, IP dst = the directed
  address). A router never relays it to another subnet (`directed_bcast_drop`).
* **Drops are counted, not silent**: `reserved_drop` (loopback/0/8 forged or wire-borne,
  or a reserved destination on the transmit path) and `directed_bcast_drop`.
* **Configuration checks** run at setup: `IFACE_CLASS side=… class=… private=…` per
  interface, `CFG_WARN ADDR_NOT_UNICAST | ADDR_IS_NETWORK | ADDR_IS_BROADCAST |
  ADDR_NOT_PRIVATE` for bad addresses, and `ADDR_WARN_SUMMARY warnings=…`. A LAN is
  expected to use RFC1918: `10/8`, `172.16/12`, `192.168/16` are accepted silently, a
  public address (e.g. `8.8.8.0/24`) warns, and 192/8 addresses outside 192.168/16
  (192.0.0.0/24, 192.0.2.0/24) are *not* private.
* API: `rpv.ip_class(ip)`, `ip_class_info`, `ip_is_private`, `ip_is_loopback`,
  `ip_is_multicast`, `ip_is_linklocal`, `ip_is_unspecified`, `ip_is_broadcast`,
  `ip_forwardable`, `ip_directed_broadcast(net, prefix)`, `ip_is_directed_broadcast(ip, iface)`,
  `ip_iface_warnings(iface)`.
* Acceptance: `poc/tests/t_addr.lua` (classification matrix, forwardability, directed
  broadcast, warning codes) and `poc/run-addr.ps1` (CraftOS-PC: loopback without modem
  traffic, reserved destinations refused, directed broadcast answered, ADDR_WARN on a
  deliberately public host).

### DHCP-lite (`services.lua`)

Address autoconfiguration on top of rpv's own stack (not RFC 2131 on the wire: the
messages are a compact rpv format, so it only interoperates with rpv peers).

```
DISCOVER (broadcast) -> OFFER  (offered ip/mask/gw/dns/lease, server-id, client-id)
REQUEST  (broadcast) -> ACK    (lease committed)  |  NAK (bad request / no free address)
RELEASE                frees the lease
DECLINE                blacklists the offered address (somebody already uses it)
```

* **Leases are keyed on the client id (its mac)**, falling back to the source address
  only when the client sends no id -- keying on the source address alone collides as soon
  as two clients still hold the same placeholder address.
* **Conflict probe**: before offering, the server probes the candidate with an ICMP echo
  (configurable: `dhcp_probe=0` disables it, `dhcp_probe_timeout` in seconds) and skips an
  address that answers, marking it bad.
* **Lease lifecycle**: an offer expires after `dhcp_offer_ttl` (default 30 s); a bound
  lease after `dhcp_lease` (default 600 s). `M.dhcp_expire(node, srv, now)` (also run by a
  sweeper every `dhcp_sweep` seconds) logs `DHCP_EXPIRE` and returns the addresses to the
  pool (allocation wraps around). The client renews at T1 = `dhcp_lease/2` (override with
  `dhcp_t1` seconds or `dhcp_t1_scale`), logs `DHCP_RENEW`, and falls back to a fresh
  DISCOVER if the server stops answering; the server logs `renew=true` on each extension.
* **Client API**: `rpv.dhcp_client_start(node, iface)` (or `dhcp=1`), `rpv.dhcp_release(node)`
  (hand the lease back from a `node:shutdown` handler), `rpv.dhcp_decline(node, ip)`
  (report an address that is already in use). On ACK the interface is re-addressed, its
  connected route replaced, the default route installed and the hostname registered.
* **Server keys**: `dhcp_pool=10.0.1.100-10.0.1.150`, `dhcp_gw`, `dhcp_dns`, `dhcp_lease`,
  `dhcp_port` (6700), `dhcp_offer_ttl`, `dhcp_sweep`, `dhcp_probe`, `dhcp_probe_timeout`.
* **Limits** (by design): single segment (no relay), no options beyond
  ip/mask/gw/dns/lease/name, leases live in RAM (a restart forgets them), and no
  cross-vendor interop.
* Logs: `DHCP_SERVER_START`, `DHCP_OFFER`, `DHCP_LEASE`, `DHCP_NAK`, `DHCP_EXPIRE`,
  `DHCP_RELEASE`, `DHCP_DECLINE`, `DHCP_PROBE_INUSE`, `DHCP_CLIENT_START`,
  `DHCP_DISCOVER`, `DHCP_OFFER_GOT`, `DHCP_BOUND`, `DHCP_RENEW`, `DHCP_APPLIED`.
* Acceptance: `poc/tests/t_services.lua` (offline: pool/idempotence/exhaustion/NAK/expiry/
  renewal/release/decline/probe/client state machine) and `poc/run-svc.ps1` (CraftOS-PC,
  including a T1 renewal during the run).

### rednet WAN (`wan`)
`rpv.wan_new(side, mtu)`, `rpv.wan_setup(node, w, cidr)`,
`rpv.wan_frame_send(node, w, peer, pkt)`, `rpv.wan_send(node, w, path, src, dst, proto, ttl, payload)`,
`rpv.wan_input(node, w, sender, message, protocol)`,
`rpv.wan_advert(node, w)`, `rpv.wan_advert_loop(node, w)`,
`rpv.wan_advert_input(node, w, sender, message)`, `rpv.wan_who_has(...)`,
`rpv.wan_legacy_rx(node, w, sender, message)`.

**Modem media (wired / wireless / advanced / ender-as-bridge).** The WAN port accepts any
peripheral that reports type `modem` -- wired, wireless and advanced modems all do, and
nothing in the library assumes wireless. `wan_setup` logs what it actually found:
`WAN_READY side=... peripheral=modem phys_wireless=true|false|nil` (`nil` = the peripheral
has no `isWireless()` method, i.e. a wired modem). Consequences of the medium:

* **wireless**: the peer must be within wireless range; a wireless network is shared, so the
  WAN channel carries every node's traffic.
* **wired**: both modems must be on the same wired network (`computercraft:wired_modem_full`
  chains; a `/fill` of `computercraft:cable` does not join a network). Wired WAN is faster and
  physically isolated, but a wired modem cannot cross dimensions -- that is what the
  standalone bridge program is for.
* **ender/advanced**: only ever used by the standalone bridge program, never by `rpv/*`.

The WAN interface also gets a **connected route** for its own subnet, so a directly attached
WAN peer is reachable without waiting for an advert. Related keys:

| Key | Meaning |
| --- | --- |
| `wan_modem=modem\|wired_modem_full` | emulator only: kind to `periphemu.create` for the WAN side |
| `modem_<side>=modem\|wired_modem_full` | emulator only: same, per interface side |
| `wan_peer=<ip>:<id>[,<ip>:<id>...]` | static WAN neighbours (a static-ARP equivalent): pins `ip -> rednet id` so the first packet does not wait for an advert/hello to learn the peer id |

Acceptance: `poc/run-wansec.ps1` (wireless, CraftOS-PC) and
`poc\mc\run-mc.ps1 -Scenario wanlink -WanLink wired|wireless -Target fabric` (direct WAN-only
topology, real server: 4/4 ICMP + 900 B UDP echo, `WAN_LINK=wired|wireless` reported).

## Examples (in `poc/examples/`, installed as `startup.lua`)

| File | What it shows |
| --- | --- |
| `rpv-echo.lua` | minimal host: config table, `node:setup()`, UDP echo via `node:bind` + `rpv.udp_send`, `node:run()` |
| `rpv-libtest.lua` | self-check that uses only this API: ARP, ICMP with RTT, UDP round trip, 4 KiB fragmentation/reassembly, stats |

Both are run as acceptance tests: `pwsh -File poc\run-lib.ps1` (CraftOS-PC) and
`pwsh -File poc\mc\run-mc.ps1 -Scenario lib -Target fabric` (real Minecraft).

## Wire format

Frame `dstMAC(4)|srcMAC(4)|ethertype(2)|body`; ethertypes for IPv4/ARP/fabric;
IPv4 header with checksum, DF/PMTU (RFC 1191 ICMP type 3 code 4), fragmentation
and bounded reassembly; UDP with pseudo-header checksum; rednet interop via adverts
(`ver/seq/hops/default`) on the WAN interface. See the project's
[roadmap](../rpv-roadmap.md) and [measurements](../poc/out/measurements-mc.md).
