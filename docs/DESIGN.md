# Design notes

What `core/src/` has to get right to read a Firefox profile, and why each
part is written the way it is. Read this before changing the decryption
path. The measurements come from a live Firefox 152.0.6 profile on macOS
15.7.7 arm64, Zig 0.16.0. `README.md` covers usage and the threat model.

## Where Firefox stores the data

- `logins.json` — one record per saved login. The on-disk keys are `hostname`,
  `httpRealm`, `formSubmitURL`, `usernameField`, `passwordField`,
  `encryptedUsername`, `encryptedPassword`, `guid`, `encType`, `timeCreated`,
  `timeLastUsed`, `timePasswordChanged`, `timesUsed`, `encryptedUnknownFields`.
  There is no `origin` key. That name belongs to the JavaScript side.
- `key4.db` — SQLite. `metaData` holds the global salt and the password-check
  value under `id = 'password'`. `nssPrivate` holds the wrapped master keys.
- `cert9.db` — certificate store, unused here.

`metaData` also holds `sig_key_*` rows, so `keydb.zig` matches
`id = "password"`. `nssPrivate` also holds non-key objects, so the same
file filters on CKA_ID `f8000000000000000000000000000001` and object class
`a0 = 00 00 00 04`.

`core/src/sqlitedb.zig` reads the SQLite file format directly. It maps
`a0`, `a11` and `a102` to record positions through the `CREATE TABLE`
text, because the column count moves: `nssPrivate` declares 192 columns in
the `unmigrated` fixture and 193 in every other one.

### Two limits bound the b-tree walk

`RowIterator` caps its stack at 24 frames. That limit stops a walk on a page
that points back at itself or at an ancestor.

`RowIterator` also caps how many pages one walk descends into, at the file's
own page count. A valid b-tree reaches each page once. An interior page whose
cells all name one child multiplies the work at every level while the stack
stays under 24 frames. Measured before the page budget landed: a crafted
11,776-byte `key4.db` made `keydb.load` run over 20 seconds with no return,
and a 6,144-byte one yielded 1,048,576 rows in 3.9 seconds. The same crafted
file now returns `error.QueryFailed` in 0.37 seconds.

The budget bounds total reads at the page count times the cells one page
holds. A 512-byte page holds at most 71 interior cells and a 4096-byte page at
most 2044. `overflow.db` pushes 256 pages against a budget of 772.
`core/testdata/fanout.db` is the fixture that reaches the budget.

### Two master keys, one key id

A profile Firefox 144 has opened holds **two** rows under CKA_ID
`f8000000000000000000000000000001` with object class `CKO_SECRET_KEY`
(`a0 = x'00000004'`):

| wrapped size | decrypted size | key |
|---|---|---|
| 32 bytes | 24 bytes | legacy 3DES |
| 48 bytes | 32 bytes | AES-256, added by Firefox 144 |

Firefox 144 adds the AES-256 key and leaves the 3DES key in place.
`keydb.zig` unwraps both rows and picks by decrypted length. The 3DES row
comes first in insertion order, so a reader that stops at the first row
decrypts every AES entry with the legacy key and fails its PKCS7 check.

### Firefox 144 migrated the whole store at once

Read an entry's cipher from its OID. On the measured profile, 1625 of the
1701 entries predate October 2025 and the oldest dates to March 2011. All
1701 use AES-256, so the timestamps predict nothing. The 144 upgrade
re-encrypted every entry in one pass. The `unmigrated` and `migrated`
fixtures are the same profile before and after that pass.

### A Primary Password changes the global salt's size and the seed hash

A never-initialized token stores metaData's global salt as 20 raw bytes and
seeds its key derivation with SHA-1. Setting a Primary Password for the
first time replaces it with a 48-byte salt and reseeds with SHA-384.
`sftkdb_passwordToKey` in NSS's softoken picks the hash by the salt's
length, so the reader must do the same. Seeding with SHA-1 for a 48-byte
salt makes the correct password fail. That failure looks exactly like a
wrong password, so the `primary` fixture covers it.

### profiles.ini

