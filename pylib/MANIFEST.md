# python interpreter export
Source: the DeepSeek share archived by the Marvis session "lua development"
Dump: `C:\Users\ymd10\AppData\Roaming\Tencent\Marvis\User\BEE8C8819ED0EAC0E38D844A06450AE8\workspace\conv_c761312b431a4aa8935c6961ce2b1767\output\deepseek-share-t7l9c9g3h0h72ijjy2-dialogue-original.md` (2579284 bytes, 89895 lines)

## interpreter
- `pylib/pythonlib.lua`: 130759 bytes, 3647 lines, 301 revision(s) in the dump, block at line 47518, 220 mention(s) after it; compiles: yes
- `pyrepl.lua`: 6853 bytes, 224 lines, 7 revision(s) in the dump, block at line 75855, 12 mention(s) after it; compiles: yes
- `legacy-py.lua` (superseded by pythonlib.lua): 64422 bytes, 1643 lines, 6 revision(s), block at line 19664; compiles: yes

## python modules (pylib)
- `pylib/argparse.py`: 2608 bytes, 81 lines, 1 revision(s) in the dump, block at line 70649, 1 mention(s) after it; python parses: yes
- `pylib/cc.py`: 12445 bytes, 456 lines, 4 revision(s) in the dump, block at line 34620, 97 mention(s) after it; python parses: yes
- `pylib/cc_utf8.py`: 1351 bytes, 50 lines, 1 revision(s) in the dump, block at line 77067, 4 mention(s) after it; python parses: yes
- `pylib/collections.py`: 5037 bytes, 206 lines, 1 revision(s) in the dump, block at line 63871, 5 mention(s) after it; python parses: yes
- `pylib/copy.py`: 855 bytes, 41 lines, 1 revision(s) in the dump, block at line 66843, 3 mention(s) after it; python parses: yes
- `pylib/dataclasses.py`: 1846 bytes, 77 lines, 4 revision(s) in the dump, block at line 73484, 10 mention(s) after it; python parses: yes
- `pylib/datetime.py`: 3479 bytes, 97 lines, 1 revision(s) in the dump, block at line 70825, 1 mention(s) after it; python parses: yes
- `pylib/enum.py`: 903 bytes, 37 lines, 2 revision(s) in the dump, block at line 70514, 3 mention(s) after it; python parses: yes
- `pylib/functools.py`: 1250 bytes, 52 lines, 1 revision(s) in the dump, block at line 66732, 4 mention(s) after it; python parses: yes
- `pylib/itertools.py`: 3990 bytes, 179 lines, 1 revision(s) in the dump, block at line 64082, 5 mention(s) after it; python parses: yes
- `pylib/json.py`: 4769 bytes, 190 lines, 1 revision(s) in the dump, block at line 63644, 6 mention(s) after it; python parses: yes
- `pylib/pathlib.py`: 2452 bytes, 85 lines, 1 revision(s) in the dump, block at line 70735, 1 mention(s) after it; python parses: yes
- `pylib/string.py`: 823 bytes, 27 lines, 1 revision(s) in the dump, block at line 63839, 4 mention(s) after it; python parses: yes
- `pylib/sys.py`: 953 bytes, 49 lines, 1 revision(s) in the dump, block at line 66789, 1 mention(s) after it; python parses: yes
- `pylib/typing.py`: 689 bytes, 51 lines, 1 revision(s) in the dump, block at line 70556, 1 mention(s) after it; python parses: yes

Not imported by the interpreter, left out: gen_rsa.py, geometry.py

## package manifest
`pkg/manifest` in the package format of this project's package manager, ready for a repository to serve.

## post-export fixes (2026-11-01)

`pylib/pythonlib.lua` was modified after the export, so the byte/line numbers in
the "interpreter" section above are the historical extraction record. Measured
now (after the exception-class and os.path round): 144913 bytes, 4021 lines
(was 130760 / 3647; the previous round left it at 136733 / 3798). Everything
else is untouched - the 15 `pylib/*.py`, `py.lua`, `pyrepl.lua` and `manifest`
hash to the same SHA256 as at export time.

Reasons (full write-up in DECISIONS.md):

1. slice subscripts `seq[a:b:c]` - the parser rejected `:` outright, which
   blocked 5 of the 15 exported modules (argparse.py:38, collections.py:48,
   json.py:175, pathlib.py:33, string.py:18). Implemented for str/list/tuple
   with CPython bound rules; slice assignment, dict slicing and step 0 raise
   explicit errors instead of producing a value.
2. `luaToPy` / `pyToLua` forward declaration - `getBuiltins()` referenced both
   names before their `local function` definition, so those references compiled
   to globals and the builtin `lua()` failed with "attempt to call global
   'luaToPy' (a nil value)". This was why `cc.py` could not be imported.
3. the `print` builtin counted arguments with `#{...}`, so a nil argument
   (`print(None)`, `print(f())` for a function without `return`) printed an
   empty line. It now uses `select("#", ...)`.
4. `evalCall` collected positional arguments with `table.insert(args, ...)`,
   and a nil insert is a no-op: `f(1, None, 3)` silently passed `1, 3`.
   Argument counting is now explicit and `unpack(args, 1, argCount)` is used.
   A `None` inside `*args` is still dropped (documented in tests/COVERAGE.md).
5. negative subscripts (`l[-1]`) raised IndexError while slices already accepted
   negative bounds; both now normalise through `pyIndexPos`.
6. exception classes - the builtin exception names were constructor *functions*,
   so `class ArgumentError(Exception)` failed in `execClass` with "base class
   not found or not a class: Exception" and argparse.py / copy.py could not be
   imported. They are now real class tables (`excClass`, shared singletons with
   a BaseException/Exception base chain), `raise`/`except`/`isinstance` walk that
   chain, and `makeException(type, value, cls)` keeps the thrown value exactly
   the same table as before, so `str(e)`/`repr(e)` text did not change. Also
   makes `raise SomeErrorClass` (the class, not an instance) legal.
7. builtin `os.path` - `import os.path as _osp` (pathlib.py:3) raised
   `ImportError: No module named 'os.path'`. Minimal module added with the seven
   functions pylib calls (join/basename/dirname/splitext/exists/isfile/isdir,
   CPython "/" rules; splitext returns a 2-tuple because pathlib indexes `[1]`).
   `os` now exposes it as `os.path`, and a plain `import os.path` binds the top
   package like Python instead of binding the submodule to the name `os`.

`SHA256SUMS` was regenerated (new `pythonlib.lua` hash) and its stale
`legacy-py.lua` row was renamed to `py.lua`: the file was never renamed on disk,
only the checksum list kept the pre-export name, so that row could not be
verified.
