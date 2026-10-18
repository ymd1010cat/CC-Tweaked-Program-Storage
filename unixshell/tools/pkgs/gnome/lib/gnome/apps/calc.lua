-- gnome.apps.calc - a calculator with a mouse keypad and a keyboard.
--
-- WHY IT IS IN THIS SET: it is the one app whose answer is a known number, so it
-- is the app that proves a click really reached the application -- through the
-- desktop's hit testing, the window's interior offset, and the app's own keypad
-- grid. "It drew something" would not.
--
-- THE ARITHMETIC is a three register machine (accumulator, pending operator, and
-- the digits being typed) and not load()/eval: a calculator does not need to run
-- the string the operator typed, and a desktop app that did would be handing the
-- keyboard to arbitrary code. It is IMMEDIATE EXECUTION, left to right: there is
-- no operator precedence, so 2 + 3 * 4 is 20, not 14. That is stated here, in the
-- ROADMAP and pinned by an assertion, because a calculator that silently did
-- either would be right half the time.
--
-- THE KEYPAD is a 4x4 grid of digits and operators -- 7 8 9 /, 4 5 6 *, 1 2 3 -,
-- 0 . = + -- plus AC and a backspace (<) on the row above it. Every key is an
-- inverse block of cells, so a key is visible even when its label is not; the key
-- under the pointer is drawn in the palette's brown, and a key that was just
-- pressed in the accent orange for a moment. The geometry is one function of the
-- body size that both the drawing and the hit testing call, so a click on the
-- label is a click on the key, and a narrow body shrinks the keys rather than
-- pushing them out of the window.
local fmt = require("gnome.fmt")

local calc = {}

-- The grid as drawn, one table row per visible row of keys.
calc.GRID = {
    { "7", "8", "9", "/" },
    { "4", "5", "6", "*" },
    { "1", "2", "3", "-" },
    { "0", ".", "=", "+" },
}
calc.FUNCTIONS = { "AC", "<" }

-- How long a pressed key stays lit. The desktop's clock only moves on ticks, so
-- this is deterministic: a press is visible on the frame the click draws, and a
-- tick past the window clears it.
calc.PRESS_TIME = 0.25

local function state(win)
    -- The desktop hands every window an empty state table, so the fields have to
    -- be filled in one by one: "win.state or {...}" alone leaves entry nil and
    -- the first key press then concatenates nil.
    win.state = win.state or {}
    local st = win.state
    if st.entry == nil then st.entry = "" end
    if st.shown == nil then st.shown = "0" end
    return st
end

calc.state = state

-- A number the way an operator writes it: 10, not 10.0. %.10g keeps the result
-- identical on Lua 5.1 and 5.4 (tostring would print 0.30000000000000004 on one
-- and 0.3 on the other).
local function show_number(n)
    local value = tonumber(n)
    if not value or value ~= value or value == math.huge or value == -math.huge then
        return "error"
    end
    if value == math.floor(value) and math.abs(value) < 1e15 then
        return string.format("%d", value)
    end
    return string.format("%.10g", value)
end

local function apply(acc, op, rhs)
    local a, b = tonumber(acc) or 0, tonumber(rhs) or 0
    if op == "+" then return a + b end
    if op == "-" then return a - b end
    if op == "*" then return a * b end
    if op == "/" then
        if b == 0 then return nil, "divide by zero" end
        return a / b
    end
    return b
end

-- The digits being typed are the ONLY "is this a new number" flag this machine
-- needs: "=" empties them, so the next key starts a number, and a pending
-- operator empties them too. A separate "fresh" flag would be a second copy of
-- that answer, and two copies can disagree.
local function clear(st)
    st.entry, st.acc, st.op, st.shown, st.error = "", nil, nil, "0", nil
end

