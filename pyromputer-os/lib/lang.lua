-- lang.lua - the message catalogue, and the one place a language is chosen.
--
-- WHY THIS FILE EXISTS. Every sentence the shell says used to be an English
-- literal at the point that said it. A Chinese interface cannot be built that
-- way: the text has to be one table keyed by meaning, so that "switch the
-- language" is one variable and not a rewrite of every command.
--
-- THE FILE IS ASCII, THE CHINESE IS NOT. gate 2 requires every deployed file to
-- be ASCII (only README.md and ROADMAP.zh.md are exempt, and they are never
-- deployed). The Chinese below is therefore written as UTF-8 BYTE ESCAPES: a
-- decimal backslash escape is one byte, so three of them are one CJK character.
-- Lua does not decode escapes into codepoints; the bytes go straight to the
-- terminal and to files, which is exactly right -- a file written in Chinese
-- mode must contain UTF-8, and only the SCREEN needs the bitmap renderer
-- (lib/cc_chinese.lua), because the CraftOS font has no CJK glyphs at all.
--
-- TWO KINDS OF "CANNOT SPEAK CHINESE", AND BOTH ARE SAID OUT LOUD:
--   1. the renderer module is not on the machine (it lives on the system module
--      medium), or
--   2. the glyphs are not on an inserted medium.
-- In both cases zh is UNAVAILABLE and set() refuses with the reason. Silently
-- staying in English would be the worst outcome: the operator would believe the
-- language changed and wonder why the screen did not.
--
-- A WRITE TO A FILE IS BYTES, A WRITE TO THE SCREEN IS GLYPHS. The shell has one
-- output choke point (emit in usr/psh.lua). When its destination is a file or a
-- command substitution buffer, Chinese is written as UTF-8 bytes like any other
-- text; only when the destination is the console does say() draw glyphs. That
-- distinction is what keeps a redirected Chinese line a real UTF-8 file.
--
-- HOW A MIXED LINE IS DRAWN. A CraftOS cell is 2x3 pixels, so a size 12 glyph is
-- 6 cells wide and 4 cells tall (cc_chinese.cells). A line that mixes Chinese
-- with ASCII therefore mixes a 4-row band with ordinary characters. The line is
-- split into runs: a CJK run is blitted on the band, an ASCII run is written on
-- the band top row, which keeps the whole line on one visual line. A line with
-- no CJK at all is printed normally and costs one row, so English output stays
-- byte-for-byte what it always was.
local lang = {}

-- The languages this build knows. "zh" is listed even when it cannot be used
-- right now, because status() has to be able to say WHY it cannot.
lang.LANGUAGES = { "en", "zh" }

-- key -> { en = ..., zh = ... }. A missing zh falls back to en, and a missing key
-- falls back to the key itself so that a typo is visible on screen instead of
-- printing nothing.
local CATALOGUE = {
    banner_hint = {
        en = "type 'help' for commands",
        zh = "\232\190\147\229\133\165 help \230\159\165\231\156\139\229\145\189\228\187\164",
    },
    help_title = {
        en = "Commands",
        zh = "\229\145\189\228\187\164",
    },
    help_more = {
        en = "type 'help NAME' for one command",
        zh = "\232\190\147\229\133\165 help \229\138\160\229\144\141\229\173\151\231\156\139\229\141\149\228\184\170",
    },
    lang_now = {
        en = "language",
        zh = "\232\175\173\232\168\128",
    },
    lang_avail = {
        en = "available",
        zh = "\229\143\175\231\148\168",
    },
    lang_fonts = {
        en = "font medium",
        zh = "\229\173\151\229\189\162\231\155\152",
    },
    lang_fonts_ok = {
        en = "inserted",
        zh = "\229\183\178\230\143\146\229\133\165",
    },
    lang_fonts_no = {
        en = "not inserted",
        zh = "\230\156\170\230\143\146\229\133\165",
    },
    lang_set = {
        en = "language is now",
        zh = "\232\175\173\232\168\128\229\183\178\229\136\135\228\184\186",
    },
    lang_saved = {
        en = "saved for the next boot",
        zh = "\229\183\178\228\191\157\229\173\152\239\188\140\228\184\139\230\172\161\229\188\128\230\156\186\231\148\159\230\149\136",
    },
    lang_need_root = {
        en = "only root can save the language",
        zh = "\229\143\170\230\156\137 root \232\131\189\228\191\157\229\173\152\232\175\173\232\168\128",
    },
    lang_no_font = {
        en = "zh needs the font medium: insert both font disks",
        zh = "\228\184\173\230\150\135\233\156\128\232\166\129\229\173\151\229\189\162\231\155\152\239\188\154\232\175\183\230\143\146\229\133\165\228\184\164\229\188\160\229\173\151\229\189\162\231\155\152",
    },
    lang_unknown = {
        en = "unknown language",
        zh = "\230\156\170\231\159\165\232\175\173\232\168\128",
    },
    lang_usage = {
        en = "usage: lang [zh|en] [--save]",
        zh = "\231\148\168\230\179\149\239\188\154lang [zh|en] [--save]",
    },
    err_denied = {
        en = "permission denied",
        zh = "\230\157\131\233\153\144\228\184\141\232\182\179",
    },
    err_nofile = {
        en = "no such file",
        zh = "\230\150\135\228\187\182\228\184\141\229\173\152\229\156\168",
    },
    err_nospace = {
        en = "not enough space",
        zh = "\231\169\186\233\151\180\228\184\141\232\182\179",
    },
    err_readonly = {
        en = "read-only file system",
        zh = "\229\143\170\232\175\187\230\150\135\228\187\182\231\179\187\231\187\159",
    },
    boot_welcome = {
        en = "Welcome",
        zh = "\230\172\162\232\191\142",
    },
    boot_username = {
        en = "your name",
        zh = "\228\189\160\231\154\132\231\148\168\230\136\183\229\144\141",
    },
    boot_rootpw = {
        en = "root password",
        zh = "root \229\175\134\231\160\129",
    },
    boot_done = {
        en = "setup complete",
        zh = "\232\174\190\231\189\174\229\174\140\230\136\144",
    },
}

