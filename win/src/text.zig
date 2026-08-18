//! UTF-8 to UTF-16 for the Win32 calls that take a null-terminated wide
//! string.
//!
//! `std.unicode.utf8ToUtf16Le` returns `error{InvalidUtf8}` alone. A
//! destination shorter than the source is an index-out-of-bounds panic inside
//! `utf8ToUtf16LeImpl`. `win_exe.subsystem = .Windows` in build.zig sends that
//! panic to a stderr with no console, so the window disappears with no
//! message.
//!
//! This file imports `std` alone, so build.zig runs its tests on the build
//! host.

const std = @import("std");

/// Converts `text` into `dest` and writes the terminator. A source too long
/// for `dest` is cut at a codepoint boundary. Invalid UTF-8 yields an empty
/// string.
///
/// The clamp counts source bytes, and UTF-8 spends at least one byte per
/// UTF-16 unit. A 4-byte codepoint therefore drops out when the last two
/// units of `dest` are free.
pub fn wideZ(dest: []u16, text: []const u8) [:0]const u16 {
    std.debug.assert(dest.len >= 1);
    var take = @min(text.len, dest.len - 1);
    // 0b10xxxxxx is a UTF-8 continuation byte. Back up to the lead byte.
    while (take > 0 and take < text.len and text[take] & 0xC0 == 0x80) take -= 1;
    const n = std.unicode.utf8ToUtf16Le(dest[0..take], text[0..take]) catch 0;
    dest[n] = 0;
    return dest[0..n :0];
}

const testing = std.testing;

test "a source that fits arrives whole and terminated" {
    var dest: [16]u16 = undefined;
    const out = wideZ(&dest, "hello");
    try testing.expectEqualSlices(u16, &.{ 'h', 'e', 'l', 'l', 'o' }, out);
    try testing.expectEqual(@as(u16, 0), dest[5]);
}

test "a source longer than the destination is cut" {
    var dest: [4]u16 = undefined;
    const out = wideZ(&dest, "abcdefgh");
    try testing.expectEqualSlices(u16, &.{ 'a', 'b', 'c' }, out);
    try testing.expectEqual(@as(u16, 0), dest[3]);
}

test "a two-byte codepoint straddling the cut is dropped whole" {
    // "aé" is 61 c3 a9. A 3-unit destination takes 2 bytes, and byte 2 is the
    // continuation a9.
    var dest: [3]u16 = undefined;
    const out = wideZ(&dest, "a\u{e9}");
    try testing.expectEqualSlices(u16, &.{'a'}, out);
}

test "a surrogate pair straddling the cut is dropped whole" {
    // U+1F600 is f0 9f 98 80 and becomes two UTF-16 units. A 5-unit
    // destination takes 4 bytes, and bytes 1 to 3 are continuations.
    var dest: [5]u16 = undefined;
    const out = wideZ(&dest, "ab\u{1f600}");
    try testing.expectEqualSlices(u16, &.{ 'a', 'b' }, out);

    // Room for all four units keeps the pair.
    var roomy: [7]u16 = undefined;
    try testing.expectEqual(@as(usize, 4), wideZ(&roomy, "ab\u{1f600}").len);
}

test "invalid utf-8 yields an empty string" {
    var dest: [16]u16 = undefined;
    // 0x80 with no lead byte ahead of it.
    const out = wideZ(&dest, "ab\x80cd");
    try testing.expectEqual(@as(usize, 0), out.len);
    try testing.expectEqual(@as(u16, 0), dest[0]);
}

test "a destination of one unit holds the terminator alone" {
    var dest: [1]u16 = undefined;
    const out = wideZ(&dest, "abc");
    try testing.expectEqual(@as(usize, 0), out.len);
    try testing.expectEqual(@as(u16, 0), dest[0]);
}

test "an empty source yields an empty string" {
    var dest: [4]u16 = undefined;
    const out = wideZ(&dest, "");
    try testing.expectEqual(@as(usize, 0), out.len);
    try testing.expectEqual(@as(u16, 0), dest[0]);
}
