-- pkg.lua - apt-like package manager over rednet
--
-- Packages travel over the same channel as everything else: the protocol name
-- and the shared key come from /etc/pkg.conf through lib/netcfg.lua, and a
-- payload is encrypted with lib/crypto.lua, exactly like a file transfer or a
-- remote command. A fetched package is checked twice before anything is
-- written: the canonical digest of its file set against the signature the
-- repository publishes, and each file against the checksum it published.
local pkg = {}

local netcfg   = require("netcfg")
local rpvnet  = require("rpvnet")
local checksum = require("checksum")
local semver   = require("semver")
-- Room for the file set. The download arrives as one answer in memory, so the
-- unpack is the moment it lands on the disk and the moment to refuse it: a
-- package that does not fit must not be written file by file until the volume
-- fills, which leaves a package that is present, listed and broken.
local space    = require("space")

-- ============================================================
-- update server availability
-- ============================================================

-- The configuration file the repository settings come from, for messages that
-- have to name one. netcfg picks the winner between /etc/pkg.conf and
-- /etc/network.conf; this asks it rather than guessing.
local function config_path()
    return netcfg.server_file()
end

-- Is there an update server to talk to right now? Returns true, or nil plus a
-- reason plus a kind ("offline", "unconfigured" or "nokey").
--
-- A computer that was never given an update server is a normal state, not an
-- error. Everything here is local, so asking costs no waiting: the caller
-- reports the reason and pkg.setup_hint() and carries on, instead of raising
-- or blocking on a reply that cannot come.
function pkg.server_ready()
    local st = netcfg.server_config()
    if st.offline then return nil, st.reason, "offline" end
    if not st.configured then return nil, st.reason, "unconfigured" end
    local key, kerr = netcfg.key()
    if not key then return nil, kerr, "nokey" end
    return true
end

-- What to do about it: one line naming
-- the file, the keys and the command to run, after a failed request.
function pkg.setup_hint()
    if netcfg.offline() then
        local file = netcfg.source("offline") or config_path()
        return "to use an update server, set offline=false and server_id" ..
               "=<pc id> in " .. file .. ", then run 'pkg update'"
    end
    if netcfg.server_config().configured then
        return "an update server is configured: check it with 'pkg update'"
    end
    return "set server_id=<pc id> in " .. config_path() ..
           " (or offline=true to run without an update server), then run " ..
           "'pkg update'"
end

-- Request ids. Every request carries one and the repository echoes it back, so a
-- reply can be matched to the request that asked for it. Without that, the answer
-- to "list" was whatever message came next on the channel: a fetch reply left
-- over from an install (the client had already timed out and the answer arrived
-- late) was saved as the index, so the repository looked EMPTY. Measured on a
-- real machine as 'server index shape=a leftover fetch reply (ok=true)'.
local request_seq = 0

local function next_request_id()
    request_seq = request_seq + 1
    return tostring(os.getComputerID()) .. "-" .. tostring(request_seq)
end

-- The shape of the two answers the repository serves. A "list" answer is an array
-- of entries; a "fetch" answer is a table carrying ok. Neither can be read as the
-- other, which is what lets the answer of a repository that predates ids (and so
-- does not echo one) still be told apart from the other action's answer.
local function answer_shape(value)
    if type(value) ~= "table" then return nil end
    if value.ok ~= nil then return "fetch" end
    -- A message of one of this project's own protocols carries action or t. An
    -- index never does, and a block or a request read as an index is the very
    -- defect this change is about -- so those are not any answer's shape.
    if value.action ~= nil or value.t ~= nil then return nil end
    for i = 1, #value do
        local entry = value[i]
        if type(entry) ~= "table" or entry.name == nil then return nil end
    end
    return "list"
end

-- Is this reply the answer to the request with this id?
--
-- The id is authoritative when the reply carries one. A repository that predates
-- ids does not, and the shape of the answer is the fallback there. A message that
-- matches neither belongs to somebody else on the channel (a request from another
-- computer, a file block) and is not this request's answer.
local function answers(action, reply, id)
    if type(reply) ~= "table" then return false end
    if reply.id ~= nil then return tostring(reply.id) == tostring(id) end
    return answer_shape(reply) == action
end

local function request(action, extra)
    -- No server configured (or offline mode): answer at once, with a reason.
    local ready, why = pkg.server_ready()
    if not ready then return nil, why end

    local msg = { action = action }
    for k, v in pairs(extra or {}) do msg[k] = v end
    local id = next_request_id()
    msg.id = id

    local server = netcfg.server_id()
    local cipher, perr = netcfg.pack(msg)
    if not cipher then return nil, perr end
    rpvnet.send(server, cipher, netcfg.channel())

    -- One deadline for the whole wait: skipping a message that is not the answer
    -- must not restart the budget, or a channel that keeps producing strays would
    -- keep this call alive. os.epoch is the clock lib/xfer.lua waits on, and it is
    -- virtual in the test harness.
    local deadline = os.epoch("utc") + (netcfg.timeout() or 0) * 1000
    while true do
        local remain = (deadline - os.epoch("utc")) / 1000
        if remain <= 0 then return nil, "timeout" end
        local _, reply = rpvnet.receive(netcfg.channel(), remain)
        if not reply then return nil, "timeout" end
        local decoded, derr = netcfg.unpack(reply)
        if not decoded then return nil, derr end
        if answers(action, decoded, id) then
            -- The id is bookkeeping, not part of the answer: pkg.update() writes
            -- what comes back here into the index cache.
            decoded.id = nil
            return decoded
        end
        -- Not this request's answer. Ignore it and keep waiting for the one that
        -- is, instead of reading it as the answer to this request.
    end
end

function pkg.update()
    local idx, err = request("list")
    if not idx then return false, err end
    -- A "list" answer is an array of entries. Saving anything else would write an
    -- index that lists nothing -- which is exactly what a stray reply used to
    -- cause -- so a wrong shape is refused by name instead of cached.
    if type(idx) ~= "table" or idx.ok ~= nil then
        return false,
               "the repository answered 'list' with something that is not a package index"
    end
    if not fs.exists("/var/cache/pkg") then fs.makeDir("/var/cache/pkg") end
    local f = fs.open("/var/cache/pkg/index", "w")
    f.write(textutils.serialize(idx))
    f.close()
    return true, #idx .. " packages"
end

function pkg.search(name)
    if not fs.exists("/var/cache/pkg/index") then
        local ok, err = pkg.update()
        if not ok then return false, err end
    end
    local f = fs.open("/var/cache/pkg/index", "r")
    local idx = textutils.unserialize(f.readAll())
    f.close()
    local found = {}
    for _, entry in ipairs(idx) do
        if entry.name:find(name, 1, true) then
            table.insert(found, entry)
        end
    end
    return true, found
end

-- ============================================================
-- repository index
-- ============================================================

local INDEX_PATH = "/var/cache/pkg/index"

-- The cached answer to "list", in the shape the repository serves it:
-- { { name = "foo", version = "1.2.0" }, ... }. It is only a cache, so this
-- reads it and never refreshes it; pkg.update() is the command that does.
function pkg.index()
    if not fs.exists(INDEX_PATH) then
        return nil, "no package index: run 'pkg update' first"
    end
    local f = fs.open(INDEX_PATH, "r")
    if not f then return nil, INDEX_PATH .. ": cannot be read" end
    local text = f.readAll()
    f.close()
    local idx = textutils.unserialize(text)
    if type(idx) ~= "table" then return nil, INDEX_PATH .. ": not a package index" end
    return idx
end

-- The index entry for one package. A repository that keeps several versions of
-- a package publishes them all, so the highest one wins; the comparison comes
-- from lib/semver.lua, which is what makes 1.10 newer than 1.9 while a plain
-- string comparison would call it older. Returns the entry, or nil plus a
-- reason.
function pkg.latest(name)
    local idx, err = pkg.index()
    if not idx then return nil, err end
    local best = nil
    for _, entry in ipairs(idx) do
        if type(entry) == "table" and entry.name == name then
            if not best or semver.is_newer(entry.version, best.version) then
                best = entry
            end
        end
    end
    if not best then return nil, tostring(name) .. ": not in the repository index" end
    return best
end

-- Version of an installed package, taken from its manifest. Unparsable or
-- missing means "0", which every well formed version is newer than, so the
-- next install refreshes it.
function pkg.installed_version(name)
    local mf = pkg.read_manifest(name)
    if mf and type(mf.version) == "string" and mf.version ~= "" then
        return mf.version
    end
    return "0"
end

-- Installed packages the repository carries a newer version of: a list of
-- { name, from, to }. Returns nil plus a reason when the index cannot be read.
function pkg.upgradable()
    local idx, err = pkg.index()
    if not idx then return nil, err end
    local out = {}
    for _, name in ipairs(pkg.list()) do
        local entry = pkg.latest(name)
        if entry then
            local current = pkg.installed_version(name)
            if semver.is_newer(entry.version, current) then
                table.insert(out, { name = name, from = current, to = entry.version })
            end
        end
    end
    return out
end

-- ============================================================
-- manifests
-- ============================================================

-- Parse a manifest: "key=value" lines, "bin" and "depends" hold comma
-- separated lists.
local function parse_manifest(text)
    local mf = { bin = {}, depends = {} }
    for line in (text or ""):gmatch("[^\r\n]+") do
        local k, v = line:match("^%s*([%w_]+)%s*=%s*(.*)$")
        if k == "bin" or k == "depends" then
            for item in v:gmatch("[^,]+") do
                item = (item:gsub("^%s+", ""):gsub("%s+$", ""))
                if item ~= "" then table.insert(mf[k], item) end
            end
        elseif k then
            mf[k] = v
        end
    end
    return mf
