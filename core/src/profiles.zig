//! Resolves which profile Firefox actually uses.

const std = @import("std");

pub const Error = error{NoProfileFound} || std.mem.Allocator.Error;

/// Returns the absolute profile directory. Caller owns the memory.
///
/// Since Firefox 67 the `[InstallXXXX]` section names the profile for a given
/// installation and `Default=1` under `[ProfileN]` is only the pre-67 fallback.
/// Reading `Default=1` first selects an abandoned profile on machines that have
/// one.
pub fn resolveDefault(gpa: std.mem.Allocator, firefox_dir: []const u8, ini: []const u8) Error![]u8 {
    var install_path: ?[]const u8 = null;
    var legacy_path: ?[]const u8 = null;

    var section: []const u8 = "";
    var current_path: ?[]const u8 = null;
    var current_default = false;

    var lines = std.mem.splitScalar(u8, ini, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) continue;

        if (line[0] == '[') {
            if (std.mem.startsWith(u8, section, "Profile") and current_default) {
                if (current_path) |p| legacy_path = p;
            }
            section = std.mem.trim(u8, line[1 .. line.len - 1], "]");
            current_path = null;
            current_default = false;
            continue;
        }

        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = std.mem.trim(u8, line[0..eq], " \t");
        const value = std.mem.trim(u8, line[eq + 1 ..], " \t");

        if (std.mem.startsWith(u8, section, "Install")) {
            if (std.mem.eql(u8, key, "Default")) install_path = value;
        } else if (std.mem.startsWith(u8, section, "Profile")) {
            if (std.mem.eql(u8, key, "Path")) current_path = value;
            if (std.mem.eql(u8, key, "Default") and std.mem.eql(u8, value, "1")) current_default = true;
        }
    }
    if (std.mem.startsWith(u8, section, "Profile") and current_default) {
        if (current_path) |p| legacy_path = p;
    }

    const rel = install_path orelse legacy_path orelse return error.NoProfileFound;
    if (rel.len > 0 and rel[0] == '/') return gpa.dupe(u8, rel);
    return std.fs.path.join(gpa, &.{ firefox_dir, rel });
}

test "install section wins over the legacy Default flag" {
    const ini =
        \\[Profile1]
        \\Name=default
        \\IsRelative=1
        \\Path=Profiles/abandoned.default
        \\Default=1
        \\
        \\[Profile0]
        \\Name=default-release
        \\IsRelative=1
        \\Path=Profiles/real.default-release
        \\
        \\[Install2656FF1E876E9973]
        \\Default=Profiles/real.default-release
        \\Locked=1
    ;
    const got = try resolveDefault(std.testing.allocator, "/ff", ini);
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualStrings("/ff/Profiles/real.default-release", got);
}

test "falls back to Default=1 when no install section exists" {
    const ini =
        \\[Profile0]
        \\Path=Profiles/only.default
        \\Default=1
    ;
    const got = try resolveDefault(std.testing.allocator, "/ff", ini);
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualStrings("/ff/Profiles/only.default", got);
}
