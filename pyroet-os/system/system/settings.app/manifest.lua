--[[- pyroet-os/system/settings.app/manifest.lua -- the Settings package (read only).

Settings is a *read only* view of the machine: the manifest declares exactly one
capability, so the runtime hands it `api.fs.read` and nothing else. There is no
`fs.write` here on purpose -- a system app that cannot write cannot corrupt the
configuration it is describing, and a test asserts that the capability list stays
at one entry.

No non-ASCII bytes in this file.
]]

return {
    name = "settings",
    version = "0.1.0",
    entry = "main.lua",
    capabilities = { "fs.read" },
}
