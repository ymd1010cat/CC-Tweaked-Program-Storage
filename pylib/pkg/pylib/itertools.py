# itertools.py - Iteration utilities

def chain(*iterables):
    for it in iterables:
        for x in it:
            yield x

def repeat(obj, times=None):
    if times == None:
        while True:
            yield obj
    else:
        for _ in range(times):
            yield obj

def count(start=0, step=1):
    n = start
    while True:
        yield n
        n = n + step

def cycle(iterable):
    saved = []
    for x in iterable:
        yield x
        saved.append(x)
    while len(saved) > 0:
        for x in saved:
            yield x

def islice(iterable, start, stop=None, step=1):
    if stop == None:
        stop = start
        start = 0
    i = 0
    for x in iterable:
        if i >= stop:
            break
        if i >= start and (i - start) % step == 0:
            yield x
        i = i + 1

def takewhile(predicate, iterable):
    for x in iterable:
        if predicate(x):
            yield x
        else:
            break

def dropwhile(predicate, iterable):
    dropping = True
    for x in iterable:
        if dropping:
            if not predicate(x):
                dropping = False
                yield x
        else:
            yield x

def filterfalse(predicate, iterable):
    for x in iterable:
        if not predicate(x):
            yield x

def product(*args):
    if len(args) == 0:
        yield ()
        return
    if len(args) == 1:
        for x in args[0]:
            yield (x,)
        return
    if len(args) == 2:
        for x in args[0]:
            for y in args[1]:
                yield (x, y)
        return
    if len(args) == 3:
        for x in args[0]:
            for y in args[1]:
                for z in args[2]:
                    yield (x, y, z)
        return

def combinations(iterable, r):
    pool = []
    for x in iterable:
        pool.append(x)
    n = len(pool)
    if r > n:
        return
    if r == 0:
        yield ()
        return
    indices = []
    for i in range(r):
        indices.append(i)
    while True:
        result = []
        for i in indices:
            result.append(pool[i])
        yield tuple(result)
        i = r - 1
        while i >= 0 and indices[i] == i + n - r:
            i = i - 1
        if i < 0:
            break
        indices[i] = indices[i] + 1
        j = i + 1
        while j < r:
            indices[j] = indices[j - 1] + 1
            j = j + 1

def permutations(iterable, r=None):
    pool = []
    for x in iterable:
        pool.append(x)
    n = len(pool)
    if r == None:
        r = n
    if r > n:
        return
    if r == 0:
        yield ()
        return
    indices = []
    for i in range(n):
        indices.append(i)
    cycles = []
    i = n - 1
    while i >= n - r:
        cycles.append(i)
        i = i - 1
    result = []
    for i in range(r):
        result.append(pool[indices[i]])
    yield tuple(result)
    while True:
        found = False
        i = r - 1
        while i >= 0:
            cycles[i] = cycles[i] - 1
            if cycles[i] == -1:
                tmp = indices[i]
                j = i
                while j < n - 1:
                    indices[j] = indices[j + 1]
                    j = j + 1
                indices[n - 1] = tmp
                cycles[i] = n - i
            else:
                j = cycles[i]
                tmp = indices[i]
                indices[i] = indices[n - j]
                indices[n - j] = tmp
                result = []
                for k in range(r):
                    result.append(pool[indices[k]])
                yield tuple(result)
                found = True
                break
            i = i - 1
        if not found:
            break

def zip_longest(a, b, fillvalue=None):
    n = len(a)
    if len(b) > n:
        n = len(b)
    for i in range(n):
        if i < len(a):
            x = a[i]
        else:
            x = fillvalue
        if i < len(b):
            y = b[i]
        else:
            y = fillvalue
        yield (x, y)
