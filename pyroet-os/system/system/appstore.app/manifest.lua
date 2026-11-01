--[[- pyroet-os/system/system/appstore.app/manifest.lua -- package downloader + system update entry.

Downloads a package from a server the user picks (plain http, plain text
protocol: index.txt / <dir>/files.txt / <dir>/<relpath> / optional SHA256.txt),
stages it in /pkgs/<name>.app and installs it through the kernel bridge.

The last list row is `System update`: it reads <base>/meta.txt (PYROET-OTA/2,
base = first line of /etc/ota.servers, else the built-in upgrade URL) and hands
the download+apply to the kernel through api.sys.ota_apply("image", ...), so the
three capabilities it needs already are http (the meta file) and fs.read /
fs.write (the bridge checks both). The app itself never writes /system.

    http      GET the server's text files, the upgrade meta.txt
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
    capabilities = { "http", "fs.read", "fs.write", "input", "terminal",
        "net.rednet" },
}
