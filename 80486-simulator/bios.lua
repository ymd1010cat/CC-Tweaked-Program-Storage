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
--   * INT 13h AH=03 fails with "write protected" (AH=0x03) because the disk
--     image is read-only; it never reports a successful write.
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
--   03 write sectors (always fails: the image is read-only, AH = 0x03)
--   08 read drive parameters (CH/CL/DH, DL = 0)
--   0C seek (CF = 0, AH = 0 for a valid CHS)
--
-- INT 19h bootstrap
--   Reads sector 0 (the boot sector) from the attached disk into memory at
--   0x0000:0x7C00, verifies the 0xAA55 signature, sets DL to the boot drive
--   and hands control to 0x0000:0x7C00 through cpu:jump_far().  Like real
--   firmware it never returns from this interrupt; the CPU therefore
--   suppresses the implicit IRET for this handler.
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
Bios.INT_DISK = 0x13
Bios.INT_BOOT = 0x19
Bios.BOOT_ADDRESS = BOOT_ADDRESS
Bios.BOOT_SIGNATURE = BOOT_SIGNATURE
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
    }, Bios)

    self.interrupts = {
        [Bios.INT_VIDEO] = function(cpu) return self:int10(cpu) end,
        [Bios.INT_DISK] = function(cpu) return self:int13(cpu) end,
        [Bios.INT_BOOT] = function(cpu) return self:int19(cpu) end,
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
    cpu.interrupts[Bios.INT_DISK] = self.interrupts[Bios.INT_DISK]
    cpu.interrupts[Bios.INT_BOOT] = self.interrupts[Bios.INT_BOOT]

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
    -- The shard image is read-only by design; report the real write
    -- protection error instead of a fake success.
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

-- The machine entry point invokes the bootstrap exactly like real firmware.
Bios.boot = Bios.int19

return Bios
