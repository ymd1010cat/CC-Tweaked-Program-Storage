--[[- pyroet-os/system/system/web.app/manifest.lua -- the built-in browser.

A text HTTP browser: `api.http.get(url)` -> body, wrapped to the screen, with
scroll / history / reload. The capabilities are exactly what that needs:

    fs.read    read /etc/browser.home (the start page); there is no write path
    http       fetch a URL through the host's http table
    input      pull delivered events (api.input.pullEvent) and read key names
    terminal   paint the screen (api.terminal)

Without `http` the app shows `browser unavailable: no http host` and still
quits with `q`.

No non-ASCII bytes in this file.
]]

return {
    name = "web",
    version = "0.1.0",
    entry = "main.lua",
    capabilities = { "fs.read", "http", "input", "terminal" },
}
