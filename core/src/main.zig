//! Validation probe. Reports what the core managed to read from the default
//! profile and prints no credential.

const std = @import("std");
const c = @import("c");
const profiles = @import("profiles.zig");
const keydb = @import("keydb.zig");
const logins = @import("logins.zig");

pub fn main() !void {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const gpa = arena_state.allocator();

    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // std.process.Environ needs the process init block, which a plain main()
    // does not receive. libc is already linked for sqlite3.
    const home_c = c.getenv("HOME") orelse return error.NoHome;
    const home = std.mem.span(home_c);
    const firefox_dir = try std.fs.path.join(gpa, &.{ home, "Library/Application Support/Firefox" });

    const cwd = std.Io.Dir.cwd();
    const ini_path = try std.fs.path.join(gpa, &.{ firefox_dir, "profiles.ini" });
    const ini = try cwd.readFileAlloc(io, ini_path, gpa, .unlimited);

    const profile = try profiles.resolveDefault(gpa, firefox_dir, ini);
    std.debug.print("profile:   {s}\n", .{profile});

    const key4 = try std.fs.path.joinZ(gpa, &.{ profile, "key4.db" });
    const keys = try keydb.load(key4, "");
    std.debug.print("password-check verified with an empty Primary Password\n", .{});
    std.debug.print("aes256 key: {s}\n", .{if (keys.aes256 != null) "present (32 bytes)" else "absent"});
    std.debug.print("3des key:   {s}\n", .{if (keys.des3 != null) "present (24 bytes)" else "absent"});

    const logins_path = try std.fs.path.join(gpa, &.{ profile, "logins.json" });
    const json = try cwd.readFileAlloc(io, logins_path, gpa, .unlimited);

    const stats = try logins.scan(gpa, json, keys);

    std.debug.print(
        "logins:    {d} total, {d} decrypted, {d} incomplete, {d} legacy 3des, {d} failed\n",
        .{ stats.total, stats.decrypted, stats.incomplete, stats.legacy_3des, stats.failed },
    );
}
