-- t_core.lua - core language features of the exported pythonlib.lua.
--
-- Every assertion goes through the public pipeline (Lexer -> Parser ->
-- Interpreter -> builtins -> print), i.e. exactly what a user program does.
-- Expected strings are Python's own output, not "whatever the subset printed":
-- where the subset differs on purpose the row is marked in COVERAGE.md.

local H = ...

H.group("core:arith")
H.expect('print(1 + 2 * 3)', "7", "precedence")
H.expect('print(7 / 2)', "3.5", "true division keeps the fraction")
H.expect('print(7 // 2)', "3", "floor division")
H.expect('print(2 ** 10)', "1024", "power")
H.expect('print(10 % 3)', "1", "modulo")
H.expect('print(-5 + 2)', "-3", "unary minus")
H.expect('print(1 < 2)', "True", "comparison")
H.expect('print(1 == 1.0)', "True", "int/float equality")
H.expect('print(3 & 1)', "1", "bitwise and")
H.expect('print(1 << 4)', "16", "left shift")
H.expect('print("a" in "cat")', "True", "in on a string")
H.expect('print(2 in [1, 2])', "True", "in on a list")
H.expectError('print(1 / 0)', "ZeroDivisionError", "division by zero raises")

H.group("core:strings")
H.expect('print("hello" + " " + "world")', "hello world", "concatenation")
H.expect('s = "hello"\nprint(len(s))', "5", "len")
H.expect('print("hello"[1])', "e", "index")
H.expect('print("hello".upper())', "HELLO", "upper()")
H.expect('print("a,b,c".split(","))', "['a', 'b', 'c']", "split()")
H.expect('print(str(42))', "42", "str()")
H.expect('name = "py"\nprint(f"hello {name} {1 + 1}")', "hello py 2",
    "f-string")
H.expect('print("abc".replace("a", "z"))', "zbc", "replace()")

H.group("core:containers")
H.expect('l = [1, 2, 3]\nprint(l)', "[1, 2, 3]", "list literal")
H.expect('l = [1, 2, 3]\nprint(len(l))', "3", "list len")
H.expect('l = [1]\nl.append(2)\nprint(l)', "[1, 2]", "append()")
H.expect('l = [10, 20]\nprint(l[0])', "10", "list index")
H.expect('l = [1, 2, 3]\nprint(l[-1])', "3", "negative index")
H.expect('d = {"a": 1}\nprint(d["a"])', "1", "dict get")
H.expect('print((1, 2))', "(1, 2)", "tuple literal")
H.expect('print([x * x for x in range(4)])', "[0, 1, 4, 9]", "comprehension")
H.expectError('l = [1]\nprint(l[5])', "IndexError", "index out of range")
H.expectError('d = {}\nprint(d["k"])', "KeyError", "missing dict key")

H.group("core:control-flow")
H.expect('i = 0\nout = []\nwhile i < 3:\n' ..
    '    if i % 2 == 0:\n        out.append("even")\n' ..
    '    else:\n        out.append("odd")\n    i = i + 1\nprint(out)',
    "['even', 'odd', 'even']", "while + if/else")
H.expect('total = 0\nfor i in range(4):\n    total = total + i\nprint(total)',
    "6", "for over range()")
H.expect('for x in [1, 2, 3]:\n    print(x)', "1\n2\n3", "for over a list")
H.expect('i = 0\nwhile True:\n    i = i + 1\n    if i > 2:\n        break\n' ..
    'print(i)', "3", "break")
H.expect('i = 0\nn = 0\nwhile i < 4:\n    i = i + 1\n' ..
    '    if i == 2:\n        continue\n    n = n + 1\nprint(n)', "3",
    "continue")
H.expect('x = 5\nprint("big" if x > 3 else "small")', "big", "ternary")
H.expect('print(0 or "fallback")', "fallback", "or returns the value")
H.expect('print(1 and "value")', "value", "and returns the value")

H.group("core:functions")
H.expect('def counter():\n    n = 0\n    def inc():\n        nonlocal n\n' ..
    '        n = n + 1\n        return n\n    return inc\n' ..
    'c = counter()\nprint(c())\nprint(c())', "1\n2", "closure + nonlocal")
