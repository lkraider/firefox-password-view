# Firefox Password View

Reads a local Firefox profile's saved logins and shows them to the profile
owner: a terminal UI and a macOS app, both built on the same Zig core.
Apple Silicon macOS only, for now.

## What this is not

This does not write or edit logins, does not touch `cert9.db`, does not
read or write Firefox Sync, does not do form autofill, and does not recover
an unknown Primary Password. 3DES is detected and reported, never
decrypted: a profile Firefox 144 or newer has never opened carries only
3DES-encrypted entries, and this tool cannot read those.

## Threat model

**Protects against:** passwords written to disk, terminal scrollback, and
clipboard history managers. Revealing a password shows exactly one at a
time; copying marks the clipboard entry `org.nspasteboard.ConcealedType`
and clears it after 30 seconds.

**Does not protect against:** anyone who can already read this user's
memory or files. `key4.db` is readable by that user already, so this tool
cannot raise the bar above what Firefox itself offers. Once a password
reaches a Zig buffer, a Swift `String`, or a terminal cell buffer, copies
of it exist that nothing here wipes beyond the buffers this code owns.

One entry is special: a profile synced to a Mozilla Account carries a
`chrome://FirefoxAccounts` row whose password is sync key material, not a
site password. Revealing it hands over the account, not one login. Both
front ends label this row and ask for confirmation before revealing it.

## Building

Needs [Zig 0.16.0](https://ziglang.org/download/#release-0.16.0) and Xcode
Command Line Tools (`xcode-select --install`), which the build uses for
`libsqlite3` via the macOS SDK.

```
zig build          # builds core/, the TUI, and the C ABI static library
zig build test     # runs the core test suite (26+ tests, fixtures only)
zig build tui      # runs the TUI
zig build smoke    # runs the C ABI smoke test
```

The macOS app is a separate Swift package; see [`macos/README.md`](macos/README.md)
for how to build and test it, and for why it is a Swift package rather than
an Xcode project.

## Layout

```
core/       the Zig core: key4.db and logins.json decryption, the C ABI
core/testdata/  fixtures written by a real Firefox over Marionette, synthetic credentials only
tui/        the terminal UI, on libvaxis
macos/      the SwiftUI app, a Swift package linking core's static library
tools/      tools/mkfixtures.py, the fixture generator
```

`FEASIBILITY.md` has the byte-level format details, verified against a
live profile, and the reasoning behind each implementation decision.

## Status

Milestones 0 through 5 of the implementation plan are complete: the
decryption core, both front ends, the C ABI, and the fixture and fuzz test
suites. See `FEASIBILITY.md` for what has been measured and where.
