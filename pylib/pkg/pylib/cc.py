# cc.py - CC:Tweaked API wrapper for Python
# Requires pythonlib.lua with lua() / lua_call() builtins.

# ============================================================
# Time
# ============================================================
def sleep(sec):
    lua_call("os.sleep", sec)

def time():
    return lua_call("os.epoch", "utc") / 1000

def epoch(unit):
    return lua_call("os.epoch", unit)

# ============================================================
# Terminal
# ============================================================
def term_size():
    return lua_call("term.getSize")

def setCursorPos(x, y):
    lua_call("term.setCursorPos", x, y)

def getCursorPos():
    return lua_call("term.getCursorPos")

def write(s):
    lua_call("term.write", str(s))

def setTextColor(c):
    lua_call("term.setTextColor", c)

def setBackgroundColor(c):
    lua_call("term.setBackgroundColor", c)

def getTextColor():
    return lua_call("term.getTextColor")

def getBackgroundColor():
    return lua_call("term.getBackgroundColor")

def clear():
    lua_call("term.clear")
    lua_call("term.setCursorPos", 1, 1)

# ============================================================
# File system
# ============================================================
def exists(path):
    return lua_call("fs.exists", path)

def isDir(path):
    return lua_call("fs.isDir", path)

def list_dir(path):
    return lua_call("fs.list", path)

def makeDir(path):
    return lua_call("fs.makeDir", path)

def delete(path):
    return lua_call("fs.delete", path)

def copy(src, dst):
    return lua_call("fs.copy", src, dst)

def move(src, dst):
    return lua_call("fs.move", src, dst)

def read_file(path):
    return lua('''local p = ...
local f = fs.open(p, 'r')
if not f then return nil end
local c = f.readAll()
f.close()
return c''', path)

def write_file(path, content):
    lua('''local p, c = ...
local f = fs.open(p, 'w')
if not f then return end
f.write(c)
f.close()''', path, str(content))

def append_file(path, content):
    lua('''local p, c = ...
local f = fs.open(p, 'a')
if not f then return end
f.write(c)
f.close()''', path, str(content))

# ============================================================
# Redstone
# ============================================================
def redstone_set(side, value):
    lua_call("redstone.setOutput", side, value)

def redstone_get(side):
    return lua_call("redstone.getOutput", side)

def redstone_setAnalog(side, value):
    lua_call("redstone.setAnalogOutput", side, value)

def redstone_getAnalog(side):
    return lua_call("redstone.getAnalogOutput", side)

def redstone_setBundled(side, colorMask, value):
    lua_call("redstone.setBundledOutput", side, colorMask, value)

def redstone_getBundled(side):
    return lua_call("redstone.getBundledOutput", side)

def redstone_testBundled(side, color):
    return lua_call("redstone.testBundledInput", side, color)

# ============================================================
# Peripherals
# ============================================================
def peripheral_list():
    return lua_call("peripheral.getNames")

def peripheral_type(side):
    return lua_call("peripheral.getType", side)

def peripheral_methods(side):
    return lua_call("peripheral.getMethods", side)

def peripheral_call(side, method, args):
    return lua('''local side, method, args = ...
local p = peripheral.wrap(side)
if not p then return nil end
local fn = p[method]
if not fn then return nil end
return fn(table.unpack(args))''', side, method, args)

# ============================================================
# Colors
# ============================================================
colors = lua('''return {
  white=colors.white, orange=colors.orange, magenta=colors.magenta,
  lightBlue=colors.lightBlue, yellow=colors.yellow, lime=colors.lime,
  pink=colors.pink, gray=colors.gray, lightGray=colors.lightGray,
  cyan=colors.cyan, purple=colors.purple, blue=colors.blue,
  brown=colors.brown, green=colors.green, red=colors.red,
  black=colors.black
}''')

# ============================================================
# Text utils
# ============================================================
def serialize(obj):
    return lua_call("textutils.serialize", obj)

def unserialize(s):
    return lua('''local s = ...
return textutils.unserialize(s)''', s)

