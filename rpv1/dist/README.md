# RPV1 library 1.0.0 - internal install notes

RPV1 (Rednet Protocol Version 1) is a user-space IPv4-like network stack for
CC:Tweaked computers: MAC/IPv4/ARP/ICMP/UDP, routing, fragmentation, PMTU,
a connection layer with congestion control, a cluster fabric, and rednet as WAN.

Requires: **CC:Tweaked 1.120.x** (Minecraft 1.21.1) or **CraftOS-PC 2.8.x**.

## Option A - single file (easiest)

Copy `rpv-bundle.lua` to a computer and:

    local rpv = dofile("rpv-bundle.lua")
    local node = rpv.node_new({ role = "host",
        ifaces = { { side = "left", name = "LAN", cidr = "10.0.1.2/24",
                     channel = 4001, mtu = 256, linktype = "wireless" } },
        gw = "10.0.1.1" })
    node:setup()
    node:bind(4100, function(data, src, sport)
        rpv.udp_send(node, src, 4100, sport, "pong")
    end)
    rpv.icmp_echo(node, rpv.ip2int("10.0.1.1"), 1, "hello")
    node:run()

## Option B - folder layout (recommended for projects)

    /rpv.lua          <- entry point
    /rpv/*.lua        <- modules
    /compat/rednet.lua  (optional: legacy rednet programs)
    /examples/*.lua   (optional)

then in your program:

    local rpv = require("rpv")

## Option C - let the installer do it

Put `install.lua` + `MANIFEST.txt` + the files next to each other (e.g. on a
floppy or in a folder), then on the computer:

    install.lua                 -- from the current directory
    install.lua /disk           -- from a floppy/disk path
    install.lua https://<your-host>/rpv-release   -- from an HTTP(S) base URL (self-hosted)
    install.lua /disk --target /lib --no-examples

The installer copies every file listed in `MANIFEST.txt`, verifies its CRC32 and
size in pure Lua, then loads the installed copy and builds a node, printing:

    INSTALL_OK files=.. verified=.. skipped=..
    INSTALL_VERIFY ok=true version=RPV1 modules=<n>

`MANIFEST.txt` also carries SHA256 for every file (verify from your OS if you
want strong integrity; the installer's built-in check is CRC32 + size).

## Self-check

`examples/rpv-libtest.lua` is a complete external program that only uses the
public API. Install it as `startup.lua` on two computers (edit the two IP
constants) and it checks ARP, ICMP with RTT, a UDP round trip, 4 KiB
fragmentation/reassembly and the stats surface, ending with
`LIBTEST_RESULT ... pass=true`.

## Files in this release

    rpv.lua rpv/*.lua            the library (folder layout)
    rpv-bundle.lua               the same library as one file
    install.lua                  on-computer installer
    compat/rednet.lua            rednet compatibility shim
    examples/rpv-echo.lua        minimal UDP/ICMP host
    examples/rpv-libtest.lua     library self-check (7 assertions)
    API.md                       public API reference (stable surface)
    MANIFEST.txt                 sha256 / crc32 / size for every file
    LICENSE                      MIT license text

This package is distributed under the MIT License: see ``LICENSE`` in this
release and the repository's LICENSE file.
    

Public API and design notes live in `API.md`; the project's roadmap, wire format
and real-machine measurements are in the source repository.