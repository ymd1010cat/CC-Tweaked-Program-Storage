--[[- pyroet-os/tests/t_files.lua -- the optional file manager (examples/files.app).

Read-only browsing: the list hides dot files by default (`h` shows them), enter
opens a directory or views a text file (first lines, scrollable), b/backspace
goes up and q quits. The package is staged under /tests (it is an example, not
image payload), so the test loads it from there.

No non-ASCII bytes in this file.
]]

_G.PYROET_FILES_TEST = true
local FILES = assert(loadfile("/tests/files.app/main.lua"))()
_G.PYROET_FILES_TEST = nil

local KEYS = { up = 10, down = 11, enter = 14, q = 16, b = 18, r = 19,
    h = 20, backspace = 21 }

return function(H)
    local F = H.real_fs()

    local function api_with(fs_override, log)
        local lines = nil
        local sink = log
        if sink == nil then
            sink, lines = H.logger()
        end
        return {
            fs = fs_override or {
                list = function(path)
                    if not F.exists(path) then return nil, "not found" end
                    if not F.isDir(path) then return nil, "not a directory" end
                    return F.list(path)
                end,
                isDir = function(path) return F.isDir(path) end,
                getSize = function(path) return F.getSize(path) end,
                read = function(path)
                    if not F.exists(path) then return nil, "not found" end
                    return H.read(path)
                end,
            },
            input = { keys = KEYS, pullEvent = function() return nil end },
            yield = function() end,
            log = sink,
        }, lines
    end

    -- -----------------------------------------------------------------
    H.group("files.manifest")
    do
        local raw = assert(loadfile("/tests/files.app/manifest.lua"))()
        local caps = {}
        for i = 1, #(raw.capabilities or {}) do caps[raw.capabilities[i]] = true end
        H.eq("files_name", raw.name, "files")
        H.eq("files_version", raw.version, "0.1.0")
        H.eq("files_cap_read", caps["fs.read"], true)
        H.eq("files_cap_input", caps.input, true)
        H.eq("files_cap_terminal", caps.terminal, true)
        H.eq("files_no_write", caps["fs.write"], nil)
    end

    -- -----------------------------------------------------------------
    H.group("files.list")
    do
        H.mkdirp("/tfs/sub")
        H.write("/tfs/note.txt", "hello\n")
        H.write("/tfs/.hidden.txt", "secret\n")
        local api, lines = api_with(nil)
        local state = FILES.new_state(api, { cwd = "/tfs" })
        H.eq("list_count", #state.entries, 2)
        H.eq("list_first_dir", state.entries[1].name, "sub")
        H.eq("list_first_is_dir", state.entries[1].dir, true)
        H.eq("list_hidden_off", FILES.hidden(".hidden.txt"), true)
        local frame = FILES.render(state, 51, 19)
        H.contains("list_row1", frame[1] or "", "Files 0.1.0")
        H.contains("list_path", frame[2] or "", "/tfs")
        H.contains("list_sub", frame[3] or "", "> /sub/")
        H.contains("list_note", table.concat(frame, "\n"), "note.txt")

        -- h shows the dot files
        H.eq("list_h_key", FILES.dispatch_event(state, "key", "h", api), "repaint")
        H.eq("list_hidden_on", state.show_hidden, true)
        H.eq("list_hidden_count", #state.entries, 3)
        H.eq("list_h_off", FILES.dispatch_event(state, "key", "h", api), "repaint")
        H.eq("list_hidden_off_count", #state.entries, 2)
    end

    -- -----------------------------------------------------------------
    H.group("files.view")
    do
        H.rmrf("/tfs")
        H.mkdirp("/tfs")
        H.write("/tfs/page.txt", "line one\nline two\nline three\n")
        local api, lines = api_with(nil)
        local state = FILES.new_state(api, { cwd = "/tfs" })
        local entry = FILES.selected(state)
        H.eq("view_selected", entry and entry.name, "page.txt")
        H.eq("view_enter", FILES.dispatch_event(state, "key", "enter", api), "open")
        H.check("view_open", type(state.view) == "table", "no viewer")
        H.eq("view_path", state.view.path, "/tfs/page.txt")
        H.eq("view_lines", #state.view.lines, 3)
        H.contains("view_line1", state.view.lines[1], "line one")
        H.has(lines, "FILES_VIEW path=/tfs/page.txt lines=3")
        local frame = FILES.render(state, 51, 19)
        H.contains("view_row1", frame[1] or "", "Files 0.1.0")
        H.contains("view_header", frame[2] or "", "view /tfs/page.txt")
        H.contains("view_body", frame[3] or "", "line one")
        H.contains("view_hint", frame[19] or "", "up/dn scroll b back q quit")

        -- b/backspace closes the viewer, then goes up a directory
        H.eq("view_close", FILES.dispatch_event(state, "key", "b", api), "open")
        H.eq("view_closed", state.view, nil)
        H.eq("view_cwd", state.cwd, "/tfs")
        H.eq("view_up", FILES.dispatch_event(state, "key", "backspace", api), "open")
        H.eq("view_up_cwd", state.cwd, "/")
        H.has(lines, "FILES_OPEN path=/")
    end

    -- -----------------------------------------------------------------
    H.group("files.errors")
    do
        -- a denied / missing directory is a status line, not a crash
        local api, lines = api_with(nil)
        local state = FILES.new_state(api, { cwd = "/tfs-nope" })
        H.eq("err_entries", #state.entries, 0)
        H.contains("err_status", state.message, "denied:")
        H.has(lines, "FILES_DENIED path=/tfs-nope")

        -- no fs at all
        local api2, lines2 = api_with(nil)
        local state2 = FILES.new_state(api2, { cwd = "/tfs" })
        state2.view = nil
        local bad = FILES.view_file(state2, { input = { keys = KEYS } }, "/tfs/page.txt")
        H.eq("err_view", bad, "error")

        -- a missing file in the viewer
        H.eq("err_view2", FILES.view_file(state, api, "/tfs/missing.txt"), "error")
        H.contains("err_view_status", state.message, "denied:")
        H.has(lines, "FILES_DENIED path=/tfs/missing.txt")

        -- /system/kernel is refused by the runtime, not by this app: an fs that
        -- denies it must still produce a readable line
        local deny_api = api_with({
            list = function() return nil, "capability denied: fs.read" end,
        })
        local state3 = FILES.new_state(deny_api, { cwd = "/system/kernel" })
        H.contains("err_denied_status", state3.message, "denied:")

        -- a large file is truncated with a status line
        H.write("/tfs/big.txt", string.rep("x", 70000))
        local state4 = FILES.new_state(api, { cwd = "/tfs" })
        FILES.view_file(state4, api, "/tfs/big.txt")
        H.contains("err_truncated", state4.message, "truncated")
        H.eq("err_truncated_lines", #state4.view.lines, 1)

        H.rmrf("/tfs")
    end

    -- -----------------------------------------------------------------
    H.group("files.keys")
    do
        local api, lines = api_with(nil)
        local state = FILES.new_state(api, { cwd = "/tfs2" })
        H.eq("keys_quit", FILES.dispatch_event(state, "key", "q", api), "quit")
        H.eq("keys_quit_char", FILES.dispatch_event(state, "char", "q", api), "quit")
        H.eq("keys_reload", FILES.dispatch_event(state, "key", "r", api), "repaint")
        H.eq("keys_void_up", FILES.dispatch_event(state, "key", "b", api), "open")
        H.eq("keys_void_cwd", state.cwd, "/")
        H.eq("keys_root_up", FILES.dispatch_event(state, "key", "b", api), "none")
        H.eq("keys_root_message", state.message, "root")
        H.eq("files_hint", FILES.HINT, "up/dn enter b up r refresh h hidden q quit")
    end
end
