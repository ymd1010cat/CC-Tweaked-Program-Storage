-- t_sha256.lua -- known-answer vectors for common/sha256.lua.
-- Reference digests computed with an independent implementation.

local function run(H)
    H.group("sha256")
    local sha = dofile("/sha256.lua")

    local vectors = {
        {
            name = "empty",
            msg = "",
            hex = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
        },
        {
            name = "abc",
            msg = "abc",
            hex = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
        },
        {
            name = "fox",
            msg = "The quick brown fox jumps over the lazy dog",
            hex = "d7a8fbb307d7809469ca9abcb0082e4f8d5651e46d3cdb762d02d0bf37c9e592",
        },
        {
            name = "fox_dot",
            msg = "The quick brown fox jumps over the lazy dog.",
            hex = "ef537f25c895bfa782526529a9b63d97aa631564d5d789c2b765448c8635fb6c",
        },
        {
            name = "two_blocks",
            msg = "abcdefghbcdefghicdefghijdefghijkefghijklfghijklmghijklmnhijklmnoijklmnopjklmnopqklmnopqrlmnopqrsmnopqrstnopqrstu",
            hex = "cf5b16a778af8380036ce59e7b0492370b249b11e8f07a51afac45037afee9d1",
        },
        {
            name = "len55",
            msg = string.rep("a", 55),
            hex = "9f4390f8d30c2dd92ec9f095b65e2b9ae9b0a925a5258e241c9f1e910f734318",
        },
        {
            name = "len56",
            msg = string.rep("a", 56),
            hex = "b35439a4ac6f0948b6d6f9e3c6af0f5f590ce20f1bde7090ef7970686ec6738a",
        },
        {
            name = "len64",
            msg = string.rep("a", 64),
            hex = "ffe054fe7ae0cb6dc65c3af9b61d5209f439851db43d0ba5997337df154668eb",
        },
        {
            name = "len200",
            msg = string.rep("0123456789", 20),
            hex = "295cbb667c2d2380418d4c7576c666c4f1690de2a2433f0e301bd5923377f8ed",
        },
        {
            name = "len1000",
            msg = string.rep("a", 1000),
            hex = "41edece42d63e8d9bf515a9ba6932e1c20cbc9f5a5d134645adb5db1b9737ea3",
        },
    }

    for _, v in ipairs(vectors) do
        local got = sha.hash(v.msg)
        H.check("sha256." .. v.name, got == v.hex, got)
    end

    H.check("sha256.hash_is_hex64",
        sha.hash("abc"):match("^[0-9a-f]+$") ~= nil and #sha.hash("abc") == 64)
    H.check("sha256.digest_is_32_bytes", #sha.digest("abc") == 32)

    local raw = sha.digest("abc")
    local hex = {}
    for i = 1, #raw do
        hex[i] = string.format("%02x", raw:byte(i))
    end
    H.check("sha256.digest_matches_hash", table.concat(hex) == sha.hash("abc"))

    H.check("sha256.differs_on_last_byte", sha.hash("abc") ~= sha.hash("abd"))
    H.check("sha256.empty_differs_from_space", sha.hash("") ~= sha.hash(" "))
    H.check("sha256.repeatable", sha.hash("repeat") == sha.hash("repeat"))
end

return run
