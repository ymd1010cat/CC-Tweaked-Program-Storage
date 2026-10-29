--[[- pyroet-os/system/launcher.app/manifest.lua -- the desktop package.

Same .app format as every other app (DECISIONS.md 5.2). The system image grants
exactly these capabilities and the app can never ask for more at runtime:

    fs.read    list /apps and /system, read /boot.slot, the boot marker and
               /etc/network.conf
    fs.write   append one line to /etc/launcher.recent after a successful start;
               purely cosmetic, a refusal is ignored

No non-ASCII bytes in this file.
]]

return {
    name = "launcher",
    version = "0.1.0",
    entry = "main.lua",
    capabilities = { "fs.read", "fs.write" },
}
