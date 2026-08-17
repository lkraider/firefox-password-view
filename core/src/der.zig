//! DER reader covering the subset Firefox writes into key4.db and logins.json.
//! Every read is bounds-checked against the input slice. std.crypto.Certificate.der
//! omits those checks (ziglang/zig#19775), so this project carries its own reader.

const std = @import("std");

pub const Error = error{
    Truncated,
    UnsupportedLength,
    UnexpectedTag,
    IntegerTooLarge,
};

pub const tag_integer: u8 = 0x02;
pub const tag_octet_string: u8 = 0x04;
pub const tag_oid: u8 = 0x06;
pub const tag_sequence: u8 = 0x30;

pub const Element = struct {
    tag: u8,
    /// Contents with the identifier and length octets removed.
    contents: []const u8,
    /// The element as it appears in the input, identifier and length included.
    /// NSS reuses these bytes verbatim as an AES IV, see pbes2.zig.
    raw: []const u8,
};

pub const Reader = struct {
    buf: []const u8,
    pos: usize = 0,

    pub fn init(buf: []const u8) Reader {
        return .{ .buf = buf };
    }

    pub fn atEnd(r: Reader) bool {
        return r.pos >= r.buf.len;
    }

    pub fn next(r: *Reader) Error!Element {
        const start = r.pos;
        if (r.buf.len - r.pos < 2) return error.Truncated;
        const tag = r.buf[r.pos];
        const first = r.buf[r.pos + 1];
        r.pos += 2;

        var len: usize = first;
        if (first & 0x80 != 0) {
            const n = first & 0x7f;
            // A zero count is the indefinite form. DER forbids it. Anything
            // above four length octets exceeds every structure Firefox writes.
            if (n == 0 or n > 4) return error.UnsupportedLength;
            if (r.buf.len - r.pos < n) return error.Truncated;
            len = 0;
            for (r.buf[r.pos..][0..n]) |b| len = (len << 8) | b;
            r.pos += n;
        }

        if (r.buf.len - r.pos < len) return error.Truncated;
        const contents = r.buf[r.pos..][0..len];
        r.pos += len;
        return .{ .tag = tag, .contents = contents, .raw = r.buf[start..r.pos] };
    }

    pub fn expect(r: *Reader, tag: u8) Error!Element {
        const e = try r.next();
        if (e.tag != tag) return error.UnexpectedTag;
        return e;
    }

    pub fn octetString(r: *Reader) Error![]const u8 {
        return (try r.expect(tag_octet_string)).contents;
    }

    pub fn oid(r: *Reader) Error![]const u8 {
        return (try r.expect(tag_oid)).contents;
    }

    pub fn seq(r: *Reader) Error!Reader {
        return init((try r.expect(tag_sequence)).contents);
    }

    pub fn int(r: *Reader) Error!u32 {
        const c = (try r.expect(tag_integer)).contents;
        if (c.len == 0) return error.Truncated;
        // A leading zero octet only carries the sign for values that would
        // otherwise look negative.
        const s = if (c[0] == 0) c[1..] else c;
        if (s.len > 4) return error.IntegerTooLarge;
        var v: u32 = 0;
        for (s) |b| v = (v << 8) | b;
        return v;
    }
};
