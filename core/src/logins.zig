//! Decrypts and keeps the entries in logins.json.

const std = @import("std");
const sdr = @import("sdr.zig");
const keydb = @import("keydb.zig");

/// Distinguishes rows a viewer must treat differently from an ordinary saved
/// login. `account_credential`'s password is Mozilla Account sync key
/// material, not a site password; revealing it surrenders the account.
pub const Kind = enum { normal, account_credential, extension };

pub const Entry = struct {
    hostname: []const u8,
    /// Decrypted at load, since the list shows it. Empty when `legacy_3des`
    /// is true: the username is undecryptable without a 3DES implementation,
    /// which this project does not carry (see FEASIBILITY.md section 5).
    username: []const u8,
    kind: Kind,
    /// True when this entry's fields are still des_ede3_cbc, meaning
    /// Firefox 144 has never re-encrypted this profile's store. Neither the
    /// username above nor `reveal`'s password will decrypt.
    legacy_3des: bool,
    /// The base64 SDR blob, kept as-is. Decrypted only when the caller
    /// reveals this entry, so a password never exists in memory before then.
    encrypted_password: []const u8,
    time_password_changed: i64,
};

pub const ScanResult = struct {
    entries: []Entry,
    /// Sync deletion tombstones (`deleted: true`, no hostname, no encrypted
    /// fields). Skipped rather than counted as entries.
    tombstones_skipped: usize = 0,
    /// A row that is not a tombstone but is missing hostname or the
    /// encrypted fields anyway. Not expected on a real profile.
    malformed: usize = 0,
};

fn classify(hostname: []const u8) Kind {
    if (std.mem.eql(u8, hostname, "chrome://FirefoxAccounts")) return .account_credential;
    if (std.mem.startsWith(u8, hostname, "moz-extension://")) return .extension;
    return .normal;
}

/// Decrypts a base64 SDR field into `out`. Checks the cipher before asking
/// for a key, so a profile carrying only a 3DES key still reports
/// `LegacyTripleDes` instead of the unhelpful `NoSdrKey`.
fn decryptField(b64: []const u8, keys: keydb.Keys, scratch: []u8, out: []u8) ![]u8 {
    const decoder = std.base64.standard.Decoder;
    const n = try decoder.calcSizeForSlice(b64);
    if (n > scratch.len) return error.TooLarge;
    try decoder.decode(scratch[0..n], b64);

    const blob = try sdr.parse(scratch[0..n]);
    if (blob.cipher == .des_ede3_cbc) return error.LegacyTripleDes;
    const key = keys.aes256 orelse return error.NoSdrKey;
    return sdr.decrypt(blob, key, out);
}

/// Walks every entry in logins.json, decrypting each username now and
/// keeping each password's base64 blob for a later `Store.reveal`. `gpa`
/// owns the returned entries and every string they hold.
pub fn scan(gpa: std.mem.Allocator, json_bytes: []const u8, keys: keydb.Keys) !ScanResult {
    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, json_bytes, .{});
    defer parsed.deinit();

    const logins = switch (parsed.value) {
        .object => |o| (o.get("logins") orelse return error.NoLoginsArray).array,
        else => return error.NoLoginsArray,
    };

    var entries: std.ArrayList(Entry) = .empty;
    errdefer entries.deinit(gpa);

    var result: ScanResult = .{ .entries = &.{} };

    const scratch = try gpa.alloc(u8, 8192);
    defer gpa.free(scratch);
    const plain = try gpa.alloc(u8, 8192);
    defer gpa.free(plain);
    defer std.crypto.secureZero(u8, plain);

    for (logins.items) |item| {
        const obj = switch (item) {
            .object => |o| o,
            else => {
                result.malformed += 1;
                continue;
            },
        };

        if (obj.get("deleted")) |deleted| {
            if (deleted == .bool and deleted.bool) {
                result.tombstones_skipped += 1;
                continue;
            }
        }

        const hostname_v = obj.get("hostname");
        const pass_v = obj.get("encryptedPassword");
        const user_v = obj.get("encryptedUsername");
        if (hostname_v == null or pass_v == null or user_v == null) {
            result.malformed += 1;
            continue;
        }

        const hostname = switch (hostname_v.?) {
            .string => |s| s,
            else => {
                result.malformed += 1;
                continue;
            },
        };
        const encrypted_password = switch (pass_v.?) {
            .string => |s| s,
            else => {
                result.malformed += 1;
                continue;
            },
        };
        const encrypted_username = switch (user_v.?) {
            .string => |s| s,
            else => {
                result.malformed += 1;
                continue;
            },
        };

        var username: []const u8 = &.{};
        var legacy_3des = false;
        if (decryptField(encrypted_username, keys, scratch, plain)) |dec| {
            username = try gpa.dupe(u8, dec);
        } else |err| switch (err) {
            error.LegacyTripleDes => legacy_3des = true,
            else => {
                result.malformed += 1;
                continue;
            },
        }

        const time_password_changed: i64 = if (obj.get("timePasswordChanged")) |t|
            (switch (t) {
                .integer => |i| i,
                else => 0,
            })
        else
            0;

        try entries.append(gpa, .{
            .hostname = try gpa.dupe(u8, hostname),
            .username = username,
            .kind = classify(hostname),
            .legacy_3des = legacy_3des,
            .encrypted_password = try gpa.dupe(u8, encrypted_password),
            .time_password_changed = time_password_changed,
        });
    }

    result.entries = try entries.toOwnedSlice(gpa);
    return result;
}

/// Decrypts one entry's password. Never called at load time.
pub fn revealPassword(entry: Entry, keys: keydb.Keys, scratch: []u8, out: []u8) ![]u8 {
    return decryptField(entry.encrypted_password, keys, scratch, out);
}
