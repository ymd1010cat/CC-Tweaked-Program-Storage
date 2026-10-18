# collections.py - Counter, defaultdict, deque, OrderedDict

class Counter:
    def __init__(self, items=None):
        self.data = {}
        if items != None:
            if type(items) == "dict":
                for k, v in items.items():
                    self.data[k] = v
            else:
                for item in items:
                    self._add(item, 1)

    def _add(self, key, n):
        if key in self.data:
            self.data[key] = self.data[key] + n
        else:
            self.data[key] = n

    def update(self, items=None):
        if items == None:
            return
        if type(items) == "dict":
            for k, v in items.items():
                self._add(k, v)
        else:
            for item in items:
                self._add(item, 1)

    def most_common(self, n=None):
        items = []
        for k in self.data.keys():
            items.append((k, self.data[k]))
        i = 1
        while i < len(items):
            j = i
            while j > 0:
                if items[j][1] > items[j-1][1]:
                    tmp = items[j]
                    items[j] = items[j-1]
                    items[j-1] = tmp
                    j = j - 1
                else:
                    break
            i = i + 1
        if n == None:
            return items
        return items[0:n]

    def __getitem__(self, key):
        if key in self.data:
            return self.data[key]
        return 0

    def __setitem__(self, key, value):
        self.data[key] = value

    def __len__(self):
        return len(self.data)

    def __contains__(self, key):
        return key in self.data

    def __iter__(self):
        for k in self.data.keys():
            yield k

    def keys(self):
        return self.data.keys()

    def values(self):
        return self.data.values()

    def items(self):
        return self.data.items()

    def __str__(self):
        return "Counter(" + str(self.data) + ")"

class defaultdict:
    def __init__(self, default_factory=None):
        self.default_factory = default_factory
        self.data = {}

    def __getitem__(self, key):
        if key in self.data:
            return self.data[key]
        if self.default_factory != None:
            value = self.default_factory()
            self.data[key] = value
            return value
        return None

    def __setitem__(self, key, value):
        self.data[key] = value

    def __contains__(self, key):
        return key in self.data

    def __len__(self):
        return len(self.data)

    def __iter__(self):
        for k in self.data.keys():
            yield k

    def keys(self):
        return self.data.keys()

    def values(self):
        return self.data.values()

    def items(self):
        return self.data.items()

    def get(self, key, default=None):
        return self.data.get(key, default)

    def __str__(self):
        return "defaultdict(" + str(self.data) + ")"

class deque:
    def __init__(self, items=None, maxlen=None):
        self.items = []
        self.maxlen = maxlen
        if items != None:
            for item in items:
                self.append(item)

    def append(self, item):
        self.items.append(item)
        if self.maxlen != None and len(self.items) > self.maxlen:
            self.items.pop(0)

    def appendleft(self, item):
        self.items.insert(0, item)
        if self.maxlen != None and len(self.items) > self.maxlen:
            self.items.pop()

    def pop(self):
        if len(self.items) == 0:
            return None
        return self.items.pop()

    def popleft(self):
        if len(self.items) == 0:
            return None
        return self.items.pop(0)

    def __len__(self):
        return len(self.items)

    def __getitem__(self, i):
        return self.items[i]

    def __iter__(self):
        for item in self.items:
            yield item

    def __str__(self):
        return "deque(" + str(self.items) + ")"

class OrderedDict:
    def __init__(self, items=None):
        self.data = {}
        if items != None:
            if type(items) == "dict":
                for k, v in items.items():
                    self.data[k] = v
            else:
                for pair in items:
                    self.data[pair[0]] = pair[1]

    def __getitem__(self, key):
        return self.data[key]

    def __setitem__(self, key, value):
        self.data[key] = value

    def __contains__(self, key):
        return key in self.data

    def __len__(self):
        return len(self.data)

    def __iter__(self):
        for k in self.data.keys():
            yield k

    def keys(self):
        return self.data.keys()

    def values(self):
        return self.data.values()

    def items(self):
        return self.data.items()

    def get(self, key, default=None):
        return self.data.get(key, default)

    def pop(self, key, default=None):
        return self.data.pop(key, default)

    def __str__(self):
        return "OrderedDict(" + str(self.data) + ")"