end

-- ============================================================
-- where packages are installed
-- ============================================================
--
-- Packages normally live in /usr/pkgs, on the computer's own filesystem. A
-- machine may instead keep them on removable media, and on MORE THAN ONE: the
-- first store that is present is where a new package is written, and every store
-- is searched when a package is read. A store keeps <medium>/usr/pkgs, exactly
-- the "root/name" layout the internal directory uses, so every store is a
-- package source.
--
-- WHAT MAKES A MEDIUM A STORE IS THE MARKER ON THE MEDIUM ITSELF
-- --------------------------------------------------------------
-- A medium is a package store when its root carries a marker file. The marker is
-- written by "pkg store <n>" and removed by "pkg store remove <n>"; the machine
-- records no drive letter anywhere. That is deliberate: a drive letter is a
-- property of the drive bay, not of the data, so a medium that is moved to
-- another bay (or inserted after a reboot) is still recognised by its own
-- contents instead of being confused with whatever disk number it used to be.
-- When a store has to be written to and it is not inserted, there is no marker
-- to find and the install is refused rather than landing on another medium.
--
-- TWO MARKERS, BECAUSE THERE ARE TWO KINDS OF STORE
-- ------------------------------------------------
-- A machine built in two parts -- the shell on its own disk, its own modules on a
-- medium -- needs to tell those modules apart from ordinary extra packages. The
-- difference is not decoration: one is part of the installation and the other is
-- not, so "the medium is not inserted" has to mean two different things.
--
--   .pkgsys     the SYSTEM MODULE store: carries modules the shell itself needs
--               (the manual pages, the file transfer, the services, ...). Losing
--               it costs functionality, so a machine can require it and be told
--               when it is missing.
--   .pkgstore   an ordinary REMOVABLE PACKAGE store: extra packages that are nice
--               to have. Losing it costs nothing but those packages.
--
-- Both are searched when a package is read, and a system store is searched before
-- an ordinary one, so a module the shell needs is found even when both are
-- inserted. Only a medium carrying one of these two markers is a store: a disk
-- full of packages with no marker is not searched at all.
--
-- /etc/pkgstore.conf keeps only the rules that cannot live on a medium:
--   store_required=1    refuse to install on the internal filesystem at all
--   sys_required=1      this machine needs its system module store inserted
--
-- All names are declared HERE, before the functions that read them: a local
-- declared below its user is still nil for that user, which is how an earlier
-- revision of this file read a nil path and reported "auto" forever.
local STORE_CONF = "/etc/pkgstore.conf"
local INTERNAL_ROOT = "/usr/pkgs"

-- The marker a medium carries when it is the system module store.
local PKG_SYS_MARKER = ".pkgsys"

-- The marker a medium carries when it is an ordinary package store.
local PKG_STORE_MARKER = ".pkgstore"

-- Forward declarations. The store helpers below are read by functions that come
-- before the mount table helpers, and a local that is not in scope yet is nil
-- (not a compile error), so the names have to exist first.
local mounted_media, mounted_of

local function store_config()
    local out = { required = false, sys_required = false }
    if fs.exists(STORE_CONF) then
        local f = fs.open(STORE_CONF, "r")
        if f then
            while true do
                local line = f.readLine()
                if line == nil then break end
                line = line:gsub("^%s+", ""):gsub("%s+$", "")
                if line ~= "" and line:sub(1, 1) ~= "#" then
                    local k, v = line:match("^([%w_]+)%s*=%s*(.-)%s*$")
                    local on = (v == "1" or v == "on" or v == "yes" or v == "true")
                    if k == "store_required" and v ~= "" then
                        out.required = on
                    elseif k == "sys_required" and v ~= "" then
                        out.sys_required = on
                    end
                end
            end
            f.close()
        end
    end
    return out
end

-- Which kind of store a medium is, or nil when it is not one.
--   "sys"    carries PKG_SYS_MARKER: the shell's own modules
--   "store"  carries PKG_STORE_MARKER: ordinary extra packages
-- A medium carrying both is a system store: the stronger claim wins, because a
-- store that is required must not be mistaken for one that is optional.
function pkg.store_kind(side)
    if type(side) ~= "string" then return nil end
    if fs.exists(side .. "/" .. PKG_SYS_MARKER) then return "sys" end
    if fs.exists(side .. "/" .. PKG_STORE_MARKER) then return "store" end
    return nil
end

-- True when the medium itself says it is a package store, of either kind.
function pkg.is_store(side)
    return pkg.store_kind(side) ~= nil
end

-- True when the medium is the system module store.
function pkg.is_sys_store(side)
    return pkg.store_kind(side) == "sys"
end

-- The media that are package stores right now, in the order the mount table
-- lists them, as
--   { side = "/disk2", base = "/disk2", root = "/disk2/usr/pkgs",
--     kind = "sys"|"store", entry = <mount> }
-- A medium carrying the marker that is not mounted is simply not in the list:
-- there is no drive letter recorded to look for it under.
function pkg.store_list()
    local out = {}
    for _, entry in ipairs(mounted_media()) do
        local side = entry.source
        local kind = pkg.store_kind(side)
        if kind then
            out[#out + 1] = { side = side, base = side, root = side .. "/usr/pkgs",
                              kind = kind, entry = entry }
        end
    end
    return out
end

