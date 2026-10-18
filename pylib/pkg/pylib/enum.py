# enum.py - Minimal enum implementation

class Enum:
    def __init__(self, value):
        self.value = value
    def __str__(self):
        return self.__class__.__name__ + "." + str(self.name)
    def __eq__(self, other):
        if other == None:
            return False
        return self.value == getattr(other, "value", None)
    def __hash__(self):
        return self.value

class IntEnum(Enum):
    pass

def enum_factory(cls):
    members = {}
    for k in dir(cls):
        if not k.startswith("_"):
            v = getattr(cls, k)
            if type(v) != "function":
                instance = cls(v)
                instance.name = k
                members[k] = instance
                setattr(cls, k, instance)
    cls._members = members
    def getitem(self, name):
        return members.get(name, None)
    return cls

def unique(cls):
    return cls

def auto():
    return None
