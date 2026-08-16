# Firefox Password Viewer — Technical Plan

Date: 2026-08-15. Supersedes the v1 feasibility report.

## 1. Status

The decryption core is built and verified against a live profile. `zig build
run` reports:

```
profiles:  2 found
profile:   ~/Library/Application Support/Firefox/Profiles/cbl1mroj.default-release
password-check verified with an empty Primary Password
aes256 key: present (32 bytes)
3des key:   present (24 bytes)
logins:    1701 total, 1701 decrypted, 0 legacy 3des, 2 tombstones skipped, 0 malformed
kinds:     1 account credential, 4 extension
```

Section 3, "Sync deletion tombstones and two non-web schemes", explains why
the login total is 1701 rather than the 1703 rows `logins.json` holds.

The TUI and the SwiftUI app are both built on top of this core; see the
plan's milestones for each. Everything in sections 3 and 4 was measured on
that profile, not inferred from other projects.

Verified environment: Firefox 152.0.6, macOS 15.7.7 arm64, Zig 0.16.0.

## 2. Goal and non-goals

Read a local Firefox profile's saved logins and show them to the profile owner.
A TUI runs on macOS, Linux and Windows. A SwiftUI app covers macOS.

Out of scope: writing or editing logins, `cert9.db`, Firefox Sync, form autofill,
credit cards, other Mozilla products, and recovering an unknown Primary Password.

Profiles that Firefox 144 or newer has never opened are also out of scope. They
hold 3DES entries, and this tool reports them rather than decrypting them.

## 3. Where Firefox stores the data

- `logins.json` — one record per saved login. The on-disk keys are `hostname`,
  `httpRealm`, `formSubmitURL`, `usernameField`, `passwordField`,
  `encryptedUsername`, `encryptedPassword`, `guid`, `encType`, `timeCreated`,
  `timeLastUsed`, `timePasswordChanged`, `timesUsed`, `encryptedUnknownFields`.
  There is no `origin` key; that name belongs to the JavaScript side.
- `key4.db` — SQLite. `metaData` holds the global salt and the password-check
  value under `id = 'password'`. `nssPrivate` holds the wrapped master keys.
- `cert9.db` — certificate store, unused here.

`metaData` carried about seventy rows on the test profile and `nssPrivate`
carried three, so both queries filter rather than taking the first row.

### Two master keys, one key id

`nssPrivate` holds **two** rows under CKA_ID `f8000000000000000000000000000001`
with object class `CKO_SECRET_KEY` (`a0 = x'00000004'`):

| wrapped size | decrypted size | key |
|---|---|---|
| 32 bytes | 24 bytes | legacy 3DES |
| 48 bytes | 32 bytes | AES-256, added by Firefox 144 |

Firefox 144 adds the AES-256 key and leaves the 3DES key in place. Reading one
row returns the legacy key, and every AES entry then fails its PKCS7 check. Both
rows are unwrapped and sorted by decrypted length.

### Firefox 144 migrated the whole store at once

1625 of the 1701 encrypted entries on the test profile were created before
October 2025, and the oldest dates to March 2011. All 1701 use AES-256. The v1
report claimed Firefox re-encrypts an entry only when it is added or edited.
That is wrong: the upgrade re-encrypted the entire store.

### profiles.ini

Since Firefox 67 the `[InstallXXXX]` section names the profile for a given
installation. `Default=1` under `[ProfileN]` is the pre-67 fallback. On the test
machine `Default=1` sits on a profile that contains no `key4.db`, and the real
profile is named only by the install section. Resolution reads the install
section first.

### Sync deletion tombstones and two non-web schemes

The test profile syncs to a Mozilla Account. Encryption is unaffected, but the
data model is not.

2 records in `logins.json` carry `{deleted: true, everSynced, guid, id,
syncCounter, timePasswordChanged}` and no hostname and no encrypted fields.
These are deletions still held for propagation to other devices, not entries
missing data; the store filters them before counting rather than reporting
them as failures.

One entry has `hostname = chrome://FirefoxAccounts` and
`httpRealm = Firefox Accounts credentials`. Its username is the Mozilla
Account email and its decrypted password is a JSON document holding sync key
material, so revealing it hands over the account rather than one site
password. The store labels this row `account_credential` rather than
`normal`. 4 entries carry a `moz-extension://` origin and are labelled
`extension`; hostname parsing must not assume `http` or `https`.

## 4. The decryption chain

Both layers use PBKDF2 and AES-256-CBC. They differ in how the IV is carried.

**Unwrapping a key4.db value** (`metaData.item2` and each `nssPrivate.a11`):

```
seed = SHA1(globalSalt ‖ primaryPassword)
key  = PBKDF2-HMAC-SHA256(seed, entrySalt, iterations, keyLength)
iv   = the full DER encoding of the IV element, header included
plain = AES-256-CBC-decrypt(ciphertext, key, iv), PKCS7 stripped
```

The IV element carries a 14-byte body. NSS feeds the two header octets plus that
body to AES as the 16-byte IV. Passing the body alone produces garbage.