-- The system module stores that are present, as sides.
function pkg.sys_stores()
    local out = {}
    for _, item in ipairs(pkg.store_list()) do
        if item.kind == "sys" then out[#out + 1] = item.side end
    end
    return out
end

-- The system module store in use, or nil when none is inserted.
function pkg.sys_store()
    local sides = pkg.sys_stores()
    return sides[1]
end

-- True when this machine requires its system module store to be inserted.
function pkg.sys_required()
    return store_config().sys_required
end

-- How the system module store stands: the answer to "is the machine complete".
--   required  the rule is on
--   present   a medium carrying .pkgsys is mounted
--   side      which one, when there is one
--   complete  required implies present; without the rule the machine is complete
--             either way, because nothing is missing that it promised to have
function pkg.sys_status()
    local required = store_config().sys_required
    local side = pkg.sys_store()
    return {
        required = required,
        present = side ~= nil,
        side = side,
        complete = (not required) or (side ~= nil),
    }
end

-- The stores that are there, as sides. (The name is kept: callers ask for "the
-- stores" and get the ones the machine can actually use.)
function pkg.stores()
    local out = {}
    for _, item in ipairs(pkg.store_list()) do out[#out + 1] = item.side end
    return out
end

-- "/disk2,/disk3" when stores are present, "auto" when the machine installs on
-- its own filesystem. This is the value the messages and the tests read.
function pkg.store()
    local sides = pkg.stores()
    if #sides == 0 then return "auto" end
    return table.concat(sides, ",")
end

-- Every root a package may be found in, in priority order: the SYSTEM stores
-- first, then the ordinary stores, then the computer's own directory. Reading
-- always walks the whole list, so a package installed on any medium, and one
-- installed before a store was made, are both still visible.
--
-- The system store comes first on purpose: when both media are inserted and each
-- carries a package of the same name, the one the shell itself depends on is the
-- one that must win.
function pkg.roots()
    local out = {}
    for _, item in ipairs(pkg.store_list()) do
        if item.kind == "sys" then out[#out + 1] = item.root end
    end
    for _, item in ipairs(pkg.store_list()) do
        if item.kind ~= "sys" then out[#out + 1] = item.root end
    end
    out[#out + 1] = INTERNAL_ROOT
    return out
end

-- The root a new package is written to: the first store that is present, or the
-- internal directory when no medium is a store (which check_root() refuses to
-- accept when /etc/pkgstore.conf requires a medium).
--
-- A system store is not an install target: it holds the modules the installation
-- put there, and writing a new package into it would mix the machine's own
-- modules with extra ones. So the write target is the first ORDINARY store.
function pkg.root()
    local present = pkg.store_list()
    for _, item in ipairs(present) do
        if item.kind ~= "sys" then return item.root end
    end
    if #present > 0 then return present[1].root end
    return INTERNAL_ROOT
end

-- Where a package of this name is installed, or nil when it is nowhere.
function pkg.package_path(name)
    for _, root in ipairs(pkg.roots()) do
        if fs.exists(root .. "/" .. name) then return root .. "/" .. name end
    end
    return nil
end

-- What the install root is right now: where it is, whether that is a removable
-- medium, and why it cannot be used when it cannot. The system module store is
-- reported alongside it, because "where do new packages go" and "is the machine
-- complete" are two different questions on a two-part machine.
function pkg.root_state()
    local cfg = store_config()
    local present = pkg.store_list()
    local sys = nil
    for _, item in ipairs(present) do
        if item.kind == "sys" then sys = item break end
    end
    -- The write target is the first ORDINARY store, matching pkg.root().
    local target = nil
    for _, item in ipairs(present) do
        if item.kind ~= "sys" then target = item break end
    end
    if not target then target = present[1] end

    local out = {
        required = cfg.required,
        sys_required = cfg.sys_required,
        sys_present = sys ~= nil,
        sys_side = sys and sys.side or nil,
        sys_root = sys and sys.root or nil,
        stores = present,
    }
    if target then
        out.path = target.root
        out.removable = true
        out.internal = false
        out.base = target.base
        out.side = target.side
        out.kind = target.kind
    else
        out.path = INTERNAL_ROOT
        out.removable = false
        out.internal = true
    end
    return out
end

-- True when packages must be installed on removable media on this machine.
function pkg.store_required()
    return store_config().required
end

-- What the installer has to say about the root before it starts. Returns true
-- plus a note, or false plus the reason to refuse the install.
--
-- PRECEDENCE, and it is not cosmetic: the store_required refusal comes first,
-- because it is a hard block on the install. An earlier revision asked about the
-- system store first and returned early, so a machine that required a medium AND
-- was missing its system store was told "the system store is missing" and the
-- install went ahead -- the refusal never ran. A warning must never mask a
-- refusal.
--
-- A missing SYSTEM store does not refuse an install: it is not a rule about where
-- packages go, it is a statement that the machine is not complete. It is reported
-- when the install may proceed, because it is the more serious of the remaining
-- facts -- an operator told only "installing on this computer" would never learn
-- that the shell's own modules are missing.
function pkg.check_root()
    local root = pkg.root_state()
    if not root.removable and root.required then
        return false, "this machine requires packages on a removable medium: " ..
                      "insert one, make it a store with 'pkg store <n>', and " ..
                      "install again"
    end
    if root.sys_required and not root.sys_present then
        return true, "this machine needs its system module store: no medium " ..
                     "carrying " .. PKG_SYS_MARKER .. " is inserted"
    end
    if root.removable then
        return true, "packages are installed on the removable store " ..
                     tostring(root.side) .. " (" .. tostring(root.path) .. ")"
    end
    return true, "packages are installed on this computer (" .. root.path .. ")"
end

-- The line a shell prints at login when the machine is missing something it
-- needs, or nil when it is complete. Kept here rather than in the shell so the
-- rule and the wording live with the store mechanism they describe.
function pkg.completeness_warning()
    local st = pkg.sys_status()
    if st.required and not st.present then
        return "this machine needs its system module store: insert the medium " ..
               "carrying " .. PKG_SYS_MARKER
    end
    return nil
end

-- The directory of a package that is already installed. New packages are
-- written to pkg.root(); this is for the ones that are somewhere already.
local function package_dir(name)
    return pkg.package_path(name) or (pkg.root() .. "/" .. name)
end

-- Manifest of an installed package, or nil.
function pkg.read_manifest(name)
    for _, root in ipairs(pkg.roots()) do
        local path = root .. "/" .. name .. "/manifest"
        if fs.exists(path) then
            local f = fs.open(path, "r")
            if not f then return nil end
            local text = f.readAll()
            f.close()
            return parse_manifest(text)
        end
    end
    return nil
end

-- True when the package directory exists, in any root.
function pkg.installed(name)
    return pkg.package_path(name) ~= nil
end

-- Dependencies of an installed package.
function pkg.dependencies(name)
    local mf = pkg.read_manifest(name)
    if not mf then return {} end
    return mf.depends
end

-- Dependencies as published by the repository (also for packages that are not
-- installed yet).
function pkg.depends(name)
    local resp, err = request("fetch", { name = name })
    if not resp then return nil, err end
    if not resp.ok then return nil, resp.error end
    local mf = parse_manifest(resp.files and resp.files["manifest"])
    return mf.depends
end

-- ============================================================
-- dependency constraints
-- ============================================================
--
-- A "depends" entry may name a version constraint next to the package:
--
--   depends=base                      any version
--   depends=base>=1.2                 at least 1.2
--   depends=base>1.2, base<2.0        a range (two entries)
--   depends=base=1.2.3                exactly 1.2.3
--   depends=base<=1.9                 at most 1.9
--
-- The comparison comes from lib/semver.lua, so 1.10 is newer than 1.9.

local OPS = { ">=", "<=", "==", ">", "<", "=" }

-- Split "name>=1.2" into the name and, when written, the operator and version.
function pkg.parse_dependency(spec)
    local text = tostring(spec or ""):gsub("^%s+", ""):gsub("%s+$", "")
    if text == "" then return nil, "empty dependency" end
    for _, op in ipairs(OPS) do
        local at = text:find(op, 1, true)
        if at then
            local name = (text:sub(1, at - 1):gsub("%s+$", ""))
            local version = (text:sub(at + #op):gsub("^%s+", ""))
            if name == "" or version == "" then
                return nil, "malformed dependency: " .. text
            end
            if not semver.is_valid(version) then
                return nil, "malformed version in dependency: " .. text
            end
            if op == "==" then op = "=" end
            return { name = name, op = op, version = version }
        end
    end
    return { name = text, op = nil, version = nil }
end

-- Does a version satisfy a parsed dependency?
function pkg.version_satisfies(version, dep)
    if not dep or not dep.op then return true end
    if not semver.is_valid(version) then return false end
    local cmp = semver.compare(version, dep.version)
    if dep.op == ">=" then return cmp >= 0 end
    if dep.op == "<=" then return cmp <= 0 end
    if dep.op == ">" then return cmp > 0 end
    if dep.op == "<" then return cmp < 0 end
    return cmp == 0
end

-- How a dependency reads in a message: "base>=1.2" or just "base".
function pkg.describe_dependency(dep)
    if type(dep) == "string" then return dep end
    if not dep.op then return dep.name end
    return dep.name .. dep.op .. dep.version
end

-- Is a dependency satisfied by what is on this machine? An installed package
-- whose version is too old is not satisfied: the caller then installs the
-- version the repository carries, which is also how a too old dependency gets
-- upgraded.
function pkg.dependency_met(dep)
    if not pkg.installed(dep.name) then return false end
    return pkg.version_satisfies(pkg.installed_version(dep.name), dep)
end

-- ============================================================
-- preflight: what a package needs before it may be installed
-- ============================================================
--
-- Some packages are only useful with something the computer does not carry
-- itself, and the useful case ships a lot of data that will never fit in the
-- machine's own filesystem. The manifest declares that, and the installer
-- checks it BEFORE it asks the repository for anything, so a machine without
-- the medium is told what to insert instead of downloading a package it cannot
-- use. Keys (all optional):
--
--   requires_disk=<marker file>   a mounted removable medium has to carry that
--                                 file in its root, e.g.
--                                 requires_disk=cc_fonts.marker
--   requires_file=<path>          a file that has to exist (a font index on the
--                                 medium, say); "/disk..." style paths are
--                                 looked up on every mounted medium too, so the
--                                 drive letter does not matter
--   requires_feature=<kind>       a built-in feature this build provides
--
-- The marker is a file because that is what the disk route already speaks: the
-- medium is mounted by lib/disk.lua (automount, /etc/disk.conf, the .label
-- convention) and any file on it is readable through the mount table.
--
-- A machine with more than one drive needs to say WHICH medium carries the
-- packages. The user names it by disk number ("/disk2", "2") and the answer is
-- kept in /etc/pkgstore.conf:
--
--   pkg store           show the removable store and whether it is usable
--   pkg store 2         this machine's package data lives on disk 2
--   pkg store disk0     the same, written the way the side is called
--   pkg store auto      back to "whichever medium carries the marker"
--
-- With a store named, a requires_disk/requires_file requirement is only
-- satisfied BY THAT medium: a second disk that happens to carry the marker is
-- not the store the user pointed the machine at, and saying so is the whole
-- point of naming one.

-- "<spec>" as the canonical side the configuration stores, e.g. "2" -> "/disk2".
-- "auto"/"none"/"" are the absence of a store, which is "auto".
function pkg.normalize_store(spec)
    if spec == nil then return nil end
    local text = tostring(spec):gsub("^%s+", ""):gsub("%s+$", "")
    if text == "" or text == "auto" or text == "none" then return "auto" end
    text = text:gsub("^/", "")
    if text:match("^disk%d*$") then return "/" .. text end
    if text:match("^%d+$") then return "/disk" .. text end
    return nil, "not a disk number: " .. tostring(spec)
end

-- Write the marker that makes a medium a package store. The medium has to be
-- inserted and mounted: this is a write to the medium, and the whole point of
-- the marker is that the medium carries it from then on, wherever it is moved.
--
-- kind is "sys" for the system module store (PKG_SYS_MARKER) or anything else for
-- an ordinary one (PKG_STORE_MARKER). Claiming a medium as a system store removes
-- the ordinary marker if it is there: a medium cannot be both, and leaving both
-- files behind would make the kind depend on which check ran first.
function pkg.store_claim(spec, kind)
    local side, err = pkg.normalize_store(spec)
    if not side then return false, err end
    if side == "auto" then return pkg.store_release_all() end
    local entry = mounted_of(side)
    if not entry then
        local present = fs.exists(side)
        return false, tostring(side) .. " is not a mounted medium (" ..
                      (present and "run 'disk scan'" or "no medium in that drive") ..
                      "): nothing can be written to it"
    end
    if not fs.exists(side .. "/usr") then fs.makeDir(side .. "/usr") end
    if not fs.exists(side .. "/usr/pkgs") then fs.makeDir(side .. "/usr/pkgs") end

    local sys = (kind == "sys")
    local marker = sys and PKG_SYS_MARKER or PKG_STORE_MARKER
    local other = sys and PKG_STORE_MARKER or PKG_SYS_MARKER
    if fs.exists(side .. "/" .. other) then fs.delete(side .. "/" .. other) end

    local f = fs.open(side .. "/" .. marker, "w")
    if not f then return false, "cannot write " .. side .. "/" .. marker end
    -- The content records who made the medium a store and when. It deliberately
    -- does NOT record the drive it was written in: that is the one thing this
    -- whole mechanism exists to avoid depending on.
    f.write(sys and "ush system module store\n" or "ush package store\n")
    f.write("computer=" .. tostring(os.getComputerID and os.getComputerID() or "?") .. "\n")
    f.write("created=" .. tostring(os.epoch and os.epoch("utc") or "?") .. "\n")
    f.close()
    return true, side
end

-- Make a medium the system module store. A named wrapper so a caller reads as
-- what it means, and so the shell does not have to pass a magic string.
function pkg.store_claim_sys(spec)
    return pkg.store_claim(spec, "sys")
end

-- Remove the marker, so the medium stops being a store. The packages already on
-- it are left alone: the user asked for the medium to stop being a store, not
-- for its contents to be deleted.
--
-- Both markers are removed: the user asked for "this medium is no longer a store",
-- and which kind it happened to be is not something they should have to say twice.
function pkg.store_release(spec)
    local side, err = pkg.normalize_store(spec)
    if not side or side == "auto" then
        return false, err or ("not a disk number: " .. tostring(spec))
    end
    if not pkg.is_store(side) then
        return false, tostring(side) .. " is not a package store"
    end
    fs.delete(side .. "/" .. PKG_STORE_MARKER)
    fs.delete(side .. "/" .. PKG_SYS_MARKER)
    return true, side
end

-- Remove the marker from every mounted store.
function pkg.store_release_all()
    local freed = {}
    for _, item in ipairs(pkg.store_list()) do
        -- Both markers: whichever kind the medium carried, it stops being a store.
        fs.delete(item.side .. "/" .. PKG_STORE_MARKER)
        fs.delete(item.side .. "/" .. PKG_SYS_MARKER)
        freed[#freed + 1] = item.side
    end
    return true, #freed > 0 and table.concat(freed, ",") or "auto"
end

-- Compatibility shims for callers that still name a store the old way. Naming a
-- store now means writing the marker on that medium; "auto" means removing it.
-- Naming a store means writing the marker on that medium; "auto" means taking it
-- off every medium. This is the whole of "selecting a removable package store"
-- now that no drive letter is recorded anywhere.
function pkg.set_store(spec, opts)
    local ok, res = pkg.store_claim(spec)
    if not ok then return false, res end
    if opts and opts.required ~= nil then
        local rok, rerr = pkg.set_store_required(opts.required)
        if not rok then return false, rerr end
    end
    return true, res
end

-- Set several stores at once (the media are claimed one by one). An empty list
-- means "no store": every marker is removed.
function pkg.set_stores(spec, opts)
    local list = spec
    if type(spec) == "string" then
        list = {}
        for piece in tostring(spec):gmatch("[^,%s]+") do list[#list + 1] = piece end
    end
    if type(list) ~= "table" or #list == 0 then
        local ok, res = pkg.store_release_all()
        if ok and opts and opts.required ~= nil then
            pkg.set_store_required(opts.required)
        end
        return ok, res
    end
    for _, item in ipairs(list) do
        local ok, res = pkg.store_claim(item)
        if not ok then return false, res end
    end
    if opts and opts.required ~= nil then pkg.set_store_required(opts.required) end
    return true, pkg.store()
end

-- The markers a medium carries when it is a package store. Exposed so that a
-- package manifest can require one and so documentation can name them.
--   store_marker      an ordinary removable package store
--   sys_marker        the system module store
pkg.store_marker = PKG_STORE_MARKER
pkg.sys_marker = PKG_SYS_MARKER

-- Turn "packages must live on a removable medium" on or off. This is the one
-- thing that has to be recorded on the computer, because it is a rule about the
-- computer (and about media that are not here to carry a marker).
function pkg.set_store_required(on)
    return pkg.set_store_conf("store_required", on, on and "required" or "optional")
end

-- Turn "this machine needs its system module store inserted" on or off. The same
-- kind of rule as store_required, about the other kind of store.
function pkg.set_sys_required(on)
    return pkg.set_store_conf("sys_required", on, on and "required" or "optional")
end

-- Write one switch in /etc/pkgstore.conf, keeping every other line as it was.
-- The two switches live in one file because they are the same kind of fact: a
-- rule about the computer that no medium can carry.
function pkg.set_store_conf(key, on, answer)
    if not fs.exists("/etc") then fs.makeDir("/etc") end
    local pattern = "^%s*" .. key .. "%s*="
    local lines = {}
    if fs.exists(STORE_CONF) then
        local f = fs.open(STORE_CONF, "r")
        if f then
            while true do
                local line = f.readLine()
                if line == nil then break end
                if not line:match(pattern) then
                    lines[#lines + 1] = line
                end
            end
            f.close()
        end
    end
    if on then table.insert(lines, 1, key .. "=1") end
    local f = fs.open(STORE_CONF, "w")
    if not f then return false, "cannot write " .. STORE_CONF end
    f.write(table.concat(lines, "\n"))
    if #lines > 0 then f.write("\n") end
    f.close()
    return true, answer
end

-- Add a store: claim the medium named. There is no list to edit any more, so
-- "add" and "claim" are the same operation.
function pkg.add_store(spec)
    return pkg.store_claim(spec)
end
-- Drop a store: remove the marker from the medium named.
function pkg.remove_store(spec)
    return pkg.store_release(spec)
end

-- Mounted removable media, as mount table entries. (Declared at the top of the
-- "where packages are installed" section, because the store helpers use it.)

mounted_of = function(side)
    for _, entry in ipairs(mounted_media()) do
        if entry.source == side then return entry end
    end
    return nil
end

-- Where the package data of this machine lives, as a table. Kept for callers
-- that only want one answer; the multi store form is pkg.store_list().
--   mode     "auto" or "fixed"
--   side     the store a package would be written to ("/disk2")
--   entry    the mount table entry of that medium
--   base     the medium directory
function pkg.store_state()
    local present = pkg.store_list()
    if #present == 0 then return { mode = "auto" } end
    return { mode = "fixed", side = present[1].side, base = present[1].base,
             entry = present[1].entry, stores = present }
end

-- Every mounted removable medium, with its drive present.
mounted_media = function()
    local ok, disk = pcall(require, "disk")
    local mounts = require("mounts")
    local out = {}
    for _, entry in ipairs(mounts.list()) do
        local removable = false
        if ok and type(disk.removable) == "function" then
            removable = disk.removable(entry.source)
        else
            removable = entry.source:match("^/disk") ~= nil
        end
        if removable then
            if ok and type(disk.present) == "function" and not disk.present(entry.source) then
                -- the entry is stale: the medium was taken out
            else
                out[#out + 1] = entry
            end
        end
    end
    return out
end

local function file_exists(path)
    return type(path) == "string" and path ~= "" and fs.exists(path)
end

local function tail_of(path)
    return tostring(path):match("([^/]+)$") or tostring(path)
end

-- The medium that carries a file of this name, or nil, as (entry, where). The
-- file is looked for at the medium's source (where lib/disk.lua mounted it from)
-- and, as a fallback, through the mount point, because a path the user knows
-- about may have been written either way.
--
-- When the machine has package stores, only those media are considered: a store
-- is a medium the user marked as carrying the machine's packages, and a disk
-- that happens to carry the file but is not a store is not it. Any of the stores
-- may satisfy the requirement -- they are one pool.
local function media_with(name)
    local stores = pkg.store_list()
    local candidates = {}
    if #stores > 0 then
        for _, item in ipairs(stores) do candidates[#candidates + 1] = item.entry end
    else
        candidates = mounted_media()
    end
    for _, entry in ipairs(candidates) do
        if entry and file_exists(entry.source .. "/" .. name) then
            return entry, entry.source
        end
        if entry and entry.target and file_exists(entry.target .. "/" .. name) then
            return entry, entry.target
        end
    end
    return nil
end

-- How to name the stores in a message: "/disk2, /disk3".
local function store_names(list)
    local names = {}
    for _, item in ipairs(list or {}) do names[#names + 1] = tostring(item.side or item) end
    return table.concat(names, ", ")
end

local REQUIRE_CHECKS = {
    requires_disk = function(value)
        local stores = pkg.store_list()
        local entry, _ = media_with(value)
        if not entry then
            if #stores > 0 then
                return false, "no package store (" .. store_names(stores) ..
                              ") carries the marker '" .. tostring(value) ..
                              "' (a medium becomes a store with 'pkg store <n>')"
            end
            return false, "no mounted disk carries the marker '" .. tostring(value) ..
                          "' (insert the disk that has it, or make one a store " ..
                          "with 'pkg store <n>')"
        end
        return true, "marker '" .. tostring(value) .. "' found on " .. entry.source
    end,
    requires_file = function(value)
        if file_exists(value) then return true, value .. " is present" end
        -- an absolute path on a medium: look for the same tail on the stores
        local name = tail_of(value)
        local entry, target = media_with(name)
        if entry then
            return true, name .. " found on " .. entry.source .. " (" .. target .. "/" .. name .. ")"
        end
        local stores = pkg.store_list()
        if #stores > 0 then
            return false, "no package store (" .. store_names(stores) .. ") holds '" ..
                          name .. "' (a medium becomes a store with 'pkg store <n>')"
        end
        return false, tostring(value) .. " is missing (a mounted medium with '" ..
                      name .. "' would satisfy it)"
    end,
}

-- Which requirements a manifest declares, as { key, value } pairs in a stable
-- order. "requires" without a suffix is read as a feature, so a manifest may
-- write either "requires=disk" or "requires_feature=disk".
function pkg.requirements(manifest)
    local out = {}
    if type(manifest) ~= "table" then return out end
    -- a pair list may be passed straight in (pkg.requires returns one)
    if manifest[1] ~= nil then
        for _, pair in ipairs(manifest) do
            if type(pair) == "table" and pair.key and pair.value then
                out[#out + 1] = { key = pair.key, value = pair.value }
            end
        end
        return out
    end
    for _, key in ipairs({ "requires_disk", "requires_file", "requires_feature" }) do
        local value = manifest[key]
        if type(value) == "string" and value ~= "" then
            out[#out + 1] = { key = key, value = value }
        end
    end
    if type(manifest.requires) == "string" and manifest.requires ~= "" then
        out[#out + 1] = { key = "requires_feature", value = manifest.requires }
    end
    return out
end

-- The names of the optional features this build provides.
function pkg.features()
    return { "disk", "xfer", "rexec", "pkg", "crypto" }
end

function pkg.has_feature(name)
    for _, item in ipairs(pkg.features()) do
        if item == name then return true end
    end
    return false
end

-- Check every requirement of a manifest. Returns true plus a one line summary of
-- what was found, or false plus the reason to show the user. The second value is
-- always a string, because every caller shows it as one.
function pkg.check_requirements(manifest)
    local wanted = pkg.requirements(manifest)
    if #wanted == 0 then return true, "no extra requirements" end
    local notes = {}
    for _, pair in ipairs(wanted) do
        local ok, note
        if pair.key == "requires_feature" then
            ok = pkg.has_feature(pair.value)
            note = ok and ("feature " .. pair.value .. " is available")
                        or ("this build has no feature '" .. pair.value .. "'")
        else
            local check = REQUIRE_CHECKS[pair.key]
            ok, note = check(pair.value)
        end
        if not ok then
            return false, "needs " .. pair.key .. "=" .. pair.value .. ": " .. tostring(note)
        end
        notes[#notes + 1] = tostring(note)
    end
    return true, table.concat(notes, "; ")
end

-- One fetch of a package's whole file set, shared by the preflight and the
-- install pass. A "fetch" answer is the ENTIRE file set plus its checksums and
-- digest, not just the manifest, so a second ask is a second download of
-- everything. It lives up here, before pkg.requires(), because that function
-- has to call it: a local declared below its caller is not the same upvalue (it
-- would be read as a global and be nil at run time).
--
-- A miss is what reaches the repository; a cached answer -- including a cached
-- FAILURE -- is handed back as it is. The install pass then reports the
-- repository's own reason for a package that is not there, instead of asking
-- again or, worse, treating the empty answer as a success.
local function fetch_cached(name, ctx)
    if type(ctx) ~= "table" or type(ctx.cache) ~= "table" then ctx = { cache = {} } end
    if not ctx.cache[name] then
        local resp, err = request("fetch", { name = name })
        ctx.cache[name] = { resp = resp, err = err }
    end
    local hit = ctx.cache[name]
    return hit.resp, hit.err
end

-- The requirements a package *in the repository* declares. This is what the
-- installer preflights with. The optional second argument is the fetch cache the
-- install pass is about to use, and handing it over is what makes an install
-- cost ONE download per package: the preflight's answer is the same whole file
-- set install_tree would otherwise ask for again. A caller that only wants to
-- know what a package needs (the shell's "pkg requires NAME") passes nothing and
-- the answer is dropped with the throwaway cache.
function pkg.requires(name, cache)
    local resp, err = fetch_cached(name, { cache = cache or {} })
    if not resp then return nil, err end
    if not resp.ok then return nil, resp.error end
    return pkg.requirements(parse_manifest(resp.files and resp.files["manifest"]))
end

-- The requirements a package *installed on this machine* declares, checked the
-- same way. A medium that is gone from a machine that still has the package is
-- exactly the state this reports.
function pkg.installed_requirements(name)
    local mf = pkg.read_manifest(name)
    if not mf then return nil, tostring(name) .. ": not installed" end
    return pkg.requirements(mf)
end

-- Human readable form of one requirement pair, for messages and for `pkg
-- requirements`.
function pkg.describe_requirement(pair)
    if type(pair) ~= "table" then return tostring(pair) end
    return tostring(pair.key) .. "=" .. tostring(pair.value)
end

-- ============================================================
-- verification
-- ============================================================

-- A repository answer may carry, next to the files:
--   sig / signature / sha256 : the canonical digest of the file set, as
--                              checksum.files_digest() computes it
--   checksums / sums         : path -> sha256 hex of that file
-- Both are checked before a single byte is written, so a package that arrived
-- damaged, or whose file set was altered in transit, never reaches /usr/pkgs.
-- The channel itself is encrypted with the shared key, so only the repository
-- can produce an answer at all; the digest is what binds that answer to the
-- exact file set it claims to be.
local function signature_of(resp)
    local value = resp.sig or resp.signature or resp.sha256
    if type(value) == "string" and value ~= "" then return value end
    return nil
end

-- What an unsigned package means. The shipped repository (pkgserver.lua) does
-- publish a digest and per-file checksums, but a third party repository may
-- not, so refusing outright would stop every install against one of those;
-- "warn" reports it and goes on. /etc/pkg.conf decides:
--   pkg_sig_required=1        refuse a package that carries no signature
function pkg.signature_policy()
    local text = tostring(netcfg.get("pkg_sig_required", "warn"))
    if text == "1" or text == "true" or text == "yes" or text == "require" then
        return "require"
    end
    return "warn"
end

-- Check one fetched package. Returns true plus a summary table, or nil plus a
-- reason. "signed" is false when the repository published no digest, which the
-- policy above turns into a refusal or a warning.
local function verify_package(name, resp)
    local files = resp.files
    if type(files) ~= "table" then
        return nil, "no file set in the repository answer"
    end

    local checked = 0
    local sums = resp.checksums or resp.sums
    if type(sums) == "table" then
        for path, expected in pairs(sums) do
            local body = files[path]
            if body == nil then
                return nil, "checksum published for a file that is missing: " ..
                            tostring(path)
            end
            local actual = checksum.sha256(tostring(body))
            if string.lower(tostring(expected)) ~= actual then
                return nil, "checksum mismatch for " .. tostring(path) ..
                            " (published " .. tostring(expected) ..
                            ", got " .. actual .. ")"
            end
            checked = checked + 1
        end
    end

    local published = signature_of(resp)
    if published then
        local actual = checksum.files_digest(files)
        if string.lower(published) ~= actual then
            return nil, "signature mismatch (published " .. tostring(published) ..
                        ", got " .. actual .. ")"
        end
        return true, { signed = true, files = checked }
    end

    if pkg.signature_policy() == "require" then
        return nil, "not signed, and pkg_sig_required is set in /etc/pkg.conf"
    end
    return true, { signed = false, files = checked }
end

-- ============================================================
-- residue
-- ============================================================

-- Every file under a directory, as paths relative to it. Used to compare what
-- is on the disk with what the current version ships.
local function list_files(dir, prefix, into)
    into = into or {}
    if not fs.exists(dir) then return into end
    for _, entry in ipairs(fs.list(dir) or {}) do
        local full = dir .. "/" .. entry
        local relative = prefix and (prefix .. "/" .. entry) or entry
        if fs.isDir(full) then
            list_files(full, relative, into)
        else
            table.insert(into, relative)
        end
    end
    return into
end

pkg.list_files = list_files

-- Drop everything under a package directory that the version being installed
-- does not ship, and remove the directories that leaves empty. An upgrade
-- writes the new file set first and prunes second, so the package is never
-- absent from the disk and the files of the previous version do not survive.
local function prune_files(dir, keep)
    local removed = 0
    for _, relative in ipairs(list_files(dir)) do
        if not keep[relative] then
            if fs.delete(dir .. "/" .. relative) then removed = removed + 1 end
        end
    end
    return removed
end

-- Remove empty directories below "dir" (never "dir" itself), deepest first.
local function prune_empty_dirs(dir, depth)
    if not fs.isDir(dir) then return 0 end
    local removed = 0
    for _, entry in ipairs(fs.list(dir) or {}) do
        local full = dir .. "/" .. entry
        if fs.isDir(full) then
            removed = removed + prune_empty_dirs(full, (depth or 0) + 1)
        end
    end
    if (depth or 0) > 0 and #(fs.list(dir) or {}) == 0 then
        if fs.delete(dir) then removed = removed + 1 end
    end
    return removed
end

-- Registry entries that point at a package directory which is gone. A package
-- removed by hand, or a removal interrupted halfway, used to leave the command
-- names registered: the shell then found a file that was not there and failed
-- with "cannot open" instead of "command not found". Returns the names dropped.
function pkg.prune_registry()
    local db = pkg.get_bins()
    local dropped = {}
    for name in pairs(db) do
        if not fs.exists(package_dir(name)) then
            db[name] = nil
            table.insert(dropped, name)
        end
    end
    if #dropped > 0 then
        if not fs.exists("/var/lib/pkg") then fs.makeDir("/var/lib/pkg") end
        local f = fs.open("/var/lib/pkg/bins", "w")
        f.write(textutils.serialize(db))
        f.close()
        table.sort(dropped)
    end
    return dropped
end

-- ============================================================
-- install (with dependency resolution)
-- ============================================================

-- Write a package into "dir" (an absolute package directory). Returns the path,
-- or nil plus the reason when the file set cannot fit.
local function write_into(dir, files)
    local root = dir:match("^(.*)/[^/]+$") or dir
    -- The whole set is measured before the first file: a package written until
    -- the disk fills would be half a package with a valid manifest.
    local total = 0
    for _, content in pairs(files or {}) do total = total + #tostring(content) end
    local room, why = space.need_tree(dir, total)
    if not room then return nil, why end

    if not fs.exists(root) then fs.makeDir(root) end
    if not fs.exists(dir) then fs.makeDir(dir) end
    for fname, content in pairs(files or {}) do
        local subdir = fname:match("^(.-)/[^/]+$")
        if subdir then
            local full = dir .. "/" .. subdir
            if not fs.exists(full) then fs.makeDir(full) end
        end
        local path = dir .. "/" .. fname
        -- The preflight covers the set as a whole; this narrows the window for a
        -- disk that filled up while the files were being written. It runs BEFORE
        -- the open, because an open truncates the file it lands on.
        local file_room, file_why = space.need(path, #tostring(content))
        if not file_room then return nil, file_why end
        local f = fs.open(path, "w")
        if not f then return nil, "cannot write " .. path end
        f.write(content)
        f.close()
    end
    return dir
end

-- Install one package. An install writes to the root the machine is installing
-- into right now (pkg.root()), never to a copy of the same package that happens
-- to sit in another root: "pkg install --store 2 NAME" has to land on disk 2
-- even when an older NAME is still on the computer, and an older copy elsewhere
-- is removed afterwards so the two cannot drift apart.
local function remove_tree(dir)
    for _, entry in ipairs(fs.list(dir) or {}) do
        local full = dir .. "/" .. entry
        if fs.isDir(full) then remove_tree(full) else fs.delete(full) end
    end
    fs.delete(dir)
end

local function write_package(name, files)
    local dir = pkg.root() .. "/" .. name
    local old = pkg.package_path(name)
    local written, werr = write_into(dir, files)
    if not written then return nil, werr end
    if old and old ~= dir and fs.exists(old) then remove_tree(old) end
    return written
end

-- Commands a package publishes: the manifest "bin" list, or every .lua file
-- under bin/ when the manifest does not list any.
local function package_bins(name, manifest)
    local bins = {}
    for _, item in ipairs((manifest and manifest.bin) or {}) do
        table.insert(bins, item)
    end
    if #bins == 0 then
        local binDir = package_dir(name) .. "/bin"
        if fs.exists(binDir) then
            for _, fname in ipairs(fs.list(binDir)) do
                local cmd = fname:match("^(.+)%.lua$")
                if cmd then table.insert(bins, cmd) end
            end
        end
    end
    return bins
end

-- Default permissions, same rules as before.
local function set_package_permissions(name, files)
    local perm = require("perm")
    for fname in pairs(files or {}) do
        local mode = fname:match("^bin/") and "rwxr-xr-x" or "rw-r--r--"
        perm.set_mode(package_dir(name) .. "/" .. fname, mode, "root")
    end
end

local function find_on_stack(stack, name)
    for _, item in ipairs(stack) do
        if item == name then return true end
    end
    return false
end

-- Install one package and, recursively, everything it depends on.
--   * dependencies that are already installed are skipped
--   * a package that appears twice on the recursion stack is a cycle
--   * a failure aborts with the package name and the dependency chain
local function install_tree(name, ctx, is_dependency)
    if ctx.done[name] then return true end
    if find_on_stack(ctx.stack, name) then
        return false, "circular dependency: " ..
            table.concat(ctx.stack, " -> ") .. " -> " .. name
    end

    if is_dependency then
        local dep = ctx.want and ctx.want[name]
        if dep and pkg.dependency_met(dep) then
            ctx.done[name] = true
            table.insert(ctx.skipped, name)
            return true
        end
        -- An installed package that does not satisfy the constraint has to be
        -- replaced, so the repository version is fetched below. This is the
        -- "installed but too old" case.
        if not dep and pkg.installed(name) then
            ctx.done[name] = true
            table.insert(ctx.skipped, name)
            return true
        end
    end

    local resp, err = fetch_cached(name, ctx)
    -- The root package's answer is the one the preflight already paid for, so
    -- this is a cache hit and costs no second download; a dependency is asked
    -- for here for the first and only time.
    if not resp then
        return false, "package '" .. name .. "': " .. tostring(err)
    end
    if not resp.ok then
        return false, "package '" .. name .. "': " .. tostring(resp.error)
    end

    -- Nothing is written until the answer has been checked.
    local ok_sig, info = verify_package(name, resp)
    if not ok_sig then
        return false, "package '" .. name .. "': " .. tostring(info)
    end
    if info.signed then
        ctx.signed = (ctx.signed or 0) + 1
    else
        ctx.unsigned = (ctx.unsigned or 0) + 1
    end

    local manifest = parse_manifest(resp.files and resp.files["manifest"])

    -- What this package needs before it is written: a mounted disk with a
    -- marker, or a file on one. For the root package this repeats a check the
    -- preflight already made against the same cached file set; it is done here
    -- anyway because a dependency's requirements only become known once its
    -- parent's manifest is read.
    local ok_req, req_note = pkg.check_requirements(manifest)
    if not ok_req then
        return false, "package '" .. name .. "' " .. tostring(req_note)
    end
    if req_note and req_note ~= "no extra requirements" then
        ctx.requirements = (ctx.requirements or 0) + 1
        table.insert(ctx.requirement_notes, req_note)
    end

    -- The fetched version has to satisfy the constraint that pulled it in, or
    -- the install would silently deliver a package the dependent cannot use.
    local want = ctx.want and ctx.want[name]
    if want and manifest.version and not pkg.version_satisfies(manifest.version, want) then
        return false, "the repository carries " .. name .. " " ..
            tostring(manifest.version) .. ", which does not satisfy " ..
            pkg.describe_dependency(want) .. " required by " ..
            tostring(ctx.wanted_by and ctx.wanted_by[name] or "?")
    end

    -- Dependencies first, so that a failure leaves nothing half installed.
    table.insert(ctx.stack, name)
    for _, spec in ipairs(manifest.depends) do
        local dep, derr = pkg.parse_dependency(spec)
        if not dep then
            table.remove(ctx.stack)
            return false, "package '" .. name .. "': " .. tostring(derr)
        end
        if dep.name == name then
            table.remove(ctx.stack)
            return false, "circular dependency: " .. name .. " depends on itself"
        end
        -- Remember what the parent asked for: the same package may be wanted by
        -- two parents, and the first constraint that made it install is what
        -- install_tree checks when it builds it.
        if not ctx.want then ctx.want, ctx.wanted_by = {}, {} end
        if not ctx.want[dep.name] then
            ctx.want[dep.name] = dep
            ctx.wanted_by[dep.name] = name
        end
        if not ctx.done[dep.name] then
            if not pkg.dependency_met(dep) then
                local ok, derr2 = install_tree(dep.name, ctx, true)
                if not ok then
                    table.remove(ctx.stack)
                    return false, "dependency '" .. pkg.describe_dependency(dep) ..
                                  "' of '" .. name .. "' failed: " .. tostring(derr2)
                end
            else
                ctx.done[dep.name] = true
                table.insert(ctx.skipped, dep.name)
            end
        end
    end
    table.remove(ctx.stack)

    -- The package lands in the current install root (see write_package); the
    -- prune that follows has to look there, not at wherever a copy used to be.
    local written, write_err = write_package(name, resp.files)
    if not written then
        return false, "package '" .. name .. "': " .. tostring(write_err)
    end

    -- Installing over an existing package is an upgrade, so the files of the
    -- version that was there before do not survive: the new file set is on the
    -- disk by now and everything it does not list is dropped.
    local pruned = prune_files(written, resp.files)
    prune_empty_dirs(written, 0)
    ctx.pruned = (ctx.pruned or 0) + pruned

    local bins = package_bins(name, pkg.read_manifest(name) or manifest)
    pkg._register_bins(name, bins)
    set_package_permissions(name, resp.files)

    ctx.done[name] = true
    table.insert(ctx.installed, name)
    ctx.bins[name] = #bins
    return true
end

function pkg.install(name, opts)
    if type(name) ~= "string" or name == "" then
        return false, "usage: pkg install <name>"
    end
    opts = opts or {}

    -- A one-off store: "pkg install --store 2 NAME" installs onto that medium
    -- without changing what the machine uses from now on. The marker is written
    -- by store_claim() and is the only record, so it is removed again at the
    -- end: the medium stops being a store the moment the command finishes.
    local one_off = nil
    if opts.store ~= nil and opts.store ~= "" then
        local want = select(1, pkg.normalize_store(opts.store))
        local ok_store, store_err = pkg.store_claim(opts.store)
        if not ok_store then
            return false, "pkg install --store: " .. tostring(store_err)
        end
        if not pkg.is_store(want) then
            pkg.store_release(want)
            return false, "pkg install --store: " .. tostring(want) ..
                          " did not become a store"
        end
        one_off = want
    end
    local function restore_store()
        if one_off and one_off ~= "auto" and pkg.is_store(one_off) then
            pkg.store_release(one_off)
        end
    end

    -- Where the packages may go: a machine that keeps them on a medium refuses
    -- to install them on its own filesystem, and a named store that is not
    -- inserted is an error rather than a silent fallback.
    local ok_root, root_note = pkg.check_root()
    if not ok_root then
        restore_store()
        return false, tostring(root_note)
    end

    -- Preflight, before anything is written: a package that wants a mounted
    -- medium must not cost a full install on a machine that has no medium.
    -- pkg.requires() asks the repository, because the manifest of a package that
    -- is not installed yet only exists there -- but the answer to that "fetch" is
    -- the whole file set, not just the manifest, so it is kept in the cache the
    -- install pass reads below. Without that hand-over every install downloaded
    -- the package twice: once here and once in install_tree. The preflight's
    -- failure is cached just the same, so a package the repository does not have
    -- still fails in install_tree with the repository's reason (an earlier build
    -- leaving it as a success is the defect this shape rules out).
    local cache = {}
    local needs = pkg.requires(name, cache)
    if type(needs) == "table" and #needs > 0 then
        local ok_req, req_note = pkg.check_requirements(needs)
        if not ok_req then
            restore_store()
            return false, "package '" .. name .. "' " .. tostring(req_note)
        end
    end

    local ctx = {
        stack = {}, done = {}, cache = cache,
        installed = {}, skipped = {}, bins = {},
        signed = 0, unsigned = 0, pruned = 0,
        requirements = 0, requirement_notes = {}, root_note = root_note,
        root_removable = pkg.root_state().removable,
    }
    local ok, err = install_tree(name, ctx, false)
    -- The one-off store was only for this command, so it goes back before the
    -- caller sees the result; the message below still reports where it went.
    restore_store()
    if not ok then return false, tostring(err) end

    local msg = "installed " .. name .. " (" .. tostring(ctx.bins[name] or 0) ..
                " command(s))"
    local extra = {}
    for _, item in ipairs(ctx.installed) do
        if item ~= name then table.insert(extra, item) end
    end
    if #extra > 0 then
        msg = msg .. "; dependencies installed: " .. table.concat(extra, ", ")
    end
    if #ctx.skipped > 0 then
        msg = msg .. "; dependencies already installed: " ..
              table.concat(ctx.skipped, ", ")
    end
    if (ctx.pruned or 0) > 0 then
        msg = msg .. "; " .. ctx.pruned .. " leftover file(s) of the previous " ..
              "version removed"
    end
    if ctx.root_note and ctx.root_removable then
        msg = msg .. "; " .. ctx.root_note
    end
    if (ctx.unsigned or 0) > 0 then
        msg = msg .. "; " .. ctx.unsigned .. " package(s) are not signed " ..
              "(policy: " .. pkg.signature_policy() .. ")"
    end
    -- The third return value carries what the pass collected, so callers such
    -- as pkg.upgrade() can report signatures and pruned leftovers without
    -- reaching into the installer themselves.
    return true, msg, {
        installed = ctx.installed, skipped = ctx.skipped,
        signed = ctx.signed or 0, unsigned = ctx.unsigned or 0,
        pruned = ctx.pruned or 0,
    }
end

function pkg._register_bins(name, bins)
    local db = {}
    if fs.exists("/var/lib/pkg/bins") then
        local f = fs.open("/var/lib/pkg/bins", "r")
        db = textutils.unserialize(f.readAll()) or {}
        f.close()
    else
        if not fs.exists("/var/lib/pkg") then fs.makeDir("/var/lib/pkg") end
    end
    db[name] = bins
    local f = fs.open("/var/lib/pkg/bins", "w")
    f.write(textutils.serialize(db))
    f.close()
end

function pkg.get_bins()
    if not fs.exists("/var/lib/pkg/bins") then return {} end
    local f = fs.open("/var/lib/pkg/bins", "r")
    local db = textutils.unserialize(f.readAll()) or {}
    f.close()
    return db
end

-- The name of the command a manifest "bin" entry publishes: the entry is a file
-- under bin/ ("bin/demo.lua" from the deploy layout, or a bare "demo"), and what
-- a user types is the bare name, so both sides are normalised to that.
local function command_name(entry)
    local name = tostring(entry)
    name = name:gsub("^%s+", ""):gsub("%s+$", "")
    name = name:match("([^/]+)$") or name
    name = name:gsub("%.lua$", "")
    return name
end

-- ============================================================
-- modules a package contributes to require()
-- ============================================================
--
-- A package can publish COMMANDS (manifest "bin") and MODULES (a lib/ directory).
-- Commands need no path work: the shell asks resolve_command() for the file and
-- runs it. Modules are different -- require() searches package.path, and a module
-- on a medium is invisible to it unless its directory is on that path. The layout
-- is the one installs already write:
--
--     <root>/<package>/lib/<module>.lua
--
-- THE IMPLEMENTATION LIVES IN lib/mounts.lua, not here, and that is not tidiness:
-- on a two-part machine THIS FILE IS ON THE MEDIUM. A shell that had to load pkg
-- in order to find the medium's modules could never start, because the code that
-- would put the medium on the path is itself on the medium. mounts.lua is part of
-- the load-time closure and is always on the computer, so it owns the scan and the
-- path refresh; pkg just asks for a refresh after it changes what is installed.
function pkg.refresh_module_paths()
    local ok, m = pcall(require, "mounts")
    if not ok or type(m) ~= "table" or type(m.refresh_module_paths) ~= "function" then
        return 0, {}
    end
    return m.refresh_module_paths()
end

-- The module directories the machine can see right now, as "<dir>" paths. Kept
-- here as well as in mounts so a caller holding a pkg handle does not have to know
-- where the scan lives.
function pkg.module_dirs()
    local ok, m = pcall(require, "mounts")
    if not ok or type(m) ~= "table" or type(m.module_dirs) ~= "function" then
        return {}
    end
    return m.module_dirs()
end

-- The file a package installs for a command, or nil when no package publishes
-- it. The registry is a list of entries as the manifest wrote them, so the
-- lookup normalises them: a registry that says "bin/x.lua" must still answer a
-- request for "x".
function pkg.resolve_command(cmd)
    local wanted = command_name(cmd)
    local db = pkg.get_bins()
    for name, bins in pairs(db) do
        for _, b in ipairs(bins) do
            if command_name(b) == wanted then
                local dir = pkg.package_path(name)
                if dir then
                    return dir .. "/bin/" .. wanted .. ".lua"
                end
                -- the package is not there any more: do not hand back a path
                -- that cannot be opened
            end
        end
    end
    return nil
end

-- Recursively delete a file or a whole directory tree.
local function rm_tree(path)
    if not fs.exists(path) then return false end
    if fs.isDir(path) then
        for _, name in ipairs(fs.list(path) or {}) do
            rm_tree(path .. "/" .. name)
        end
    end
    fs.delete(path)
    return true
end

-- Drop the commands a package registered, so its names resolve nowhere once
-- the package is gone. Returns true when something was actually removed.
local function unregister_bins(name)
    if not fs.exists("/var/lib/pkg/bins") then return false end
    local f = fs.open("/var/lib/pkg/bins", "r")
    local db = textutils.unserialize(f.readAll()) or {}
    f.close()
    if db[name] == nil then return false end
    db[name] = nil
    local w = fs.open("/var/lib/pkg/bins", "w")
    w.write(textutils.serialize(db))
    w.close()
    return true
end

function pkg.remove(name)
    if type(name) ~= "string" or name == "" then
        return false, "usage: pkg remove <name>"
    end
    local dir = package_dir(name)
    if not fs.exists(dir) then return false, "not installed" end
    rm_tree(dir)
    unregister_bins(name)
    require("perm").remove(dir)
    -- What removal used to leave behind: registry entries of packages whose
    -- directory is gone. Dropping them here keeps "pkg remove" from depending
    -- on a later purge, which is what a user would otherwise have to run by
    -- intuition before a command name stops resolving.
    local dropped = pkg.prune_registry()
    local msg = "removed " .. name
    if #dropped > 0 then
        msg = msg .. "; dropped " .. #dropped .. " stale command record(s): " ..
              table.concat(dropped, ", ")
    end
    return true, msg
end

-- "purge" removes a package together with everything a plain removal can leave
-- behind: its directory, the commands it registered and the permission record
-- of the directory. It also succeeds when the directory is already gone but
-- such records survive, so a half finished removal can be cleaned up; a name
-- that left nothing behind is still reported as not installed.
function pkg.purge(name)
    if type(name) ~= "string" or name == "" then
        return false, "usage: pkg purge <name>"
    end
    local dir = package_dir(name)
    local existed = fs.exists(dir)
    local stubborn = false
    if existed then
        rm_tree(dir)
        -- A directory that survived the tree walk (a file the filesystem
        -- refused to delete, for instance) gets a second pass so that purge
        -- really means "nothing of this package is left".
        if fs.exists(dir) then
            rm_tree(dir)
            stubborn = fs.exists(dir)
        end
    end

    local cleaned = unregister_bins(name)
    local had_record = require("perm").get_owner(dir) ~= nil
    require("perm").remove(dir)
    local dropped = pkg.prune_registry()

    if not existed and not cleaned and not had_record then
        return false, "not installed"
    end

    local notes = {}
    if cleaned then table.insert(notes, "command names dropped") end
    if had_record then table.insert(notes, "permission record dropped") end
    if #dropped > 0 then
        table.insert(notes, #dropped .. " stale command record(s) dropped")
    end

    local msg = "purged " .. name
    if #notes > 0 then msg = msg .. " (" .. table.concat(notes, ", ") .. ")" end
    if stubborn then
        msg = msg .. "; " .. dir .. " could not be removed, run pkg purge again"
    end
    return true, msg
end

-- Upgrade pass: refresh the index, then install every package the repository
-- carries a newer version of. The comparison uses lib/semver.lua, so "1.10.0"
-- counts as newer than "1.9.9" while a string comparison would call it older,
-- and a package whose manifest has no version at all is treated as the oldest
-- so that it gets refreshed. A package the index says nothing about is
-- refreshed as well, which is the old "refresh then reinstall" behaviour and
-- what a repository that publishes no versions needs; only a package the index
-- carries at the version that is already installed is left alone. opts.all
-- (pkg upgrade -f / --all) refreshes every installed package.
--
-- Returns true plus a report, or nil plus a reason:
--   { upgraded = {{name, from, to}}, skipped = {{name, version, why}},
--     failed = {{name, error}}, signed = n, unsigned = n, pruned = n,
--     note = "..." }
function pkg.upgrade(opts)
    opts = opts or {}
    local ok, msg = pkg.update()
    if not ok then
        return nil, "cannot read the repository index: " .. tostring(msg)
    end

    local report = {
        upgraded = {}, skipped = {}, failed = {},
        signed = 0, unsigned = 0, pruned = 0,
    }
    local names = pkg.list()
    if #names == 0 then
        report.note = "no packages installed"
        return true, report
    end

    for _, name in ipairs(names) do
        local entry, why = pkg.latest(name)
        local current = pkg.installed_version(name)
        -- Refresh when it is forced, when the index carries a newer version,
        -- or when the index knows nothing about the package. The work goes
        -- through pkg.install(), the same public entry point the shell uses.
        local refresh = opts.all or (not entry) or
                        semver.is_newer(entry.version, current)
        if not refresh then
            table.insert(report.skipped, {
                name = name, version = current, why = "up to date",
            })
        else
            local iok, ierr, info = pkg.install(name)
            if info then
                report.signed = report.signed + (info.signed or 0)
                report.unsigned = report.unsigned + (info.unsigned or 0)
                report.pruned = report.pruned + (info.pruned or 0)
            end
            if iok then
                table.insert(report.upgraded, {
                    name = name, from = current,
                    to = (entry and entry.version) or current,
                })
            elseif entry then
                table.insert(report.failed, { name = name, error = tostring(ierr) })
            else
                -- Nothing in the index to reinstall from: keep it, say so.
                table.insert(report.skipped, {
                    name = name, version = current,
                    why = why or "not in the index",
                })
            end
        end
    end
    return true, report
end

-- "clean" drops the downloaded package index. It is a cache, so an empty or
-- missing directory is not an error; the count reports what was removed.
function pkg.clean()
    local dir = "/var/cache/pkg"
    local removed = 0
    if fs.exists(dir) then
        for _, fname in ipairs(fs.list(dir) or {}) do
            fs.delete(dir .. "/" .. fname)
            removed = removed + 1
        end
    end
    return true, "cleaned " .. removed .. " cached file(s)"
end

-- Installed packages, from every root: the stores that are present and the
-- computer's own directory. A package that moved to a medium, or one that was
-- installed before a store was made, stays visible rather than disappearing from
-- "pkg list".
function pkg.list()
    local list, seen = {}, {}
    for _, root in ipairs(pkg.roots()) do
        if fs.exists(root) then
            for _, name in ipairs(fs.list(root)) do
                if fs.isDir(root .. "/" .. name) and not seen[name] then
                    seen[name] = true
                    table.insert(list, name)
                end
            end
        end
    end
    table.sort(list)
    return list
end

-- Installed packages grouped by the root they are in, so a machine with several
-- stores can be taken in at a glance:
--   { { root = "/disk2/usr/pkgs", side = "/disk2", removable = true,
--       packages = { {name=..., version=...}, ... } }, ... }
-- The internal directory is always the last group.
function pkg.list_by_root()
    local out = {}
    for _, root in ipairs(pkg.roots()) do
        local group = { root = root, removable = root ~= INTERNAL_ROOT,
                        packages = {} }
        group.side = group.removable and root:match("^(/disk%d*)") or nil
        if fs.exists(root) and fs.isDir(root) then
            for _, name in ipairs(fs.list(root)) do
                if fs.isDir(root .. "/" .. name) then
                    local mf = pkg.read_manifest(name)
                    group.packages[#group.packages + 1] = {
                        name = name,
                        version = mf and mf.version or nil,
                    }
                end
            end
        end
        table.sort(group.packages, function(a, b) return a.name < b.name end)
        group.count = #group.packages
        out[#out + 1] = group
    end
    return out
end

-- What each package store is and holds, for `pkg store` and for a script that
-- wants the answer in one table:
--   { stores = { { side, root, packages, count, capacity, free, marker } },
--     internal = { root, packages, count, capacity, free },
--     required = <the store_required switch>,
--     install_root = <where a new package would go> }
-- capacity/free come from fs.getCapacity/fs.getFreeSpace and stay nil when the
-- filesystem does not answer them, because a store is usable without a quota.
function pkg.store_report()
    local function group_of(root, removable, side, marker, kind)
        local packages = {}
        if fs.exists(root) and fs.isDir(root) then
            for _, name in ipairs(fs.list(root)) do
                if fs.isDir(root .. "/" .. name) then
                    local mf = pkg.read_manifest(name)
                    packages[#packages + 1] = {
                        name = name,
                        version = mf and mf.version or nil,
                        depends = mf and mf.depends or {},
                    }
                end
            end
        end
        table.sort(packages, function(a, b) return a.name < b.name end)
        -- A filesystem may not answer a quota question at all, and fs.exists is
        -- checked first because getCapacity on a missing path is an error on
        -- some platforms rather than a nil.
        local capacity, free
        if fs.exists(root) then
            local ok_cap, cap = pcall(fs.getCapacity, root)
            if ok_cap and type(cap) == "number" then capacity = cap end
            local ok_free, space = pcall(fs.getFreeSpace, root)
            if ok_free and type(space) == "number" then free = space end
        end
        return {
            root = root, side = side, removable = removable, marker = marker,
            kind = kind,
            packages = packages, count = #packages,
            capacity = capacity, free = free,
        }
    end

    local sys = pkg.sys_status()
    local report = {
        stores = {},
        internal = group_of(INTERNAL_ROOT, false, nil, nil, "internal"),
        required = pkg.store_required(),
        -- The system module store is reported separately from the list of stores:
        -- it is not a place new packages go, it is a fact about whether this
        -- machine is complete.
        sys_required = sys.required,
        sys_present = sys.present,
        sys_side = sys.side,
        sys_complete = sys.complete,
        install_root = pkg.root(),
    }
    for _, item in ipairs(pkg.store_list()) do
        local marker = nil
        local path = item.side .. "/" ..
            (item.kind == "sys" and PKG_SYS_MARKER or PKG_STORE_MARKER)
        if fs.exists(path) then
            local f = fs.open(path, "r")
            if f then marker = f.readAll() f.close() end
        end
        report.stores[#report.stores + 1] =
            group_of(item.root, true, item.side, marker, item.kind)
    end
    return report
end

-- The same report as JSON, for a script or another machine to read. The encoder
-- is local because the project ships no json module and a machine reading this
-- wants a standard format, not a Lua table dump. Keys are sorted so the text is
-- stable between two runs.
local function json_string(text)
    local out = text:gsub('[%c"\\]', function(c)
        if c == '"' then return '\\"' end
        if c == "\\" then return "\\\\" end
        local byte = string.byte(c)
        if byte == 8 then return "\\b" end
        if byte == 9 then return "\\t" end
        if byte == 10 then return "\\n" end
        if byte == 12 then return "\\f" end
        if byte == 13 then return "\\r" end
        return string.format("\\u%04x", byte)
    end)
    return '"' .. out .. '"'
end

local function json_value(value, indent, depth)
    local t = type(value)
    if value == nil then return "null" end
    if t == "boolean" then return value and "true" or "false" end
    if t == "number" then
        if value ~= value or value == math.huge or value == -math.huge then
            return "null"
        end
        return tostring(value)
    end
    if t == "string" then return json_string(value) end
    if t ~= "table" then return json_string(tostring(value)) end
    local pad = string.rep(" ", indent * (depth + 1))
    local close = string.rep(" ", indent * depth)
    local keys = {}
    local is_array = #value > 0
    if is_array then
        for _, item in ipairs(value) do
            keys[#keys + 1] = json_value(item, indent, depth + 1)
        end
        if #keys == 0 then return "[]" end
        return "[\n" .. pad .. table.concat(keys, ",\n" .. pad) .. "\n" .. close .. "]"
    end
    for key in pairs(value) do keys[#keys + 1] = tostring(key) end
    table.sort(keys)
    local parts = {}
    for _, key in ipairs(keys) do
        parts[#parts + 1] = json_string(key) .. ": " ..
            json_value(value[key], indent, depth + 1)
    end
    if #parts == 0 then return "{}" end
    return "{\n" .. pad .. table.concat(parts, ",\n" .. pad) .. "\n" .. close .. "}"
end

function pkg.json_encode(value)
    return json_value(value, 2, 0)
end

-- The store report as JSON text.
function pkg.store_report_json()
    local report = pkg.store_report()
    local plain = {
        required = report.required and true or false,
        -- The system module store, so a script can ask "is this machine complete"
        -- without reading the marker files itself.
        sys_required = report.sys_required and true or false,
        sys_present = report.sys_present and true or false,
        sys_complete = report.sys_complete and true or false,
        install_root = report.install_root,
        stores = {},
        internal = {
            root = report.internal.root,
            count = report.internal.count,
            packages = {},
        },
    }
    if report.sys_side then plain.sys_side = report.sys_side end
    if report.internal.capacity then plain.internal.capacity = report.internal.capacity end
    if report.internal.free then plain.internal.free = report.internal.free end
    for _, p in ipairs(report.internal.packages) do
        plain.internal.packages[#plain.internal.packages + 1] = {
            name = p.name, version = p.version,
        }
    end
    for _, store in ipairs(report.stores) do
        local entry = {
            side = store.side, root = store.root, count = store.count,
            -- "sys" or "store": which marker the medium carries.
            kind = store.kind,
            packages = {},
        }
        if store.capacity then entry.capacity = store.capacity end
        if store.free then entry.free = store.free end
        for _, p in ipairs(store.packages) do
            entry.packages[#entry.packages + 1] = { name = p.name, version = p.version }
        end
        plain.stores[#plain.stores + 1] = entry
    end
    return pkg.json_encode(plain)
end

-- The modem side may differ from the default, and a computer whose modem sits
-- elsewhere still works: netcfg.open() falls back to the first side that
-- carries one. A machine with no modem at all keeps the package manager
-- loadable, so "pkg" reports the failure instead of the shell refusing to
-- start.
netcfg.open()
return pkg