-- The language of this session. Read from /etc/locale.conf at boot, changed by
-- the lang command; never guessed from the environment (CraftOS has none).
local current = "en"

local function renderer()
    -- The renderer lives on the system module medium, so it may simply not be
    -- loadable. pcall rather than require: a machine without the medium must
    -- still be able to run the shell in English.
    local ok, mod = pcall(require, "cc_chinese")
    if ok and type(mod) == "table" then return mod end
    return nil, tostring(mod)
end

-- ok, reason. zh is available when the renderer loads AND a glyph medium is in
-- the machine. "en" is always available: it is what the shell was written in.
function lang.available(code)
    code = tostring(code or "")
    if code == "en" then return true end
    if code ~= "zh" then return false, "unknown language: " .. code end
    local mod = renderer()
    if not mod then
        return false, "the CJK renderer is not on this machine (insert the system module medium)"
    end
    local ok, reason = mod.available()
    if not ok then return false, tostring(reason) end
    return true
end

function lang.get() return current end

-- set(code) -> true, or false plus the reason. Refusing is deliberate: see the
-- header. A session may switch without being root; only SAVING needs root.
function lang.set(code)
    code = tostring(code or "")
    if code == current then return true end
    local ok, why = lang.available(code)
    if not ok then return false, why end
    current = code
    return true
end

-- text(key, ...) -> the sentence in the current language. %s and %d are filled
-- by string.format, so a message may carry its arguments in the usual order.
function lang.text(key, ...)
    local entry = CATALOGUE[key]
    local s
    if type(entry) == "table" then
        s = entry[current] or entry.en
    else
        s = tostring(key)
    end
    if select("#", ...) > 0 then
        local ok, filled = pcall(string.format, s, ...)
        if ok then s = filled end
    end
    return s
end

