-- t_slices.lua - slice subscripts (seq[a:b:c]).
--
-- This was the single parser gap that blocked 5 of the 15 exported modules
-- (argparse.py:38, collections.py:48, json.py:175, pathlib.py:33,
-- string.py:18). The rows below are Python 3's own results; the unsupported
-- cases are asserted as explicit errors so they cannot regress into a silently
-- wrong value.

local H = ...

H.group("slice:list")
H.expect('l = [1, 2, 3, 4, 5]\nprint(l[1:3])', "[2, 3]", "[1:3]")
H.expect('l = [1, 2, 3, 4, 5]\nprint(l[2:])', "[3, 4, 5]", "[2:]")
H.expect('l = [1, 2, 3, 4, 5]\nprint(l[:2])', "[1, 2]", "[:2]")
H.expect('l = [1, 2, 3, 4, 5]\nprint(l[:])', "[1, 2, 3, 4, 5]", "[:]")
H.expect('l = [1, 2, 3, 4, 5]\nprint(l[-2:])', "[4, 5]", "[-2:]")
H.expect('l = [1, 2, 3, 4, 5]\nprint(l[0:5:2])', "[1, 3, 5]", "[0:5:2]")
H.expect('l = [1, 2, 3, 4, 5]\nprint(l[3:0:-1])', "[4, 3, 2]", "[3:0:-1]")
H.expect('l = [1, 2, 3, 4, 5]\nprint(l[::-1])', "[5, 4, 3, 2, 1]", "[::-1]")
H.expect('l = [1, 2, 3, 4, 5]\nprint(l[-100:100])', "[1, 2, 3, 4, 5]",
    "bounds are clamped")
H.expect('l = [1, 2, 3]\nprint(l[1:1])', "[]", "empty slice")
H.expect('l = [1, 2, 3]\nprint(l[1:2][0])', "2", "chained subscript")
H.expect('l = [1, 2, 3, 4]\nt = l[1:3]\nt.append(9)\nprint(l)\nprint(t)',
    "[1, 2, 3, 4]\n[2, 3, 9]", "the slice is a copy, not a view")
H.expect('l = [1, 2, 3, 4]\nprint(l[1:3])', "[2, 3]", "slice prints a list")
H.expect('a = [1, 2, 3, 4]\nb = [9, 8]\nprint(a[1:3] + b)', "[2, 3, 9, 8]",
    "sliced list concatenates")

H.group("slice:string")
H.expect('print("hello"[1:3])', "el", "string [1:3]")
H.expect('print("hello"[2:])', "llo", "string [2:]")
H.expect('print("hello"[:2])', "he", "string [:2]")
H.expect('print("hello"[::-1])', "olleh", "string [::-1]")
H.expect('print("hello"[4:0:-1])', "olle", "string [4:0:-1]")
H.expect('print("hello"[-3:])', "llo", "string [-3:]")
H.expect('print(len("hello"[1:3]))', "2", "sliced string len")

H.group("slice:tuple")
H.expect('print((1, 2, 3)[1:])', "(2, 3)", "tuple [1:]")
H.expect('print((1, 2, 3)[::-1])', "(3, 2, 1)", "tuple [::-1]")
H.expect('t = (1, 2, 3)\nprint(type(t[0:2]))', "tuple",
    "slicing a tuple yields a tuple")

H.group("slice:expressions-inside-brackets")
H.expect('s = "abcdef"\nn = 2\nprint(s[n:n + 2])', "cd",
    "slice bounds are expressions")
H.expect('l = [1, 2, 3, 4]\nprint(l[len(l) - 2:])', "[3, 4]",
    "len() in a slice bound")
H.expect('l = [[1, 2], [3, 4]]\nprint(l[0][1:])', "[2]",
    "nested subscripts")

H.group("slice:unsupported-cases-are-explicit")
H.expectError('l = [1, 2, 3]\nl[0:1] = [9]', "slice assignment", 
    "slice assignment is a clear TypeError, not silent corruption")
H.expectError('d = {"a": 1}\nprint(d["a":"b"])', "not sliceable",
    "dict slicing is rejected")
H.expectError('print([1, 2, 3][0:3:0])', "slice step cannot be zero",
    "step 0 raises ValueError")
H.expectError('print([1, 2, 3][0:2.5])', "must be an integer",
    "float slice bound raises TypeError")
