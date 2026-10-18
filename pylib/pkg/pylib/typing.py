# typing.py - Type hints stubs (runtime no-op)

Any = None
Optional = None
Union = None
List = list
Dict = dict
Tuple = tuple
Set = None
FrozenSet = None
Callable = None
Iterable = None
Iterator = None
Sequence = None
Mapping = None
Type = None
ClassVar = None
Final = None
Literal = None
TypedDict = None
Protocol = None
Generic = None
TypeVar = None
NewType = None
NoReturn = None
Never = None
Self = None

def cast(t, v):
    return v

def get_type_hints(fn):
    return {}

def get_origin(t):
    return None

def get_args(t):
    return ()

def overload(fn):
    return fn

def final(fn):
    return fn

def runtime_checkable(cls):
    return cls

def no_type_check(fn):
    return fn
