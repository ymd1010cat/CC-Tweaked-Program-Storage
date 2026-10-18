# functools.py - Function utilities

def reduce(fn, iterable, initial=None):
    result = initial
    started = False
    for x in iterable:
        if not started and initial == None:
            result = x
        else:
            result = fn(result, x)
        started = True
    return result

def partial(fn, *args, **kwargs):
    def wrapper(*more_args, **more_kwargs):
        merged_kwargs = {}
        for k, v in kwargs.items():
            merged_kwargs[k] = v
        for k, v in more_kwargs.items():
            merged_kwargs[k] = v
        all_args = []
        for a in args:
            all_args.append(a)
        for a in more_args:
            all_args.append(a)
        return fn(*all_args, **merged_kwargs)
    return wrapper

def lru_cache(maxsize=128):
    def decorator(fn):
        cache = {}
        def wrapper(*args):
            key = str(args)
            if key in cache:
                return cache[key]
            result = fn(*args)
            cache[key] = result
            return result
        wrapper.cache = cache
        return wrapper
    return decorator

def wraps(original):
    def decorator(fn):
        return fn
    return decorator

def cmp_to_key(fn):
    return fn

def _identity(x):
    return x