-- One key press. Answers the state, so the drawing code has one source of truth
-- and a test can ask the app directly as well as read the screen. `now` is the
-- desktop's clock, used only for the pressed highlight.
function calc.press(win, key, now)
    local st = state(win)
    st.hover = nil
    st.pressed = { key = key, at = tonumber(now) or 0 }
    if key == "AC" then
        clear(st)
        return st
    end
    -- An error is cleared by AC or by starting a number, and by nothing else:
    -- backspace on an error does nothing, so "error: divide by zero" cannot be
    -- edited into a wrong number.
    local function leave_error()
        if st.error then
            st.error, st.shown = nil, "0"
            st.acc, st.op, st.entry = nil, nil, ""
        end
    end
    if key == "<" then
        if st.error then return st end
        st.entry = st.entry:sub(1, -2)
        return st
    end
    if key == "=" then
        if st.error then return st end
        if st.op and (st.entry ~= "" or st.acc ~= nil) then
            local rhs = st.entry ~= "" and st.entry or st.acc
            local value, why = apply(st.acc, st.op, rhs)
            if value == nil then
                st.error, st.shown = why, "error"
                st.acc, st.op, st.entry = nil, nil, ""
            else
                st.shown = show_number(value)
                -- Emptying the digits is what makes the NEXT digit a new number.
                st.acc, st.op, st.entry = nil, nil, ""
            end
        elseif st.entry ~= "" then
            st.shown = st.entry
            st.entry = ""
        end
        return st
    end
    if key == "+" or key == "-" or key == "*" or key == "/" then
        leave_error()
        if st.entry ~= "" then
            if st.op then
                local value, why = apply(st.acc, st.op, st.entry)
                if value == nil then
                    st.error, st.shown = why, "error"
                    st.acc, st.op, st.entry = nil, nil, ""
                    return st
                end
                st.acc = value
            else
                st.acc = tonumber(st.entry)
            end
            st.entry = ""
        elseif st.acc == nil then
            -- A pending operator with nothing typed continues from the answer on
            -- the display (2 + 3 = , then * 4 = is 20).
            st.acc = tonumber(st.shown)
        end
        st.op = key
        return st
    end
    if key == "." then
        leave_error()
        if st.entry:find(".", 1, true) then return st end
        st.entry = (st.entry == "" and "0." or st.entry .. ".")
        return st
    end
    if type(key) ~= "string" or not key:match("^%d$") then return st end
    leave_error()
    st.entry = st.entry .. key
    return st
end

-- The line the operator reads: the error, the digits being typed, or the answer.
function calc.display(st)
    if st.error then return "error: " .. st.error end
    if st.entry ~= "" then return st.entry end
    return st.shown or "0"
end

-- The sum so far, for the small line above the keypad: "2 + 3" while typing.
function calc.expression(st)
    if st.acc == nil and st.op == nil then return st.entry end
    local left = st.acc ~= nil and show_number(st.acc) or ""
    local text = left .. " " .. (st.op or "") .. " " .. st.entry
    text = text:gsub("%s+$", "")
    return text
end

-- The keypad geometry, in body relative cells. Drawing and hit testing both ask
-- this function, so a click on a key is a click on the label it shows.
--
-- Rows: 1 is the display, 2 is the function row (AC and <), and the four grid
-- rows follow, each `key_h` cells tall. key_h is 2 in a body of ten cells (the
-- default window) and 1 in a shorter one, so the grid shrinks with the body
-- instead of hanging out of it.
function calc.layout(w, h)
    w = math.max(0, math.floor(tonumber(w) or 0))
    h = math.max(0, math.floor(tonumber(h) or 0))
    local gap = 1
    local key_w = math.floor((w - 3 * gap) / 4)
    if key_w < 2 then key_w = math.max(1, math.floor(w / 4)) end
    local key_h = 2
    local room = math.max(1, h - 2)
    key_h = math.max(1, math.floor(room / 4))
    if key_h > 3 then key_h = 3 end
    local pitch = key_w + gap
    local lay = {
        display = 1, function_row = 2, first_row = 3,
        key_w = key_w, key_h = key_h, pitch = pitch, buttons = {},
    }
    lay.expression_col = 1 + #calc.FUNCTIONS * pitch
    for i, key in ipairs(calc.FUNCTIONS) do
        lay.buttons[#lay.buttons + 1] = {
            key = key, col = 1 + (i - 1) * pitch, row = lay.function_row,
            w = key_w, h = 1,
        }
    end
    for r, keys in ipairs(calc.GRID) do
        for c, key in ipairs(keys) do
            lay.buttons[#lay.buttons + 1] = {
                key = key, col = 1 + (c - 1) * pitch,
                row = lay.first_row + (r - 1) * key_h,
                w = key_w, h = key_h,
            }
        end
    end
    return lay
