-- t_os_path.lua - the builtin `os.path` module.
--
-- This is not one of the 15 exported .py files: it is a builtin module added to
-- pythonlib.lua so `import os.path as _osp` (pathlib.py:3) works. The surface
-- is deliberately minimal - exactly the functions pylib/*.py calls - and the
-- behaviour matches CPython for "/"-separated CraftOS paths.
--
-- The same tests prove the dotted-import binding: `import os.path` must bind
-- the `os` package and expose `path` on it, not bind `os` to the submodule.

local H = ...

H.group("os-path:join")
-- join(): absolute later parts replace the accumulated prefix (CPython rule).
H.expect('from os.path import join\nprint(join("a", "b"))', "a/b",
    "join of two relative parts")
H.expect('from os.path import join\nprint(join("/a", "b"))', "/a/b",
    "join keeps an absolute prefix")
H.expect('from os.path import join\nprint(join("a", "/b"))', "/b",
    "an absolute later part resets the result")
H.expect('from os.path import join\nprint(join("a/", "b"))', "a/b",
    "join does not double the separator")
H.expect('from os.path import join\nprint(join("a", "", "b"))', "a/b",
    "an empty middle part adds no separator")
H.expect('from os.path import join\nprint(join())', "",
    "join of nothing is the empty string")
H.expect('from os.path import join\nprint(join("/a", "b", "c.txt"))',
    "/a/b/c.txt", "join of three parts")

H.group("os-path:basename-dirname")
H.expect('from os.path import basename\nprint(basename("/a/b.txt"))',
    "b.txt", "basename of an absolute path")
H.expect('from os.path import basename\nprint(basename("/a/b/"))', "b",
    "basename ignores a trailing separator")
H.expect('from os.path import basename\nprint(basename("/"))', "",
    "basename of the root is empty")
H.expect('from os.path import dirname\nprint(dirname("/a/b.txt"))', "/a",
    "dirname of an absolute path")
H.expect('from os.path import dirname\nprint(dirname("/a"))', "/",
    "dirname of a top level entry is the root")
H.expect('from os.path import dirname\nprint(dirname("a/b"))', "a",
    "dirname of a relative path")
H.expect('from os.path import dirname\nprint(dirname("a"))', "",
    "dirname of a bare name is empty")

H.group("os-path:splitext")
H.expect('from os.path import splitext\nprint(splitext("/a/x.tar.gz"))',
    "('/a/x.tar', '.gz')", "splitext splits at the last dot")
H.expect('from os.path import splitext\nprint(splitext(".bashrc"))',
    "('.bashrc', '')", "a leading dot does not start an extension")
H.expect('from os.path import splitext\nprint(splitext("a."))',
    "('a.', '')", "a trailing dot is part of the root")
H.expect('from os.path import splitext\nprint(splitext("a"))',
    "('a', '')", "a name without a dot has no extension")

H.group("os-path:filesystem")
-- /pylib/pathlib.py is staged by run-tests.ps1, so these are real fs queries.
H.expect('from os.path import exists\nprint(exists("/pylib/pathlib.py"))',
    "True", "exists on a staged file")
H.expect('from os.path import exists\nprint(exists("/no-such-path-xyz"))',
    "False", "exists on a missing path")
H.expect('from os.path import isfile\nprint(isfile("/pylib/pathlib.py"))',
    "True", "isfile on a staged file")
H.expect('from os.path import isdir\nprint(isdir("/pylib"))', "True",
    "isdir on a staged directory")
H.expect('from os.path import isfile\nprint(isfile("/pylib"))', "False",
    "isfile is false for a directory")

H.group("os-path:imports")
H.expect('import os.path as _osp\nprint(_osp.basename("a/b"))', "b",
    "import os.path as alias")
H.expect('from os.path import join, basename\n' ..
    'print(join("x", basename("/a/y.txt")))', "x/y.txt",
    "from os.path import a list of names")
H.expect('import os\nprint(os.path.join("a", "b"))', "a/b",
    "import os exposes os.path as an attribute")
H.expect('import os.path\nprint(os.path.dirname("/a/b"))', "/a",
    "plain import os.path binds the os package, not the submodule")
H.expect('import os.path\nprint(os.path.basename("a/b.txt"))', "b.txt",
    "plain import os.path then os.path.<fn>")

-- ---------- os.makedirs / mkdir / remove / rmdir / rename ----------
-- These are the mutators pathlib's write methods call. Every case uses its own
-- path so the assertions do not depend on each other's leftovers.

H.group("os-path:mkdir")
H.expect('import os\nos.makedirs("/pylib-dbg/a/b")\n' ..
    'print(os.path.isdir("/pylib-dbg/a/b"))', "True",
    "makedirs creates every missing level")
H.expect('import os\nos.makedirs("/pylib-dbg/a/b", True)\n' ..
    'os.makedirs("/pylib-dbg/a/b", True)\nprint("ok")', "ok",
    "makedirs with exist_ok=True tolerates an existing tree")
H.expect('import os\nos.makedirs("/pylib-dbg/a/b/exists")\ntry:\n' ..
    '    os.makedirs("/pylib-dbg/a/b/exists")\nexcept FileExistsError:\n' ..
    '    print("exists")', "exists",
    "makedirs without exist_ok raises FileExistsError")
H.expect('import os\nos.mkdir("/pylib-dbg/single")\n' ..
    'print(os.path.isdir("/pylib-dbg/single"))', "True", "mkdir creates one level")
H.expect('import os\nos.mkdir("/pylib-dbg/dup")\ntry:\n' ..
    '    os.mkdir("/pylib-dbg/dup")\nexcept FileExistsError:\n' ..
    '    print("exists")', "exists", "mkdir on an existing path is FileExistsError")
H.expect('import os\ntry:\n    os.mkdir("/pylib-dbg/no-parent/x")\n' ..
    'except FileNotFoundError:\n    print("noparent")', "noparent",
    "mkdir with a missing parent is FileNotFoundError")

H.group("os-path:remove-rmdir")
H.expect('import os\ntry:\n    os.remove("/pylib-dbg/never")\n' ..
    'except FileNotFoundError:\n    print("missing")', "missing",
    "remove on a missing path is FileNotFoundError")
H.expect('import os\nos.makedirs("/pylib-dbg/rm")\n' ..
    'f = open("/pylib-dbg/rm/f.txt", "w")\nf.write("x")\nf.close()\n' ..
    'os.remove("/pylib-dbg/rm/f.txt")\n' ..
    'print(os.path.exists("/pylib-dbg/rm/f.txt"))', "False",
    "remove deletes a file")
H.expect('import os\ntry:\n    os.remove("/pylib-dbg/rm")\n' ..
    'except OSError:\n    print("isdir")', "isdir",
    "remove on a directory is an OSError")
H.expect('import os\nos.makedirs("/pylib-dbg/full")\n' ..
    'f = open("/pylib-dbg/full/f.txt", "w")\nf.write("x")\nf.close()\n' ..
    'try:\n    os.rmdir("/pylib-dbg/full")\nexcept OSError:\n' ..
    '    print("notempty")', "notempty", "rmdir on a non-empty directory is OSError")
H.expect('import os\nos.makedirs("/pylib-dbg/gone")\n' ..
    'os.rmdir("/pylib-dbg/gone")\n' ..
    'print(os.path.exists("/pylib-dbg/gone"))', "False",
    "rmdir removes an empty directory")

H.group("os-path:rename")
H.expect('import os\nos.makedirs("/pylib-dbg/old")\n' ..
    'os.rename("/pylib-dbg/old", "/pylib-dbg/new")\n' ..
    'print(os.path.isdir("/pylib-dbg/new"))\n' ..
    'print(os.path.exists("/pylib-dbg/old"))', "True\nFalse",
    "rename moves a directory")
H.expect('import os\ntry:\n' ..
    '    os.rename("/pylib-dbg/never", "/pylib-dbg/x")\n' ..
    'except FileNotFoundError:\n    print("missing")', "missing",
    "rename on a missing source is FileNotFoundError")

H.group("os-path:error-hierarchy")
H.expect('print(isinstance(FileExistsError("x"), OSError))', "True",
    "FileExistsError is an OSError subclass")
H.expect('print(isinstance(FileNotFoundError("x"), OSError))', "True",
    "FileNotFoundError is an OSError subclass")
H.expect('print(isinstance(OSError("x"), Exception))', "True",
    "OSError is an Exception subclass")
H.expect('try:\n    raise FileNotFoundError("x")\nexcept OSError:\n' ..
    '    print("os")', "os", "except OSError catches FileNotFoundError")
