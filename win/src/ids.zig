//! Resource ids. win/app.rc reads the same numbers from
//! win/src/resource.h, and the test below compares the two files.

const std = @import("std");

pub const IDI_APP: u16 = 1;
pub const IDR_MAINMENU: u16 = 2;
pub const IDR_ROWMENU: u16 = 3;
pub const IDR_MAINACCEL: u16 = 4;
pub const IDD_PASSWORD: u16 = 5;

pub const IDM_FILE_EXIT: u16 = 100;
pub const IDM_HELP_ABOUT: u16 = 101;
pub const IDM_ROW_REVEAL: u16 = 102;
pub const IDM_ROW_COPY: u16 = 103;
pub const IDM_EDIT_FIND: u16 = 104;
pub const IDM_EDIT_HIDE: u16 = 105;

/// One menu id per profile in profiles.ini, counting up from here. The
/// `Profile` menu is built at runtime, so app.rc carries no id for it.
pub const IDM_PROFILE_FIRST: u16 = 200;
pub const IDM_PROFILE_LAST: u16 = 299;

pub const IDC_SEARCH: u16 = 1000;
pub const IDC_LIST: u16 = 1001;
pub const IDC_STATUS: u16 = 1002;

pub const IDC_PW_PROMPT: u16 = 1010;
pub const IDC_PW_EDIT: u16 = 1011;
pub const IDC_PW_ERROR: u16 = 1012;

/// SetTimer ids. 1 masks a revealed row and 2 clears the clipboard.
pub const timer_hide_reveal: usize = 1;
pub const timer_clear_clipboard: usize = 2;

test "every #define in resource.h matches the constant here" {
    const header = @embedFile("resource.h");
    inline for (@typeInfo(@This()).@"struct".decls) |decl| {
        const value = @field(@This(), decl.name);
        if (@TypeOf(value) != u16) continue;
        if (comptime std.mem.startsWith(u8, decl.name, "IDM_PROFILE_")) continue;

        var buf: [64]u8 = undefined;
        const line = try std.fmt.bufPrint(&buf, "#define {s} {d}\n", .{ decl.name, value });
        std.testing.expect(std.mem.indexOf(u8, header, line) != null) catch |err| {
            std.debug.print("win/src/resource.h is missing: {s}", .{line});
            return err;
        };
    }
}
