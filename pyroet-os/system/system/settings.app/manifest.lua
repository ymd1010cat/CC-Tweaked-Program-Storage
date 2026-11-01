--[[- pyroet-os/system/system/settings.app/manifest.lua -- the Settings package.

Settings is the machine's **writable** settings screen since D1-fix round 3: it
edits the one config file pyroet-os already treats as user settings,
`/etc/network.conf` (the net service reads it at boot). The capabilities are
exactly what that needs:

    fs.read    read /etc/network.conf, /boot.ok (image version), /etc/install.set
               and the app index through api.sys
    fs.write   rewrite exactly one `key=value` line of /etc/network.conf when a
               setting is changed; every other byte of the file is preserved, and
               a refused write is shown on screen ("save failed: ..."), never
               retried behind the user's back
    input      pull delivered events from the machine's input queue
               (api.input.pullEvent) and read the key names (api.input.keys)
    terminal   paint the screen (api.terminal)

It still cannot touch the network, redstone, peripherals or http: editing a
config line is the whole job.

No non-ASCII bytes in this file.
]]

return {
    name = "settings",
    version = "0.2.0",
    entry = "main.lua",
    capabilities = { "fs.read", "fs.write", "input", "terminal" },
}
