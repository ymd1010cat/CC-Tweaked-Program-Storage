--[[- pyroet-os/system/installer.app/manifest.lua -- the Installer package.

Same .app format as every other package (DECISIONS.md 5.1). Installing means
running a file system transaction under /apps, so this package declares the two
capabilities that transaction needs, and exactly these two:

    fs.read    scan /pkgs for packages on this computer's own disk and list the
               two installed roots (/apps and /system/system)
    fs.write   the install transaction creates /apps/<name>.app and unwinds its
               own temporary directory; a refusal is reported on screen, never
               retried behind the user's back

There is no net.*, redstone, peripheral or http entry on purpose: an installer
that cannot start a program, toggle a pin or open a socket has nothing to lose.
The installer itself is not reached through a capability -- see main.lua and
DECISIONS.md 17.2 for the bridge contract.

`input` and `terminal` (D1-fix round 3) make the UI actually operable: up/down
moves the list, a digit jumps to a row, `enter` installs / removes / reports a
locked system package through the host bridge (api.sys.install / uninstall, no
new bridge), `c` cancels a confirmation, `q` (or escape) returns to the desktop.
When there is no local source or no bridge the screen says `installer
unavailable` / `no source: checked /pkgs` with the reason -- it never fakes an
install.

No non-ASCII bytes in this file.
]]

return {
    name = "installer",
    version = "0.2.0",
    entry = "main.lua",
    capabilities = { "fs.read", "fs.write", "input", "terminal" },
}