def serializeJSON(obj):
    return lua_call("textutils.serializeJSON", obj)

def unserializeJSON(s):
    return lua('''local s = ...
return textutils.unserializeJSON(s)''', s)

def url_encode(s):
    return lua_call("textutils.urlEncode", s)

# ============================================================
# Computer
# ============================================================
def computer_id():
    return lua_call("os.getComputerID")

def computer_label():
    return lua('''return os.getComputerLabel()''')

def set_computer_label(label):
    lua_call("os.setComputerLabel", label)

def shutdown():
    lua_call("os.shutdown")

def reboot():
    lua_call("os.reboot")

# ============================================================
# GPS
# ============================================================
def gps_locate(timeout):
    return lua('''local t = ...
local x, y, z = gps.locate(t)
if x == nil then return nil end
return {x, y, z}''', timeout)

# ============================================================
# Rednet
# ============================================================
def rednet_open(side):
    lua_call("rednet.open", side)

def rednet_close():
    lua_call("rednet.close")

def rednet_close_side(side):
    lua_call("rednet.close", side)

def rednet_send(recipient, message):
    return lua_call("rednet.send", recipient, message)

def rednet_broadcast(message):
    return lua_call("rednet.broadcast", message)

def rednet_receive(protocol, timeout):
    return lua('''local proto, t = ...
local sender, msg, p = rednet.receive(proto, t)
if sender == nil then return nil end
return {sender, msg, p}''', protocol, timeout)

def rednet_host(protocol):
    return lua('''local proto = ...
local label = os.getComputerLabel()
return rednet.host(proto, label)''', protocol)

def rednet_lookup(protocol):
    return lua_call("rednet.lookup", protocol)

# ============================================================
# Turtle
# ============================================================
def turtle_forward():
    return lua_call("turtle.forward")

def turtle_back():
    return lua_call("turtle.back")

def turtle_up():
    return lua_call("turtle.up")

def turtle_down():
    return lua_call("turtle.down")

def turtle_turnLeft():
    return lua_call("turtle.turnLeft")

def turtle_turnRight():
    return lua_call("turtle.turnRight")

def turtle_dig():
    return lua_call("turtle.dig")

def turtle_digUp():
    return lua_call("turtle.digUp")

def turtle_digDown():
    return lua_call("turtle.digDown")

def turtle_place():
    return lua_call("turtle.place")

def turtle_placeUp():
    return lua_call("turtle.placeUp")

def turtle_placeDown():
    return lua_call("turtle.placeDown")

def turtle_detect():
    return lua_call("turtle.detect")

def turtle_detectUp():
    return lua_call("turtle.detectUp")

def turtle_detectDown():
    return lua_call("turtle.detectDown")

def turtle_compare():
    return lua_call("turtle.compare")

def turtle_compareUp():
    return lua_call("turtle.compareUp")

def turtle_compareDown():
    return lua_call("turtle.compareDown")

def turtle_drop():
    return lua_call("turtle.drop")

def turtle_dropUp():
    return lua_call("turtle.dropUp")

def turtle_dropDown():
    return lua_call("turtle.dropDown")

def turtle_suck():
    return lua_call("turtle.suck")

def turtle_suckUp():
    return lua_call("turtle.suckUp")

def turtle_suckDown():
    return lua_call("turtle.suckDown")

def turtle_getFuelLevel():
    return lua_call("turtle.getFuelLevel")

def turtle_getFuelLimit():
    return lua_call("turtle.getFuelLimit")

def turtle_refuel(count):
    return lua_call("turtle.refuel", count)

def turtle_select(slot):
    return lua_call("turtle.select", slot)

def turtle_getItemCount(slot):
    return lua_call("turtle.getItemCount", slot)

def turtle_getItemSpace(slot):
    return lua_call("turtle.getItemSpace", slot)

def turtle_inspect():
    return lua_call("turtle.inspect")

def turtle_inspectUp():
    return lua_call("turtle.inspectUp")

