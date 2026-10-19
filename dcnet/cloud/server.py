#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""dcnet 云端参考服务端（只用 Python 标准库）

把一台能跑 Python 的机器（本机、NAS、云服务器、云函数容器…）变成 dcnet 的
"云端算力"：主控通过 HTTP POST 把任务发过来，这里算完把结果返回。

    python cloud/server.py                 # 监听 0.0.0.0:8080
    python cloud/server.py --port 9000
    python cloud/server.py --quiet         # 不打印每个请求

协议（见 docs/CLOUD.md）：

    POST /dcnet
      { "dcnet": 1, "job": "cloudprimes", "task": 7,
        "payload": { "op": "primes", "from": 2, "to": 25000 },
        "args": { ... } }
    ← { "ok": true,  "data": { "count": 2762, "last": 24989 } }
    ← { "ok": false, "err": "..." }

    GET /health  → { "ok": true, "status": "...", "ops": [...] }

内置 op（payload.op）：primes / pi / hashsearch / sleep / echo。
要接自己的算力，照抄一个 op 函数注册进 OPS 即可。
"""

import argparse
import json
import math
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

VERSION = "dcnet-cloud/1.0"

# ── 计算实现 ────────────────────────────────────────────────────────────

def is_prime(n):
    if n < 2:
        return False
    if n % 2 == 0:
        return n == 2
    if n % 3 == 0:
        return n == 3
    i = 5
    while i * i <= n:
        if n % i == 0 or n % (i + 2) == 0:
            return False
        i += 6
    return True


def op_primes(payload, body):
    lo = int(payload.get("from", 2))
    hi = int(payload.get("to", lo))
    count, last = 0, None
    for n in range(max(2, lo), hi + 1):
        if is_prime(n):
            count += 1
            last = n
    return {"lo": lo, "hi": hi, "count": count, "last": last}


def op_pi(payload, body):
    n = int(payload.get("samples", 100000))
    seed = int(payload.get("seed", 12345)) % 2147483647 or 1
    inside, s = 0, seed
    for _ in range(n):
        s = (s * 16807) % 2147483647
        x = s / 2147483647
        s = (s * 16807) % 2147483647
        y = s / 2147483647
        if x * x + y * y <= 1:
            inside += 1
    return {"n": n, "inside": inside}


def op_hashsearch(payload, body):
    lo = int(payload.get("from", 1))
    hi = int(payload.get("to", lo))
    mod = max(2, int(payload.get("modulus", 65536)))

    def h(s):
        x = 5381
        for ch in s.encode("utf-8"):
            x = (x * 33 + ch) % 2147483647
        return x

    for n in range(lo, hi + 1):
        if h("dc%d" % n) % mod == 0:
            return {"hit": n, "scanned": n - lo + 1}
    return {"hit": None, "scanned": hi - lo + 1}


def op_sleep(payload, body):
    ms = int(payload.get("ms", 0))
    time.sleep(max(0, ms) / 1000.0)
    return {"slept": ms}


def op_echo(payload, body):
    return {"echo": payload, "job": body.get("job"), "task": body.get("task")}


OPS = {
    "primes": op_primes,
    "pi": op_pi,
    "hashsearch": op_hashsearch,
    "sleep": op_sleep,
    "echo": op_echo,
}

# ── HTTP 层 ─────────────────────────────────────────────────────────────

VERBOSE = True

# 分块上传的暂存区：xid -> {"n": 块数, "parts": {序号: 文本}, "at": 时间}
CHUNKS = {}
CHUNK_TTL = 300          # 秒：攒了一半不来的分块多久清掉


class Handler(BaseHTTPRequestHandler):
    server_version = VERSION

    def _send(self, obj, code=200):
        raw = json.dumps(obj, ensure_ascii=False).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

    def do_GET(self):
        # GET 任何路径都返回服务描述：dcnet 的 `cloud test` 就是 GET 一次端点 URL，
        # 这样不用约定 /health 这种路径，自己写的服务也好实现。
        self._send({"ok": True, "status": VERSION, "ops": sorted(OPS), "path": self.path})

    def do_POST(self):
        length = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(length) if length else b""
        try:
            body = json.loads(raw.decode("utf-8") or "{}")
        except Exception as exc:                       # noqa: BLE001
            return self._send({"ok": False, "err": "bad json: %s" % exc}, 400)
        if not isinstance(body, dict):
            return self._send({"ok": False, "err": "body must be a json object"}, 400)

        # 分块上传：主控把一个大请求切成 N 块发过来（HTTP 单请求有大小上限），
        # 我们按 xid 攒起来，最后一块带 commit=true 时拼装成原来的 JSON 再执行。
        if "chunk" in body:
            return self._handle_chunk(body)

        return self._run(body)

    def _handle_chunk(self, body):
        xid = str(body.get("xid") or "")
        try:
            i, n = int(body.get("i") or 0), int(body.get("n") or 0)
        except (TypeError, ValueError):
            return self._send({"ok": False, "err": "bad chunk index"})
        part = body.get("chunk")
        if not xid or i < 1 or n < 1 or not isinstance(part, str):
            return self._send({"ok": False, "err": "bad chunk"})

        now = time.time()
        for k in [k for k, v in CHUNKS.items() if now - v["at"] > CHUNK_TTL]:
            CHUNKS.pop(k, None)
        rec = CHUNKS.setdefault(xid, {"n": n, "parts": {}, "at": now})
        rec["n"], rec["parts"][i], rec["at"] = n, part, now

        if not body.get("commit"):
            return self._send({"ok": True, "partial": i, "n": n})

        missing = [j for j in range(1, n + 1) if j not in rec["parts"]]
        if missing:
            return self._send({"ok": False, "err": "missing chunks: %s" % missing})
        text = "".join(rec["parts"][j] for j in range(1, n + 1))
        CHUNKS.pop(xid, None)
        try:
            inner = json.loads(text)
        except Exception as exc:                       # noqa: BLE001
            return self._send({"ok": False, "err": "assembled json bad: %s" % exc})
        if not isinstance(inner, dict):
            return self._send({"ok": False, "err": "assembled body must be an object"})
        if VERBOSE:
            sys.stderr.write("[cloud] 分块拼装完成 xid=%s 共 %d 块 %d 字节\n"
                             % (xid, n, len(text)))
            sys.stderr.flush()
        return self._run(inner)

    def _run(self, body):
        payload = body.get("payload") if isinstance(body.get("payload"), dict) else {}
        op = payload.get("op")
        fn = OPS.get(op)
        if not fn:
            return self._send({"ok": False, "err": "unknown op: %r" % (op,)})
        started = time.time()
        try:
            data = fn(payload, body)
        except Exception as exc:                       # noqa: BLE001
            return self._send({"ok": False, "err": "%s: %s" % (type(exc).__name__, exc)})
        if VERBOSE:
            sys.stderr.write("[cloud] job=%s task=%s op=%s %.1fms\n" % (
                body.get("job"), body.get("task"), op, (time.time() - started) * 1000))
            sys.stderr.flush()
        self._send({"ok": True, "data": data})

    def log_message(self, fmt, *args):
        if VERBOSE:
            sys.stderr.write("[cloud] %s\n" % (fmt % args))
            sys.stderr.flush()


def main(argv=None):
    global VERBOSE
    ap = argparse.ArgumentParser(description="dcnet cloud reference server")
    ap.add_argument("--host", default="0.0.0.0")
    ap.add_argument("--port", type=int, default=8080)
    ap.add_argument("--quiet", action="store_true")
    ap.add_argument("--once", action="store_true", help="只处理一个请求就退出（测试用）")
    args = ap.parse_args(argv)
    VERBOSE = not args.quiet

    httpd = ThreadingHTTPServer((args.host, args.port), Handler)
    host = "127.0.0.1" if args.host in ("0.0.0.0", "::") else args.host
    print("%s 监听 http://%s:%d/dcnet" % (VERSION, host, httpd.server_address[1]))
    print("ops: %s" % ", ".join(sorted(OPS)))
    print("在游戏里的主控输入：cloud add local http://%s:%d/dcnet 2"
          % (host, httpd.server_address[1]))
    sys.stdout.flush()
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        print("\nbye")
    return 0


if __name__ == "__main__":
    sys.exit(main())
