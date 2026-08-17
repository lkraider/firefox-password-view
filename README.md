# Firefox Password View

[![CI](https://github.com/lkraider/firefox-password-view/actions/workflows/ci.yml/badge.svg)](https://github.com/lkraider/firefox-password-view/actions/workflows/ci.yml)

A terminal UI and a macOS app show the saved logins in a local Firefox
profile. Both link one Zig core. The released binaries are Apple Silicon
macOS.

### TUI

![The terminal UI listing five logins with masked passwords, one revealed, and the confirmation prompt on the Firefox Accounts row](docs/images/tui.png)

### SwiftUI

![The macOS app listing the same five logins, with icons marking the Firefox Accounts row and the extension row](docs/images/macos-app.png)

## Installing

```
brew tap lkraider/firefox-password-view https://github.com/lkraider/firefox-password-view
brew trust lkraider/firefox-password-view  # Homebrew 6.0 and newer
brew install ffpw                          # the terminal UI
brew install --cask firefox-password-view  # the macOS app
```

The app is ad-hoc signed. This project has no Apple Developer ID, so it is
not notarized. On first launch, right-click the app in Finder and choose
Open. Gatekeeper otherwise blocks it as coming from an unidentified
developer.

## Using it

Run `ffpw`. It reads `profiles.ini` under `~/Library/Application
Support/Firefox` and opens the profile your Firefox uses. It prompts for a
Primary Password when the profile has one.

| Key | Does |
|---|---|
| `/` | Enter the search field. `enter` or `escape` leaves it. |
| `↑` `↓`, `k` `j` | Move through the list. |
| `enter` | Reveal the selected password. Press again to hide it. |
| `y` | Copy the selected password. The row stays masked. |
| `q`, `ctrl-c` | Quit. |

To open another profile:

```
ffpw --list-profiles       # one profile per line, name then path
ffpw --profile <path>      # open that directory
```

Passwords stay masked until you press `enter`, and only the selected one is
shown. The macOS app shows the same data under the same rules. Each row
there carries a copy button that leaves the row masked, and a revealed
password masks itself again after 30 seconds.

## Limits

This reads a profile and writes nothing back. `key4.db` opens
`SQLITE_OPEN_READONLY`, so it is safe to run while Firefox has the profile
open.

It cannot read these profiles:

- One with a Primary Password you do not know. Decryption uses the
  password you type. There is no recovery path.
- One that Firefox 144 or newer has never opened. Those hold
  3DES-encrypted entries only. This tool reports 3DES per entry and stops
  there.

## Security

Copying marks the clipboard entry `org.nspasteboard.ConcealedType` and
clears it after 30 seconds. Copying never puts the password on screen. In
the macOS app a revealed password masks itself after the same 30 seconds.
There are no network calls and no telemetry.

Anyone who can read your files or your memory already has this data.
`key4.db` is readable by your own user, and Firefox exposes the same
logins. Once a password reaches a buffer, copies of it exist. This code
wipes the buffers it owns.

A profile synced to a Mozilla Account holds a `chrome://FirefoxAccounts`
row. Its password is sync key material, so revealing it hands over the
whole account. Both front ends mark that row and ask a second time before
revealing it.

## Building

Needs [Zig 0.16.0](https://ziglang.org/download/#release-0.16.0) and Xcode
Command Line Tools (`xcode-select --install`). The build links
`libsqlite3` through the macOS SDK those tools install.

```
zig build          # core, the TUI, and the C ABI static library
zig build test     # the core tests, against the committed fixtures
zig build tui      # run the TUI
zig build smoke    # the C ABI smoke test
```

`zig build test` reads only `core/testdata/`. It runs on a machine with no
Firefox installed.

The macOS app is a separate Swift package. See
[`macos/README.md`](macos/README.md) for how to build and test it.

`scripts/screenshots.sh` regenerates the two images above.

## Layout

```
core/       key4.db and logins.json decryption, and the C ABI
tui/        the terminal UI, on libvaxis
macos/      the SwiftUI app
tools/      the fixture generator
```

[`docs/DESIGN.md`](docs/DESIGN.md) has the on-disk format, the reasoning
behind each decision in the core, and what a front end on another platform
has to link.

## License

MIT. See [`LICENSE`](LICENSE).