def turtle_inspectDown():
    return lua_call("turtle.inspectDown")

def turtle_getSelectedSlot():
    return lua_call("turtle.getSelectedSlot")

# ============================================================
# Paintutils
# ============================================================
def paintutils_drawPixel(x, y, color):
    lua_call("paintutils.drawPixel", x, y, color)

def paintutils_drawLine(x1, y1, x2, y2, color):
    lua_call("paintutils.drawLine", x1, y1, x2, y2, color)

def paintutils_drawBox(x1, y1, x2, y2, color):
    lua_call("paintutils.drawBox", x1, y1, x2, y2, color)

def paintutils_drawFilledBox(x1, y1, x2, y2, color):
    lua_call("paintutils.drawFilledBox", x1, y1, x2, y2, color)

def paintutils_loadImage(path):
    return lua('''local p = ...
local img = paintutils.loadImage(p)
if img == nil then return nil end
return img''', path)

def paintutils_drawImage(image, x, y):
    lua_call("paintutils.drawImage", image, x, y)

# ============================================================
# HTTP
# ============================================================
def http_get(url, headers):
    return lua('''local url, headers = ...
local r = http.get(url, headers)
if r == nil then return nil end
local body = r.readAll()
r.close()
return body''', url, headers)

def http_post(url, body, headers):
    return lua('''local url, body, headers = ...
local r = http.post(url, body, headers)
if r == nil then return nil end
local out = r.readAll()
r.close()
return out''', url, body, headers)

def http_request(url, body, headers):
    return lua('''local url, body, headers = ...
local r = http.request(url, body, headers)
if r == nil then return nil end
local out = r.readAll()
r.close()
return out''', url, body, headers)

# ============================================================
# Keys
# ============================================================
keys = lua('''return {
  enter=keys.enter, tab=keys.tab, backspace=keys.backspace,
  up=keys.up, down=keys.down, left=keys.left, right=keys.right,
  space=keys.space, a=keys.a, b=keys.b, c=keys.c, d=keys.d,
  e=keys.e, f=keys.f, g=keys.g, h=keys.h, i=keys.i, j=keys.j,
  k=keys.k, l=keys.l, m=keys.m, n=keys.n, o=keys.o, p=keys.p,
  q=keys.q, r=keys.r, s=keys.s, t=keys.t, u=keys.u, v=keys.v,
  w=keys.w, x=keys.x, y=keys.y, z=keys.z,
  zero=keys.zero, one=keys.one, two=keys.two, three=keys.three,
  four=keys.four, five=keys.five, six=keys.six, seven=keys.seven,
  eight=keys.eight, nine=keys.nine
}''')

def read():
    return lua_call("read")

def print_line(s):
    lua_call("print", s)

def pull_event():
    return lua('''local ev = {os.pullEvent()}
return ev''')

def pull_event_raw():
    return lua('''local ev = {os.pullEventRaw()}
return ev''')

# ============================================================
# Vector
# ============================================================
def vector_new(x, y, z):
    return lua('''local x, y, z = ...
return vector.new(x, y, z)''', x, y, z)

# ============================================================
# Settings
# ============================================================
def settings_get(name):
    return lua('''local n = ...
return settings.get(n)''', name)

def settings_set(name, value):
    lua_call("settings.set", name, value)

def settings_unset(name):
    lua_call("settings.unset", name)

def settings_save():
    lua_call("settings.save")

def settings_load():
    lua_call("settings.load")

# ============================================================
# Parallel
# ============================================================
def parallel_wait(fns):
    return lua('''local fns = ...
parallel.waitForAll(table.unpack(fns))''', fns)

def parallel_any(fns):
    return lua('''local fns = ...
return parallel.waitForAny(table.unpack(fns))''', fns)

# ============================================================
# Window
# ============================================================
def window_create(parent, x, y, w, h):
    return lua('''local p, x, y, w, h = ...
return window.create(p, x, y, w, h)''', parent, x, y, w, h)