Since Firefox 67 the `[InstallXXXX]` section names the profile for a given
installation. `Default=1` under `[ProfileN]` is the pre-67 fallback. On the
measured machine `Default=1` sits on a profile that contains no `key4.db`,
and the install section names the profile Firefox opens. Resolution reads
the install section first.

### Sync tombstones and the non-web schemes

A profile synced to a Mozilla Account uses the same encryption as any
other profile. It adds deletion tombstones and rows whose hostname carries
a non-web scheme.

A tombstone carries `{deleted: true, everSynced, guid, id, syncCounter,
timePasswordChanged}` and no hostname or encrypted field. These are
deletions held for propagation to other devices. `logins.zig` counts them
under `tombstones_skipped` and leaves them out of the entry list. The
`sync-shaped` fixture carries two.

One entry has `hostname = chrome://FirefoxAccounts` and
`httpRealm = Firefox Accounts credentials`. Its username is the Mozilla
Account email, and its decrypted password is a JSON document holding sync
key material. Revealing it hands over the whole Mozilla Account. The store
labels this row `account_credential`. Entries can also carry a
`moz-extension://` origin, labelled `extension`. Hostname parsing must not
assume `http` or `https`.

## The decryption chain

Both layers use PBKDF2 and AES-256-CBC. They differ in how the IV is carried.

**Unwrapping a key4.db value** (`metaData.item2` and each `nssPrivate.a11`):

```
seed = SHA1(globalSalt ‖ primaryPassword)     — SHA-384 if globalSalt is 48 bytes
key  = PBKDF2-HMAC-SHA256(seed, entrySalt, iterations, keyLength)
iv   = the full DER encoding of the IV element, header included
plain = AES-256-CBC-decrypt(ciphertext, key, iv), PKCS7 stripped
```

The IV element carries a 14-byte body. NSS feeds the two header octets plus
that body to AES as the 16-byte IV.

`iterations` was 1 on a never-initialized token and 10000 once a Primary
Password is set. The reader takes the value from the structure.

**Decrypting a logins.json field:** base64-decode, then parse
`SEQUENCE { OCTET keyId, SEQUENCE { OID cipher, OCTET iv }, OCTET ciphertext }`.
Here the IV is the element **body**, 16 bytes, used directly. Decrypt with
the 32-byte master key.

`metaData.item2` decrypts to the ASCII string `password-check`. This
confirms the Primary Password before any key material is unwrapped.

## Decisions

