-- gnome.apps - the application registry of the desktop.
--
-- WHY EVERY LOAD IS GUARDED AND THE MODULE NAMES LIVE IN ONE TABLE
-- The desktop is an installed package: its files arrive over the network, so
-- "this app's module is not there" is a state that really happens -- a half
-- finished install, a file the operator deleted, an app a later version adds.
-- require() of a missing module raises, and a raise while the desktop is being
-- built would take the whole desktop down, which is the one thing an event loop
-- must never do. So each module is loaded here, once, and the failure becomes an
-- entry the overview can draw and the status can report.
local apps = {}

apps.SPECS = {
    { id = "terminal", name = "Terminal", icon = ">_", module = "gnome.apps.terminal" },
    { id = "files", name = "Files", icon = "[=]", module = "gnome.apps.files" },
    { id = "settings", name = "Settings", icon = "(*)", module = "gnome.apps.settings" },
    { id = "calc", name = "Calculator", icon = "123", module = "gnome.apps.calc" },
    -- The task manager is the window onto the scheduler. It is deliberately not
    -- a dock favourite: the dock is the operator's own list, and adding a fifth
    -- entry to it would move every other one.
    { id = "taskman", name = "Tasks", icon = "[T]", module = "gnome.apps.taskman" },
    -- The console is the SAME windowed shell as the Terminal (1.6.0): both are
    -- thin wrappers over gnome.apps.shellwin, one mechanism behind two names. It
    -- is kept as the sixth card because 1.5.0 shipped that name and the machine
    -- acceptance drives it; the reasons are in console.lua's header and ROADMAP 6.9.
    { id = "console", name = "Console", icon = "#_", module = "gnome.apps.console" },
    -- The text editor: a window with a buffer, and the target of Files' Enter
    -- through one documented seam -- `api.open("editor", { path = ... })` (see the
    -- headers of editor.lua and files.lua). It is not a dock favourite: the dock
    -- is the operator's list and a fifth icon would move every other one.
    { id = "editor", name = "Text Editor", icon = "TXT", module = "gnome.apps.editor" },
}

-- The hooks that make a spec an application in its own right, with no file and no
-- module name behind it. They are the whole callback surface the desktop calls:
-- open is setup, draw is the picture, event is the input, and main/task is the
-- scheduled body. A spec carrying any one of them IS the app -- without this list
-- a spec that only defined main (or only open) was classified as "no module" and
-- opened a window saying the app was not available.
apps.HOOKS = { "open", "draw", "event", "main", "task" }

function apps.is_app_spec(spec)
    if type(spec) ~= "table" then return false end
    if type(spec.app) == "table" then return true end
    for _, key in ipairs(apps.HOOKS) do
        if type(spec[key]) == "function" then return true end
    end
    return false
end

-- Build the registry. A spec may carry `app` (a table), or be the app itself
-- (any hook directly on the spec), or name a `module` to require -- which is how a
-- host such as a test or the machine acceptance registers an application of its
-- own without shipping a file for it.
function apps.load(specs)
    specs = specs or apps.SPECS
    local out = {}
    for _, spec in ipairs(specs or {}) do
        local entry = {
            id = tostring(spec.id or ("app" .. tostring(#out + 1))),
            name = tostring(spec.name or spec.id or "app"),
            icon = tostring(spec.icon or "???"),
            module = spec.module,
            spec = spec,
        }
        if type(spec.app) == "table" then
            entry.app = spec.app
        elseif apps.is_app_spec(spec) then
            entry.app = spec
        elseif spec.module then
            local ok, mod = pcall(require, spec.module)
            if ok and type(mod) == "table" then
                entry.app = mod
            else
                entry.error = tostring(mod)
                entry.app = { unavailable = true }
            end
        else
            entry.error = "the spec names no module"
            entry.app = { unavailable = true }
        end
        out[#out + 1] = entry
    end
    return out
end

function apps.by_id(entries, id)
    for _, entry in ipairs(entries or {}) do
        if entry.id == id then return entry end
    end
    return nil
end

return apps
