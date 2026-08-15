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

test "pbes2 seeds with SHA384 when the global salt is 48 bytes" {
    // Captured from a real Firefox 152 profile after setting a synthetic
    // Primary Password ("fixture-primary-password-1"). A never-initialized
    // token carries a 20-byte SHA1-length global salt; setting a Primary
    // Password for the first time replaces it with this 48-byte SHA384-length
    // one, and NSS seeds with SHA384 instead of SHA1 to match. Getting this
    // wrong makes the correct password look wrong (regression: it did).
    const global_salt = hex("661C366FD887564582212421FC6E1388A4F37714EFA99166B3AE3D767079E607" ++
        "6FFA02718064165695084DAE22EDB6E9");
    const item2 = hex("308182306E06092A864886F70D01050D3061304206092A864886F70D01050C30" ++
        "35042087E7510D9573FAC37B76B335B4404A3B8C088B1A7B80AA01FCA56A3F87" ++
        "FBB7D702022710020120300A06082A864886F70D0209301B0609608648016503" ++
        "04012A040E9C99693DDEF51F20FE260E1FD5790410155C6C52F21267D0E27A5E" ++
        "64315CB340");

    var out: [256]u8 = undefined;
    const plain = try pbes2.unwrap(&item2, &global_salt, "fixture-primary-password-1", &out);
    try testing.expectEqualStrings("password-check", plain);

    try testing.expectError(
        error.BadPadding,
        pbes2.unwrap(&item2, &global_salt, "wrong-password", &out),
    );
}

test "pbes2 rejects a scheme it does not implement" {
    // AlgorithmIdentifier carrying the legacy PBE-SHA1-3DES OID.
    const buf = hex("3013" ++ "300f" ++ "060b2a864886f70d010c050103" ++ "0400" ++ "0400");
    try testing.expectError(error.UnsupportedScheme, pbes2.parse(&buf));
}

// Fixtures are written by real Firefox over Marionette, never by this
// project's own reading of the format. See tools/mkfixtures.py. A real
// profile dropped into core/testdata by mistake fails these loudly: it
// was never unlocked with these documented passwords.

fn readFixtureLogins(gpa: std.mem.Allocator, path: []const u8) ![]u8 {
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    return std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .unlimited);
}

test "the fresh fixture decrypts every entry with an empty Primary Password" {
    const keydb = @import("keydb.zig");
    const logins = @import("logins.zig");
    const json = try readFixtureLogins(testing.allocator, "core/testdata/fresh/logins.json");
    defer testing.allocator.free(json);

    const keys = try keydb.load("core/testdata/fresh/key4.db", "");
    const stats = try logins.scan(testing.allocator, json, keys);
    try testing.expectEqual(@as(usize, 3), stats.total);
    try testing.expectEqual(@as(usize, 3), stats.decrypted);
    try testing.expectEqual(@as(usize, 0), stats.failed);
}

test "the primary fixture needs its documented Primary Password" {
    const keydb = @import("keydb.zig");
    const logins = @import("logins.zig");
    const json = try readFixtureLogins(testing.allocator, "core/testdata/primary/logins.json");
    defer testing.allocator.free(json);

    try testing.expectError(error.WrongPassword, keydb.load("core/testdata/primary/key4.db", ""));
    try testing.expectError(error.WrongPassword, keydb.load("core/testdata/primary/key4.db", "wrong"));

    const keys = try keydb.load("core/testdata/primary/key4.db", "fixture-primary-password-1");
    const stats = try logins.scan(testing.allocator, json, keys);
    try testing.expectEqual(@as(usize, 3), stats.total);
    try testing.expectEqual(@as(usize, 3), stats.decrypted);
    try testing.expectEqual(@as(usize, 0), stats.failed);
}

test "two-profiles resolves to the profile the install section names, not Default=1" {
    const profiles = @import("profiles.zig");
    const keydb = @import("keydb.zig");
    const firefox_dir = "core/testdata/two-profiles";

    const ini = try readFixtureLogins(testing.allocator, firefox_dir ++ "/profiles.ini");
    defer testing.allocator.free(ini);

    const profile = try profiles.resolveDefault(testing.allocator, firefox_dir, ini);
    defer testing.allocator.free(profile);
    try testing.expectEqualStrings(firefox_dir ++ "/Profiles/real.default-release", profile);

    const key4 = try std.fmt.allocPrintSentinel(testing.allocator, "{s}/key4.db", .{profile}, 0);
    defer testing.allocator.free(key4);
    _ = try keydb.load(key4, "");
}