| Decision | Choice | Rejected alternative |
|---|---|---|
| Crypto source | Reimplement PBES2 in Zig | Linking NSS needs a matching libnss3 per platform and a bundled dylib on macOS |
| 3DES | Not implemented. `sdr.decrypt` returns `LegacyTripleDes` | A DES implementation adds roughly 300 lines of legacy cipher that 0 of 1701 entries need |
| DER | Own bounds-checked reader | `std.crypto.Certificate.der` has no bounds checks, no canonical-form checks and no tests (ziglang/zig#19775) |
| C interop | `b.addTranslateC` | `@cImport` is deprecated in Zig 0.16 |
| SQLite | `core/src/sqlitedb.zig`, a read-only reader for the file format | The vendored amalgamation needs libc. Three exes at `-Doptimize=ReleaseSmall` on `x86_64-windows-gnu`, measured against the 3.53.4 amalgamation: 803840 bytes with it, 64000 for a minimal one linking libc, 4608 for a minimal one without it. SQLite's CVE advisories also cover a SQL layer this reader never calls |
| Win32 | Hand-written externs in `win/src/win32.zig` | `zigwin32` is a generated source tree of about 300 MB |
| Windows UI | Windows mechanisms for every macOS feature: a `Profile` menu, a context menu, `MessageBoxW`, a `DIALOGEX` template | Porting a SwiftUI layout puts macOS interactions in a Windows app |
| Windows optimize mode | `ReleaseSafe` for both released zips | `ReleaseSmall` saves 81 KB in the zip and drops the bounds, alignment and overflow checks. `sqlitedb.zig` takes every offset it follows from the file it reads |
| Zig | Pin 0.16.0 | Tracking master breaks on each stdlib redesign |
| Reveal | Masked by default, reveal one entry, copy to clipboard | Printing every password fills terminal scrollback |
| Architecture | Ship one `aarch64-macos` slice, plus `x86_64-windows` and `aarch64-windows` | A macOS universal binary adds a lipo step and a second build for an architecture no release targets |
| Fixtures | Written by an installed Firefox over Marionette, committed under `core/testdata/` | A generator built from this project's own reading of the format would only show the reader agrees with itself |

## Module layout

```
core/src/
  der.zig        bounds-checked TLV reader
  oids.zig       encoded OID bodies and the Cipher enum
  aescbc.zig     AES-256-CBC over std.crypto.core.aes, PKCS7
  pbes2.zig      unwraps key4.db values
  sdr.zig        parses logins.json blobs
  profiles.zig   resolves and enumerates profiles
  sqlitedb.zig   read-only reader for the SQLite file format
  keydb.zig      reads key4.db, returns the master keys
  logins.zig     decrypts and classifies logins.json entries
  store.zig      owns the arena, the keys, the entries, and the search filter
  messages.zig   the text a front end shows for a core failure
  core.zig       exports the C ABI the macOS app links, core/include/ffpw.h
  root.zig       the module a front end imports through
  main.zig       validation probe
  c.h            the stdlib header for addTranslateC, for getenv
  tests.zig      NIST and DER vectors, and fixture round-trips
core/test/
  oracle.zig     diffs sqlitedb.zig against the system sqlite3
  smoke.c        calls every function in ffpw.h
build.zig
tui/src/        the libvaxis TUI, imports store.zig through root.zig
macos/          the SwiftUI app, a Swift package linking core.zig's static library
win/src/        the Win32 app, importing the core module directly
scripts/
  screenshots.sh       writes the three README images
  wine-check.sh        asserts the Windows app's behaviour under wine
  wine-shutdown.sh     ends a wine prefix's session and kills its helpers
  win-launch-check.ps1 launches the Windows exe on a CI runner
  win-build-hash.ps1   builds the Windows exe and records its SHA-256
  compare-sums.sh      asserts every build host recorded one sum per target
  winid.swift          lists every on-screen window and its bounds
  macinput.swift       posts synthetic mouse and keyboard events through CGEvent
  pixdiff.swift        counts differing pixels in one rectangle of two captures
```

Inside `win/src/`, `model.zig` holds every rule about what a row shows and
what an activation means. It imports `core` and `std` alone, so `zig build
test` runs its tests on the build host. `main.zig` owns the window, the
timers and the dialogs. `win32.zig` holds the externs and `clipboard.zig`
the clipboard writer. `text.zig` converts UTF-8 into a caller-sized UTF-16
buffer, and its tests run on the build host too. `crash.zig` holds the panic
handler.

The three Swift files above are one-shot tools. `screenshots.sh` and
`wine-check.sh` each compile the ones they need with `swiftc -O` into their
own work directory.

Both scripts create a wine prefix per run and call `wine-shutdown.sh` from
their cleanup trap. `wineboot --init` starts `services.exe`, `explorer.exe`,
`plugplay.exe`, `svchost.exe` and two `winedevice.exe` for the prefix. On wine
11.15 under Rosetta 2 those keep running after `wineserver -k` and after the
prefix directory is deleted, reparented to launchd. A run leaves 8 of them
without this call, and they accumulate until the Mac reboots. Their argv names
no prefix, so `wine-shutdown.sh` reads each candidate's cwd through `lsof` and
kills the ones inside the prefix it was given.

### A panic on Windows shows a message box

`build.zig` sets `win_exe.subsystem = .Windows`, so the process has no console
and Zig's default panic write to stderr reaches nobody. A panic there closes
the window and reports nothing.

`main.zig` declares `pub const panic = std.debug.FullPanic(crash.report)`.
`std.debug.panicExtra` formats each safety panic into text, so `crash.report`
receives strings like `index out of bounds: index 512, len 511`. The handler
shows that text, the return address and the issues URL in a `MessageBoxW` with
a null owner, then calls `std.process.exit(3)`.

`crash.report` calls `Model.wipeSecrets` first. `MessageBoxW` waits as long as
the user takes, and a memory dump taken during that wait would hold the
revealed password. `wipeSecrets` zeroes both 8192-byte buffers whole and reads
no stored length, because a panic can arrive with `revealed_len` set past the
buffer.

`MessageBoxW` runs a modal message loop that dispatches to this thread's
windows, so a panic inside `windowProc` re-enters `windowProc`. A `reporting`
flag turns a second panic into `exit(3)` with no message.

`ci.yml`'s two Windows jobs run `scripts/win-launch-check.ps1`, which asserts
the exe is still alive 5 seconds after launch. That assertion fails on a panic
during startup.

## Linking the core from another front end

`zig build` installs the static library at `zig-out/lib/libffpw.a` and the
header at `zig-out/include/ffpw.h`. A front end links those two. Any
language with a C FFI can call them. The SwiftUI app links them through a
raw `-L`/`-l` flag and uses no bridging header.

Call `ffpw_open` first. It returns `FFPW_ERR_NEEDS_PASSWORD` for a profile
with a Primary Password, so call `ffpw_unlock` next. Then `ffpw_entries`
fills a whole list in one call, `ffpw_search` filters it, and `ffpw_reveal`
returns one password. Release that password with `ffpw_secret_free`. It
zeroes the buffer before freeing it. One `ffpw_store` belongs to one
thread.

`core/test/smoke.c` calls every function in the header in order and runs as
`zig build smoke`.

### One open reads the disk, and nothing after it

`Store.open` is the only function that touches a file. `keydb.load` opens
`key4.db`, reads it and closes it before returning. `Store.open` then reads
all of `logins.json` into the arena and closes that too. `Store.reveal`
decrypts from the SDR blob and the master key already in the arena.

An open profile is therefore a snapshot. Firefox may rewrite either file
while a front end holds a `Store`, and the entry list stays as it was. A
login saved after the open appears when the front end calls `Store.open`
again. `switchProfile` in `win/src/main.zig` calls it for the profile
already selected, and `selectProfile` in `AppModel.swift` builds a fresh
store, so choosing the same profile reloads on both. The TUI opens once
per run.

`Store.open` landing while Firefox writes `key4.db` is the failure window,
and the known limitation below covers it. That path returns `OpenFailed`
or `Corrupt`, so a torn read reaches the front end as a message.

The decryption modules call no OS-specific API. The macOS assumptions live
in the front ends. `core.zig` and `tui/src/main.zig` build the profile
directory as `$HOME/Library/Application Support/Firefox`, and
`tui/src/main.zig` copies by running `pbcopy`. `win/src/main.zig` builds
`%APPDATA%\Mozilla\Firefox` and copies through `SetClipboardData`.

Each platform marks a copied password so a clipboard manager skips it.
macOS writes the `org.nspasteboard.ConcealedType` pasteboard type.
`win/src/clipboard.zig` registers four formats and writes all four ahead of
`CF_UNICODETEXT`, so a monitor reading the moment the text lands already
finds them:

- `CanIncludeInClipboardHistory` and `CanUploadToCloudClipboard` take a
  DWORD 0. These are Windows' own opt-outs for `Win+V` history and for the
  cloud clipboard.
- `ExcludeClipboardContentFromMonitorProcessing` takes any value. A monitor
  that finds it leaves the copy alone.
- `Clipboard Viewer Ignore` is the convention third-party managers honoured
  before Windows 10 named its own.

Both apps clear the clipboard 30 seconds after a copy, and both re-mask a
revealed password on the same timer. Each reads the clipboard's serial
number right after its own write and compares before it clears, so a copy
another program made in between stays: `GetClipboardSequenceNumber` on
Windows and `NSPasteboard.changeCount` on macOS. The TUI writes through
OSC 52 and `pbcopy` and arms no timer.

## Build and platform notes

`libsqlite3` reaches only `core/test/oracle.zig`, and that test builds on a
macOS host. `/usr/lib/libsqlite3.dylib` lives in the dyld shared cache on
macOS 11 and later, and linking resolves through the SDK stub at
`$(xcrun --show-sdk-path)/usr/lib/libsqlite3.tbd`. Pass `-Doracle=false` on
a host without the Command Line Tools. The C ABI library still links libc,
and that link needs the same SDK, so cross-compiling `libffpw.a` to macOS
from another host stays out of reach.

Three build hosts produce the same Windows exe, and `ci.yml` asserts it. Each
build job writes its exe's SHA-256 to the run summary and publishes it as a job
output: `build-and-test` cross-compiles both targets on `macos-15`, the host
`scripts/package-release.sh` runs on, `windows-test` builds `x86_64` twice in
parallel on `windows-latest`, and `windows-arm-test` cross-compiles `arm64` on
`windows-11-arm` through the emulated x86_64 toolchain. The `compare-sums` job
waits for all three and runs `scripts/compare-sums.sh` once per target. An
empty sum fails that job, since two missing values compare equal.

`windows-test` also fails when its own two builds disagree. `build.zig` pins
the cpu to a baseline, so the target string decides the code generation on
every host.

Nothing else links a C library. `zig build -Dtarget=x86_64-windows-gnu`,
`-Dtarget=aarch64-windows-gnu` and `-Dtarget=x86_64-linux-musl` all run on
this Mac. `build.zig` names `user32`, `comctl32`, `gdi32`, `dwmapi`,
`uxtheme` and `advapi32`, and Zig links `kernel32` for every Windows
target. Zig bundles a `.def` file for each one under
`lib/libc/mingw/lib-common/` and generates the import library from it, so
the Win32 link needs no Windows SDK.

Zig ships no `windows.h`. `win/app.rc` therefore defines every constant it
uses. Measured: without those defines the compile fails with
`expected number or number expression; got 'DS_MODALFRAME'`. The same file
gives the `Profile` popup one separator, because resinator rejects an empty
block with `empty menu of type 'POPUP' not allowed`, and
`buildProfileMenu` deletes that separator after it inserts the profiles.

Win32 hands out pointers that miss their natural alignment, and
`@ptrFromInt` checks alignment in Debug and in ReleaseSafe. These casts
carry `align(1)`:

- `win32.zig` declares `LPCWSTR` as `[*:0]align(1) const WCHAR`, because
  `intResource` turns a resource id into a pointer and `IDI_APP` is 1.
  Windows reads a pointer whose high word is zero as an id in the low word.
- `onNotify` reads `NMHDR` through an `align(1)` pointer, because
  commctrl.h declares `NMLVKEYDOWN` inside `pshpack1.h`. Measured: an arrow
  key in the list delivered `lparam = 0x11125aa`, 2 bytes off an 8-byte
  boundary. `NMHDR`'s three fields sit at offsets 0, 8 and 16 in the packed
  layout and in the unpacked one.

The message loop calls `IsDialogMessageW`, so Tab moves the focus between
the search box and the list. Both carry `WS_TABSTOP`. The call runs after
`TranslateAcceleratorW`, so the accelerator table keeps Enter and Escape.
`WM_SETFOCUS` on the frame hands the focus to the search box. That covers
the launch and a click on the frame.

The loop passes `WM_SYSKEYDOWN`, `WM_SYSKEYUP` and `WM_SYSCHAR` straight to
`TranslateMessage`. `IsDialogMessage` swallows those three while a modeless
dialog is active, and the frame's menu mnemonics then stop working.

`TranslateAcceleratorW` matches whatever control holds the focus, so Ctrl+C
over a selected search term used to copy the selected row's password. The
`IDM_ROW_COPY` branch reads the HIWORD of `wParam`, which is 1 for an
accelerator and 0 for a menu item, and sends `WM_COPY` to the search box in
the accelerator case.

The `x86_64-windows-gnu` exe runs under wine on macOS.
`scripts/screenshots.sh win` writes the README image there, and
`scripts/wine-check.sh` asserts behaviour and exits non-zero on a failure.
Measured under wine 11.15: the profile list, the search filter, reveal,
copy, the 30-second clipboard clear, the 30-second re-mask, the
account-row confirmation, the context menu, the `Profile` menu, the
Primary Password dialog and the failure message box.

wine's Mac driver bridges the Win32 clipboard to `NSPasteboard` in
`dlls/winemac.drv/clipboard.c`, so `pbpaste` reads what a copy put there.
`pbpaste` reads plain text alone, and the four registered privacy formats
never appear in it. comctl32 moves the list selection on `WM_RBUTTONDOWN`,
so `showRowMenu` acts on the row the cursor is over.

Option+P under wine typed a literal character into the search box, both
through System Events and through a CGEvent carrying `.maskAlternate`. The
menu mnemonics still need a Windows machine.

macOS App Sandbox needs a per-run open panel before it allows reading
another app's data directory. TCC leaves `~/Library/Application Support`
open to any process outside the sandbox, so the app reads a profile with
no permission prompt.

## Known limitations

- `oids.zig`'s `Cipher.fromOid` knows two OIDs, AES-256-CBC and legacy
  3DES. Firefox 152.0.6 writes no others. A profile using any other
  cipher stops at `error.UnsupportedCipher` from `sdr.parse`. Adding one
  means adding its OID and an implementation.
- Reading `key4.db` while Firefox has it open works. Verified against
  Firefox 152.0.6 running with its `.parentlock` held, decrypting the
  same 1701 entries as a closed-Firefox run, and no `key4.db-wal`
  appeared. A read landing mid-write with a WAL file present is
  untested. Reaching that state needs a write to a live profile.
  `sqlitedb.zig` reads the write version at header offset 18 and returns
  `error.WalJournal` for a value of 2. Every committed `key4.db` reports 1.
- `zig build test --fuzz` does not run on the pinned Zig 0.16.0. Zig's
  bundled `test_runner.zig` passes a `*builtin.StackTrace` to
  `std.debug.writeStackTrace`, whose signature now wants
  `*debug.StackTrace`. The runner fails to compile. Plain `zig build
  test` still runs the fuzz corpus once, with no mutation.
- Zig 0.16.0's `aarch64-windows` build cannot run `zig build`. On a
  `windows-11-arm` runner it answers `zig version` and `zig env`, then exits
  `-1073741819`, an access violation, printing nothing. `ci.yml`'s
  `windows-arm-test` therefore runs the `x86_64-windows` toolchain under
  Windows-on-ARM emulation and cross-compiles with
  `-Dtarget=aarch64-windows-gnu`. `zig build test` runs on `windows-latest`
  and on `macos-15`. No machine runs the core tests compiled for arm64
  Windows.
- Linux is deferred. The core builds for `x86_64-linux-musl` on a
  development Mac, and no CI job compiles that target. A Linux TUI needs the
  profile directory (`~/.mozilla/firefox`) and a clipboard call to replace
  `pbcopy`.
- The Windows TUI is out of scope. `tui/src/main.zig` calls
  `std.process.Args.Iterator.init`, and that function is a compile error on
  Windows. `build.zig` installs `ffpw` only for a non-Windows target.
- The Windows app follows the system dark-mode setting at startup only. It
  reads `AppsUseLightTheme` once and handles no `WM_SETTINGCHANGE`.
- One machine building the release twice produces byte-identical output.
  That holds across a clean cache, a different absolute path, `-j1`
  against `-j4`, and ad-hoc codesigning. Two machines with different
  macOS SDKs installed produce different bytes from the same source.
  Zig's macOS linker hashes SDK-derived bytes into the binary's
  `LC_UUID`. `vtool(1)` rewrites `LC_BUILD_VERSION`. It has no option for
  `LC_UUID`. Closing this needs the macOS SDK vendored into every build
  environment, as `zig-build-macos-sdk` does for Ghostty. Until then
  `Formula/ffpw.rb` and `Casks/firefox-password-view.rb` carry CI's hash,
  printed by `ci.yml`'s `reproducible-build` job on every push.

## Prior art

- `firepwd.py` (lclevy) — pure Python, no NSS, updated October 2025 for
  the Firefox 144 change. Cross-check format questions against this one.
  The IV construction above came from it.
- `firefox_decrypt` (unode) — Python, calls into NSS. Run it on the same
  profile to compare this core's output against NSS itself.
