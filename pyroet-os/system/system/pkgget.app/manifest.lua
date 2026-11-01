--[[- pyroet-os/system/system/pkgget.app/manifest.lua -- the package downloader.

Downloads a package from a server the user picks (plain http, plain text
protocol: index.txt / <dir>/files.txt / <dir>/<relpath> / optional SHA256.txt),
stages it in /pkgs/<name>.app and installs it through the kernel bridge.

    http      GET the server's text files
    fs.read   read /etc/pkg.servers (the default server list)
    fs.write  write the downloaded package into /pkgs
    input     pull delivered events, read key names
    terminal  paint the screen
    net.rednet  receive a package pushed from another computer (pushpkg)

No non-ASCII bytes in this file.
]]

return {
    name = "pkgget",
    version = "0.1.0",
    entry = "main.lua",
    capabilities = { "http", "fs.read", "fs.write", "input", "terminal",
        "net.rednet" },
}
