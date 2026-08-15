//! Decrypts the entries in logins.json.

const std = @import("std");
const sdr = @import("sdr.zig");
const keydb = @import("keydb.zig");

pub const Stats = struct {
    total: usize = 0,
    decrypted: usize = 0,
    /// Entries carrying no encrypted fields at all. Real profiles contain them.
    incomplete: usize = 0,
    legacy_3des: usize = 0,
    failed: usize = 0,
};

pub const Entry = struct {
    hostname: []const u8,
    username: []const u8,
    password: []const u8,
};

fn decryptField(b64: []const u8, keys: keydb.Keys, scratch: []u8, out: []u8) ![]u8 {
    const decoder = std.base64.standard.Decoder;
    const n = try decoder.calcSizeForSlice(b64);
    if (n > scratch.len) return error.TooLarge;
    try decoder.decode(scratch[0..n], b64);

    // Parse before requiring a key. A profile Firefox 144 has never opened
    // carries no AES-256 key at all, and every entry is des_ede3_cbc; asking
    // for keys.aes256 first would report NoSdrKey instead of the more useful
    // LegacyTripleDes on every single entry.
    const blob = try sdr.parse(scratch[0..n]);
    if (blob.cipher == .des_ede3_cbc) return error.LegacyTripleDes;
    const key = keys.aes256 orelse return error.NoSdrKey;
    return sdr.decrypt(blob, key, out);
}

/// Walks every entry and reports what happened. Plaintext is wiped before this
/// returns, so nothing leaves the function.
pub fn scan(gpa: std.mem.Allocator, json_bytes: []const u8, keys: keydb.Keys) !Stats {
    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, json_bytes, .{});
    defer parsed.deinit();

    const logins = switch (parsed.value) {
        .object => |o| (o.get("logins") orelse return error.NoLoginsArray).array,
        else => return error.NoLoginsArray,
    };

    const scratch = try gpa.alloc(u8, 8192);
    defer gpa.free(scratch);
    const plain = try gpa.alloc(u8, 8192);
    defer gpa.free(plain);
    defer std.crypto.secureZero(u8, plain);

    var stats: Stats = .{};
    for (logins.items) |item| {
        stats.total += 1;
        const obj = switch (item) {
            .object => |o| o,
            else => {
                stats.incomplete += 1;
                continue;
            },
        };

        const user = obj.get("encryptedUsername");
        const pass = obj.get("encryptedPassword");
        if (user == null or pass == null) {
            stats.incomplete += 1;
            continue;
        }

        var ok = true;
        for ([_]std.json.Value{ user.?, pass.? }) |field| {
            const b64 = switch (field) {
                .string => |s| s,
                else => {
                    ok = false;
                    break;
                },
            };
            _ = decryptField(b64, keys, scratch, plain) catch |err| {
                if (err == error.LegacyTripleDes) stats.legacy_3des += 1;
                ok = false;
                break;
            };
        }
        if (ok) stats.decrypted += 1 else stats.failed += 1;
    }
    return stats;
}
