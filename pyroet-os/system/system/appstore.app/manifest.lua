--[[- pyroet-os/system/system/appstore.app/manifest.lua -- package downloader + system update entry.

Downloads a package from a server the user picks (RHTP/1.0, plain text
protocol: index.txt / <dir>/files.txt / <dir>/<relpath> / optional SHA256.txt),
stages it in /pkgs/<name>.app and installs it through the kernel bridge.

The last list row is `System update`: it reads <base>/meta.txt (PYROET-OTA/2,
base = first line of /etc/ota.servers, else the built-in rhtp upgrade URL) and
hands the download+apply to the kernel through api.sys.ota_apply("image", ...).
The app itself never writes /system.

    net.rhtp  RHTP GET of the server's text files and of the upgrade meta.txt
              (and the kernel bridge needs it too, because the image update
              downloads over the same client)
    fs.read   read /etc/appstore.servers and /etc/ota.servers
    fs.write  write the downloaded package into /pkgs; required by the image
              update bridge (the kernel does the writing)
    input     pull delivered events, read key names
    terminal  paint the screen
    net.rednet  receive a package pushed from another computer (pushpkg)

No non-ASCII bytes in this file.
]]

return {
    name = "appstore",
    version = "0.1.0",
    entry = "main.lua",
    capabilities = { "net.rhtp", "fs.read", "fs.write", "input", "terminal",
        "net.rednet" },
}
