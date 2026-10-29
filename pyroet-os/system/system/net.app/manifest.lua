--[[- pyroet-os/system/net.app/manifest.lua -- Net system app package.

Same .app format as every other app (DECISIONS.md 5.2). The system image
grants exactly the capabilities listed here; the app cannot ask for more at
runtime (kernel/apps.lua refuses anything not declared).

No non-ASCII bytes in this file.
]]

return {
    name = "net",
    version = "0.1.0",
    entry = "main.lua",
    capabilities = { "net.rpv", "fs.read" },
}
