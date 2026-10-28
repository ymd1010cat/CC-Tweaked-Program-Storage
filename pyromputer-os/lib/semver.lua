-- semver.lua - semantic version parsing and comparison
--
-- Supports the subset of semver the package repository needs:
--   MAJOR.MINOR.PATCH[-PRERELEASE][+BUILD]
-- Missing components count as zero ("1.2" == "1.2.0"), which keeps the older
-- repository entries written as "1.0" usable next to full versions.
--
-- Precedence follows the specification: a version with a pre-release tag is
-- lower than the same version without one, and pre-release identifiers are
-- compared identifier by identifier, numerically when both are numeric.

local semver = {}

local function split_identifiers(text)
    local parts = {}
    if text == nil or text == "" then return parts end
    for part in tostring(text):gmatch("[^%.]+") do
        table.insert(parts, part)
    end
    return parts
end

local function is_numeric(text)
    return tostring(text):match("^%d+$") ~= nil
end

-- Parse a version string. Returns a table, or nil plus a reason.
function semver.parse(text)
    if type(text) ~= "string" then return nil, "version is not a string" end
    local body = text:match("^%s*(.-)%s*$")
    if body == "" then return nil, "empty version" end

    local core, build = body:match("^([^%+]*)+(.+)$")
    if not core then core, build = body, nil end
    local main, pre = core:match("^([^%-]*)-(.+)$")
    if not main then main, pre = core, nil end

    local major, minor, patch, rest = main:match("^(%d+)%.(%d+)%.(%d+)(.*)$")
    if not major then
        major, minor, rest = main:match("^(%d+)%.(%d+)(.*)$")
        patch = patch or "0"
    end
    if not major then
        major, rest = main:match("^(%d+)(.*)$")
        minor, patch = minor or "0", patch or "0"
    end
    if not major or rest ~= "" then
        return nil, "malformed version: " .. text
    end

    return {
        raw  = body,
        major = tonumber(major),
        minor = tonumber(minor),
        patch = tonumber(patch),
        pre  = pre and split_identifiers(pre) or nil,
        build = build,
    }
end

function semver.is_valid(text)
    return semver.parse(text) ~= nil
end

-- Compare two parsed versions, or two strings (which are parsed on the fly).
-- Returns -1, 0 or 1, or nil plus a reason when a string cannot be parsed.
function semver.compare(a, b)
    if type(a) == "string" then
        local err
        a, err = semver.parse(a)
        if not a then return nil, err end
    end
    if type(b) == "string" then
        local err
        b, err = semver.parse(b)
        if not b then return nil, err end
    end
    if type(a) ~= "table" or type(b) ~= "table" then
        return nil, "compare expects version tables or strings"
    end

    for _, field in ipairs({ "major", "minor", "patch" }) do
        -- A missing field means zero, so a stored "1.0" compares equal to
        -- "1.0.0" instead of failing.
        local av, bv = a[field] or 0, b[field] or 0
        if av ~= bv then return av < bv and -1 or 1 end
    end

    local ap, bp = a.pre, b.pre
    local a_has, b_has = ap ~= nil and #ap > 0, bp ~= nil and #bp > 0
    if a_has and not b_has then return -1 end
    if b_has and not a_has then return 1 end
    if not a_has and not b_has then return 0 end

    for i = 1, math.max(#ap, #bp) do
        local ai, bi = ap[i], bp[i]
        if ai == nil then return -1 end
        if bi == nil then return 1 end
        if ai ~= bi then
            local an, bn = is_numeric(ai), is_numeric(bi)
            if an and bn then
                local av, bv = tonumber(ai), tonumber(bi)
                if av ~= bv then return av < bv and -1 or 1 end
            elseif an then
                return -1          -- numeric identifiers rank below alphanumeric
            elseif bn then
                return 1
            else
                return ai < bi and -1 or 1
            end
        end
    end
    return 0
end

function semver.equal(a, b)
    local result = semver.compare(a, b)
    return result == 0
end

function semver.lt(a, b) return semver.compare(a, b) == -1 end
function semver.gt(a, b) return semver.compare(a, b) == 1 end

-- True when "candidate" is strictly newer than "current". An unparsable side
-- counts as older, which makes a repository entry with a newer, well formed
-- version upgradeable while a local manifest without a version is refreshed.
function semver.is_newer(candidate, current)
    local ok_c = semver.parse(candidate)
    if not ok_c then return false end
    if current == nil or current == "" then return true end
    local ok_u = semver.parse(current)
    if not ok_u then return true end
    return semver.compare(candidate, current) == 1
end

-- Highest version first; entries without a parsable version go last.
function semver.sort_desc(list, key)
    local pick = key or function(entry) return entry end
    table.sort(list, function(a, b)
        local av, bv = semver.parse(pick(a)), semver.parse(pick(b))
        if not av then return false end
        if not bv then return true end
        return semver.compare(av, bv) == 1
    end)
    return list
end

function semver.tostring(v)
    if type(v) == "string" then return v end
    if type(v) ~= "table" then return nil end
    if v.raw then return v.raw end
    local out = string.format("%d.%d.%d", v.major or 0, v.minor or 0, v.patch or 0)
    if v.pre and #v.pre > 0 then out = out .. "-" .. table.concat(v.pre, ".") end
    if v.build then out = out .. "+" .. v.build end
    return out
end

return semver
