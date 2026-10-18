# argparse.py - Minimal argument parser

class Namespace:
    def __init__(self, **kwargs):
        for k, v in kwargs.items():
            setattr(self, k, v)
    def __repr__(self):
        parts = []
        for k in dir(self):
            if not k.startswith("_"):
                v = getattr(self, k)
                if type(v) != "function":
                    parts.append(k + "=" + repr(v))
        return "Namespace(" + ", ".join(parts) + ")"

class ArgumentParser:
    def __init__(self, description=None, prog=None):
        self.description = description
        self.prog = prog
        self._args = []
        self._defaults = {}
    def add_argument(self, name, type=None, default=None, help=None,
                     action=None, choices=None, required=False):
        self._args.append({
            "name": name,
            "type": type,
            "default": default,
            "help": help,
            "action": action,
            "choices": choices,
            "required": required,
        })
        if default != None:
            self._defaults[name] = default
    def parse_args(self, args=None):
        import sys
        if args == None:
            args = sys.argv[1:]
        result = {}
        for k, v in self._defaults.items():
            result[k] = v
        i = 0
        while i < len(args):
            a = args[i]
            if a.startswith("--"):
                key = a[2:]
                spec = None
                for s in self._args:
                    if s["name"] == "--" + key:
                        spec = s
                        break
                if spec and spec["action"] == "store_true":
                    result[key] = True
                elif i + 1 < len(args):
                    i = i + 1
                    value = args[i]
                    if spec and spec["type"] == int:
                        value = int(value)
                    elif spec and spec["type"] == float:
                        value = float(value)
                    result[key] = value
            i = i + 1
        ns = Namespace(**result)
        return ns
    def format_help(self):
        lines = []
        if self.description:
            lines.append(self.description)
        for spec in self._args:
            line = "  " + spec["name"]
            if spec["help"]:
                line = line + "  " + spec["help"]
            lines.append(line)
        return "\n".join(lines)
    def error(self, msg):
        raise ValueError(msg)
    def print_help(self):
        print(self.format_help())

class ArgumentError(Exception):
    pass
