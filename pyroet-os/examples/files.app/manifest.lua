--[[- pyroet-os/examples/files.app/manifest.lua -- the optional file manager.

An *example* package (not in the image): copy examples/files.app to
/pkgs/files.app and install it. It browses the file system read-only on
purpose -- no write, no delete -- so a mis-key cannot lose a file.

    fs.read   list directories and read a text file (viewer)
    input     pull delivered events, read key names
    terminal  paint the screen

No non-ASCII bytes in this file.
]]

return {
    name = "files",
    version = "0.1.0",
    entry = "main.lua",
    capabilities = { "fs.read", "input", "terminal" },
}
