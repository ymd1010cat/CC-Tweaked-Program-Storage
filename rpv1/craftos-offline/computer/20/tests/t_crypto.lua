--[[- tests/t_crypto.lua — RFC known-answer tests (the primitives everything else uses).]]
local T, M = ...

T.eq(M.hex(M.sha256("")),
    "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855", "SHA-256('')")
T.eq(M.hex(M.sha256("abc")),
    "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", "SHA-256('abc')")
T.eq(M.hex(M.sha256("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq")),
    "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1", "SHA-256(56 bytes)")

T.eq(M.hex(M.hmac_sha256(string.rep("\11", 20), "Hi There")),
    "b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7", "HMAC-SHA256 RFC4231#1")
T.eq(M.hex(M.hmac_sha256(M.unhex("0102030405060708090a0b0c0d0e0f10111213141516171819"),
        string.rep("\205", 50))),
    "82558a389a443c0ea4cc819899f2083a85f0faa3e578f8077a2e3ff46729665b", "HMAC-SHA256 RFC4231#4")

T.eq(M.hex(M.pbkdf2_sha256("password", "salt", 1, 32)),
    "120fb6cffcf8b32c43e7225256c4f837a86548c92ccc35480805987cb70be17b", "PBKDF2-HMAC-SHA256 c=1")
T.eq(M.hex(M.pbkdf2_sha256("password", "salt", 4096, 32)),
    "c5e478d59288c841aa530db6845c4c8d962893a001ce4e11a4963873aa98134a", "PBKDF2-HMAC-SHA256 c=4096")

local ikm = M.unhex("0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b")
T.eq(M.hex(M.hkdf_sha256(ikm, M.unhex("000102030405060708090a0b0c"), M.unhex("f0f1f2f3f4f5f6f7f8f9"), 42)),
    "3cb25f25faacd57a90434f64d0362f2a2d2d0a90cf1a5a4c5db02d56ecc4c5bf34007208d5b887185865",
    "HKDF-SHA256 RFC5869#1")

T.eq(M.hex(M.chacha20_block(
        M.unhex("000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f"),
        M.unhex("000000090000004a00000000"), 1)),
    "10f1e7e4d13b5915500fdd1fa32071c4c7d1f4c733c068030422aa9ac3d46c4ed2826446079faa0914c2d705d98b02a2b5129cd1de164eb9cbd083e8a2503c4e",
    "ChaCha20 RFC8439 block")

local key = M.unhex("00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff")
local nonce = M.unhex("000102030405060708090a0b")
local msg = "rpv secure frame payload"
T.eq(M.chacha20_xor(key, nonce, 1, M.chacha20_xor(key, nonce, 1, msg)), msg, "ChaCha20 round trip")
T.ok(#M.random_bytes(32) == 32, "random_bytes returns the requested length")
T.ok(M.random_bytes(16) ~= M.random_bytes(16), "random_bytes is not constant")