end

-- The key under a body relative cell, or nil.
function calc.hit(lay, col, row)
    col, row = tonumber(col), tonumber(row)
    if not col or not row then return nil end
    for _, button in ipairs(lay.buttons) do
        if row >= button.row and row < button.row + button.h and
           col >= button.col and col < button.col + button.w then
            return button.key, button
        end
    end
    return nil
end

-- The colours of one key: the accent (orange) while it is being pressed, the
-- palette's brown under the pointer, and the plain inverse block otherwise.
function calc.key_colours(api, st, key)
    local colours = api.colours
    local now = tonumber(api.desktop and api.desktop.now) or 0
    if st.pressed and st.pressed.key == key and
       now - (tonumber(st.pressed.at) or 0) < calc.PRESS_TIME then
        return colours.black, colours.orange
    end
    if st.hover == key then return colours.white, colours.brown end
    return colours.black, colours.lightGray
end

function calc.draw(api, win)
    local st = state(win)
    local lay = calc.layout(api.w, api.h)
    local colours = api.colours
    if api.w > 0 and lay.display <= api.h then
        local text = fmt.fit_left(calc.display(st), api.w)
        local colour = st.error and colours.red or colours.lime
        api.write(1, lay.display, (" "):rep(api.w), colour)
        api.write(api.w - #text + 1, lay.display, text, colour)
    end
    if api.w >= lay.expression_col and api.h >= lay.function_row then
        local expression = fmt.fit_left(calc.expression(st), api.w - lay.expression_col + 1)
        if expression ~= "" then
            api.write(api.w - #expression + 1, lay.function_row, expression, colours.gray)
        end
    end
    for _, button in ipairs(lay.buttons) do
        local fg, bg = calc.key_colours(api, st, button.key)
        for dy = 0, button.h - 1 do
            local row = button.row + dy
            if row > api.h then break end
            api.fill(button.col, row, button.w, 1, " ", fg, bg)
        end
        if button.row <= api.h then
            api.write(button.col, button.row, fmt.fit(button.key, button.w), fg, bg)
        end
    end
end

-- The keyboard. Digits, the decimal point and the four operators are the same
-- presses as the keys of the same name; ENTER is "=", backspace is "<", and "c"
-- or "C" is AC. The desktop's back-out key (F10) is deliberately not handled: the
-- desktop consumes it before an application sees it, and an app that ate it would
-- leave the operator unable to back out of the window. Escape is not a key this
-- machine receives at all (Minecraft keeps it for its own menu).
function calc.key_for(api, key)
    local keys = api.keys or {}
    if key == keys.backspace or key == 14 then return "<" end
    if key == keys.enter or key == 28 then return "=" end
    return nil
end

function calc.char_for(ch)
    if type(ch) ~= "string" then return nil end
    if ch:match("^%d$") then return ch end
    if ch == "." or ch == "+" or ch == "-" or ch == "*" or ch == "/" or ch == "=" then return ch end
    if ch == "c" or ch == "C" then return "AC" end
    return nil
end

function calc.event(api, win, ev)
    if ev[1] == "key" then
        local key = calc.key_for(api, tonumber(ev[2]))
        if not key then return false end
        calc.press(win, key, api.desktop and api.desktop.now)
        return true
    end
    if ev[1] == "char" then
        local key = calc.char_for(ev[2])
        if not key then return false end
        calc.press(win, key, api.desktop and api.desktop.now)
        return true
    end
    if ev[1] ~= "mouse_move" and ev[1] ~= "mouse_click" then return false end
    if not ev[3] or not ev[4] then return false end
    local row = tonumber(ev[4]) - api.body.y + 1
    local col = tonumber(ev[3]) - api.body.x + 1
    if not row or not col then return false end
    local key = calc.hit(calc.layout(api.w, api.h), col, row)
    local st = state(win)
    if ev[1] == "mouse_move" then
        if key == st.hover then return false end
        st.hover = key
        return true
    end
    if not key then return false end
    calc.press(win, key, api.desktop and api.desktop.now)
    return true
end

return calc
