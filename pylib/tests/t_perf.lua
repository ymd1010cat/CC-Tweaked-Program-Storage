-- t_perf.lua - performance evidence for the "slotting" item, plus the
-- correctness net a future optimisation has to keep green.
--
-- pylib/DECISIONS.md explains why local-variable slotting was deferred. The
-- numbers below are the evidence: the host VM is CraftOS-PC's Lua 5.2, where a
-- table-hash access and an array-slot access cost the same inside the noise, so
-- rewriting name lookups into slots cannot pay for itself. Timing lines are
-- emitted as PERF <key> <value> and are NOT asserted (CraftOS-PC timings move
-- with the host); the correctness rows are asserted.

local H = ...

local function minTime(fn, trials)
    local best = nil
    for _ = 1, trials do
        local t0 = os.clock()
        fn()
        local dt = os.clock() - t0
        if best == nil or dt < best then best = dt end
    end
    return best
end

H.group("perf:correctness")
-- The benchmark programs themselves must be right, otherwise the timings are
-- meaningless.
H.expect('def loop(n):\n    i = 0\n    s = 0\n    while i < n:\n' ..
    '        s = s + i\n        i = i + 1\n    return s\n' ..
    'print(loop(20000))', "199990000", "benchmark loop result")
H.expect('def add(a, b):\n    return a + b\nn = 0\ni = 0\n' ..
    'while i < 5000:\n    n = add(n, i)\n    i = i + 1\nprint(n)',
    "12497500", "benchmark call result")

-- Safety net for any future slotting work: every way a name can be resolved
-- today. If a slot rewrite gets one of these wrong, the suite fails here.
H.group("perf:name-resolution-net")
H.expect('def outer():\n    x = 1\n    def mid():\n        def inner():\n' ..
    '            return x\n        return inner()\n    return mid()\n' ..
    'print(outer())', "1", "three-level closure lookup")
H.expect('x = "global"\ndef f():\n    x = "local"\n    return x\n' ..
    'print(f())\nprint(x)', "local\nglobal", "local shadows global")
H.expect('g = 1\ndef bump():\n    global g\n    g = g + 1\n' ..
    'bump()\nbump()\nprint(g)', "3", "global write hits module scope")
H.expect('def outer():\n    n = 0\n    def inc():\n        nonlocal n\n' ..
    '        n = n + 1\n    inc()\n    inc()\n    return n\n' ..
    'print(outer())', "2", "nonlocal write hits the enclosing frame")
H.expect('def f(a):\n    return a\nprint(f(7))\nprint(a)', "7\nNone",
    "a parameter is not visible outside its call")
H.expect('def f(a=[]):\n    a.append(1)\n    return a\nprint(f())\nprint(f())',
    "[1]\n[1, 1]", "default argument is evaluated once, at def time")
H.expect('def order():\n    a = 1\n    b = a + 1\n    a = 9\n    return b\n' ..
    'print(order())', "2", "assignment order inside a frame")
H.expect('class C:\n    def __init__(self):\n        self.v = []\n' ..
    '    def add(self, x):\n        self.v.append(x)\n        return self.v\n' ..
    'c = C()\nc.add(1)\nprint(c.add(2))', "[1, 2]",
    "instance attributes survive across calls")
H.expect('def f(n):\n    if n == 0:\n        return "done"\n    return f(n - 1)\n' ..
    'print(f(30))', "done", "recursion keeps frames separate")

H.group("perf:host-vm")
-- Raw host cost of the two access shapes slotting would swap between.
local N = 2000000
local tbl = {}
local acc = 0
-- Baseline: one add plus the loop itself, so the marginal cost of a table
-- access can be isolated instead of being hidden by loop overhead.
local baseRead = minTime(function()
    for i = 1, N do acc = acc + 1 end
end, 3)
local hashWrite = minTime(function()
    for i = 1, N do tbl.name = i end
end, 3)
local arrayWrite = minTime(function()
    for i = 1, N do tbl[1] = i end
end, 3)
local hashRead = minTime(function()
    for i = 1, N do acc = acc + tbl.name end
end, 3)
local arrayRead = minTime(function()
    for i = 1, N do acc = acc + tbl[1] end
end, 3)
H.note(string.format("PERF host.base_read_per_2M=%.4f", baseRead))
local function marginalNs(t)
    local d = t - baseRead
    if d < 0 then d = 0 end
    return d * 1e9 / N
end
H.note(string.format("PERF host.hash_read_marginal_ns=%.2f",
    marginalNs(hashRead)))
H.note(string.format("PERF host.array_read_marginal_ns=%.2f",
    marginalNs(arrayRead)))
H.note(string.format("PERF host.hash_read_per_2M=%.4f", hashRead))
H.note(string.format("PERF host.array_read_per_2M=%.4f", arrayRead))
H.note(string.format("PERF host.hash_write_per_2M=%.4f", hashWrite))
H.note(string.format("PERF host.array_write_per_2M=%.4f", arrayWrite))
-- Correctness of the measurement itself (a Lua loop that ran).
H.ok(acc ~= 0, "raw Lua read loop executed", acc)

H.group("perf:interpreter")
local loopSrc = 'def loop(n):\n    i = 0\n    s = 0\n    while i < n:\n' ..
    '        s = s + i\n        i = i + 1\n    return s\nprint(loop(20000))'
local callSrc = 'def add(a, b):\n    return a + b\nn = 0\ni = 0\n' ..
    'while i < 5000:\n    n = add(n, i)\n    i = i + 1\nprint(n)'
local loopTime = minTime(function()
    H.run(loopSrc)
end, 2)
local callTime = minTime(function()
    H.run(callSrc)
end, 2)
H.note(string.format("PERF interp.loop_20000_best=%.4f", loopTime))
H.note(string.format("PERF interp.calls_5000_best=%.4f", callTime))
if loopTime > 0 then
    H.note(string.format("PERF interp.loop_iters_per_sec=%.0f",
        20000 / loopTime))
end
if callTime > 0 then
    H.note(string.format("PERF interp.calls_per_sec=%.0f",
        5000 / callTime))
end
H.ok(loopTime > 0, "interpreter loop benchmark measured", loopTime)
H.ok(callTime > 0, "interpreter call benchmark measured", callTime)
