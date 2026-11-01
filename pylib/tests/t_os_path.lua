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
