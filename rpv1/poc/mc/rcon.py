#!/usr/bin/env python3
"""Minimal Minecraft RCON client (Source RCON protocol).

Used by the rpv harness to drive a headless MC server: place computers/modems,
read block data and run commands without a player.

  python rcon.py <host> <port> <password> "<command>" [more commands...]
  python rcon.py --batch <host> <port> <password> <file-with-commands>

Exits 0 on success, 1 on failure; each command's response is printed with a
"--- <command>" header so the caller can grep it.
"""
import socket
import struct
import sys
import time

LOGIN = 3
COMMAND = 2

# Minecraft/RCON payloads and batch files may contain non-ASCII; never die on
# console encoding (Windows defaults to GBK here).
try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    sys.stderr.reconfigure(encoding="utf-8", errors="replace")
except Exception:  # noqa: BLE001
    pass


class RconError(Exception):
    pass


class Rcon:
    def __init__(self, host, port, password, timeout=10.0):
        self.sock = socket.create_connection((host, port), timeout=timeout)
        self.sock.settimeout(timeout)
        self.rid = 0
        self._send(LOGIN, password)
        rid, _type, body = self._recv()
        if rid == -1:
            raise RconError("authentication failed")

    def _send(self, ptype, body):
        self.rid += 1
        payload = struct.pack("<ii", self.rid, ptype) + body.encode("utf-8") + b"\x00\x00"
        self.sock.sendall(struct.pack("<i", len(payload)) + payload)
        return self.rid

    def _recv_exact(self, n):
        buf = b""
        while len(buf) < n:
            chunk = self.sock.recv(n - len(buf))
            if not chunk:
                raise RconError("connection closed")
            buf += chunk
        return buf

    def _recv(self):
        (length,) = struct.unpack("<i", self._recv_exact(4))
        payload = self._recv_exact(length)
        rid, ptype = struct.unpack("<ii", payload[:8])
        return rid, ptype, payload[8:-2].decode("utf-8", "replace")

    def cmd(self, command):
        self._send(COMMAND, command)
        _rid, _type, body = self._recv()
        return body

    def close(self):
        self.sock.close()


def main(argv):
    if len(argv) >= 5 and argv[1] == "--batch":
        host, port, password, path = argv[2], int(argv[3]), argv[4], argv[5]
        # utf-8-sig: tolerate a BOM written by PowerShell's Set-Content
        with open(path, "r", encoding="utf-8-sig") as fh:
            cmds = [ln.strip() for ln in fh if ln.strip() and not ln.startswith("#")]
        cmds = [c.lstrip("\ufeff").strip() for c in cmds]
    elif len(argv) >= 5:
        host, port, password, cmds = argv[1], int(argv[2]), argv[3], argv[4:]
    else:
        print(__doc__)
        return 2

    r = Rcon(host, port, password)
    try:
        for c in cmds:
            try:
                out = r.cmd(c)
            except Exception as exc:  # noqa: BLE001
                print("--- %s\nERROR %s" % (c, exc))
                return 1
            print("--- %s" % c)
            if out.strip():
                print(out)
            time.sleep(0.02)
    finally:
        r.close()
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
