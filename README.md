# Firefox Password View

[![CI](https://github.com/lkraider/firefox-password-view/actions/workflows/ci.yml/badge.svg)](https://github.com/lkraider/firefox-password-view/actions/workflows/ci.yml)

A terminal UI and a macOS app read a local Firefox profile's saved logins
and show them to the profile owner. Both are built on the same Zig core.
The released binaries are Apple Silicon macOS.

## Scope

This reads a profile. It never writes one. `key4.db` is opened
`SQLITE_OPEN_READONLY`, so running this against a profile Firefox has
open cannot corrupt it.

It cannot read these profiles:

- One whose Primary Password you do not know. This decrypts with the
  password you type. It does not crack or recover it.
- One that Firefox 144 or newer has never opened. Those hold
  3DES-encrypted entries only. This tool detects 3DES and reports it per
  entry, and stops there.

## Threat model

**Protects against:** passwords written to disk, terminal scrollback, and
clipboard history managers. Revealing a password shows exactly one at a
time. Copying marks the clipboard entry `org.nspasteboard.ConcealedType`
and clears it after 30 seconds. No network calls and no telemetry.

**Does not protect against:** anyone who can already read this user's
memory or files. `key4.db` is already readable by that user, and Firefox
already exposes the same data to them. Once a password reaches a Zig
buffer, a Swift `String`, or a terminal cell buffer, copies of it exist.
This code wipes only the buffers it owns.

One entry is special. A profile synced to a Mozilla Account carries a
`chrome://FirefoxAccounts` row whose password is sync key material.
Revealing it hands over the whole Mozilla Account. Both front ends label
this row and ask for confirmation before revealing it.

## Installing

Precompiled for Apple Silicon macOS, via this repo's own Homebrew tap:

```
brew tap lkraider/firefox-password-view https://github.com/lkraider/firefox-password-view
brew trust lkraider/firefox-password-view  # Homebrew 6.0 and newer
brew install ffpw                          # the terminal UI
brew install --cask firefox-password-view  # the macOS app
```

Homebrew 6.0 refuses to load a formula or a cask from an unofficial tap
until you trust that tap. Skipping `brew trust` gives "Refusing to load
formula ... from untrusted tap". Trusting the tap once covers both the
formula and the cask. Verified on Homebrew 6.0.17. If `brew trust`
reports an unknown command, your Homebrew installs without that line.

The app is ad-hoc signed. This project has no Apple Developer ID, so it is
not notarized. On first launch, right-click the app in Finder and choose
Open, or run `xattr -cr` on it yourself. Otherwise Gatekeeper blocks it as
coming from an unidentified developer.

## Using it

Run `ffpw`. It takes no arguments. It reads `profiles.ini` under
`~/Library/Application Support/Firefox` and opens the profile your
Firefox install uses. A profile with a Primary Password prompts for it
before the list appears.

| Key | Does |
|---|---|
| `/` | Enter the search field. `enter` or `escape` leaves it. |
| `↑` `↓`, `k` `j` | Move through the list. |
| `enter` | Reveal the selected password. Press again to hide it. |
| `y` | Copy the selected password to the clipboard. |
| `q`, `ctrl-c` | Quit. |

Passwords stay masked until you press `enter`, and only the selected one
is shown. On a `chrome://FirefoxAccounts` row, `enter` asks for a second
`enter` to confirm. See the threat model above for why.

The macOS app shows the same data with the same rules.

## Building

Needs [Zig 0.16.0](https://ziglang.org/download/#release-0.16.0) and Xcode
Command Line Tools (`xcode-select --install`). The build links
`libsqlite3` through the macOS SDK those tools install.

```
zig build          # builds core/, the TUI, and the C ABI static library
zig build test     # runs the core tests against the committed fixtures
zig build tui      # runs the TUI
zig build smoke    # runs the C ABI smoke test
```

`zig build test` needs no Firefox install and no profile of your own. It
reads only `core/testdata/`.

The macOS app is a separate Swift package. See
[`macos/README.md`](macos/README.md) for how to build and test it, and for
why it is a Swift package.

## Layout

```
core/       the Zig core: key4.db and logins.json decryption, the C ABI
core/testdata/  fixtures written by an installed Firefox over Marionette, synthetic credentials only
tui/        the terminal UI, on libvaxis
macos/      the SwiftUI app, a Swift package linking core's static library
tools/      tools/mkfixtures.py, the fixture generator
```

Read [`docs/DESIGN.md`](docs/DESIGN.md) before changing anything under
`core/src/`. It records the on-disk layout, the two places the IV is
built differently, and what each decision rejected.

## Porting it

The decryption modules (`der`, `oids`, `aescbc`, `pbes2`, `sdr`, `keydb`,
`logins`, `store`) call no OS-specific API. They take a profile path and
read SQLite. libvaxis supports Linux terminals. `build.zig` uses
`standardTargetOptions`, so `-Dtarget=` reaches every artifact. No CI job
builds a non-macOS target, so treat the list below as the starting point.

These assume macOS:

- `core/src/core.zig`, `core/src/main.zig` and `tui/src/main.zig` build
  the profile directory as `$HOME/Library/Application Support/Firefox`.
  Linux uses `~/.mozilla/firefox`.
- `tui/src/main.zig` copies by running `pbcopy`.
- Windows ships no system SQLite. See
  [`docs/DESIGN.md`](docs/DESIGN.md) for what vendoring it needs.

`zig build` installs the static library at `zig-out/lib/libffpw.a` and
the header at `zig-out/include/ffpw.h`. A GUI on another platform links
those two. Any language with a C FFI can call them. The SwiftUI app links
them through a raw `-L`/`-l` flag and uses no bridging header.

Call `ffpw_open` first. It returns `FFPW_ERR_NEEDS_PASSWORD` for a
profile with a Primary Password, so call `ffpw_unlock` next. Then
`ffpw_entries` fills a whole list in one call, `ffpw_search` filters it,
and `ffpw_reveal` returns one password. Release that password with
`ffpw_secret_free`. It zeroes the buffer before freeing it. One
`ffpw_store` belongs to one thread.

`core/test/smoke.c` calls every function in the header in order and runs
as `zig build smoke`. Start there.

## License

MIT. See [`LICENSE`](LICENSE).
