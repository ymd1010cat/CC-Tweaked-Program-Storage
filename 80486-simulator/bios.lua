---------------------------------------------------------------------------
-- 80486-simulator/bios.lua
--
-- The firmware interrupt layer of the 80486 simulator: INT 10h (video) and
-- INT 13h (disk).  It talks to the CPU only through the public CPU API
-- documented by cpu.lua (registers, segment registers, flags and memory
-- accesses), and it talks to the display and the block device through the
-- vga / disk objects it is given.
--
--     local bios = Bios.new{ memory = memory, vga = vga, disk = disk }
--     bios:attach(cpu)              -- installs INT 10h / INT 13h
--     -- ... cpu executes "int 0x10" ...
--
-- Honesty rules that this module follows:
--   * Every video function that changes the screen calls refresh(), so after
--     an INT 10h call returns, the terminal already shows the new state.
--   * Unknown INT 10h / INT 13h sub-functions raise an error that names the
--     interrupt and the AH value.  Nothing is silently ignored.
--   * Unimplemented CRTC registers (anything but the cursor position
--     registers 0x0E / 0x0F) raise instead of pretending to be programmed.
--   * INT 13h AH=03 never touches the disk: a well-formed request fails with
--     "write protected" (AH=0x03) because the image is read-only, while an
--     invalid sector count or CHS fails earlier with AH=0x04.  It never
--     reports a successful write.
--   * A failed disk transfer really reports an error code and the reason is
--     kept in bios.last_error for diagnostics.
--
-- INT 10h functions implemented
--   00 set text mode (0/1/2/3/7) - clears the text plane, refreshes
--   01 set cursor shape (CH = start scanline, CL = end scanline)
--   02 set cursor position (DH = row, DL = column)
--   03 read cursor position (DH/DL) and shape (CX)
--   05 set display page (only page 0 exists)
--   06 scroll window up   (AL = lines, 0 = clear; BH = attribute)
--   07 scroll window down (AL = lines, 0 = clear; BH = attribute)
--   08 read character/attribute at the cursor (AL = code, AH = attribute)
--   09 write character with attribute (AL, BL, CX, cursor does not move)
--   0A write character, keep attribute (AL, CX, cursor does not move)
--   0E teletype (AL; handles CR, LF, BS, BEL, right-edge wrap, bottom scroll)
--   0F read current mode (AL = mode, AH = columns, BH = page)
--
-- INT 13h functions implemented
--   00 reset disk system (CF = 0, AH = 0)
--   02 read sectors (AL, CH/CL/DH/DL CHS, ES:BX destination)
--   03 write sectors (well-formed requests fail with AH=0x03, image is
--      read-only; an invalid count or CHS fails earlier with AH=0x04)
--   08 read drive parameters (CH/CL/DH, DL = 0)
--   0C seek (CF = 0, AH = 0 for a valid CHS)
--
-- INT 11h equipment check
--   AX = equipment word (0x0021 by default: one floppy drive, 80x25 color,
--   no serial or parallel adapters).
--
-- INT 17h printer services
--   00 print character, 01 initialize, 02 read status.  No parallel printer
--   is emulated; every function returns AH = 0x91 (bit 7 = not busy,
--   bit 4 = selected, bit 0 = time-out) and no character is ever sent
--   anywhere.  Bit 7 is deliberately set so a DOS kernel probing for a
--   printer never waits for a "ready" state that cannot happen.
--
-- INT 19h bootstrap
--   Reads sector 0 (the boot sector) from the attached disk into memory at
--   0x0000:0x7C00, verifies the 0xAA55 signature, sets DL to the boot drive
--   and hands control to 0x0000:0x7C00 through cpu:jump_far().  Like real
--   firmware it never returns from this interrupt; the CPU therefore
--   suppresses the implicit IRET for this handler.
--
-- INT 16h keyboard
--   00/10 blocking read: waits for a keystroke (internal buffer first, then
--        the keyboard source) and returns AL = ASCII, AH = scan code
--   01/11 non-blocking read: ZF = 1 and the buffer untouched when no key is
--        pending; otherwise ZF = 0 and AX = (scan << 8) | ASCII, key kept
--   02 read shift flags (no shift state is tracked yet, AL = 0)
--   Keys can be injected with bios:push_key(scan, ascii) / push_char(ch).
--   The default source reads CraftOS char/key events through os.pullEvent.
--
-- INT 12h memory size
--   AX = conventional memory in KiB (default 640).
--
-- INT 15h system services
--   AH = 88h: AX = extended memory in KiB (default 15 MiB = 15360 KiB).
--
-- INT 1Ah real-time clock / tick counter
--   00 read system clock ticks (CX:DX = 32-bit count, AL = midnight flag)
--   01 set system clock ticks (CX:DX)
--   02 read RTC time (CH = hour, CL = minute, DH = second, CF = 0 binary)
--   04 read RTC date (CH = century, CL = year, DH = month, DL = day)
--   Reading uses the injected clock/date sources (os.clock / os.date by
--   default); setting the RTC (AH = 03/05) raises because it is not
--   emulated rather than pretending to work.
--
-- INT 08h system timer
--   Advances the same tick counter read by INT 1Ah (18.2065 ticks/second,
--   1573040 ticks per day).  There is no emulated PIC, so this handler runs
--   when the guest executes INT 08h; there is no asynchronous IRQ0 source.
--
-- Error codes returned by INT 13h in AH:
--   0x03 write protected      (AH = 03 write)
--   0x04 sector not found     (invalid CHS, bad count, short read, read error)
--   0x09 DMA boundary crossed (transfer would cross a 64 KiB boundary)
--   0x80 no disk attached
--
-- Conventions: CraftOS Lua 5.1 (no bitwise operators, no goto, no //),
-- pure ASCII source, four-space indent, everything local.
---------------------------------------------------------------------------

local floor = math.floor
local byte  = string.byte

---------------------------------------------------------------------------
-- Constants
---------------------------------------------------------------------------

local MAX_SECTORS_PER_READ = 128
local SECTOR_SIZE = 512
local BOOT_ADDRESS = 0x7C00
local BOOT_SIGNATURE = 0xAA55
local BOOT_SIGNATURE_OFFSET = 511

local CONVENTIONAL_KB = 640
local EXTENDED_KB = 15 * 1024
-- Equipment word returned by INT 11h: bit 0 = one floppy drive present,
-- bits 4-5 = 10b (80x25 color), no serial/parallel adapters.  This is the
-- classic PC/XT value and is what DOS 2.x expects from the boot floppy.
local EQUIPMENT_WORD = 0x0021
-- INT 17h status for "no printer attached".  Bit 7 (not busy) MUST be set:
-- a DOS kernel probing the printer treats "busy" as "wait for ready" and
-- would spin forever on a machine with no printer.  The value is the
-- reviewer-suggested 0x90 (bit 7 not busy, bit 4 selected/on-line) with
-- bit 0 (time-out) added: no device ever acknowledges, so the status
-- reports a time-out instead of a ready printer.
local PRINTER_STATUS = 0x0091
local KEYBOARD_BUFFER_MAX = 64
local TICKS_PER_SECOND = 18.2065
local TICKS_PER_DAY = 1573040

---------------------------------------------------------------------------
-- Keyboard translation tables (DOS scan code set 1)
---------------------------------------------------------------------------

local CHAR_SCAN = {
    ["1"] = 0x02, ["2"] = 0x03, ["3"] = 0x04, ["4"] = 0x05,
    ["5"] = 0x06, ["6"] = 0x07, ["7"] = 0x08, ["8"] = 0x09,
    ["9"] = 0x0A, ["0"] = 0x0B,
    ["-"] = 0x0C, ["="] = 0x0D,
    ["q"] = 0x10, ["w"] = 0x11, ["e"] = 0x12, ["r"] = 0x13,
    ["t"] = 0x14, ["y"] = 0x15, ["u"] = 0x16, ["i"] = 0x17,
    ["o"] = 0x18, ["p"] = 0x19, ["["] = 0x1A, ["]"] = 0x1B,
    ["a"] = 0x1E, ["s"] = 0x1F, ["d"] = 0x20, ["f"] = 0x21,
    ["g"] = 0x22, ["h"] = 0x23, ["j"] = 0x24, ["k"] = 0x25,
    ["l"] = 0x26, [";"] = 0x27, ["'"] = 0x28, ["`"] = 0x29,
    ["\\"] = 0x2B,
    ["z"] = 0x2C, ["x"] = 0x2D, ["c"] = 0x2E, ["v"] = 0x2F,
    ["b"] = 0x30, ["n"] = 0x31, ["m"] = 0x32,
    [","] = 0x33, ["."] = 0x34, ["/"] = 0x35,
    [" "] = 0x39,
}

-- Shifted symbols keep the scan code of their unshifted key.
local SHIFTED_BASE = {
    ["~"] = "`", ["!"] = "1", ["@"] = "2", ["#"] = "3", ["$"] = "4",
    ["%"] = "5", ["^"] = "6", ["&"] = "7", ["*"] = "8", ["("] = "9",
    [")"] = "0", ["_"] = "-", ["+"] = "=", ["{"] = "[", ["}"] = "]",
    ["|"] = "\\", [":"] = ";", ['"'] = "'", ["<"] = ",", [">"] = ".",
    ["?"] = "/",
}

-- { ASCII, scan code } for keys that do not produce a char event.
local SPECIAL_KEYS = {
    enter     = {0x0D, 0x1C},
    backspace = {0x08, 0x0E},
    tab       = {0x09, 0x0F},
    up        = {0x00, 0x48},
    down      = {0x00, 0x50},
    left      = {0x00, 0x4B},
    right     = {0x00, 0x4D},
    home      = {0x00, 0x47},
    ["end"]   = {0x00, 0x4F},
    pageUp    = {0x00, 0x49},
    pageDown  = {0x00, 0x51},
    insert    = {0x00, 0x52},
    delete    = {0x00, 0x53},
    ["f1"]    = {0x00, 0x3B}, ["f2"]  = {0x00, 0x3C},
    ["f3"]    = {0x00, 0x3D}, ["f4"]  = {0x00, 0x3E},
    ["f5"]    = {0x00, 0x3F}, ["f6"]  = {0x00, 0x40},
    ["f7"]    = {0x00, 0x41}, ["f8"]  = {0x00, 0x42},
    ["f9"]    = {0x00, 0x43}, ["f10"] = {0x00, 0x44},
}

local function char_scan(ch)
    if type(ch) ~= "string" or #ch ~= 1 then
        return 0
    end
    local scan = CHAR_SCAN[ch:lower()]
    if scan ~= nil then
        return scan
    end
    local base = SHIFTED_BASE[ch]
    if base ~= nil then
        return CHAR_SCAN[base] or 0
    end
    return 0
end

-- Default real-time clock date source: a table with hour/min/sec/year/
-- month/day, or nil when the host has no clock.
local function default_date_source()
    local osapi = rawget(_G, "os")
    if type(osapi) ~= "table" or type(osapi.date) ~= "function" then
        return nil
    end
    local ok, value = pcall(osapi.date, "*t")
    if ok and type(value) == "table" then
        return value
    end
    return nil
end

-- Default blocking keyboard source: CraftOS key/char events.  Printable keys
-- arrive as a key event followed by a char event, so the scan code is
-- remembered and the char event returns the pair exactly once.
local function default_keyboard_pull(bios)
    local osapi = rawget(_G, "os")
    if type(osapi) ~= "table" or type(osapi.pullEvent) ~= "function" then
        error("INT 16h: no keyboard source available "
            .. "(inject opts.keyboard_pull)", 0)
    end
    local keysapi = rawget(_G, "keys")
    local pending_scan = nil
    while true do
        local event, first = osapi.pullEvent()
        if event == "char" then
            local text = tostring(first)
            if #text >= 1 then
                local ch = text:sub(1, 1)
                local scan = pending_scan
                if scan == nil then
                    scan = char_scan(ch)
                end
                pending_scan = nil
                return {ascii = byte(ch), scan = scan}
            end
        elseif event == "key" then
            local name = nil
            if type(keysapi) == "table"
                and type(keysapi.getName) == "function" then
                local ok, value = pcall(keysapi.getName, first)
                if ok and type(value) == "string" then
                    name = value
                end
            end
            if name ~= nil then
                local special = SPECIAL_KEYS[name]
                if special ~= nil then
                    pending_scan = nil
                    return {ascii = special[1], scan = special[2]}
                end
                if #name == 1 then
                    pending_scan = char_scan(name)
                end
            end
        elseif event == "terminate" then
            error("INT 16h: machine terminated while waiting for a key", 0)
        end
    end
end

local CPU_METHODS = {
    "get_reg8", "set_reg8",
    "get_reg16", "set_reg16",
    "get_sreg", "set_sreg",
    "get_flag", "set_flag",
    "read8", "write8",
}

local VGA_METHODS = {
    "get_width", "get_height", "get_base",
    "cell_offset", "read_char", "read_attr", "write_cell",
    "clear", "set_cursor", "get_cursor",
    "scroll_up", "read_line", "snapshot", "render",
}

local MEMORY_METHODS = {"read8", "write8", "read", "write"}

local TEXT_MODES = {[0] = true, [1] = true, [2] = true, [3] = true,
    [7] = true}

---------------------------------------------------------------------------
-- Module table (declared early so the helpers below can read its defaults)
---------------------------------------------------------------------------

local Bios = {}
Bios.__index = Bios

---------------------------------------------------------------------------
-- Small helpers
---------------------------------------------------------------------------

local function check_methods(target, methods, where, name)
    if type(target) ~= "table" then
        error(string.format("%s: %s must be a table (got %s)",
            where, name, type(target)), 0)
    end
    for i = 1, #methods do
        local method = methods[i]
        if type(target[method]) ~= "function" then
            error(string.format("%s: %s is missing method '%s'",
                where, name, method), 0)
        end
    end
end

local function check_cpu(cpu, where)
    check_methods(cpu, CPU_METHODS, where, "cpu object")
end

local function is_integer(value)
    return type(value) == "number" and value == value and value % 1 == 0
end

local function check_byte(where, name, value)
    if not is_integer(value) or value < 0 or value > 255 then
        error(string.format("%s: %s must be an integer 0..255 (got %s)",
            where, name, tostring(value)), 0)
    end
end

local function merge_geometry(source)
    if source == nil then
        source = Bios.DEFAULT_GEOMETRY
    end
    if type(source) ~= "table" then
        error(string.format("Bios.new: opts.geometry must be a table "
            .. "(got %s)", type(source)), 0)
    end
    local geometry = {}
    local keys = {"sectors", "heads", "cylinders"}
    for i = 1, #keys do
        local key = keys[i]
        local value = source[key]
        if value == nil then
            value = Bios.DEFAULT_GEOMETRY[key]
        end
        if not is_integer(value) or value < 1 then
            error(string.format("Bios.new: geometry.%s must be a positive "
                .. "integer (got %s)", key, tostring(value)), 0)
        end
        geometry[key] = value
    end
    -- 6-bit sector field, 8-bit head field, 10-bit cylinder field.
    if geometry.sectors > 63 then
        error(string.format("Bios.new: geometry.sectors must be <= 63 "
            .. "(got %d)", geometry.sectors), 0)
    end
    if geometry.heads > 256 then
        error(string.format("Bios.new: geometry.heads must be <= 256 "
            .. "(got %d)", geometry.heads), 0)
    end
    if geometry.cylinders > 1024 then
        error(string.format("Bios.new: geometry.cylinders must be <= 1024 "
            .. "(got %d)", geometry.cylinders), 0)
    end
    return geometry
end

---------------------------------------------------------------------------
-- Public constants
---------------------------------------------------------------------------

Bios.DEFAULT_GEOMETRY = {sectors = 9, heads = 2, cylinders = 40}
Bios.INT_VIDEO = 0x10
Bios.INT_EQUIPMENT = 0x11
Bios.INT_DISK = 0x13
Bios.INT_PRINTER = 0x17
Bios.INT_BOOT = 0x19
Bios.INT_TIMER = 0x08
Bios.INT_MEMORY = 0x12
Bios.INT_SYSTEM = 0x15
Bios.INT_KEYBOARD = 0x16
Bios.INT_TIME = 0x1A
Bios.BOOT_ADDRESS = BOOT_ADDRESS
Bios.BOOT_SIGNATURE = BOOT_SIGNATURE
Bios.CONVENTIONAL_KB = CONVENTIONAL_KB
Bios.EXTENDED_KB = EXTENDED_KB
Bios.EQUIPMENT_WORD = EQUIPMENT_WORD
Bios.PRINTER_STATUS = PRINTER_STATUS
Bios.KEYBOARD_BUFFER_MAX = KEYBOARD_BUFFER_MAX
Bios.TICKS_PER_DAY = TICKS_PER_DAY
Bios.MAX_SECTORS_PER_READ = MAX_SECTORS_PER_READ
Bios.TEXT_MODES = TEXT_MODES

---------------------------------------------------------------------------
-- Construction
---------------------------------------------------------------------------

function Bios.new(opts)
    if type(opts) ~= "table" then
        error("BIOS.new: an options table is required", 0)
    end
    local memory = opts.memory
    local vga = opts.vga
    if type(memory) ~= "table" then
        error("BIOS.new: opts.memory is required", 0)
    end
    if type(vga) ~= "table" then
        error("BIOS.new: opts.vga is required", 0)
    end
    check_methods(memory, MEMORY_METHODS, "BIOS.new", "opts.memory")
    check_methods(vga, VGA_METHODS, "BIOS.new", "opts.vga")

    local disk = opts.disk
    if disk ~= nil then
        if type(disk) ~= "table" then
            error(string.format("BIOS.new: opts.disk must be a disk object "
                .. "(got %s)", type(disk)), 0)
        end
        if type(disk.try_read_sectors) ~= "function" then
            error("BIOS.new: opts.disk must provide try_read_sectors()", 0)
        end
    end

    -- A disk object may advertise its own multi-sector limit (the disk
    -- module exports MAX_SECTORS_PER_READ); otherwise the BIOS limit is used.
    local max_sectors = MAX_SECTORS_PER_READ
    if disk ~= nil and type(disk.MAX_SECTORS_PER_READ) == "number"
        and disk.MAX_SECTORS_PER_READ % 1 == 0
        and disk.MAX_SECTORS_PER_READ > 0
    then
        max_sectors = disk.MAX_SECTORS_PER_READ
    end

    local log = opts.log
    if log ~= nil and type(log) ~= "function" then
        error("BIOS.new: opts.log must be a function", 0)
    end

    local boot_drive = opts.boot_drive
    if boot_drive == nil then
        boot_drive = 0
    end
    if not is_integer(boot_drive) or boot_drive < 0 or boot_drive > 255 then
        error(string.format("BIOS.new: opts.boot_drive must be an integer "
            .. "0..255 (got %s)", tostring(boot_drive)), 0)
    end

    local check_boot_signature = opts.check_boot_signature
    if check_boot_signature == nil then
        check_boot_signature = true
    end
    if type(check_boot_signature) ~= "boolean" then
        error(string.format("BIOS.new: opts.check_boot_signature must be a "
            .. "boolean (got %s)", type(check_boot_signature)), 0)
    end

    local conventional_kb = opts.conventional_kb
    if conventional_kb == nil then
        conventional_kb = CONVENTIONAL_KB
    end
    if not is_integer(conventional_kb) or conventional_kb < 1
        or conventional_kb > CONVENTIONAL_KB then
        error(string.format("BIOS.new: opts.conventional_kb must be an "
            .. "integer 1..%d (got %s)", CONVENTIONAL_KB,
            tostring(conventional_kb)), 0)
    end

    local extended_kb = opts.extended_kb
    if extended_kb == nil then
        extended_kb = EXTENDED_KB
    end
    if not is_integer(extended_kb) or extended_kb < 0 or extended_kb > 65535 then
        error(string.format("BIOS.new: opts.extended_kb must be an integer "
            .. "0..65535 (got %s)", tostring(extended_kb)), 0)
    end

    local keyboard_max = opts.keyboard_max
    if keyboard_max == nil then
        keyboard_max = KEYBOARD_BUFFER_MAX
    end
    if not is_integer(keyboard_max) or keyboard_max < 1
        or keyboard_max > 1024 then
        error(string.format("BIOS.new: opts.keyboard_max must be an integer "
            .. "1..1024 (got %s)", tostring(keyboard_max)), 0)
    end

    local keyboard_pull = opts.keyboard_pull
    if keyboard_pull ~= nil and type(keyboard_pull) ~= "function" then
        error("BIOS.new: opts.keyboard_pull must be a function", 0)
    end

    local keyboard_poll = opts.keyboard_poll
    if keyboard_poll ~= nil and type(keyboard_poll) ~= "function" then
        error("BIOS.new: opts.keyboard_poll must be a function", 0)
    end

    local clock = opts.clock
    if clock == nil then
        local osapi = rawget(_G, "os")
        if type(osapi) == "table" and type(osapi.clock) == "function" then
            clock = osapi.clock
        else
            clock = function()
                return 0
            end
        end
    end
    if type(clock) ~= "function" then
        error("BIOS.new: opts.clock must be a function", 0)
    end

    local date_source = opts.date
    if date_source == nil then
        date_source = default_date_source
    end
    if type(date_source) ~= "function" then
        error("BIOS.new: opts.date must be a function", 0)
    end

    local term = opts.term
    if term == false then
        term = nil
    elseif term == nil then
        term = _G.term
    elseif type(term) ~= "table" then
        error(string.format("BIOS.new: opts.term must be a terminal table "
            .. "or false (got %s)", type(term)), 0)
    end

    local self = setmetatable({
        memory       = memory,
        vga          = vga,
        disk         = disk,
        term         = term,
        geometry     = merge_geometry(opts.geometry),
        log          = log,
        mode         = 3,
        cursor_shape = 0x0607,
        crtc_index   = 0x0E,
        last_error   = nil,
        max_sectors_per_read = max_sectors,
        boot_drive   = boot_drive,
        check_boot_signature = check_boot_signature,
        boot_count   = 0,
        conventional_kb = conventional_kb,
        extended_kb     = extended_kb,
        keyboard        = {
            buffer  = {},
            head    = 1,
            tail    = 1,
            count   = 0,
            max     = keyboard_max,
            pull    = keyboard_pull,
            poll    = keyboard_poll,
            dropped = 0,
        },
        clock           = clock,
        date_source     = date_source,
        tick_base       = 0,
        tick_epoch      = clock(),
    }, Bios)

    self.interrupts = {
        [Bios.INT_VIDEO] = function(cpu) return self:int10(cpu) end,
        [Bios.INT_EQUIPMENT] = function(cpu) return self:int11(cpu) end,
        [Bios.INT_DISK] = function(cpu) return self:int13(cpu) end,
        [Bios.INT_PRINTER] = function(cpu) return self:int17(cpu) end,
        [Bios.INT_BOOT] = function(cpu) return self:int19(cpu) end,
        [Bios.INT_TIMER] = function(cpu) return self:int08(cpu) end,
        [Bios.INT_MEMORY] = function(cpu) return self:int12(cpu) end,
        [Bios.INT_SYSTEM] = function(cpu) return self:int15(cpu) end,
        [Bios.INT_KEYBOARD] = function(cpu) return self:int16(cpu) end,
        [Bios.INT_TIME] = function(cpu) return self:int1a(cpu) end,
    }
    return self
end

---------------------------------------------------------------------------
-- Logging / refresh
---------------------------------------------------------------------------

function Bios:_log(fmt, ...)
    if self.log ~= nil then
        self.log(string.format(fmt, ...))
    end
end

function Bios:refresh()
    if self.term == nil then
        return 0, 0
    end
    return self.vga:render(self.term)
end

---------------------------------------------------------------------------
-- Installation and CRTC ports
---------------------------------------------------------------------------

function Bios:attach(cpu)
    check_cpu(cpu, "Bios:attach")
    if type(cpu.interrupts) ~= "table" then
        error("Bios:attach: cpu.interrupts table is missing", 0)
    end
    if type(cpu.ports) ~= "table" then
        error("Bios:attach: cpu.ports table is missing", 0)
    end

    cpu.interrupts[Bios.INT_VIDEO] = self.interrupts[Bios.INT_VIDEO]
    cpu.interrupts[Bios.INT_EQUIPMENT] = self.interrupts[Bios.INT_EQUIPMENT]
    cpu.interrupts[Bios.INT_DISK] = self.interrupts[Bios.INT_DISK]
    cpu.interrupts[Bios.INT_PRINTER] = self.interrupts[Bios.INT_PRINTER]
    cpu.interrupts[Bios.INT_BOOT] = self.interrupts[Bios.INT_BOOT]
    cpu.interrupts[Bios.INT_TIMER] = self.interrupts[Bios.INT_TIMER]
    cpu.interrupts[Bios.INT_MEMORY] = self.interrupts[Bios.INT_MEMORY]
    cpu.interrupts[Bios.INT_SYSTEM] = self.interrupts[Bios.INT_SYSTEM]
    cpu.interrupts[Bios.INT_KEYBOARD] = self.interrupts[Bios.INT_KEYBOARD]
    cpu.interrupts[Bios.INT_TIME] = self.interrupts[Bios.INT_TIME]

    local ports = cpu.ports
    -- "in" is a Lua keyword, so the table fields are addressed as strings.
    if type(ports["in"]) ~= "table" then ports["in"] = {} end
    if type(ports.out) ~= "table" then ports.out = {} end

    -- Only the CRTC index/data pair is registered.  Every other VGA port is
    -- deliberately left unmapped so that the CPU reports an unmapped port
    -- instead of silently accepting an access that is not implemented.
    -- The CPU calls an output handler as fn(cpu, size, value) and an input
    -- handler as fn(cpu, size) which returns the value.
    ports.out[0x3D4] = function(_, _, value)
        return self:crtc_write_index(value)
    end
    ports.out[0x3D5] = function(_, _, value)
        return self:crtc_write_data(value)
    end
    ports["in"][0x3D5] = function(_, _)
        return self:crtc_read_data()
    end
    return self
end

function Bios:cursor_position()
    local row, col = self.vga:get_cursor()
    return row * self.vga:get_width() + col
end

function Bios:set_cursor_position(position)
    local width = self.vga:get_width()
    local height = self.vga:get_height()
    if position < 0 then position = 0 end
    local last = width * height - 1
    if position > last then position = last end
    self.vga:set_cursor(floor(position / width), position % width)
end

function Bios:crtc_write_index(value)
    check_byte("CRTC", "register index", value)
    if value ~= 0x0E and value ~= 0x0F then
        error(string.format("CRTC: register 0x%02X is not implemented "
            .. "(only the cursor location registers 0x0E/0x0F)", value), 0)
    end
    self.crtc_index = value
    return true
end

function Bios:crtc_write_data(value)
    check_byte("CRTC", "register value", value)
    local register = self.crtc_index
    local position = self:cursor_position()
    if register == 0x0E then
        position = value * 256 + (position % 256)
    elseif register == 0x0F then
        position = floor(position / 256) * 256 + value
    else
        error(string.format("CRTC: data write for unimplemented register "
            .. "0x%02X", register), 0)
    end
    self:set_cursor_position(position)
    self:refresh()
    return true
end

function Bios:crtc_read_data()
    local register = self.crtc_index
    local position = self:cursor_position()
    if register == 0x0E then
        return floor(position / 256) % 256
    end
    if register == 0x0F then
        return position % 256
    end
    error(string.format("CRTC: data read for unimplemented register 0x%02X",
        register), 0)
end

---------------------------------------------------------------------------
-- INT 10h -- video
---------------------------------------------------------------------------

function Bios:int10(cpu)
    check_cpu(cpu, "INT 10h")
    local ah = cpu:get_reg8(4)
    local al = cpu:get_reg8(0)
    if ah == 0x00 then
        return self:video_set_mode(cpu, al)
    elseif ah == 0x01 then
        return self:video_set_cursor_shape(cpu)
    elseif ah == 0x02 then
        return self:video_set_cursor(cpu)
    elseif ah == 0x03 then
        return self:video_get_cursor(cpu)
    elseif ah == 0x05 then
        return self:video_set_page(cpu, al)
    elseif ah == 0x06 then
        return self:video_scroll(cpu, true)
    elseif ah == 0x07 then
        return self:video_scroll(cpu, false)
    elseif ah == 0x08 then
        return self:video_read_character(cpu)
    elseif ah == 0x09 then
        return self:video_write_character(cpu, true)
    elseif ah == 0x0A then
        return self:video_write_character(cpu, false)
    elseif ah == 0x0E then
        return self:video_teletype(cpu)
    elseif ah == 0x0F then
        return self:video_get_mode(cpu)
    end
    error(string.format("INT 10h: unsupported video function AH=0x%02X", ah),
        0)
end

function Bios:video_set_mode(cpu, mode)
    if not TEXT_MODES[mode] then
        error(string.format("INT 10h AH=00: video mode 0x%02X is not "
            .. "implemented (text modes 0/1/2/3/7 only)", mode), 0)
    end
    -- Modes 0/1 ask for 40 columns; the framebuffer geometry is fixed at
    -- 80x25, so of that request only the text-plane clear and the cursor
    -- reset are modelled here.  The mode number is still returned by 0F.
    self.mode = mode
    self.vga:clear(0x07)
    self.vga:set_cursor(0, 0)
    self:refresh()
    self:_log("INT10_SET_MODE mode=0x%02X", mode)
    return true
end

function Bios:video_set_cursor_shape(cpu)
    local start_scanline = cpu:get_reg8(5) -- CH
    local end_scanline = cpu:get_reg8(1)   -- CL
    self.cursor_shape = start_scanline * 256 + end_scanline
    -- The shape cannot be drawn on a CraftOS terminal; it is only stored so
    -- that function 03 can report it back.  No refresh is needed.
    return true
end

function Bios:video_set_cursor(cpu)
    local row = cpu:get_reg8(6) -- DH
    local col = cpu:get_reg8(2) -- DL
    self.vga:set_cursor(row, col) -- clamps to the visible text plane
    self:refresh()
    return true
end

function Bios:video_get_cursor(cpu)
    local row, col = self.vga:get_cursor()
    cpu:set_reg8(6, row)                -- DH
    cpu:set_reg8(2, col)                -- DL
    cpu:set_reg8(5, floor(self.cursor_shape / 256) % 256) -- CH
    cpu:set_reg8(1, self.cursor_shape % 256)              -- CL
    cpu:set_reg8(7, 0)                  -- BH = active page 0
    return true
end

function Bios:video_set_page(cpu, page)
    if page ~= 0 then
        error(string.format("INT 10h AH=05: display page %d is not "
            .. "implemented (the text plane has a single page 0)", page), 0)
    end
    return true
end

function Bios:video_scroll(cpu, upwards)
    local lines = cpu:get_reg8(0) -- AL
    local attr = cpu:get_reg8(7)  -- BH
    local left = cpu:get_reg8(1)  -- CL
    local top = cpu:get_reg8(5)   -- CH
    local right = cpu:get_reg8(2) -- DL
    local bottom = cpu:get_reg8(6) -- DH

    local width = self.vga:get_width()
    local height = self.vga:get_height()
    if top > height - 1 then top = height - 1 end
    if bottom > height - 1 then bottom = height - 1 end
    if left > width - 1 then left = width - 1 end
    if right > width - 1 then right = width - 1 end
    if top > bottom or left > right then
        error(string.format("INT 10h AH=%s: invalid scroll window "
            .. "rows %d..%d columns %d..%d",
            upwards and "06" or "07", top, bottom, left, right), 0)
    end

    local window_rows = bottom - top + 1
    if lines == 0 or lines > window_rows then
        lines = window_rows
    end

    local mem = self.memory
    local vga = self.vga
    if upwards then
        for row = top, bottom - lines do
            for col = left, right do
                local source = vga:cell_offset(row + lines, col)
                local destination = vga:cell_offset(row, col)
                mem:write8(destination, mem:read8(source))
                mem:write8(destination + 1, mem:read8(source + 1))
            end
        end
        if lines > 0 then
            for row = bottom - lines + 1, bottom do
                for col = left, right do
                    vga:write_cell(row, col, " ", attr)
                end
            end
        end
    else
        for row = bottom, top + lines, -1 do
            for col = left, right do
                local source = vga:cell_offset(row - lines, col)
                local destination = vga:cell_offset(row, col)
                mem:write8(destination, mem:read8(source))
                mem:write8(destination + 1, mem:read8(source + 1))
            end
        end
        if lines > 0 then
            for row = top, top + lines - 1 do
                for col = left, right do
                    vga:write_cell(row, col, " ", attr)
                end
            end
        end
    end

    self:refresh()
    return true
end

function Bios:video_read_character(cpu)
    local row, col = self.vga:get_cursor()
    local offset = self.vga:cell_offset(row, col)
    cpu:set_reg8(0, self.memory:read8(offset))     -- AL = character code
    cpu:set_reg8(4, self.memory:read8(offset + 1)) -- AH = attribute
    return true
end

function Bios:video_write_character(cpu, with_attr)
    local code = cpu:get_reg8(0)  -- AL
    local count = cpu:get_reg16(1) -- CX
    local attr = nil
    if with_attr then
        attr = cpu:get_reg8(3)    -- BL
    end

    local width = self.vga:get_width()
    local height = self.vga:get_height()
    local row, col = self.vga:get_cursor()
    local position = row * width + col
    for _ = 1, count do
        local cell_row = floor(position / width)
        local cell_col = position % width
        local cell_attr = attr
        if cell_attr == nil then
            cell_attr = self.memory:read8(
                self.vga:cell_offset(cell_row, cell_col) + 1)
        end
        self.vga:write_cell(cell_row, cell_col, code, cell_attr)
        position = position + 1
        if position >= width * height then
            break
        end
    end
    self:refresh()
    return true
end

function Bios:video_get_mode(cpu)
    cpu:set_reg8(0, self.mode)                    -- AL
    cpu:set_reg8(4, self.vga:get_width() % 256)   -- AH = columns
    cpu:set_reg8(7, 0)                            -- BH = active page
    return true
end

function Bios:video_teletype(cpu)
    return self:teletype(cpu:get_reg8(0))
end

function Bios:teletype(ch)
    local code
    if type(ch) == "number" then
        check_byte("Bios.teletype", "character", ch)
        code = ch
    elseif type(ch) == "string" then
        if #ch ~= 1 then
            error(string.format("Bios.teletype: character string must be "
                .. "exactly one byte (got %d bytes)", #ch), 0)
        end
        code = string.byte(ch)
    else
        error(string.format("Bios.teletype: character must be a string or "
            .. "a byte (got %s)", type(ch)), 0)
    end

    local width = self.vga:get_width()
    local height = self.vga:get_height()
    local attr = self.vga.attr
    local row, col = self.vga:get_cursor()

    if code == 13 then       -- CR
        col = 0
    elseif code == 10 then   -- LF
        row = row + 1
        if row > height - 1 then
            self.vga:scroll_up(1, attr)
            row = height - 1
        end
    elseif code == 8 then    -- BS
        if col > 0 then
            col = col - 1
        end
    elseif code == 7 then    -- BEL: no audible output is modelled
        self:_log("INT10_BELL")
    else
        self.vga:write_cell(row, col, code, attr)
        col = col + 1
        if col >= width then
            col = 0
            row = row + 1
            if row > height - 1 then
                self.vga:scroll_up(1, attr)
                row = height - 1
            end
        end
    end

    self.vga:set_cursor(row, col)
    self:refresh()
    return true
end

---------------------------------------------------------------------------
-- INT 13h -- disk
---------------------------------------------------------------------------

function Bios:disk_fail(cpu, code, reason)
    self.last_error = reason
    cpu:set_flag("CF", true)
    cpu:set_reg8(4, code) -- AH
    cpu:set_reg8(0, 0)    -- AL = no sectors transferred
    self:_log("INT13_ERROR ah=0x%02X %s", code, reason)
    return false
end

function Bios:decode_chs(cpu)
    local cl = cpu:get_reg8(1)
    local ch = cpu:get_reg8(5)
    local head = cpu:get_reg8(6)
    local sector = cl % 64
    local cylinder = ch + floor(cl / 64) * 256

    if sector == 0 then
        return nil, nil, nil,
            "sector number 0 is invalid (sectors are 1-based)"
    end
    if sector > self.geometry.sectors then
        return nil, nil, nil, string.format(
            "sector %d out of range 1..%d", sector, self.geometry.sectors)
    end
    if head >= self.geometry.heads then
        return nil, nil, nil, string.format(
            "head %d out of range 0..%d", head, self.geometry.heads - 1)
    end
    if cylinder >= self.geometry.cylinders then
        return nil, nil, nil, string.format(
            "cylinder %d out of range 0..%d", cylinder,
            self.geometry.cylinders - 1)
    end

    return cylinder, head, sector
end

function Bios:int13(cpu)
    check_cpu(cpu, "INT 13h")
    local ah = cpu:get_reg8(4)
    if ah == 0x00 then
        return self:int13_reset(cpu)
    elseif ah == 0x02 then
        return self:int13_read(cpu)
    elseif ah == 0x03 then
        return self:int13_write(cpu)
    elseif ah == 0x08 then
        return self:int13_parameters(cpu)
    elseif ah == 0x0C then
        return self:int13_seek(cpu)
    end
    error(string.format("INT 13h: unsupported disk function AH=0x%02X", ah),
        0)
end

function Bios:int13_reset(cpu)
    self.last_error = nil
    cpu:set_flag("CF", false)
    cpu:set_reg8(4, 0x00)
    self:_log("INT13_RESET")
    return true
end

function Bios:int13_read(cpu)
    local count = cpu:get_reg8(0) -- AL
    if count == 0 then
        return self:disk_fail(cpu, 0x04, "sector count 0 is invalid")
    end
    if count > self.max_sectors_per_read then
        return self:disk_fail(cpu, 0x04, string.format(
            "sector count %d exceeds the %d-sector limit",
            count, self.max_sectors_per_read))
    end

    local cylinder, head, sector, chs_error = self:decode_chs(cpu)
    if cylinder == nil then
        return self:disk_fail(cpu, 0x04, chs_error)
    end

    local es = cpu:get_sreg("es")
    local bx = cpu:get_reg16(3)
    local destination = es * 16 + bx
    if destination % 65536 + count * 512 > 65536 then
        return self:disk_fail(cpu, 0x09, string.format(
            "DMA transfer crosses a 64 KiB boundary "
            .. "(ES:BX=%04X:%04X, sectors=%d)", es, bx, count))
    end

    if self.disk == nil then
        return self:disk_fail(cpu, 0x80, "no disk device is attached")
    end

    local lba = (cylinder * self.geometry.heads + head)
        * self.geometry.sectors + (sector - 1)
    local data, reason = self.disk:try_read_sectors(lba, count)
    if data == nil then
        return self:disk_fail(cpu, 0x04, string.format(
            "disk read failed at LBA %d: %s", lba, tostring(reason)))
    end
    if #data ~= count * 512 then
        return self:disk_fail(cpu, 0x04, string.format(
            "disk returned %d bytes, expected %d",
            #data, count * 512))
    end

    local ok, write_error = pcall(self.memory.write, self.memory,
        destination, data)
    if not ok then
        return self:disk_fail(cpu, 0x09, "DMA write failed: "
            .. tostring(write_error))
    end

    self.last_error = nil
    cpu:set_flag("CF", false)
    cpu:set_reg8(4, 0x00)
    cpu:set_reg8(0, count)
    self:_log("INT13_READ lba=%d count=%d dst=%05X", lba, count, destination)
    return true
end

function Bios:int13_write(cpu)
    local count = cpu:get_reg8(0)
    if count == 0 then
        return self:disk_fail(cpu, 0x04, "sector count 0 is invalid")
    end
    if count > self.max_sectors_per_read then
        return self:disk_fail(cpu, 0x04, string.format(
            "sector count %d exceeds the %d-sector limit",
            count, self.max_sectors_per_read))
    end
    local cylinder, head, sector, chs_error = self:decode_chs(cpu)
    if cylinder == nil then
        return self:disk_fail(cpu, 0x04, chs_error)
    end
    -- The shard image is read-only by design.  The request is well-formed at
    -- this point (count and CHS already validated), so report the real
    -- write-protection error (AH=0x03) instead of a fake success.
    return self:disk_fail(cpu, 0x03, string.format(
        "disk image is read-only: INT 13h AH=03 write of %d sector(s) at "
        .. "cyl=%d head=%d sector=%d is not implemented",
        count, cylinder, head, sector))
end

function Bios:int13_parameters(cpu)
    local max_cylinder = self.geometry.cylinders - 1
    local max_head = self.geometry.heads - 1
    cpu:set_flag("CF", false)
    cpu:set_reg8(4, 0x00)                                -- AH
    cpu:set_reg8(5, max_cylinder % 256)                  -- CH
    cpu:set_reg8(1, self.geometry.sectors
        + floor(max_cylinder / 256) % 4 * 64)            -- CL
    cpu:set_reg8(6, max_head % 256)                      -- DH
    cpu:set_reg8(2, 0)                                   -- DL
    cpu:set_reg8(3, 0)                                   -- BL
    self:_log("INT13_PARAMS cyl=%d heads=%d sectors=%d",
        self.geometry.cylinders, self.geometry.heads, self.geometry.sectors)
    return true
end

function Bios:int13_seek(cpu)
    local cylinder, head, sector, chs_error = self:decode_chs(cpu)
    if cylinder == nil then
        return self:disk_fail(cpu, 0x04, chs_error)
    end
    self.last_error = nil
    cpu:set_flag("CF", false)
    cpu:set_reg8(4, 0x00)
    self:_log("INT13_SEEK cyl=%d head=%d sector=%d", cylinder, head, sector)
    return true
end

-- INT 19h: bootstrap.  Reads sector 0 into 0x0000:0x7C00, verifies the boot
-- signature, sets DL to the boot drive and jumps to the boot sector.  This
-- handler deliberately never returns: the CPU suppresses the implicit IRET
-- because cpu:jump_far() is called from inside an interrupt handler.
function Bios:int19(cpu)
    check_cpu(cpu, "INT 19h")
    if self.disk == nil then
        error("INT 19h: no disk device is attached", 0)
    end

    local sector, reason = self.disk:try_read_sectors(0, 1)
    if sector == nil then
        error("INT 19h: cannot read the boot sector: "
            .. tostring(reason), 0)
    end
    if type(sector) ~= "string" or #sector ~= SECTOR_SIZE then
        error(string.format("INT 19h: boot sector read returned %s bytes, "
            .. "expected %d", type(sector) == "string" and tostring(#sector)
            or type(sector), SECTOR_SIZE), 0)
    end

    local signature = byte(sector, BOOT_SIGNATURE_OFFSET)
        + byte(sector, BOOT_SIGNATURE_OFFSET + 1) * 256
    if self.check_boot_signature and signature ~= BOOT_SIGNATURE then
        error(string.format("INT 19h: sector 0 is not bootable (signature "
            .. "0x%04X at offset 510, expected 0xAA55)", signature), 0)
    end

    self.memory:write(BOOT_ADDRESS, sector)
    self.boot_count = self.boot_count + 1
    self.last_error = nil
    cpu:set_reg8(2, self.boot_drive) -- DL = boot drive number
    self:_log("INT19_BOOT lba=0 dst=%05X signature=%04X drive=%d",
        BOOT_ADDRESS, signature, self.boot_drive)

    if type(cpu.jump_far) == "function" then
        cpu:jump_far(0, BOOT_ADDRESS)
    else
        -- Minimal CPU stubs used by unit tests may not implement jump_far.
        -- A direct CS:IP change is equivalent for a direct call, because
        -- there is no interrupt frame to skip in that case.
        cpu:set_sreg("cs", 0)
        cpu.ip = BOOT_ADDRESS
    end
    return true
end

---------------------------------------------------------------------------
-- INT 16h: keyboard
---------------------------------------------------------------------------

function Bios:push_key(scan, ascii)
    scan = scan or 0
    ascii = ascii or 0
    if not is_integer(scan) or scan < 0 or scan > 255 then
        error("Bios:push_key: scan must be an integer 0..255 (got "
            .. tostring(scan) .. ")", 0)
    end
    if not is_integer(ascii) or ascii < 0 or ascii > 255 then
        error("Bios:push_key: ascii must be an integer 0..255 (got "
            .. tostring(ascii) .. ")", 0)
    end
    local kb = self.keyboard
    if kb.count >= kb.max then
        -- Like a real BIOS buffer overflow: drop the oldest keystroke.
        kb.head = kb.head % kb.max + 1
        kb.count = kb.count - 1
        kb.dropped = kb.dropped + 1
    end
    kb.buffer[kb.tail] = {scan = scan, ascii = ascii}
    kb.tail = kb.tail % kb.max + 1
    kb.count = kb.count + 1
    return true
end

function Bios:push_char(ch)
    if type(ch) == "number" then
        ch = string.char(ch % 256)
    end
    if type(ch) ~= "string" or #ch < 1 then
        error("Bios:push_char: expected a character", 0)
    end
    local first = ch:sub(1, 1)
    return self:push_key(char_scan(first), byte(first))
end

function Bios:keyboard_count()
    return self.keyboard.count
end

function Bios:keyboard_dropped()
    return self.keyboard.dropped
end

function Bios:clear_keyboard()
    local kb = self.keyboard
    kb.buffer = {}
    kb.head = 1
    kb.tail = 1
    kb.count = 0
    return true
end

function Bios:_keyboard_peek()
    local kb = self.keyboard
    if kb.count == 0 then
        return nil
    end
    return kb.buffer[kb.head]
end

function Bios:_keyboard_pop()
    local kb = self.keyboard
    if kb.count == 0 then
        return nil
    end
    local entry = kb.buffer[kb.head]
    kb.buffer[kb.head] = nil
    kb.head = kb.head % kb.max + 1
    kb.count = kb.count - 1
    return entry
end

-- Optional opportunistic refill used by the non-blocking function (AH=01).
function Bios:_keyboard_refill()
    local kb = self.keyboard
    if kb.poll == nil or kb.count >= kb.max then
        return
    end
    local ok, result = pcall(kb.poll, self)
    if not ok then
        error(result, 0)
    end
    if type(result) == "table" then
        self:push_key(result.scan or 0, result.ascii or 0)
    end
end

function Bios:_keyboard_next()
    local entry = self:_keyboard_pop()
    if entry ~= nil then
        return entry
    end
    local pull = self.keyboard.pull or default_keyboard_pull
    local ok, result = pcall(pull, self)
    if not ok then
        error(result, 0)
    end
    if type(result) ~= "table" then
        error("INT 16h: keyboard source did not return a key", 0)
    end
    return {
        scan  = (result.scan or 0) % 256,
        ascii = (result.ascii or 0) % 256,
    }
end

function Bios:int16(cpu)
    check_cpu(cpu, "INT 16h")
    local ah = cpu:get_reg8(4)
    if ah == 0x00 or ah == 0x10 then
        local key = self:_keyboard_next()
        cpu:set_reg8(0, key.ascii)
        cpu:set_reg8(4, key.scan)
        self:_log("INT16_READ ascii=%02X scan=%02X", key.ascii, key.scan)
        return true
    elseif ah == 0x01 or ah == 0x11 then
        self:_keyboard_refill()
        local key = self:_keyboard_peek()
        if key == nil then
            cpu:set_flag("ZF", true)
        else
            cpu:set_flag("ZF", false)
            cpu:set_reg8(0, key.ascii)
            cpu:set_reg8(4, key.scan)
        end
        return true
    elseif ah == 0x02 then
        -- No shift state is tracked yet, so report "no shift pressed".
        cpu:set_reg8(0, 0)
        return true
    end
    error(string.format("INT 16h: unsupported keyboard function AH=0x%02X",
        ah), 0)
end

---------------------------------------------------------------------------
-- INT 11h: equipment check
---------------------------------------------------------------------------

function Bios:int11(cpu)
    check_cpu(cpu, "INT 11h")
    cpu:set_reg16(0, EQUIPMENT_WORD)
    self:_log("INT11_EQUIPMENT ax=%04X", EQUIPMENT_WORD)
    return true
end

---------------------------------------------------------------------------
-- INT 17h: printer services (no printer is emulated)
---------------------------------------------------------------------------

function Bios:int17(cpu)
    check_cpu(cpu, "INT 17h")
    local ah = cpu:get_reg8(4)
    if ah == 0x00 or ah == 0x01 or ah == 0x02 then
        -- Report a printer that is not there; never blocks or retries.
        cpu:set_reg8(4, PRINTER_STATUS)
        self:_log("INT17_PRINTER ah=0x%02X status=0x%02X", ah, PRINTER_STATUS)
        return true
    end    error(string.format("INT 17h: unsupported printer function AH=0x%02X",
        ah), 0)
end

---------------------------------------------------------------------------
-- INT 12h: conventional memory size
---------------------------------------------------------------------------

function Bios:int12(cpu)
    check_cpu(cpu, "INT 12h")
    cpu:set_reg16(0, self.conventional_kb)
    self:_log("INT12_MEMORY kb=%d", self.conventional_kb)
    return true
end

---------------------------------------------------------------------------
-- INT 15h: system services (extended memory size)
---------------------------------------------------------------------------

function Bios:int15(cpu)
    check_cpu(cpu, "INT 15h")
    local ah = cpu:get_reg8(4)
    if ah == 0x88 then
        -- AX carries the number of KiB of extended memory (the high byte of
        -- AX is part of the size, not a status code).
        cpu:set_reg16(0, self.extended_kb)
        cpu:set_flag("CF", false)
        self:_log("INT15_EXTMEMORY kb=%d", self.extended_kb)
        return true
    end
    error(string.format("INT 15h: unsupported system function AH=0x%02X",
        ah), 0)
end

---------------------------------------------------------------------------
-- INT 1Ah / INT 08h: tick counter and real-time clock
---------------------------------------------------------------------------

function Bios:_ticks()
    local now = self.clock()
    if type(now) ~= "number" then
        now = 0
    end
    local elapsed = now - self.tick_epoch
    if elapsed < 0 then
        elapsed = 0
    end
    return (self.tick_base + floor(elapsed * TICKS_PER_SECOND))
        % TICKS_PER_DAY
end

function Bios:_read_date()
    local ok, value = pcall(self.date_source, self)
    if not ok then
        error(value, 0)
    end
    if type(value) ~= "table" then
        error("INT 1Ah: no real time clock source is available", 0)
    end
    return value
end

function Bios:int08(cpu)
    check_cpu(cpu, "INT 08h")
    self.tick_base = (self:_ticks() + 1) % TICKS_PER_DAY
    self.tick_epoch = self.clock()
    self:_log("INT08_TICK ticks=%d", self.tick_base)
    return true
end

function Bios:int1a(cpu)
    check_cpu(cpu, "INT 1Ah")
    local ah = cpu:get_reg8(4)
    if ah == 0x00 then
        local ticks = self:_ticks()
        local low = ticks % 65536
        local high = floor(ticks / 65536) % 65536
        -- CX:DX is a 32-bit count: CX is the high word, DX the low word.
        cpu:set_reg8(1, high % 256)                -- CL high word, low byte
        cpu:set_reg8(5, floor(high / 256) % 256)   -- CH high word, high byte
        cpu:set_reg8(2, low % 256)                 -- DL low word, low byte
        cpu:set_reg8(6, floor(low / 256) % 256)    -- DH low word, high byte
        cpu:set_reg8(0, 0)                         -- AL midnight flag
        self:_log("INT1A_TICKS ticks=%d", ticks)
        return true
    elseif ah == 0x01 then
        local low = cpu:get_reg8(2) + cpu:get_reg8(6) * 256
        local high = cpu:get_reg8(1) + cpu:get_reg8(5) * 256
        self.tick_base = (high * 65536 + low) % TICKS_PER_DAY
        self.tick_epoch = self.clock()
        self:_log("INT1A_SET ticks=%d", self.tick_base)
        return true
    elseif ah == 0x02 then
        local date = self:_read_date()
        cpu:set_flag("CF", false) -- CF = 0: binary number format
        cpu:set_reg8(5, (date.hour or 0) % 256) -- CH hour
        cpu:set_reg8(1, (date.min or 0) % 256)  -- CL minute
        cpu:set_reg8(6, (date.sec or 0) % 256)  -- DH second
        cpu:set_reg8(2, 0)                      -- DL daylight saving
        self:_log("INT1A_TIME %02d:%02d:%02d", date.hour or 0,
            date.min or 0, date.sec or 0)
        return true
    elseif ah == 0x04 then
        local date = self:_read_date()
        local year = date.year or 0
        cpu:set_reg8(5, floor(year / 100) % 256) -- CH century
        cpu:set_reg8(1, year % 100)              -- CL year
        cpu:set_reg8(6, (date.month or 0) % 256) -- DH month
        cpu:set_reg8(2, (date.day or 0) % 256)   -- DL day
        self:_log("INT1A_DATE %04d-%02d-%02d", year, date.month or 0,
            date.day or 0)
        return true
    end
    error(string.format("INT 1Ah: unsupported clock function AH=0x%02X "
        .. "(setting the RTC is not emulated)", ah), 0)
end

-- The machine entry point invokes the bootstrap exactly like real firmware.
Bios.boot = Bios.int19

return Bios
