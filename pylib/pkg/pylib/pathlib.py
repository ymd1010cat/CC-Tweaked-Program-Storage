# pathlib.py - Object-oriented path handling

import os.path as _osp

class PurePath:
    def __init__(self, *parts):
        if len(parts) == 0:
            self._path = ""
        elif len(parts) == 1:
            self._path = str(parts[0])
        else:
            self._path = _osp.join(*[str(p) for p in parts])
    def __str__(self):
        return self._path
    def __repr__(self):
        return "PurePath('" + self._path + "')"
    def __eq__(self, other):
        if other == None:
            return False
        return str(self) == str(other)
    @property
    def name(self):
        return _osp.basename(self._path)
    @property
    def suffix(self):
        return _osp.splitext(self._path)[1]
    @property
    def stem(self):
        base = _osp.basename(self._path)
        ext = _osp.splitext(base)[1]
        if ext == "":
            return base
        return base[:len(base) - len(ext)]
    @property
    def parent(self):
        return PurePath(_osp.dirname(self._path))
    def joinpath(self, *others):
        return PurePath(self._path, *others)
    def __truediv__(self, other):
        return PurePath(_osp.join(self._path, str(other)))
    def with_suffix(self, suffix):
        base = _osp.splitext(self._path)[0]
        return PurePath(base + suffix)

class Path(PurePath):
    def exists(self):
        return _osp.exists(self._path)
    def is_file(self):
        return _osp.isfile(self._path)
    def is_dir(self):
        return _osp.isdir(self._path)
    def read_text(self):
        with open(self._path, "r") as f:
            return f.readAll()
    def write_text(self, content):
        with open(self._path, "w") as f:
            f.write(content)
    def read_bytes(self):
        return self.read_text()
    def write_bytes(self, content):
        self.write_text(content)
    def mkdir(self, parents=False, exist_ok=False):
        import os
        if parents:
            os.makedirs(self._path)
        else:
            os.mkdir(self._path)
    def unlink(self):
        import os
        os.remove(self._path)
    def rmdir(self):
        import os
        os.rmdir(self._path)
    def rename(self, target):
        import os
        os.rename(self._path, str(target))
    def iterdir(self):
        import os
        for name in os.listdir(self._path):
            yield Path(_osp.join(self._path, name))
    def glob(self, pattern):
        return iter([])

PosixPath = Path
WindowsPath = Path
