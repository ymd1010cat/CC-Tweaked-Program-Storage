# dataclasses.py - Minimal dataclasses for pythonlib

def dataclass(cls=None, **kwargs):
    if cls == None:
        return _wrap
    return _wrap(cls)

def _wrap(cls):
    fields = []
    ann = _get_annotations(cls)
    for name in ann:
        fields.append(name)
    cls.attrs["__fields"] = fields

    def new_init(self, *args, **kw):
        i = 0
        for f in fields:
            if i < len(args):
                setattr(self, f, args[i])
            elif f in kw:
                setattr(self, f, kw[f])
            i = i + 1
    cls.methods["__init__"] = new_init

    def repr_method(self):
        parts = []
        for f in fields:
            v = getattr(self, f, None)
            parts.append(f + "=" + repr(v))
        return cls.name + "(" + ", ".join(parts) + ")"
    cls.methods["__repr__"] = repr_method

    def eq_method(self, other):
        if other == None:
            return False
        if not isinstance(other, cls):
            return False
        for f in fields:
            if getattr(self, f, None) != getattr(other, f, None):
                return False
        return True
    cls.methods["__eq__"] = eq_method

    return cls

def _get_annotations(cls):
    result = {}
    if hasattr(cls, "__annotations__"):
        ann = cls.__annotations__
        for k in ann:
            result[k] = ann[k]
    return result

def field(default=None, **kwargs):
    return default

def fields(obj):
    return []

def asdict(obj):
    result = {}
    cls = obj.__class__
    flist = cls.attrs["__fields"]
    for f in flist:
        result[f] = getattr(obj, f, None)
    return result

def astuple(obj):
    result = []
    cls = obj.__class__
    flist = cls.attrs["__fields"]
    for f in flist:
        result.append(getattr(obj, f, None))
    return tuple(result)

def replace(obj, **changes):
    return obj
