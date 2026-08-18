//! Resolves which profile Firefox opens.

const std = @import("std");

pub const Error = error{NoProfileFound} || std.mem.Allocator.Error;

const KeyValue = struct { key: []const u8, value: []const u8 };
const Section = struct { name: []const u8, fields: []const KeyValue };

/// Splits `ini` into sections, in file order. Every string in the result
/// points into `ini`, so the result dies with it. The caller frees each
/// section's `fields` and the returned slice, both with `gpa`.
fn parseSections(gpa: std.mem.Allocator, ini: []const u8) std.mem.Allocator.Error![]Section {
    var sections: std.ArrayList(Section) = .empty;
    errdefer {
        for (sections.items) |s| gpa.free(s.fields);
        sections.deinit(gpa);
    }

    var name: []const u8 = "";
    var fields: std.ArrayList(KeyValue) = .empty;
    errdefer fields.deinit(gpa);

    var lines = std.mem.splitScalar(u8, ini, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) continue;

        if (line[0] == '[') {
            try sections.append(gpa, .{ .name = name, .fields = try fields.toOwnedSlice(gpa) });
            name = std.mem.trim(u8, line[1 .. line.len - 1], "]");
            continue;
        }

        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        try fields.append(gpa, .{
            .key = std.mem.trim(u8, line[0..eq], " \t"),
            .value = std.mem.trim(u8, line[eq + 1 ..], " \t"),
        });
    }
    try sections.append(gpa, .{ .name = name, .fields = try fields.toOwnedSlice(gpa) });

    return sections.toOwnedSlice(gpa);
}

fn freeSections(gpa: std.mem.Allocator, sections: []const Section) void {
    for (sections) |s| gpa.free(s.fields);
    gpa.free(sections);
}

fn resolvePath(gpa: std.mem.Allocator, firefox_dir: []const u8, rel: []const u8) std.mem.Allocator.Error![]u8 {
    if (rel.len > 0 and rel[0] == '/') return gpa.dupe(u8, rel);
    return std.fs.path.join(gpa, &.{ firefox_dir, rel });
}

/// Returns the absolute profile directory. Caller owns the memory.
///
/// Since Firefox 67 the `[InstallXXXX]` section names the profile for a given
/// installation and `Default=1` under `[ProfileN]` is only the pre-67 fallback.
/// Reading `Default=1` first selects an abandoned profile on machines that have
/// one.
pub fn resolveDefault(gpa: std.mem.Allocator, firefox_dir: []const u8, ini: []const u8) Error![]u8 {
    const sections = try parseSections(gpa, ini);
    defer freeSections(gpa, sections);

    var install_path: ?[]const u8 = null;
    var legacy_path: ?[]const u8 = null;

    for (sections) |s| {
        if (std.mem.startsWith(u8, s.name, "Install")) {
            for (s.fields) |f| {
                if (std.mem.eql(u8, f.key, "Default")) install_path = f.value;
            }
        } else if (std.mem.startsWith(u8, s.name, "Profile")) {
            var path: ?[]const u8 = null;
            var is_default = false;
            for (s.fields) |f| {
                if (std.mem.eql(u8, f.key, "Path")) path = f.value;
                if (std.mem.eql(u8, f.key, "Default") and std.mem.eql(u8, f.value, "1")) is_default = true;
            }
            if (is_default) {
                if (path) |p| legacy_path = p;
            }
        }
    }

    const rel = install_path orelse legacy_path orelse return error.NoProfileFound;
    return resolvePath(gpa, firefox_dir, rel);
}

pub const Profile = struct {
    /// The `Name` key. Empty if a section carried none.
    name: []const u8,
    /// Absolute, resolved the same way `resolveDefault` resolves one.
    path: []const u8,
};

/// Every `[ProfileN]` section in profiles.ini, in file order.
/// `resolveDefault` returns one path. A profile Firefox abandoned carries no
/// key4.db, and opening it fails, so a front end needs the other sections to
/// fall back on.
pub fn enumerate(gpa: std.mem.Allocator, firefox_dir: []const u8, ini: []const u8) std.mem.Allocator.Error![]Profile {
    const sections = try parseSections(gpa, ini);
    defer freeSections(gpa, sections);

    var profiles: std.ArrayList(Profile) = .empty;
    errdefer {
        for (profiles.items) |p| {
            gpa.free(p.name);
            gpa.free(p.path);
        }
        profiles.deinit(gpa);
    }

    for (sections) |s| {
        if (!std.mem.startsWith(u8, s.name, "Profile")) continue;
        var name: []const u8 = "";
        var path: ?[]const u8 = null;
        for (s.fields) |f| {
            if (std.mem.eql(u8, f.key, "Name")) name = f.value;
            if (std.mem.eql(u8, f.key, "Path")) path = f.value;
        }
        const p = path orelse continue;
        try profiles.append(gpa, .{
            .name = try gpa.dupe(u8, name),
            .path = try resolvePath(gpa, firefox_dir, p),
        });
    }

    return profiles.toOwnedSlice(gpa);
}

/// `resolveDefault` and `enumerate` join through `std.fs.path.join`, which
/// writes the host's separator. The tail of each expectation below keeps the
/// forward slashes profiles.ini itself carries.
const sep = std.fs.path.sep_str;

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
    try std.testing.expectEqualStrings("/ff" ++ sep ++ "Profiles/real.default-release", got);
}

test "falls back to Default=1 when no install section exists" {
    const ini =
        \\[Profile0]
        \\Path=Profiles/only.default
        \\Default=1
    ;
    const got = try resolveDefault(std.testing.allocator, "/ff", ini);
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualStrings("/ff" ++ sep ++ "Profiles/only.default", got);
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
    try std.testing.expectEqualStrings("/ff" ++ sep ++ "Profiles/abandoned.default", got[0].path);
    try std.testing.expectEqualStrings("default-release", got[1].name);
    try std.testing.expectEqualStrings("/ff" ++ sep ++ "Profiles/real.default-release", got[1].path);
}

test "enumerate returns an empty slice for an ini with no Profile sections" {
    const got = try enumerate(std.testing.allocator, "/ff", "[General]\nVersion=2\n");
    defer std.testing.allocator.free(got);
    try std.testing.expectEqual(@as(usize, 0), got.len);
}
