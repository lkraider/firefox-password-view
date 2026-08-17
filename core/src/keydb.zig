//! Reads key4.db and returns the SDR master keys.

const std = @import("std");
const c = @import("c");
const pbes2 = @import("pbes2.zig");

pub const Error = error{
    OpenFailed,
    QueryFailed,
    MissingPasswordRow,
    WrongPassword,
    NoSdrKey,
} || pbes2.Error;

/// A profile can carry both keys at once. Firefox 144 adds the 32-byte key
/// and leaves the 24-byte one in place, both under the same CKA_ID. `load`
/// tells them apart by decrypted length.
pub const Keys = struct {
    aes256: ?[32]u8 = null,
    des3: ?[24]u8 = null,
};

const sdr_key_query =
    \\select a11 from nssPrivate
    \\ where a102 = x'F8000000000000000000000000000001'
    \\   and a0 = x'00000004'
    \\   and a11 is not null
;

const meta_query = "select item1, item2 from metaData where id = 'password'";

fn columnBlob(stmt: *c.sqlite3_stmt, col: c_int) []const u8 {
    const ptr = c.sqlite3_column_blob(stmt, col);
    const len: usize = @intCast(c.sqlite3_column_bytes(stmt, col));
    if (ptr == null or len == 0) return &.{};
    const bytes: [*]const u8 = @ptrCast(ptr.?);
    return bytes[0..len];
}

pub fn load(path: [:0]const u8, password: []const u8) Error!Keys {
    var db: ?*c.sqlite3 = null;
    // Read-only keeps this tool from touching a profile Firefox may be using.
    if (c.sqlite3_open_v2(path.ptr, &db, c.SQLITE_OPEN_READONLY, null) != c.SQLITE_OK) {
        _ = c.sqlite3_close(db);
        return error.OpenFailed;
    }
    defer _ = c.sqlite3_close(db);

    var global_salt_buf: [64]u8 = undefined;
    var global_salt_len: usize = 0;
    var check_buf: [256]u8 = undefined;
    var check_len: usize = 0;

    {
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(db, meta_query, -1, &stmt, null) != c.SQLITE_OK) return error.QueryFailed;
        defer _ = c.sqlite3_finalize(stmt);
        if (c.sqlite3_step(stmt) != c.SQLITE_ROW) return error.MissingPasswordRow;

        const salt = columnBlob(stmt.?, 0);
        const check = columnBlob(stmt.?, 1);
        if (salt.len > global_salt_buf.len or check.len > check_buf.len) return error.QueryFailed;
        @memcpy(global_salt_buf[0..salt.len], salt);
        @memcpy(check_buf[0..check.len], check);
        global_salt_len = salt.len;
        check_len = check.len;
    }

    const global_salt = global_salt_buf[0..global_salt_len];

    // metaData.item2 decrypts to the ASCII string "password-check". This proves
    // the password before any key material is unwrapped.
    if (check_len != 0) {
        var out: [256]u8 = undefined;
        const plain = pbes2.unwrap(check_buf[0..check_len], global_salt, password, &out) catch
            return error.WrongPassword;
        if (!std.mem.eql(u8, plain, "password-check")) return error.WrongPassword;
    }

    var keys: Keys = .{};
    {
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(db, sdr_key_query, -1, &stmt, null) != c.SQLITE_OK) return error.QueryFailed;
        defer _ = c.sqlite3_finalize(stmt);

        while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
            const wrapped = columnBlob(stmt.?, 0);
            var out: [128]u8 = undefined;
            defer std.crypto.secureZero(u8, &out);
            const plain = pbes2.unwrap(wrapped, global_salt, password, &out) catch continue;
            switch (plain.len) {
                32 => keys.aes256 = plain[0..32].*,
                24 => keys.des3 = plain[0..24].*,
                else => {},
            }
        }
    }

    if (keys.aes256 == null and keys.des3 == null) return error.NoSdrKey;
    return keys;
}
