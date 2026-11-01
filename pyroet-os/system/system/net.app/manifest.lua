--[[- pyroet-os/system/net.app/manifest.lua -- Net system app package.

Same .app format as every other app (DECISIONS.md 5.2). The system image
grants exactly the capabilities listed here; the app cannot ask for more at
runtime (kernel/apps.lua refuses anything not declared).

`input` and `terminal` (D1-fix round 3) make it a real, usable screen instead of
a rented still frame: up/down scroll the host table, `enter` or `r` re-reads the
service status / hosts / probe target, `q` (or escape) returns to the desktop.
Without `net.rpv` it says so -- it never pretends the network is up.

No non-ASCII bytes in this file.
]]

return {
    name = "net",
    version = "0.2.0",
    entry = "main.lua",
    capabilities = { "net.rpv", "fs.read", "input", "terminal" },
}
