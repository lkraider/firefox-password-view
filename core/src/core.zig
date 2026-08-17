//! Exports the C ABI declared in core/include/ffpw.h. Swift and C link
//! against this file. The TUI imports store.zig directly and uses none of
//! it.

const std = @import("std");
const c = @import("c");
const profiles = @import("profiles.zig");
const store_mod = @import("store.zig");
const logins = @import("logins.zig");

const ffpw_status = enum(c_int) {
    ok = 0,
    err_no_profile,
    err_open,
    err_needs_password,
    err_wrong_password,
    err_legacy_3des,
    err_oom,
    err_io,
    err_range,
};

const ffpw_entry = extern struct {
    hostname: ?[*]const u8,
    hostname_len: usize,
    username: ?[*]const u8,
    username_len: usize,
    time_password_changed: i64,
    flags: u32,
};

const flag_account_credential: u32 = 1 << 0;
const flag_extension: u32 = 1 << 1;

/// The opaque ffpw_store. Wraps a Zig Store plus everything it needs before
/// one exists: its own allocator and Io, and the profile path, so ffpw_open
/// can hand back a handle even when a Primary Password is still needed.
const CStore = struct {
    gpa: std.mem.Allocator,
    threaded: std.Io.Threaded,
    profile_path: []u8,
    store: ?store_mod.Store = null,
};

/// mem.Allocator.free ignores the length it is given for this allocator
/// specifically. It frees by pointer, through libc free(). So ffpw_reveal
/// and ffpw_secret_free can hand a caller a shorter length than the store's
/// own arena allocations, and the allocation still frees intact.
const gpa = std.heap.c_allocator;

/// ffpw_open's first attempt always uses an empty password. WrongPassword
/// there means the profile has a Primary Password of its own. No caller
/// supplied one yet.
fn mapOpenError(err: anyerror) ffpw_status {
    return switch (err) {
        error.WrongPassword => .err_needs_password,
        else => mapCommonError(err),
    };
}

/// ffpw_unlock's password came from the caller, so WrongPassword here means
/// that password was wrong.
fn mapUnlockError(err: anyerror) ffpw_status {
    return switch (err) {
        error.WrongPassword => .err_wrong_password,
        else => mapCommonError(err),
    };
}

fn mapCommonError(err: anyerror) ffpw_status {
    return switch (err) {
        error.OpenFailed => .err_no_profile,
        error.OutOfMemory => .err_oom,
        error.MissingPasswordRow, error.QueryFailed, error.NoSdrKey, error.NoLoginsArray => .err_open,
        else => .err_io,
    };
}

fn resolveFirefoxDir() ![]u8 {
    const home_c = c.getenv("HOME") orelse return error.NoHome;
    const home = std.mem.span(home_c);
    return std.fs.path.join(gpa, &.{ home, "Library/Application Support/Firefox" });
}

/// Reads profiles.ini fresh and enumerates it. The caller frees the result
/// with `freeProfileList`.
fn listProfiles(io: std.Io) ![]profiles.Profile {
    const firefox_dir = try resolveFirefoxDir();
    defer gpa.free(firefox_dir);

    const cwd = std.Io.Dir.cwd();
    const ini_path = try std.fs.path.join(gpa, &.{ firefox_dir, "profiles.ini" });
    defer gpa.free(ini_path);
    const ini = try cwd.readFileAlloc(io, ini_path, gpa, .unlimited);
    defer gpa.free(ini);

    return profiles.enumerate(gpa, firefox_dir, ini);
}

fn freeProfileList(list: []profiles.Profile) void {
    for (list) |p| {
        gpa.free(p.name);
        gpa.free(p.path);
    }
    gpa.free(list);
}

export fn ffpw_profile_count() callconv(.c) usize {
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();

    const list = listProfiles(threaded.io()) catch return 0;
    defer freeProfileList(list);
    return list.len;
}

export fn ffpw_profile_at(i: u32, buf: ?[*]u8, cap: usize, needed: ?*usize) callconv(.c) ffpw_status {
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();

    const list = listProfiles(threaded.io()) catch return .err_io;
    defer freeProfileList(list);

    if (i >= list.len) return .err_range;
    const path = list[i].path;
    if (needed) |n| n.* = path.len;
    if (buf) |b| {
        const n = @min(cap, path.len);
        @memcpy(b[0..n], path[0..n]);
    }
    return .ok;
}

export fn ffpw_open(profile_path_c: ?[*:0]const u8, out: ?*?*CStore) callconv(.c) ffpw_status {
    const out_ptr = out orelse return .err_range;
    const profile_path_z = profile_path_c orelse return .err_no_profile;
    const profile_path = std.mem.span(profile_path_z);

    const cstore = gpa.create(CStore) catch return .err_oom;
    const path_copy = gpa.dupe(u8, profile_path) catch {
        gpa.destroy(cstore);
        return .err_oom;
    };
    cstore.* = .{
        .gpa = gpa,
        .threaded = .init(gpa, .{}),
        .profile_path = path_copy,
    };

    const io = cstore.threaded.io();
    const opened = store_mod.Store.open(gpa, io, cstore.profile_path, "") catch |err| {
        const status = mapOpenError(err);
        if (status == .err_needs_password) {
            // Still a live handle: the caller must supply the real Primary
            // Password through ffpw_unlock, then release it with
            // ffpw_close either way.
            out_ptr.* = cstore;
        } else {
            gpa.free(cstore.profile_path);
            cstore.threaded.deinit();
            gpa.destroy(cstore);
            out_ptr.* = null;
        }
        return status;
    };
    cstore.store = opened;
    out_ptr.* = cstore;
    return .ok;
}

