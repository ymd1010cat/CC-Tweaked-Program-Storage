# datetime.py - Minimal datetime module

import time as _time

class timedelta:
    def __init__(self, days=0, seconds=0, microseconds=0,
                 milliseconds=0, minutes=0, hours=0, weeks=0):
        self._seconds = (days * 86400 + weeks * 7 * 86400
                         + hours * 3600 + minutes * 60 + seconds
                         + milliseconds / 1000.0
                         + microseconds / 1000000.0)
    def total_seconds(self):
        return self._seconds
    @property
    def days(self):
        return int(self._seconds / 86400)
    @property
    def seconds(self):
        return int(self._seconds % 86400)
    def __add__(self, other):
        if type(other) == "timedelta":
            return timedelta(seconds=self._seconds + other._seconds)
        return NotImplemented
    def __sub__(self, other):
        if type(other) == "timedelta":
            return timedelta(seconds=self._seconds - other._seconds)
        return NotImplemented
    def __str__(self):
        return str(self._seconds) + "s"
    def __repr__(self):
        return "timedelta(seconds=" + str(self._seconds) + ")"

class date:
    def __init__(self, year, month, day):
        self.year = year
        self.month = month
        self.day = day
    def __str__(self):
        return _pad(self.year, 4) + "-" + _pad(self.month, 2) + "-" + _pad(self.day, 2)
    def __repr__(self):
        return "date(" + str(self.year) + ", " + str(self.month) + ", " + str(self.day) + ")"
    def __eq__(self, other):
        if other == None:
            return False
        return (self.year == other.year and self.month == other.month
                and self.day == other.day)
    @classmethod
    def today(cls):
        t = _time.localtime()
        return cls(t.year, t.month, t.day)

class time:
    def __init__(self, hour=0, minute=0, second=0, microsecond=0):
        self.hour = hour
        self.minute = minute
        self.second = second
        self.microsecond = microsecond
    def __str__(self):
        return _pad(self.hour, 2) + ":" + _pad(self.minute, 2) + ":" + _pad(self.second, 2)
    def __repr__(self):
        return "time(" + str(self.hour) + ", " + str(self.minute) + ", " + str(self.second) + ")"

class datetime:
    def __init__(self, year, month, day, hour=0, minute=0, second=0, microsecond=0):
        self.year = year
        self.month = month
        self.day = day
        self.hour = hour
        self.minute = minute
        self.second = second
        self.microsecond = microsecond
    def __str__(self):
        return (_pad(self.year, 4) + "-" + _pad(self.month, 2) + "-" + _pad(self.day, 2)
                + " " + _pad(self.hour, 2) + ":" + _pad(self.minute, 2) + ":" + _pad(self.second, 2))
    def __repr__(self):
        return ("datetime(" + str(self.year) + ", " + str(self.month) + ", "
                + str(self.day) + ", " + str(self.hour) + ", " + str(self.minute)
                + ", " + str(self.second) + ")")
    @classmethod
    def now(cls):
        t = _time.localtime()
        return cls(t.year, t.month, t.day, t.hour, t.min, t.sec)
    @classmethod
    def utcnow(cls):
        return cls.now()
    def date(self):
        return date(self.year, self.month, self.day)
    def time(self):
        return time(self.hour, self.minute, self.second, self.microsecond)
    def timestamp(self):
        return _time.time()

def _pad(n, width):
    s = str(n)
    while len(s) < width:
        s = "0" + s
    return s
