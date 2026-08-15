//! Encoded OID bodies, without the identifier and length octets, so they compare
//! directly against der.Reader.oid() output.

const std = @import("std");

/// 1.2.840.113549.1.5.13
pub const pbes2 = [_]u8{ 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x05, 0x0d };
/// 1.2.840.113549.1.5.12
pub const pbkdf2 = [_]u8{ 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x05, 0x0c };
/// 1.2.840.113549.2.7
pub const hmac_sha1 = [_]u8{ 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x02, 0x07 };
/// 1.2.840.113549.2.9
pub const hmac_sha256 = [_]u8{ 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x02, 0x09 };
/// 2.16.840.1.101.3.4.1.42
pub const aes256_cbc = [_]u8{ 0x60, 0x86, 0x48, 0x01, 0x65, 0x03, 0x04, 0x01, 0x2a };
/// 1.2.840.113549.3.7
pub const des_ede3_cbc = [_]u8{ 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x03, 0x07 };
/// 1.2.840.113549.1.12.5.1.3
pub const pbe_sha1_3des = [_]u8{ 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x0c, 0x05, 0x01, 0x03 };

pub fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

/// Cipher used for a single value. Firefox 144 migrated existing stores to
/// aes256_cbc; des_ede3_cbc appears only in profiles that version has not opened.
pub const Cipher = enum {
    aes256_cbc,
    des_ede3_cbc,

    pub fn fromOid(o: []const u8) ?Cipher {
        if (eql(o, &aes256_cbc)) return .aes256_cbc;
        if (eql(o, &des_ede3_cbc)) return .des_ede3_cbc;
        return null;
    }

    pub fn keyLen(c: Cipher) usize {
        return switch (c) {
            .aes256_cbc => 32,
            .des_ede3_cbc => 24,
        };
    }
};