export fn ffpw_unlock(handle: ?*CStore, pw: ?[*]const u8, pw_len: usize) callconv(.c) ffpw_status {
    const cstore = handle orelse return .err_range;
    if (cstore.store != null) return .ok;
    const password = if (pw) |p| p[0..pw_len] else "";
    const io = cstore.threaded.io();
    const opened = store_mod.Store.open(cstore.gpa, io, cstore.profile_path, password) catch |err| return mapUnlockError(err);
    cstore.store = opened;
    return .ok;
}

export fn ffpw_close(handle: ?*CStore) callconv(.c) void {
    const cstore = handle orelse return;
    if (cstore.store) |*s| s.deinit();
    cstore.threaded.deinit();
    cstore.gpa.free(cstore.profile_path);
    cstore.gpa.destroy(cstore);
}

export fn ffpw_count(handle: ?*CStore) callconv(.c) usize {
    const cstore = handle orelse return 0;
    const s = cstore.store orelse return 0;
    return s.entries.len;
}

export fn ffpw_search(handle: ?*CStore, q: ?[*]const u8, q_len: usize, out: ?[*]u32, cap: usize) callconv(.c) usize {
    const cstore = handle orelse return 0;
    const s = &(cstore.store orelse return 0);
    const query = if (q) |p| p[0..q_len] else &[_]u8{};

    const tmp = cstore.gpa.alloc(usize, cap) catch return 0;
    defer cstore.gpa.free(tmp);
    const total = s.search(query, tmp);
    if (out) |o| {
        const n = @min(total, cap);
        for (tmp[0..n], 0..) |idx, i| o[i] = @intCast(idx);
    }
    return total;
}

fn flagsFor(kind: logins.Kind) u32 {
    return switch (kind) {
        .account_credential => flag_account_credential,
        .extension => flag_extension,
        .normal => 0,
    };
}

fn toFFPWEntry(e: logins.Entry) ffpw_entry {
    return .{
        .hostname = e.hostname.ptr,
        .hostname_len = e.hostname.len,
        .username = e.username.ptr,
        .username_len = e.username.len,
        .time_password_changed = e.time_password_changed,
        .flags = flagsFor(e.kind),
    };
}

export fn ffpw_entry_at(handle: ?*CStore, i: u32, out: ?*ffpw_entry) callconv(.c) ffpw_status {
    const cstore = handle orelse return .err_range;
    const s = cstore.store orelse return .err_needs_password;
    if (i >= s.entries.len) return .err_range;
    const o = out orelse return .err_range;
    o.* = toFFPWEntry(s.entries[i]);
    return .ok;
}

/// Hostnames and usernames are already decrypted by the time `ffpw_open`
/// or `ffpw_unlock` returns. This costs one struct copy per entry, and it
/// fills a whole list in one call. One call per row is the alternative.
export fn ffpw_entries(handle: ?*CStore, out: ?[*]ffpw_entry, cap: usize) callconv(.c) usize {
    const cstore = handle orelse return 0;
    const s = cstore.store orelse return 0;
    if (out) |o| {
        const n = @min(cap, s.entries.len);
        for (s.entries[0..n], 0..) |e, i| o[i] = toFFPWEntry(e);
    }
    return s.entries.len;
}

export fn ffpw_reveal(handle: ?*CStore, i: u32, out: ?*?[*]u8, len: ?*usize) callconv(.c) ffpw_status {
    const cstore = handle orelse return .err_range;
    const s = cstore.store orelse return .err_needs_password;
    if (i >= s.entries.len) return .err_range;
    const out_ptr = out orelse return .err_range;
    const len_ptr = len orelse return .err_range;

    var scratch: [8192]u8 = undefined;
    defer std.crypto.secureZero(u8, &scratch);
    var decrypted: [8192]u8 = undefined;
    defer std.crypto.secureZero(u8, &decrypted);

    const plain = logins.revealPassword(s.entries[i], s.keys, &scratch, &decrypted) catch |err| {
        return switch (err) {
            error.LegacyTripleDes => .err_legacy_3des,
            else => .err_open,
        };
    };

    // Sized to exactly plain.len. A caller that later frees exactly len
    // bytes then wipes every byte of the allocation.
    const owned = cstore.gpa.alloc(u8, plain.len) catch return .err_oom;
    @memcpy(owned, plain);
    out_ptr.* = owned.ptr;
    len_ptr.* = owned.len;
    return .ok;
}

export fn ffpw_secret_free(handle: ?*CStore, buf: ?[*]u8, len: usize) callconv(.c) void {
    const cstore = handle orelse return;
    const b = buf orelse return;
    if (len == 0) return;
    const slice = b[0..len];
    std.crypto.secureZero(u8, slice);
    cstore.gpa.free(slice);
}
