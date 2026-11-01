--[[- pyroet-os/system/system/launcher.app/manifest.lua -- the desktop package.

Same .app format as every other app (DECISIONS.md 5.2). The system image grants
exactly these capabilities and the app can never ask for more at runtime:

    fs.read    list /apps and /system, read the global boot marker and
               /etc/network.conf
    fs.write   append one line to /etc/launcher.recent after a successful start;
               purely cosmetic, a refusal is ignored
    input      pull delivered events from the machine's input queue
               (api.input.pullEvent) and read the key names (api.input.keys).
               The kernel's desktop loop owns the blocking pull, so this is a
               queue pop that answers nil when nothing was delivered
    terminal   paint the desktop (api.terminal), screen side only

The two UI capabilities are separate on purpose (DECISIONS.md 19): the desktop
needs both, and a package that only wants one asks for one.

No non-ASCII bytes in this file.
]]

return {
    name = "launcher",
    version = "0.2.0",
    entry = "main.lua",
    capabilities = { "fs.read", "fs.write", "input", "terminal" },
}
