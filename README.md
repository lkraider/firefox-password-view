# ![](docs/images/icon.png) Firefox Password View

[![CI](https://github.com/lkraider/firefox-password-view/actions/workflows/ci.yml/badge.svg)](https://github.com/lkraider/firefox-password-view/actions/workflows/ci.yml)

A terminal UI, a macOS app and a Windows app show the saved logins in a
local Firefox profile. All three read them through one Zig core. The
released binaries are Apple Silicon macOS, Windows x86_64 and Windows
ARM64.

### TUI

![The terminal UI listing five logins with masked passwords, one revealed, and the confirmation prompt on the Firefox Accounts row](docs/images/tui.png)

### SwiftUI

![The macOS app listing the same five logins, each with a copy button, and icons marking the Firefox Accounts row and the extension row](docs/images/macos-app.png)

### Win32

![The Windows app listing the same five logins in a report-view list, with the second row selected and its password revealed, and the status bar showing the login count](docs/images/windows-app.png)

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

On Windows, download `FirefoxPasswordView-<version>-windows-arm64.zip` or
`-windows-x86_64.zip` from the releases page and unzip it. The exe is a
single file and needs no install. It is unsigned, so SmartScreen shows a
warning on first launch. Choose More info, then Run anyway.

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

On Windows, run `FirefoxPasswordView.exe`. It reads `profiles.ini` under
`%APPDATA%\Mozilla\Firefox`. The `Profile` menu lists every profile it
found, and `--profile <path>` opens one directory.

| Key | Does |
|---|---|
| `Ctrl+F` | Move focus to the search box. |
| `Enter`, double-click | Reveal the selected password. Press again to hide it. |
| `Ctrl+C` | Copy the selected password. The row stays masked. |
| `Esc` | Hide the revealed password. |
| right-click | Reveal and Copy for the row under the cursor. |

Passwords stay masked until you press `enter`, and only the selected one is
shown. The macOS app shows the same data under the same rules, and each row
there carries a copy button that leaves the row masked.

## Limits

This reads a profile and writes nothing back. Firefox can stay open while
you use it.

The list is a snapshot from the moment you opened the profile. To pick up
a login Firefox saved after that, open the profile again: the `Profile`
menu on Windows, the profile picker on macOS, a restart for the TUI.

It cannot read these profiles:

- One with a Primary Password you do not know. Decryption uses the
  password you type. There is no recovery path.
- One that Firefox 144 or newer has never opened. Those hold
  3DES-encrypted entries only. This tool reports 3DES per entry and stops
  there.
- One whose `key4.db` uses SQLite's write-ahead log. No Firefox profile
  measured uses one. A profile that does stops the app with `WalJournal`.

## Security

Copying marks the clipboard entry so a clipboard manager skips it. On
Windows that keeps the password out of `Win+V` history and out of the
cloud clipboard. Copying never puts the password on screen. There are no
network calls and no telemetry.

The macOS app and the Windows app clear the clipboard 30 seconds after a
copy. Both mask a revealed password after the same 30 seconds. Copy
something else in the meantime and that copy stays.

The TUI runs no timer. A password it copies stays on the clipboard until
something else replaces it, and a revealed row stays open until you press
`enter` again.

Anyone who can read your files or your memory already has this data.
`key4.db` is readable by your own user, and Firefox exposes the same
logins. Once a password reaches a buffer, copies of it exist. This code
wipes the buffers it owns.

A profile synced to a Mozilla Account holds a `chrome://FirefoxAccounts`
row. Its password is sync key material, so revealing it hands over the
whole account. All three front ends mark that row and ask a second time
before revealing it.

## Building

Needs [Zig 0.16.0](https://ziglang.org/download/#release-0.16.0). On macOS it
also needs Xcode Command Line Tools (`xcode-select --install`), because the C
ABI library links libc and `core/test/oracle.zig` links `libsqlite3` through
the SDK those tools install.

```
zig build          # core, the TUI, and the C ABI static library
zig build test     # the core tests, against the committed fixtures
zig build tui      # run the TUI
zig build smoke    # the C ABI smoke test
```

`zig build test` reads only `core/testdata/`. It runs on a machine with no
Firefox installed. Pass `-Doracle=false` to drop the test that diffs the
SQLite reader against the system sqlite3.

The Windows app cross-compiles from macOS or Linux with no Windows SDK:

```
zig build win -Dtarget=aarch64-windows-gnu -Doptimize=ReleaseSafe
zig build win -Dtarget=x86_64-windows-gnu  -Doptimize=ReleaseSafe
```

The released zips carry `ReleaseSafe`. That mode keeps the bounds and
alignment checks that guard the hand-written `key4.db` reader.

`win/icon.ico` is committed, and a build reads that file. `python3
scripts/make-ico.py` rewrites it from `macos/Icon.icns`.

The macOS app is a separate Swift package. See
[`macos/README.md`](macos/README.md) for how to build and test it.

`scripts/screenshots.sh` regenerates the three images above. Its `win`
target needs wine.

## Layout

```
core/       key4.db and logins.json decryption, and the C ABI
tui/        the terminal UI, on libvaxis
macos/      the SwiftUI app
win/        the Win32 app
tools/      the fixture generator
```

[`docs/DESIGN.md`](docs/DESIGN.md) has the on-disk format, the reasoning
behind each decision in the core, and what a front end on another platform
has to link.

## License

MIT. See [`LICENSE`](LICENSE).
