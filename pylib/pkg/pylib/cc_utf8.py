# cc_utf8.py - Python wrapper for the utf8display Lua library
# Requires utf8display.lua in CC's require path.

# Cache the loaded Lua module on first use
_LOADED = [False]

def _ensure_loaded():
    if _LOADED[0]:
        return
    lua("""
    if not _G.__utf8display then
        _G.__utf8display = require("utf8display")
    end
    """)
    _LOADED[0] = True

def configure(font_path):
    # Set a local font file path (avoids HTTP download)
    _ensure_loaded()
    lua("""
    local p = ...
    _G.__utf8display.setConfig("fontPath", p)
    """, str(font_path))

def write(text, text_color, bg_color):
    # Draw text without auto-wrap. Newline is replaced by space.
    _ensure_loaded()
    lua("""
    local s, fg, bg = ...
    _G.__utf8display.write(s, fg, bg)
    """, str(text), text_color, bg_color)

def print_line(text, text_color, bg_color):
    # Draw text with auto-wrap. Newline breaks the line.
    _ensure_loaded()
    lua("""
    local s, fg, bg = ...
    _G.__utf8display.print(s, fg, bg)
    """, str(text), text_color, bg_color)

def blit(text, fg_string, bg_string):
    # Per-character colors as blit code strings
    _ensure_loaded()
    lua("""
    local s, fg, bg = ...
    _G.__utf8display.blit(s, fg, bg)
    """, str(text), str(fg_string), str(bg_string))

def set_cursor(x, y):
    lua_call("term.setCursorPos", x, y)
