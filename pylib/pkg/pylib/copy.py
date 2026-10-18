# copy.py - Shallow and deep copy

def copy(obj):
    t = type(obj)
    if t == "list":
        result = []
        for x in obj:
            result.append(x)
        return result
    if t == "dict":
        result = {}
        for k, v in obj.items():
            result[k] = v
        return result
    return obj

def _deep(obj, memo):
    t = type(obj)
    if t == "list":
        key = "L" + str(len(memo))
        if key in memo:
            return memo[key]
        result = []
        memo[key] = result
        for x in obj:
            result.append(_deep(x, memo))
        return result
    if t == "dict":
        result = {}
        for k, v in obj.items():
            result[_deep(k, memo)] = _deep(v, memo)
        return result
    return obj

def deepcopy(obj):
    return _deep(obj, {})

class Error(Exception):
    pass

error = Error