H.expect('def f(a, b=2):\n    return a + b\nprint(f(1))\nprint(f(1, 10))',
    "3\n11", "default arguments")
H.expect('def f(*args):\n    return len(args)\nprint(f(1, 2, 3))', "3",
    "varargs")
H.expect('def f():\n    return 1, 2\na, b = f()\nprint(a + b)', "3",
    "multiple return values")
H.expect('def fact(n):\n    if n <= 1:\n        return 1\n' ..
    '    return n * fact(n - 1)\nprint(fact(5))', "120", "recursion")
H.expect('f = lambda x: x * 3\nprint(f(4))', "12", "lambda")
H.expect('g = 10\ndef setg():\n    global g\n    g = 20\nsetg()\nprint(g)',
    "20", "global statement")

H.group("core:classes")
H.expect('class Point:\n    def __init__(self, x):\n        self.x = x\n' ..
    '    def double(self):\n        return self.x * 2\n' ..
    'p = Point(21)\nprint(p.x)\nprint(p.double())', "21\n42",
    "class + __init__ + method")
H.expect('class A:\n    def hello(self):\n        return "A"\n' ..
    'class B(A):\n    def hello(self):\n        return "B" + A.hello(self)\n' ..
    'print(B().hello())', "BA", "inheritance + super call")
H.expect('class C:\n    def __init__(self):\n        self.n = 0\n' ..
    '    def bump(self):\n        self.n = self.n + 1\n        return self.n\n' ..
    'c = C()\nc.bump()\nprint(c.bump())', "2", "instance attribute mutation")
H.expect('print(isinstance(1, int))', "True", "isinstance(1, int)")
-- type() returns the class name as a plain string here, not a class
-- object: documented deviation (see COVERAGE.md).
H.expect('print(type(1))', "int", "type() of an int")

H.group("core:print")
H.expect('print(None)', "None", "print(None)")
H.expect('def f():\n    pass\nprint(f())', "None",
    "print of a function that returns nothing")
H.expect('print(1, None, 2)', "1 None 2", "None among print arguments")
H.expect('print()', "", "print() with no arguments")
H.expect('print(True, False)', "True False", "print booleans")

H.group("core:nil-arguments")
H.expect('def f(a, b, c):\n    print(a)\n    print(b)\n    print(c)\n' ..
    'f(1, None, 3)', "1\nNone\n3", "None as a positional argument")
-- Not asserted, documented instead: a None inside *args leaves a hole in the
-- tuple (a Lua table), and Lua's # is undefined across holes, so len()
-- cannot be relied on there, so a None inside *args is dropped when the tuple
-- is packed. See COVERAGE.md "known gaps".
H.note("LIMITATION None inside *args leaves a table hole; len() is " ..
    "undefined across holes")
H.expect('def f(a, b=None):\n    return b\nprint(f(1))', "None",
    "omitted argument defaults to None")

H.group("core:exceptions")
H.expect('try:\n    raise ValueError("boom")\nexcept ValueError as e:\n' ..
    '    print("caught")\nfinally:\n    print("done")', "caught\ndone",
    "try/except/finally")
H.expect('try:\n    x = 1 / 0\nexcept ZeroDivisionError:\n    print("zde")',
    "zde", "except a builtin exception type")
H.expectError('raise ValueError("boom")', "ValueError: boom", "raise")
H.expectError('assert False', "AssertionError", "assert False")
H.expect('try:\n    x = 1 / 0\nexcept ZeroDivisionError as e:\n' ..
    '    print("zde")', "zde", "except ... as name")

-- Documented gap, asserted on purpose: the subset's builtin exception names are
-- constructor functions, not classes, so subclassing one fails. COVERAGE.md
-- lists this under "known gaps"; flipping this assertion is the acceptance
-- criterion for fixing it.
H.group("core:exception-subclass-gap")
H.expectError('class MyError(Exception):\n    pass', "base class not found",
    "class MyError(Exception) is rejected (known gap)")
