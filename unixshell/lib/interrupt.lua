-- interrupt.lua - Ctrl+C stops the running command, the way it does on Linux
--
-- WHAT THE PROBLEM IS
-- On Linux Ctrl+C sends SIGINT to the foreground process group: the program
-- stops, the shell keeps running, and the prompt comes back with status 130. The
-- shell is never the thing that dies.
--
-- CraftOS is single threaded and cooperative, so there is no signal to deliver.
-- A running command owns the interpreter; the shell cannot poll for a key press
-- while it runs, because the shell is not executing. What IS possible is to
-- interpose on the one place a cooperative program gives control back: the event
-- loop. os.pullEvent() and os.pullEventRaw() are what a well behaved program
-- calls to wait, and while it waits the shell's wrapper gets to see the key.
--
-- So this module wraps those two functions. While a command is running, a Ctrl+C
-- key event raises the same error the ROM raises for Ctrl+T ("Terminated"), which
-- the shell already understands: is_interrupt_error() matches it, the trap of INT
-- runs, and the status becomes 130. The command unwinds to the prompt and the
-- session carries on -- exactly the Linux outcome, reached the only way this
-- platform allows.
--
-- WHAT THIS CANNOT DO, STATED PLAINLY
-- A tight CPU loop that never calls pullEvent cannot be interrupted. That is a
-- property of a cooperative scheduler, not a gap in this implementation: the
-- interpreter is inside the loop and nothing else can run. Linux can interrupt
-- such a loop because the kernel preempts it; CraftOS has no kernel. The
-- limitation is documented rather than papered over.
--
-- WHY THE EDITOR IS NOT AFFECTED
-- The wrapper only raises while a COMMAND is in the foreground. The shell's line
-- editor runs with the flag off, so Ctrl+C at the prompt keeps its existing
-- meaning (discard the half typed line) and is not turned into an interrupt.

local interrupt = {}

local KEY_C = 46          -- keys.c in the CraftOS ROM
local CTRL_LEFT = 29
local CTRL_RIGHT = 157

local installed = false
local in_command = false
local ctrl_down = false

-- WHICH COROUTINE OWNS THE FOREGROUND, not just whether one does.
--
-- The flag alone is not enough, and the difference is the whole machine. Measured
-- on a real machine: Ctrl+C pressed while `sleep 30` ran was received by the ROM's
-- PARALLEL DISPATCHER, not by the command -- bios.lua runs the shell inside
-- parallel.waitForAny, and while ush waits the dispatcher is the thing calling
-- os.pullEventRaw. Raising there unwound the DISPATCHER:
--
--   interrupt.lua watch -> pullEventRaw -> rom/apis/parallel.lua:76 -> bios.lua:905
--
-- so bios printed "Terminated", waited for a key and SHUT THE COMPUTER DOWN, while
-- the command never saw its interrupt.
--
-- So the wrapper fires only for a pull made by the coroutine that called
-- begin_command(). Every other puller -- the dispatcher, another window's shell --
-- gets the event as usual, and the command's own next pull is what raises. The
-- stack keeps nested shells right: a shell inside a desktop window owns its own
-- foreground, and the desktop's comes back when the inner command ends.
local window = nil

local function owner_coroutine()
    return coroutine.running()
end

local real_pull_event = nil
local real_pull_event_raw = nil

-- The error the ROM raises when Ctrl+T is pressed: "Terminated". The shell's
-- is_interrupt_error() already matches that string, so reusing it means the
-- existing INT trap and the 130 status work without a second code path.
local function raise_interrupt()
    error("Terminated", 0)
end

-- Should this event stop the running command?
--   * only while a command is in the foreground
--   * only for the coroutine that command is running in (see `window` above)
--   * a key_down of either Ctrl arm sets the modifier, a key_up clears it
--   * Ctrl+C while the modifier is down is the interrupt
-- The modifier is tracked here rather than read from the event, because CraftOS
-- reports a plain key code for "c" and does not carry the modifier with it.
local function watch(ev)
    if window == nil then return end
    -- In the main coroutine coroutine.running() is nil on both sides; nil == nil
    -- keeps the single-threaded behaviour the offline harness drives.
    if owner_coroutine() ~= window.co then return end
    local kind, a = ev[1], ev[2]
    if kind == "key" then
        if a == CTRL_LEFT or a == CTRL_RIGHT then
            ctrl_down = true
        elseif a == KEY_C and ctrl_down then
            ctrl_down = false
            raise_interrupt()
        end
    elseif kind == "key_up" then
        if a == CTRL_LEFT or a == CTRL_RIGHT then ctrl_down = false end
    end
end

-- Wrap one of the pull functions.
--
-- The filter is applied HERE rather than handed to the real function, and that is
-- the whole point: os.pullEvent("char") drops every key event before the caller
-- sees it, so a program waiting on characters would be uninterruptible if the
-- filter were passed through. Pulling unfiltered and filtering afterwards sees
-- each event, and is otherwise equivalent -- the ROM drops non matching events
-- either way, so nothing is delivered that the caller did not ask for.
--
-- The check runs after the event arrives, so the wait itself is still the real
-- blocking one: a wrapper that polled with a timeout would change the timing every
-- command sees, and break programs that rely on blocking.
local function make_wrapper(real)
    return function(filter)
        while true do
            local ev = { real(nil) }
            watch(ev)
            if not filter or ev[1] == filter then
                return unpack(ev)
            end
        end
    end
end

-- Install the wrappers. Idempotent, and safe when os.pullEvent is absent (a
-- stripped ROM): the module simply does nothing rather than failing to load.
function interrupt.install()
    if installed then return true end
    if type(os.pullEvent) ~= "function" or type(os.pullEventRaw) ~= "function" then
        return false
    end
    real_pull_event = os.pullEvent
    real_pull_event_raw = os.pullEventRaw
    os.pullEvent = make_wrapper(real_pull_event)
    os.pullEventRaw = make_wrapper(real_pull_event_raw)
    installed = true
    return true
end

-- Take the wrappers off again. Used by the tests, which must not leave a global
-- function replaced for the next suite.
function interrupt.uninstall()
    if not installed then return false end
    os.pullEvent = real_pull_event
    os.pullEventRaw = real_pull_event_raw
    installed = false
    in_command = false
    ctrl_down = false
    window = nil
    return true
end

-- Mark the foreground: a command is running, so Ctrl+C means "stop it", for THIS
-- coroutine only (see `window` above).
function interrupt.begin_command()
    window = { co = owner_coroutine(), parent = window }
    in_command = true
    ctrl_down = false
end

-- The command is over (it finished, or it was interrupted): Ctrl+C goes back to
-- meaning "discard this line" for the editor, and the enclosing command, if there
-- is one, owns the foreground again.
function interrupt.end_command()
    if window then window = window.parent end
    in_command = window ~= nil
    ctrl_down = false
end

function interrupt.in_command()
    return in_command
end

function interrupt.is_installed()
    return installed
end

return interrupt
