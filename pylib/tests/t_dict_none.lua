-- t_dict_none.lua - Python None as a dict key or value.
--
-- Lua tables cannot store nil, so the interpreter keeps a None that is stored
-- in a dict as an internal sentinel and unwraps it on every read. These tests
-- pin both halves: the entry stays visible (len / `in` / repr / get / pop)
-- and the value reads back as Python None instead of vanishing.
--
-- Still a gap: a None cannot be stored in a LIST, so materialising a dict
-- into a list drops it (`values()`/`items()` on a None value, copy.deepcopy).
-- That is recorded in tests/COVERAGE.md section 2, not asserted here.

local H = ...

H.group("dict-none:value")
H.expect('d = {"a": None}\nprint(len(d))', "1", "a None value keeps the key")
H.expect('d = {"a": None}\nprint(d["a"])', "None",
    "reading a None value gives None")
H.expect('d = {"a": None}\nprint("a" in d)', "True",
    "`in` sees the key of a None value")
H.expect('d = {}\nd["b"] = None\nprint(len(d))\nprint(d["b"])',
    "1\nNone", "assigning None keeps the key")
H.expect('d = {"a": None}\nprint(d)', "{'a': None}",
    "repr of a dict with a None value")
H.expect('d = {"a": None}\nprint(d.get("a"))\nprint(d.get("a", "x"))',
    "None\nNone", "get returns the stored None, not the default")
H.expect('d = {"a": None}\nprint(d.pop("a"))\nprint(len(d))', "None\n0",
    "pop returns the stored None and removes the key")

H.group("dict-none:key")
H.expect('d = {None: 1}\nprint(d[None])', "1", "None can be a dict key")
H.expect('d = {None: 1}\nprint(None in d)', "True", "`in` finds a None key")
H.expect('d = {None: 1}\nprint(len(d))', "1", "len counts a None key")
H.expect('d = {None: 1}\nprint(d)', "{None: 1}", "repr of a None key")
H.expect('d = {None: 1}\nprint(d.get(None))', "1",
    "get works with a None key")
H.expect('d = {}\nd[None] = "n"\nprint(d[None])', "n",
    "assigning through a None key")

H.group("dict-none:absent")
-- A missing key is still a KeyError / default: the None sentinel must not
-- leak out as "present".
H.expectError('d = {}\nprint(d["missing"])', "KeyError",
    "a missing key still raises KeyError")
H.expect('d = {"a": None}\nprint(d.get("missing", "fallback"))', "fallback",
    "get default for an absent key")
H.expect('d = {"a": None}\nprint(len(d))\nprint("missing" in d)',
    "1\nFalse", "an absent key is not in a dict that holds a None value")

H.group("dict-none:json")
H.expect('import json\nprint(json.dumps({"a": None}))', '{"a":null}',
    "json.dumps encodes a None value as null")
H.expect('import json\nprint(json.loads("{\\"a\\": null}")["a"])', "None",
    "json.loads stores null as None")

H.group("dict-none:kwargs")
H.expect('def f(**kw):\n    return len(kw)\nprint(f(a=None))', "1",
    "a None keyword argument is kept in **kwargs")
H.expect('def f(**kw):\n    return kw["a"]\nprint(f(a=None))', "None",
    "reading a None keyword argument through **kwargs")
