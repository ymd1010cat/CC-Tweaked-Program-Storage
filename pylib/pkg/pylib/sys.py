# sys.py - System-related constants and helpers

argv = []
path = ["/pylib"]
modules = {}

version = "3.11.0 (pythonlib)"
version_info = (3, 11, 0, "final", 0)
platform = "cc-tweaked"
maxsize = 2147483647
byteorder = "little"
executable = "/pythonlib.lua"

class _Stream:
    def __init__(self, prefix):
        self.prefix = prefix
    def write(self, s):
        lua_call("write", str(s))
    def writelines(self, lines):
        for line in lines:
            lua_call("write", str(line))
    def flush(self):
        pass
    def read(self, n=None):
        return ""
    def readline(self):
        return ""
    def close(self):
        pass

stdin = _Stream("")
stdout = _Stream("")
stderr = _Stream("")

def set_argv(values):
    global argv
    argv = values

def exit(code=0):
    raise Exception("SystemExit: " + str(code))

def getrecursionlimit():
    return 1000

def setrecursionlimit(n):
    return None

def getsizeof(obj):
    return 0
