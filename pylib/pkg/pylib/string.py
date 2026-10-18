# string.py - String constants and helpers

ascii_lowercase = "abcdefghijklmnopqrstuvwxyz"
ascii_uppercase = "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
ascii_letters = ascii_lowercase + ascii_uppercase
digits = "0123456789"
hexdigits = "0123456789abcdefABCDEF"
octdigits = "01234567"
punctuation = "!\"#$%&'()*+,-./:;<=>?@[\\]^_`{|}~"
whitespace = " \t\n\r"
printable = digits + ascii_letters + punctuation + whitespace

def capwords(s, sep=None):
    if sep == None:
        parts = s.split()
        result = []
        for w in parts:
            result.append(w[0].upper() + w[1:].lower())
        return " ".join(result)
    parts = s.split(sep)
    result = []
    for w in parts:
        if len(w) == 0:
            result.append(w)
        else:
            result.append(w[0].upper() + w[1:].lower())
    return sep.join(result)
