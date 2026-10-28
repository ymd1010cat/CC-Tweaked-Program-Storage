-- gnome.fmt - the units and the alignment every window of the package shares.
--
-- WHY IT IS A MODULE OF ITS OWN: the settings panel said "free space: 2097152 B"
-- and the file browser said "320239B". Both are numbers only their author can
-- read, and both would have grown their own copy of the same base 1024 ladder --
-- two copies of one rounding rule, which is how a package ends up saying "1.0 KB"
-- in one window and "1 KB" in the next. There is one ladder and one rounding
-- rule, here.
--
-- THE RULE: base 1024, units B/KB/MB/GB. A byte is a whole thing, so the B form
-- carries no decimal; every larger unit carries exactly one. The unit is the
-- largest one for which the value is at least 1 -- and a value that would ROUND
-- to 1024.0 is promoted instead of printed, because "1024.0 KB" for one byte
-- under a megabyte is the rounding talking, not the machine. Above GB the ladder
-- stops (the machine's disks are kilobytes; a TB figure is not something this
-- computer has).
local fmt = {}

local UNITS = { "B", "KB", "MB", "GB" }

-- total divided by 1024^unit, without holding every step in a table.
local function scaled(total, unit)
    local value = total
    for _ = 1, unit do value = value / 1024 end
    return value
end

-- One decimal place, half away from zero, so 0.05 shows as 0.1 rather than
-- depending on the host's printf.
local function round1(value)
    return math.floor(value * 10 + 0.5) / 10
end

-- A byte count as an operator reads it: "0 B", "1023 B", "1.0 KB", "732.9 KB",
-- "1.0 MB". nil and anything that is not a number (a filesystem that cannot
-- answer) is "?" -- a question mark is honest, and 0 would be a lie.
function fmt.bytes(n)
    local total = tonumber(n)
    if not total or total ~= total or total < 0 then return "?" end
    if total < 1024 then
        return string.format("%d %s", math.floor(total + 0.5), UNITS[1])
    end
    -- `unit` is the POWER of 1024, so unit 1 is KB -- UNITS is the B first, which
    -- is why the label is UNITS[unit + 1]. The two places that must agree are
    -- this indexing and the stop at the top of the ladder.
    local unit = 1
    while unit < #UNITS - 1 and scaled(total, unit + 1) >= 1 do unit = unit + 1 end
    if unit < #UNITS - 1 and round1(scaled(total, unit)) >= 1024 then unit = unit + 1 end
    return string.format("%.1f %s", scaled(total, unit), UNITS[unit + 1])
end

-- part/whole as a percentage with one decimal and the sign: "26.8%". Missing
-- numbers are "?" and the result is clamped to 0..100, because the caller draws a
-- bar and a bar has no negative length.
function fmt.percent(part, whole)
    local p, w = tonumber(part), tonumber(whole)
    if not p or not w or w ~= w or w <= 0 then return "?" end
    if p < 0 then p = 0 end
    if p > w then p = w end
    return string.format("%.1f%%", round1(p * 100 / w))
end

-- `s` cut to `w` cells keeping its HEAD, with ">" for what was dropped: a label
-- that does not fit says so instead of running into the next column.
function fmt.fit(s, w)
    s = tostring(s or "")
    w = math.floor(tonumber(w) or 0)
    if w <= 0 then return "" end
    if #s <= w then return s end
    if w == 1 then return ">" end
    return s:sub(1, w - 1) .. ">"
end

-- The other end: keep the TAIL and mark the head. A right aligned display wants
-- this one -- the digits typed last are the ones that matter, so an overlong
-- number loses its oldest digits, not its newest.
function fmt.fit_left(s, w)
    s = tostring(s or "")
    w = math.floor(tonumber(w) or 0)
    if w <= 0 then return "" end
    if #s <= w then return s end
    if w == 1 then return ">" end
    return ">" .. s:sub(#s - (w - 2))
end

-- `s` padded on the right to `w` cells, so a value starts in one column. Never
-- cuts: a string longer than the field is returned whole and the caller decides
-- (fit / fit_left) what to drop.
function fmt.pad(s, w)
    s = tostring(s or "")
    w = math.floor(tonumber(w) or 0)
    if w <= #s then return s end
    return s .. (" "):rep(w - #s)
end

return fmt