`iterations` was 1 on the test profile. It is read from the structure.

**Decrypting a logins.json field:** base64-decode, then parse
`SEQUENCE { OCTET keyId, SEQUENCE { OID cipher, OCTET iv }, OCTET ciphertext }`.
Here the IV is the element **body**, 16 bytes, used directly. Decrypt with the
32-byte master key.

`metaData.item2` decrypts to the ASCII string `password-check`. This confirms the
Primary Password before any key material is unwrapped, and it needs no
credential, which makes it the test gate for the whole chain.

## 5. Decisions

| Decision | Choice | Rejected alternative |
|---|---|---|
| Crypto source | Reimplement PBES2 in Zig | Linking NSS needs a matching libnss3 per platform and a bundled dylib on macOS |
| 3DES | Not implemented. `sdr.decrypt` returns `LegacyTripleDes` | A DES implementation adds roughly 300 lines of legacy cipher that 0 of 1701 entries need |
| DER | Own bounds-checked reader | `std.crypto.Certificate.der` has no bounds checks, no canonical-form checks and no tests (ziglang/zig#19775) |
| C interop | `b.addTranslateC` | `@cImport` is deprecated in Zig 0.16 |
| SQLite | System library for now | Windows ships none; see section 8 |
| Zig | Pin 0.16.0 | Tracking master breaks on each stdlib redesign |
| Reveal | Masked by default, reveal one entry, copy to clipboard | Printing every password fills terminal scrollback |

## 6. Module layout

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

`des.zig` from the v1 plan is not built.

## 7. Front ends

**TUI** on `libvaxis` (Zig 0.16, `vxfw` framework, macOS/Linux/Windows). The list
holds 1701 entries on the test profile, so incremental search over hostname and
username is required rather than optional.

**SwiftUI** on macOS links the same static library through a bridging header.

Both mask passwords by default. Reveal acts on one entry at a time. Copy writes
to the clipboard marked `org.nspasteboard.ConcealedType`, which keeps clipboard
managers from recording it, and clears after a timeout.

## 8. Build and platform notes

`/usr/lib/libsqlite3.dylib` does not exist as a file on macOS 11 and later. It
lives in the dyld shared cache, and linking resolves through the SDK stub at
`$(xcrun --show-sdk-path)/usr/lib/libsqlite3.tbd`. Building therefore needs the
Command Line Tools, and cross-compiling to macOS from another host does not
work as configured.

Windows ships no system SQLite. Before the Windows target, vendor the SQLite
amalgamation and compile it with Zig's bundled clang. That also makes macOS and
Linux builds hermetic. The rejected alternative, a hand-written reader for the
SQLite page format, needs varint decoding, overflow pages and freelist handling
on a read path that must not return wrong bytes.

macOS distribution is Developer ID signed and notarized, outside the Mac App
Store. App Sandbox would block reading another app's data directory without a
per-run open panel. Outside the sandbox `~/Library/Application Support` is not
TCC-protected, so no permission prompt appears.

## 9. Security

- Open `key4.db` read-only. Never copy profile files.
- Wipe plaintext with `std.crypto.secureZero`. A plain `@memset` can be
  optimized away.
- Prompt for the Primary Password only when the password-check fails with an
  empty string. Never store it.
- No network calls and no telemetry.

## 10. Risks

- Zig 0.16 removed `std.posix.getenv`, `std.time.Timer` and the old `std.fs`
  entry points, and moved filesystem access under `std.Io`. Each upgrade needs
  migration time. The compiler version is pinned.
- `aescbc.zig`, `der.zig` and the PBES2 parsing are original code. They are
  covered by NIST vectors and by the password-check gate on a real profile.
- Firefox changed this format in October 2025. Cipher selection reads the OID
  from the file, so a further change surfaces as an explicit unsupported-cipher
  error.
- Tested against the real profile with Firefox 152.0.6 open and its
  `.parentlock` held: the probe still reads and decrypts correctly, 1701
  total and 1701 decrypted, matching a closed-Firefox run. No `key4.db-wal`
  appeared during that session; NSS did not hold one open while idle. A
  read landing mid-write, while a WAL file exists, is still unverified,
  since producing that state on demand isn't possible without triggering a
  real write to the owner's profile.

## 11. Next steps

The C ABI, the TUI, the Primary Password prompt, and the SwiftUI shell are
built; see the plan's milestones for what each covers and how it was
verified. What is left here:

1. Vendor the SQLite amalgamation before targeting Windows.

## 12. Prior art

- `firepwd.py` (lclevy) — pure Python, no NSS, updated October 2025 for the
  Firefox 144 change. The reference for the IV construction in section 4.
- `firefox_decrypt` (unode) — Python, links NSS.
- `PasswordFox` (NirSoft) — closed source, Windows only, version 1.75 added
  Firefox 144 support.
- Firefox Lockwise — Mozilla's mobile app, discontinued December 2021. No
  desktop equivalent exists.
