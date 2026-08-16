# Design notes

Byte-level detail and decisions behind the core, measured against a live
Firefox 152.0.6 profile on macOS 15.7.7 arm64, Zig 0.16.0. `README.md` covers
usage and the threat model; this covers the format and the reasoning.

## Where Firefox stores the data

- `logins.json` — one record per saved login. The on-disk keys are `hostname`,
  `httpRealm`, `formSubmitURL`, `usernameField`, `passwordField`,
  `encryptedUsername`, `encryptedPassword`, `guid`, `encType`, `timeCreated`,
  `timeLastUsed`, `timePasswordChanged`, `timesUsed`, `encryptedUnknownFields`.
  There is no `origin` key; that name belongs to the JavaScript side.
- `key4.db` — SQLite. `metaData` holds the global salt and the password-check
  value under `id = 'password'`. `nssPrivate` holds the wrapped master keys.
- `cert9.db` — certificate store, unused here.

`metaData` carried about seventy rows on the measured profile and
`nssPrivate` carried three, so both queries filter rather than taking the
first row.

### Two master keys, one key id

`nssPrivate` holds **two** rows under CKA_ID `f8000000000000000000000000000001`
with object class `CKO_SECRET_KEY` (`a0 = x'00000004'`):

| wrapped size | decrypted size | key |
|---|---|---|
| 32 bytes | 24 bytes | legacy 3DES |
| 48 bytes | 32 bytes | AES-256, added by Firefox 144 |

Firefox 144 adds the AES-256 key and leaves the 3DES key in place. Reading one
row returns the legacy key, and every AES entry then fails its PKCS7 check.
Both rows are unwrapped and sorted by decrypted length.

### Firefox 144 migrated the whole store at once

1625 of the 1701 encrypted entries on the measured profile were created
before October 2025, and the oldest dates to March 2011. All 1701 use
AES-256: Firefox does not re-encrypt an entry only when it is added or
edited, the 144 upgrade re-encrypted the entire store at once.

### A Primary Password changes the global salt's size, and its hash

A never-initialized token stores metaData's global salt as 20 raw bytes and
seeds its key derivation with SHA-1. Setting a Primary Password for the
first time replaces it with a 48-byte salt and reseeds with SHA-384 instead
(`sftkdb_passwordToKey` in NSS's softoken picks the hash by matching the
salt's length). Seeding with SHA-1 regardless makes the correct password
look wrong, indistinguishable from an incorrect one.

### profiles.ini

Since Firefox 67 the `[InstallXXXX]` section names the profile for a given
installation. `Default=1` under `[ProfileN]` is the pre-67 fallback. On the
measured machine `Default=1` sits on a profile that contains no `key4.db`,
and the real profile is named only by the install section. Resolution reads
the install section first.

### Sync deletion tombstones and two non-web schemes

A profile synced to a Mozilla Account leaves encryption unaffected, but not
the data model.

2 records in `logins.json` carry `{deleted: true, everSynced, guid, id,
syncCounter, timePasswordChanged}` and no hostname and no encrypted fields.
These are deletions still held for propagation to other devices, not
entries missing data; the store filters them before counting rather than
reporting them as failures.

One entry has `hostname = chrome://FirefoxAccounts` and
`httpRealm = Firefox Accounts credentials`. Its username is the Mozilla
Account email and its decrypted password is a JSON document holding sync
key material, so revealing it hands over the account rather than one site
password. The store labels this row `account_credential` rather than
`normal`. Entries can also carry a `moz-extension://` origin, labelled
`extension`; hostname parsing must not assume `http` or `https`.

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
Password is set; it is read from the structure either way.

**Decrypting a logins.json field:** base64-decode, then parse
`SEQUENCE { OCTET keyId, SEQUENCE { OID cipher, OCTET iv }, OCTET ciphertext }`.
Here the IV is the element **body**, 16 bytes, used directly. Decrypt with
the 32-byte master key.

`metaData.item2` decrypts to the ASCII string `password-check`. This
confirms the Primary Password before any key material is unwrapped, and it
needs no credential, which makes it the test gate for the whole chain.

## Decisions

| Decision | Choice | Rejected alternative |
|---|---|---|
| Crypto source | Reimplement PBES2 in Zig | Linking NSS needs a matching libnss3 per platform and a bundled dylib on macOS |
| 3DES | Not implemented. `sdr.decrypt` returns `LegacyTripleDes` | A DES implementation adds roughly 300 lines of legacy cipher that 0 of 1701 entries need |
| DER | Own bounds-checked reader | `std.crypto.Certificate.der` has no bounds checks, no canonical-form checks and no tests (ziglang/zig#19775) |
| C interop | `b.addTranslateC` | `@cImport` is deprecated in Zig 0.16 |
| SQLite | System library for now | Windows ships none; see Build and platform notes below |
| Zig | Pin 0.16.0 | Tracking master breaks on each stdlib redesign |
| Reveal | Masked by default, reveal one entry, copy to clipboard | Printing every password fills terminal scrollback |
| Architecture | `aarch64-macos` only, for now | A universal binary earns its lipo step only once a second architecture is in scope |
| Fixtures | Written by a real Firefox over Marionette, committed under `core/testdata/` | A generator built from this project's own reading of the format would only prove the reader agrees with the writer |

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
amalgamation and compile it with Zig's bundled clang; that also makes macOS
and Linux builds hermetic. The rejected alternative, a hand-written reader
for the SQLite page format, needs varint decoding, overflow pages and
freelist handling on a read path that must not return wrong bytes.

macOS App Sandbox would block reading another app's data directory without
a per-run open panel. Outside the sandbox, `~/Library/Application Support`
is not TCC-protected, so no permission prompt appears.

## Known limitations

- Zig 0.16 removed `std.posix.getenv`, `std.time.Timer` and the old
  `std.fs` entry points, and moved filesystem access under `std.Io`. Each
  Zig upgrade needs migration time; the compiler version stays pinned.
- Firefox changed this format in October 2025. Cipher selection reads the
  OID from the file, so a further format change surfaces as an explicit
  unsupported-cipher error rather than silent corruption.
- Reading `key4.db` while Firefox holds it open works: verified with
  Firefox 152.0.6 running and its `.parentlock` held, decrypting the same
  1701 entries as a closed-Firefox run. No `key4.db-wal` appeared during
  that session. A read landing mid-write, while a WAL file exists, is
  still unverified: producing that state on demand needs a real write to
  a real profile, which stays out of scope for a test.
- `zig build test --fuzz` does not run on the pinned Zig 0.16.0: its own
  bundled `test_runner.zig` calls `std.debug.writeStackTrace` with the old
  `*builtin.StackTrace` where the signature now wants `*debug.StackTrace`,
  a compile error in Zig's own runner. Plain `zig build test` still runs
  the fuzz corpus once, with no mutation.
- Windows and Linux are deferred; see Build and platform notes above for
  what a Windows target still needs.

## Prior art

- `firepwd.py` (lclevy) — pure Python, no NSS, updated October 2025 for the
  Firefox 144 change. The reference for the IV construction above.
- `firefox_decrypt` (unode) — Python, links NSS.
- `PasswordFox` (NirSoft) — closed source, Windows only, version 1.75 added
  Firefox 144 support.
- Firefox Lockwise — Mozilla's mobile app, discontinued December 2021. No
  desktop equivalent exists.
