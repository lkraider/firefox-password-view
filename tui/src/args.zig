//! Command line parsing for the TUI. `parse` takes a plain slice, so its
//! tests need no process.

const std = @import("std");

pub const Options = struct {
    /// The profile directory to open. A relative path joins onto the root.
    /// Null means read profiles.ini and take the pick
    /// `profiles.resolveDefault` returns.
    profile_path: ?[]const u8 = null,
    /// The directory holding profiles.ini. Null means walk
    /// `profiles.home_relative_dirs`.
    profiles_dir: ?[]const u8 = null,
    list_profiles: bool = false,
    help: bool = false,
};

pub const Error = error{ MissingValue, UnknownFlag };

pub const usage =
    \\ffpw -- view a local Firefox profile's saved logins
    \\
    \\Usage:
    \\  ffpw                       open the profile Firefox uses
    \\  ffpw --profile <path>      open the profile in <path>, joined onto
    \\                             the root when it is relative
    \\  ffpw --profiles-dir <dir>  read profiles.ini from <dir>
    \\  ffpw --list-profiles       print every profile in profiles.ini
    \\  ffpw --help                print this text
    \\
    \\Keys:
    \\  /            search, enter or escape leaves the field
    \\  up down k j  move through the list
    \\  enter        reveal the selected password, again to hide it
    \\  y            copy the selected password. The row stays masked. A copy
    \\               on Linux runs wl-copy, xclip or xsel, from the
    \\               wl-clipboard or xclip package. With stdout on a pipe or
    \\               a file, y writes the password there as well. The last y
    \\               of the run writes.
    \\  q ctrl-c     quit
    \\
;

/// `argv` excludes the program name.
pub fn parse(argv: []const []const u8) Error!Options {
    var options: Options = .{};
    var i: usize = 0;
    while (i < argv.len) : (i += 1) {
        const arg = argv[i];
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            options.help = true;
        } else if (std.mem.eql(u8, arg, "--list-profiles")) {
            options.list_profiles = true;
        } else if (std.mem.eql(u8, arg, "--profile")) {
            i += 1;
            if (i >= argv.len) return error.MissingValue;
            options.profile_path = argv[i];
        } else if (std.mem.startsWith(u8, arg, "--profile=")) {
            const value = arg["--profile=".len..];
            if (value.len == 0) return error.MissingValue;
            options.profile_path = value;
        } else if (std.mem.eql(u8, arg, "--profiles-dir")) {
            i += 1;
            if (i >= argv.len) return error.MissingValue;
            options.profiles_dir = argv[i];
        } else if (std.mem.startsWith(u8, arg, "--profiles-dir=")) {
            const value = arg["--profiles-dir=".len..];
            if (value.len == 0) return error.MissingValue;
            options.profiles_dir = value;
        } else {
            return error.UnknownFlag;
        }
    }
    return options;
}

test "no arguments leaves every field at its default" {
    const options = try parse(&.{});
    try std.testing.expect(options.profile_path == null);
    try std.testing.expect(options.profiles_dir == null);
    try std.testing.expect(!options.list_profiles);
    try std.testing.expect(!options.help);
}

test "--profile takes the next argument" {
    const options = try parse(&.{ "--profile", "/tmp/p" });
    try std.testing.expectEqualStrings("/tmp/p", options.profile_path.?);
}

test "--profile=<path> takes the value after the equals sign" {
    const options = try parse(&.{"--profile=/tmp/p"});
    try std.testing.expectEqualStrings("/tmp/p", options.profile_path.?);
}

test "--profile with nothing after it reports MissingValue" {
    try std.testing.expectError(error.MissingValue, parse(&.{"--profile"}));
    try std.testing.expectError(error.MissingValue, parse(&.{"--profile="}));
}

test "--profiles-dir takes the next argument" {
    const options = try parse(&.{ "--profiles-dir", "/tmp/ff" });
    try std.testing.expectEqualStrings("/tmp/ff", options.profiles_dir.?);
}

test "--profiles-dir=<dir> takes the value after the equals sign" {
    const options = try parse(&.{"--profiles-dir=/tmp/ff"});
    try std.testing.expectEqualStrings("/tmp/ff", options.profiles_dir.?);
}

test "--profiles-dir with nothing after it reports MissingValue" {
    try std.testing.expectError(error.MissingValue, parse(&.{"--profiles-dir"}));
    try std.testing.expectError(error.MissingValue, parse(&.{"--profiles-dir="}));
}

test "--profiles-dir and --profile set separate fields" {
    const options = try parse(&.{ "--profiles-dir", "/tmp/ff", "--profile", "Profiles/p" });
    try std.testing.expectEqualStrings("/tmp/ff", options.profiles_dir.?);
    try std.testing.expectEqualStrings("Profiles/p", options.profile_path.?);
}

test "--list-profiles and --help set their flags" {
    try std.testing.expect((try parse(&.{"--list-profiles"})).list_profiles);
    try std.testing.expect((try parse(&.{"--help"})).help);
    try std.testing.expect((try parse(&.{"-h"})).help);
}

test "an unrecognized argument reports UnknownFlag" {
    try std.testing.expectError(error.UnknownFlag, parse(&.{"--colour"}));
    try std.testing.expectError(error.UnknownFlag, parse(&.{"/tmp/p"}));
}