-- The catalogue, for a test that wants to prove every key has both languages.
function lang.keys()
    local out = {}
    for k in pairs(CATALOGUE) do out[#out + 1] = k end
    table.sort(out)
    return out
end

function lang.entry(key) return CATALOGUE[key] end

-- ---------------------------------------------------------------- the file
-- /etc/locale.conf holds one key, lang=. It is written only by "lang --save",
-- which is root only, so that a session cannot decide for the next boot.
local CONF = "/etc/locale.conf"

function lang.load()
    if type(fs) ~= "table" or not fs.exists(CONF) then return current end
    local f = fs.open(CONF, "r")
    if not f then return current end
    local text = f.readAll() or ""
    f.close()
    local value = text:match("lang%s*=%s*(%a%a)")
    if value and lang.available(value) then current = value end
    return current
end

function lang.save(code)
    code = tostring(code or current)
    local ok, why = lang.available(code)
    if not ok then return false, why end
    local f = fs.open(CONF, "w")
    if not f then return false, "cannot write " .. CONF end
    f.write("lang=" .. code .. "\n")
    f.close()
    return true
end

-- ------------------------------------------------------------- drawing text
-- (codepoint, is_cjk, raw bytes) for every character of a string.
--
-- THE CODEPOINT IS DECODED, NOT GUESSED. The first version recorded only the
-- LENGTH of a sequence (0x800 for three bytes, 0x10000 for four) and compared
-- that against the CJK range. For three-byte text that test is always false --
-- 0x800 < 0x2E80 -- so every Chinese sentence was classified as ordinary text and
-- went to term.write, where the CraftOS font has no glyphs and the screen shows
-- garbage. The PC suite cannot see it (no font medium, so the fallback path is
-- what runs there); a real machine with the glyph disks mounted showed it at
-- once: "lang zh" printed bytes through term.write and term.blit was never
-- called. A stray continuation byte is kept as itself so that a broken string
-- still prints something instead of looping.
local function decode(text)
    local out, i, n = {}, 1, #text
    while i <= n do
        local b = text:byte(i)
        local cp, len
        if b < 0x80 then
            cp, len = b, 1
        elseif b < 0xC0 then
            cp, len = b, 1
        elseif b < 0xE0 then
            local b2 = text:byte(i + 1) or 0x80
            cp, len = (b - 0xC0) * 0x40 + (b2 % 0x40), 2
        elseif b < 0xF0 then
            local b2 = text:byte(i + 1) or 0x80
            local b3 = text:byte(i + 2) or 0x80
            cp = (b - 0xE0) * 0x1000 + (b2 % 0x40) * 0x40 + (b3 % 0x40)
            len = 3
        else
            local b2 = text:byte(i + 1) or 0x80
            local b3 = text:byte(i + 2) or 0x80
            local b4 = text:byte(i + 3) or 0x80
            cp = (b - 0xF0) * 0x40000 + (b2 % 0x40) * 0x1000 +
                 (b3 % 0x40) * 0x40 + (b4 % 0x40)
            len = 4
        end
        len = math.min(len, n - i + 1)
        out[#out + 1] = { cp = cp, cjk = cp >= 0x2E80, bytes = text:sub(i, i + len - 1) }
        i = i + len
    end
    return out
end

lang.decode = decode

function lang.split_lines(text)
    local out = {}
    for line in (tostring(text) .. "\n"):gmatch("(.-)\n") do out[#out + 1] = line end
    if #out == 0 then out[1] = "" end
    return out
end

local function has_cjk(chars)
    for _, c in ipairs(chars) do
        if c.cjk then return true end
    end
    return false
end

-- say(text[, opts]) -> true when glyphs were drawn, false when the text was
-- printed as ordinary characters. opts.colour sets the glyph colour.
--
-- The caller decides WHERE the output goes: say() always draws on the console.
-- A redirection or a command substitution must not come here -- it needs bytes,
-- which is what usr/psh.lua checks before calling this.
function lang.say(text, opts)
    opts = opts or {}
    local mod = renderer()
    if not mod or not mod.available() then
        print(text)
        return false
    end
    local w, h = term.getSize()
    local cw, ch = mod.cells(mod.config.size)
    if opts.colour then mod.config.text_color = opts.colour end
    local y = select(2, term.getCursorPos())

    for _, line in ipairs(lang.split_lines(text)) do
        local chars = decode(line)
        if not has_cjk(chars) then
            -- Ordinary text: one row, exactly like print(), so the English
            -- interface is unchanged even when the language is English.
            if y > h then
                term.scroll(1)
                y = h
            end
            term.setCursorPos(1, y)
            term.write(line)
            y = y + 1
        else
            -- Split into display rows first (a CJK character costs cw columns),
            -- so the scroll amount is known before anything is drawn.
            local rows, row, used = {}, {}, 0
            for _, c in ipairs(chars) do
                local width = c.cjk and cw or 1
                if used + width > w and #row > 0 then
                    rows[#rows + 1] = row
                    row, used = {}, 0
                end
                row[#row + 1] = c
                used = used + width
            end
            rows[#rows + 1] = row

            local need = #rows * ch
            if y + need - 1 > h then
                local over = y + need - 1 - h
                if over >= h then
                    term.clear()
                    y = 1
                else
                    term.scroll(over)
                    y = y - over
                    if y < 1 then y = 1 end
                end
            end

            for _, r in ipairs(rows) do
                local x, i = 1, 1
                while i <= #r do
                    local cjk = r[i].cjk
                    local buf = {}
                    while i <= #r and r[i].cjk == cjk do
                        buf[#buf + 1] = r[i].bytes
                        i = i + 1
                    end
                    local piece = table.concat(buf)
                    if cjk then
                        mod.draw(piece, x, y)
                        x = x + #buf * cw
                    else
                        term.setCursorPos(x, y)
                        term.write(piece)
                        x = x + #buf
                    end
                end
                y = y + ch
            end
        end
    end

    if y > h then y = h end
    term.setCursorPos(1, y)
    return true
end

-- The glyph band size, for a caller that wants to lay text out itself.
function lang.cells()
    local mod = renderer()
    if not mod then return 1, 1 end
    return mod.cells(mod.config.size)
end

return lang
