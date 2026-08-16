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

Both tables hold rows this reader has to skip. `metaData` also holds
`sig_key_*` rows, so the query selects `id = 'password'`. `nssPrivate`
also holds non-key objects, so the query filters on CKA_ID and object
class. Both queries are in `keydb.zig`. Taking the first row of either
table returns the wrong bytes.

### Two master keys, one key id

A profile Firefox 144 has opened holds **two** rows under CKA_ID
`f8000000000000000000000000000001` with object class `CKO_SECRET_KEY`
(`a0 = x'00000004'`):

| wrapped size | decrypted size | key |
|---|---|---|
| 32 bytes | 24 bytes | legacy 3DES |
| 48 bytes | 32 bytes | AES-256, added by Firefox 144 |

Firefox 144 adds the AES-256 key and leaves the 3DES key in place. Reading one
row returns the legacy key, and every AES entry then fails its PKCS7 check.
Both rows are unwrapped and sorted by decrypted length.

### Firefox 144 migrated the whole store at once

An entry's timestamps say nothing about its cipher. Read the OID from the
entry. On the measured profile, 1625 of the 1701 entries predate October
2025 and the oldest dates to March 2011, and all 1701 use AES-256. The
144 upgrade re-encrypted every entry in one pass. The `unmigrated` and
`migrated` fixtures are the same profile before and after that pass.

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
and the real profile is named only by the install section. Resolution reads
the install section first.

### Sync tombstones and the non-web schemes

A profile synced to a Mozilla Account uses the same encryption as any
other profile. It adds records that a reader written against an unsynced
profile mishandles.

A tombstone carries `{deleted: true, everSynced, guid, id, syncCounter,
timePasswordChanged}` and no hostname or encrypted field. These are
deletions held for propagation to other devices. A reader that treats a
missing hostname as an error reports every tombstone as a failure.
`logins.zig` counts them under `tombstones_skipped` and leaves them out
of the entry list. The `sync-shaped` fixture carries two.

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
that body to AES as the 16-byte IV. Passing the body alone produces garbage.

`iterations` was 1 on a never-initialized token and 10000 once a Primary
Password is set. It is read from the structure either way.

**Decrypting a logins.json field:** base64-decode, then parse
`SEQUENCE { OCTET keyId, SEQUENCE { OID cipher, OCTET iv }, OCTET ciphertext }`.
Here the IV is the element **body**, 16 bytes, used directly. Decrypt with
the 32-byte master key.

`metaData.item2` decrypts to the ASCII string `password-check`. This
confirms the Primary Password before any key material is unwrapped.
Checking it needs no credential.

## Decisions

| Decision | Choice | Rejected alternative |
|---|---|---|
| Crypto source | Reimplement PBES2 in Zig | Linking NSS needs a matching libnss3 per platform and a bundled dylib on macOS |
| 3DES | Not implemented. `sdr.decrypt` returns `LegacyTripleDes` | A DES implementation adds roughly 300 lines of legacy cipher that 0 of 1701 entries need |
| DER | Own bounds-checked reader | `std.crypto.Certificate.der` has no bounds checks, no canonical-form checks and no tests (ziglang/zig#19775) |
| C interop | `b.addTranslateC` | `@cImport` is deprecated in Zig 0.16 |
| SQLite | System library for now | Windows ships none. See Build and platform notes below |
| Zig | Pin 0.16.0 | Tracking master breaks on each stdlib redesign |
| Reveal | Masked by default, reveal one entry, copy to clipboard | Printing every password fills terminal scrollback |
| Architecture | Ship one `aarch64-macos` slice | A universal binary adds a lipo step and a second build for an architecture no release targets |
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
  keydb.zig      reads key4.db, returns the master keys
  logins.zig     decrypts and classifies logins.json entries
  store.zig      owns the arena, the keys, the entries, and the search filter
  core.zig       exports the C ABI both front ends link, core/include/ffpw.h
  root.zig       the module boundary a front end imports through
  main.zig       validation probe
  c.h            sqlite3 and stdlib headers for addTranslateC
  tests.zig      NIST and DER vectors, and fixture round-trips
build.zig
tui/src/        the libvaxis TUI, imports store.zig through root.zig
macos/          the SwiftUI app, a Swift package linking core.zig's static library
```

## Build and platform notes

`/usr/lib/libsqlite3.dylib` does not exist as a file on macOS 11 and later.
It lives in the dyld shared cache, and linking resolves through the SDK
stub at `$(xcrun --show-sdk-path)/usr/lib/libsqlite3.tbd`. Building
therefore needs the Command Line Tools, and cross-compiling to macOS from
another host does not work as configured.

Windows ships no system SQLite. Before a Windows target, vendor the SQLite
amalgamation and compile it with Zig's bundled clang. That also makes
macOS and Linux builds hermetic. The rejected alternative, a hand-written
reader for the SQLite page format, needs varint decoding, overflow pages
and freelist handling on a read path that must not return wrong bytes.

macOS App Sandbox needs a per-run open panel before it allows reading
another app's data directory. Outside the sandbox, `~/Library/Application
Support` is not TCC-protected, so no permission prompt appears.

## Known limitations

- `oids.zig`'s `Cipher.fromOid` knows two OIDs, AES-256-CBC and legacy
  3DES. Firefox 152.0.6 writes no others. A profile using any other
  cipher stops at `error.UnsupportedCipher` from `sdr.parse`. Adding one
  means adding its OID and an implementation.
- Reading `key4.db` while Firefox has it open works. Verified against
  Firefox 152.0.6 running with its `.parentlock` held, decrypting the
  same 1701 entries as a closed-Firefox run, and no `key4.db-wal`
  appeared. A read landing mid-write with a WAL file present is
  untested. Reaching that state needs a write to a live profile. No test
  here performs one.
- `zig build test --fuzz` does not run on the pinned Zig 0.16.0. Zig's
  bundled `test_runner.zig` passes a `*builtin.StackTrace` to
  `std.debug.writeStackTrace`, whose signature now wants
  `*debug.StackTrace`. The runner fails to compile. Plain `zig build
  test` still runs the fuzz corpus once, with no mutation.
- Windows and Linux are deferred. `der`, `oids`, `aescbc`, `pbes2`,
  `sdr`, `keydb`, `logins` and `store` call no OS-specific API. A Linux
  TUI needs the profile directory (`~/.mozilla/firefox`) and a clipboard
  call to replace `pbcopy`. Windows needs both of those and a vendored
  SQLite.
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
