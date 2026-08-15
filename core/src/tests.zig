const std = @import("std");
const testing = std.testing;

const der = @import("der.zig");
const oids = @import("oids.zig");
const aescbc = @import("aescbc.zig");
const pbes2 = @import("pbes2.zig");
const sdr = @import("sdr.zig");

test {
    _ = @import("profiles.zig");
}

fn hex(comptime s: []const u8) [s.len / 2]u8 {
    var out: [s.len / 2]u8 = undefined;
    _ = std.fmt.hexToBytes(&out, s) catch unreachable;
    return out;
}

test "aes-256-cbc matches NIST SP 800-38A F.2.6" {
    const key = hex("603deb1015ca71be2b73aef0857d77811f352c073b6108d72d9810a30914dff4");
    const iv = hex("000102030405060708090a0b0c0d0e0f");
    const ct = hex("f58c4c04d6e5f1ba779eabfb5f7bfbd6" ++ "9cfc4e967edb808d679f777bc6702c7d");
    const want = hex("6bc1bee22e409f96e93d7e117393172a" ++ "ae2d8a571e03ac9c9eb76fac45af8e51");

    var out: [32]u8 = undefined;
    try aescbc.decryptRaw(&out, &ct, key, iv);
    try testing.expectEqualSlices(u8, &want, &out);
}

test "pkcs7 padding is stripped and validated" {
    const key = hex("603deb1015ca71be2b73aef0857d77811f352c073b6108d72d9810a30914dff4");
    const iv = hex("000102030405060708090a0b0c0d0e0f");
    // "hi" padded with 14 bytes of 0x0e, encrypted under the key and iv above.
    const ct = hex("3bc29a16024812f18539438a650d4acd");

    var out: [16]u8 = undefined;
    const plain = try aescbc.decrypt(&out, &ct, key, iv);
    try testing.expectEqualStrings("hi", plain);

    // A wrong key yields padding that does not validate.
    var bad_key = key;
    bad_key[0] ^= 1;
    try testing.expectError(error.BadPadding, aescbc.decrypt(&out, &ct, bad_key, iv));
}

test "der reader walks a nested sequence" {
    // SEQUENCE { INTEGER 1, OCTET STRING "ab", OID 1.2.840.113549.2.9 }
    const buf = hex("3011" ++ "020101" ++ "04026162" ++ "06082a864886f70d0209");
    var top = der.Reader.init(&buf);
    var s = try top.seq();
    try testing.expectEqual(@as(u32, 1), try s.int());
    try testing.expectEqualStrings("ab", try s.octetString());
    try testing.expect(oids.eql(try s.oid(), &oids.hmac_sha256));
    try testing.expect(s.atEnd());
}

test "der reader rejects a length that runs past the buffer" {
    // SEQUENCE claiming 16 contents octets with only 2 present.
    const buf = hex("30106162");
    var top = der.Reader.init(&buf);
    try testing.expectError(error.Truncated, top.seq());
}

test "der reader rejects the indefinite length form" {
    const buf = hex("3080020101");
    var top = der.Reader.init(&buf);
    try testing.expectError(error.UnsupportedLength, top.seq());
}

test "der reader rejects a truncated header" {
    const buf = [_]u8{0x30};
    var top = der.Reader.init(&buf);
    try testing.expectError(error.Truncated, top.seq());
}

test "sdr blob parses key id, cipher and iv" {
    // SEQUENCE { OCTET STRING (key id),
    //            SEQUENCE { OID aes256-CBC, OCTET STRING (iv) },
    //            OCTET STRING (ciphertext) }
    const buf = hex("30430410f8000000000000000000000000000001" ++
        "301d060960864801650304012a" ++
        "0410000102030405060708090a0b0c0d0e0f" ++
        "0410aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa");

    const blob = try sdr.parse(&buf);
    try testing.expectEqualSlices(u8, &sdr.sdr_key_id, blob.key_id);
    try testing.expectEqual(oids.Cipher.aes256_cbc, blob.cipher);
    try testing.expectEqual(@as(usize, 16), blob.iv.len);
    try testing.expectEqual(@as(usize, 16), blob.ciphertext.len);
}

test "a 3des entry reports the migration error rather than decrypting" {
    // Same shape with the des-ede3-cbc OID and an 8-byte IV.
    const buf = hex("303a0410f8000000000000000000000000000001" ++
        "3014" ++ "06082a864886f70d0307" ++ "04080001020304050607" ++
        "0410aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa");

    const blob = try sdr.parse(&buf);
    try testing.expectEqual(oids.Cipher.des_ede3_cbc, blob.cipher);

    var out: [16]u8 = undefined;
    try testing.expectError(error.LegacyTripleDes, sdr.decrypt(blob, @splat(0), &out));
}

test "pbes2 rejects a scheme it does not implement" {
    // AlgorithmIdentifier carrying the legacy PBE-SHA1-3DES OID.
    const buf = hex("3013" ++ "300f" ++ "060b2a864886f70d010c050103" ++ "0400" ++ "0400");
    try testing.expectError(error.UnsupportedScheme, pbes2.parse(&buf));
}
