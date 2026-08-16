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

pub const Profile = struct {
    /// The `Name` key. Empty if a section carried none.
    name: []const u8,
    /// Absolute, resolved the same way `resolveDefault` resolves one.
    path: []const u8,
};

fn resolvePath(gpa: std.mem.Allocator, firefox_dir: []const u8, rel: []const u8) std.mem.Allocator.Error![]u8 {
    if (rel.len > 0 and rel[0] == '/') return gpa.dupe(u8, rel);
    return std.fs.path.join(gpa, &.{ firefox_dir, rel });
}

/// Every `[ProfileN]` section in profiles.ini, in file order. A test machine
/// can carry a profile with no key4.db at all (an abandoned pre-migration
/// profile), so a viewer that only ever opens `resolveDefault`'s pick cannot
/// explain what it is showing; this lets a front end offer the rest.
pub fn enumerate(gpa: std.mem.Allocator, firefox_dir: []const u8, ini: []const u8) std.mem.Allocator.Error![]Profile {
    var profiles: std.ArrayList(Profile) = .empty;
    errdefer {
        for (profiles.items) |p| {
            gpa.free(p.name);
            gpa.free(p.path);
        }
        profiles.deinit(gpa);
    }

    var section: []const u8 = "";
    var current_name: []const u8 = "";
    var current_path: ?[]const u8 = null;

    var lines = std.mem.splitScalar(u8, ini, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) continue;

        if (line[0] == '[') {
            if (std.mem.startsWith(u8, section, "Profile")) {
                if (current_path) |p| {
                    try profiles.append(gpa, .{
                        .name = try gpa.dupe(u8, current_name),
                        .path = try resolvePath(gpa, firefox_dir, p),
                    });
                }
            }
            section = std.mem.trim(u8, line[1 .. line.len - 1], "]");
            current_name = "";
            current_path = null;
            continue;
        }

        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = std.mem.trim(u8, line[0..eq], " \t");
        const value = std.mem.trim(u8, line[eq + 1 ..], " \t");

        if (std.mem.startsWith(u8, section, "Profile")) {
            if (std.mem.eql(u8, key, "Name")) current_name = value;
            if (std.mem.eql(u8, key, "Path")) current_path = value;
        }
    }
    if (std.mem.startsWith(u8, section, "Profile")) {
        if (current_path) |p| {
            try profiles.append(gpa, .{
                .name = try gpa.dupe(u8, current_name),
                .path = try resolvePath(gpa, firefox_dir, p),
            });
        }
    }

    return profiles.toOwnedSlice(gpa);
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

test "enumerate lists every Profile section, including one Default does not pick" {
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
    const got = try enumerate(std.testing.allocator, "/ff", ini);
    defer {
        for (got) |p| {
            std.testing.allocator.free(p.name);
            std.testing.allocator.free(p.path);
        }
        std.testing.allocator.free(got);
    }

    try std.testing.expectEqual(@as(usize, 2), got.len);
    try std.testing.expectEqualStrings("default", got[0].name);
    try std.testing.expectEqualStrings("/ff/Profiles/abandoned.default", got[0].path);
    try std.testing.expectEqualStrings("default-release", got[1].name);
    try std.testing.expectEqualStrings("/ff/Profiles/real.default-release", got[1].path);
}

test "enumerate returns an empty slice for an ini with no Profile sections" {
    const got = try enumerate(std.testing.allocator, "/ff", "[General]\nVersion=2\n");
    defer std.testing.allocator.free(got);
    try std.testing.expectEqual(@as(usize, 0), got.len);
}
