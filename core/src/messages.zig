//! The text a front end shows for a failure the core reports.

/// Every error store.zig and its dependencies can produce, given a message a
/// person can act on. The store has no fixed error set (it is `!T`
/// throughout), so the fallback branch catches the rest. A DER or PBES2
/// parse error lands there, and the answer to one is a bug report.
pub fn friendly(err: anyerror) []const u8 {
    return switch (err) {
        error.WrongPassword => "wrong Primary Password",
        error.LegacyTripleDes => "this entry is still 3DES and this app cannot decrypt it",
        error.OpenFailed => "could not open key4.db for this profile",
        error.MissingPasswordRow, error.NoSdrKey, error.QueryFailed => "this profile's key4.db is missing data this app expects",
        error.NoLoginsArray => "logins.json is not in the shape this app expects",
        error.OutOfMemory => "out of memory",
        error.FileNotFound => "logins.json or key4.db is missing",
        error.AccessDenied => "permission denied reading this profile",
        else => "could not read this profile (unexpected error)",
    };
}
