--[[- pyroet-os/system/installer.app/manifest.lua -- the Installer package.

Same .app format as every other package (DECISIONS.md 5.1). Installing means
running a file system transaction under /apps, so this package declares the two
capabilities that transaction needs, and exactly these two:

    fs.read    scan /disk/apps for packages on the medium and list the two
               installed roots (/apps and /system/system)
    fs.write   the install transaction creates /apps/<name>.app and unwinds its
               own temporary directory; a refusal is reported on screen, never
               retried behind the user's back

There is no net.*, redstone, peripheral or http entry on purpose: an installer
that cannot start a program, toggle a pin or open a socket has nothing to lose.
The installer itself is not reached through a capability -- see main.lua and
DECISIONS.md 17.2 for the bridge contract.

No non-ASCII bytes in this file.
]]

return {
    name = "installer",
    version = "0.1.0",
    entry = "main.lua",
    capabilities = { "fs.read", "fs.write" },
}
