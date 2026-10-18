# json.py - Minimal JSON encoder/decoder

def dumps(obj):
    return _dump(obj)

def _dump(obj):
    t = type(obj)
    if obj == None:
        return "null"
    if t == "bool":
        if obj:
            return "true"
        return "false"
    if t == "int" or t == "float":
        return str(obj)
    if t == "str":
        return _quote(obj)
    if t == "list" or t == "tuple":
        parts = []
        for item in obj:
            parts.append(_dump(item))
        return "[" + ",".join(parts) + "]"
    if t == "dict":
        parts = []
        for k in obj.keys():
            v = obj[k]
            parts.append(_quote(str(k)) + ":" + _dump(v))
        return "{" + ",".join(parts) + "}"
    return "null"

def _quote(s):
    result = '"'
    i = 0
    while i < len(s):
        c = s[i]
        if c == '"':
            result = result + "\\\""
        elif c == "\\":
            result = result + "\\\\"
        elif c == "\n":
            result = result + "\\n"
        elif c == "\t":
            result = result + "\\t"
        elif c == "\r":
            result = result + "\\r"
        else:
            result = result + c
        i = i + 1
    return result + '"'

def loads(s):
    state = [0]
    return _parse(s, state)

def _skip_ws(s, state):
    while state[0] < len(s):
        c = s[state[0]]
        if c == " " or c == "\t" or c == "\n" or c == "\r":
            state[0] = state[0] + 1
        else:
            break

def _parse(s, state):
    _skip_ws(s, state)
    if state[0] >= len(s):
        return None
    c = s[state[0]]
    if c == "n":
        state[0] = state[0] + 4
        return None
    if c == "t":
        state[0] = state[0] + 4
        return True
    if c == "f":
        state[0] = state[0] + 5
        return False
    if c == '"':
        return _parse_string(s, state)
    if c == "[":
        return _parse_array(s, state)
    if c == "{":
        return _parse_object(s, state)
    return _parse_number(s, state)

def _parse_string(s, state):
    state[0] = state[0] + 1
    result = ""
    while state[0] < len(s):
        c = s[state[0]]
        if c == '"':
            state[0] = state[0] + 1
            return result
        if c == "\\":
            state[0] = state[0] + 1
            e = s[state[0]]
            if e == "n":
                result = result + "\n"
            elif e == "t":
                result = result + "\t"
            elif e == "r":
                result = result + "\r"
            elif e == "\\":
                result = result + "\\"
            elif e == '"':
                result = result + '"'
            elif e == "/":
                result = result + "/"
            else:
                result = result + e
            state[0] = state[0] + 1
        else:
            result = result + c
            state[0] = state[0] + 1
    return result

def _parse_array(s, state):
    state[0] = state[0] + 1
    result = []
    _skip_ws(s, state)
    if state[0] < len(s) and s[state[0]] == "]":
        state[0] = state[0] + 1
        return result
    while True:
        item = _parse(s, state)
        result.append(item)
        _skip_ws(s, state)
        if state[0] >= len(s):
            break
        c = s[state[0]]
        if c == ",":
            state[0] = state[0] + 1
        elif c == "]":
            state[0] = state[0] + 1
            break
        else:
            break
    return result

def _parse_object(s, state):
    state[0] = state[0] + 1
    result = {}
    _skip_ws(s, state)
    if state[0] < len(s) and s[state[0]] == "}":
        state[0] = state[0] + 1
        return result
    while True:
        _skip_ws(s, state)
        key = _parse_string(s, state)
        _skip_ws(s, state)
        if state[0] < len(s) and s[state[0]] == ":":
            state[0] = state[0] + 1
        value = _parse(s, state)
        result[key] = value
        _skip_ws(s, state)
        if state[0] >= len(s):
            break
        c = s[state[0]]
        if c == ",":
            state[0] = state[0] + 1
        elif c == "}":
            state[0] = state[0] + 1
            break
        else:
            break
    return result

def _parse_number(s, state):
    start = state[0]
    while state[0] < len(s):
        c = s[state[0]]
        if (c >= "0" and c <= "9") or c == "." or c == "-" or c == "+" or c == "e" or c == "E":
            state[0] = state[0] + 1
        else:
            break
    text = s[start:state[0]]
    is_float = False
    i = 0
    while i < len(text):
        if text[i] == "." or text[i] == "e" or text[i] == "E":
            is_float = True
        i = i + 1
    if is_float:
        return float(text)
    return int(text)

def dump(obj, fp):
    fp.write(dumps(obj))

def load(fp):
    return loads(fp.read())
