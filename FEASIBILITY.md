# Firefox Password Viewer — Technical Feasibility Report

Date: 2026-08-15

## 1. Goal

Read a local Firefox profile's saved logins and show them to the profile's
owner, without Firefox running, with low memory and CPU use, and with a
Zig core reused across a macOS native UI and a cross-platform TUI.

## 2. Where Firefox stores the data

A Firefox profile keeps three files relevant to this task:

- `logins.json` — one JSON record per saved login: origin URL, encrypted
  username, encrypted password, timestamps.
- `key4.db` — a SQLite database. Table `metaData` holds a global salt and
  a "password-check" value. Table `nssPrivate` holds the master key that
  Firefox uses to encrypt every entry in `logins.json`.
- `cert9.db` — certificate store, not needed for this task.

On macOS the profile sits at
`~/Library/Application Support/Firefox/Profiles/<name>.default-release/`,
with `profiles.ini` in the parent folder listing all profiles.

Format history, confirmed against the `firepwd` and `firefox_decrypt`
projects:

- Firefox < 32: `key3.db` (Berkeley DB) + `signons.sqlite`.
- Firefox ≥ 32: `key3.db` + `logins.json`.
- Firefox ≥ 58.0.2: `key4.db` (SQLite) + `logins.json`. This is the
  format in every supported Firefox release today.
- Firefox ≥ 75.0 (NSS 3.49, April 2020): the master key inside `key4.db`
  is wrapped with PBKDF2-SHA256 + AES-256-CBC.
- Firefox ≥ 144 (October 2025): the individual login fields in
  `logins.json` switched from 3DES-CBC to AES-256-CBC. A profile last
  touched before this release can still hold 3DES-encrypted entries next
  to newer AES-256 ones, since Firefox re-encrypts an entry only when it
  is added or edited. A reader built today must support both ciphers.

## 3. Decryption without running Firefox

Firefox protects the master key with a key derived from the user's
Primary Password (called "Master Password" before Firefox 58). Most
users never set one, in which case the derivation uses an empty string.
When a Primary Password is set, the tool needs it from the user before
it can decrypt anything, the same requirement `firefox_decrypt` and
`PasswordFox` both have.

Three ways exist to perform the decryption:

**A. Link against NSS (`libnss3`).** Call `NSS_Init` against the profile
path, then `PK11SDR_Decrypt` on each base64 blob from `logins.json`. This
is what `unode/firefox_decrypt` does. On Linux this now requires
`libnss3` 3.113 or newer to read a Firefox 144+ profile. On macOS, NSS
ships inside `Firefox.app/Contents/Frameworks/`, so a standalone tool
would need to bundle its own `libnss3.dylib` (for example via Homebrew's
`nss` package) rather than reuse Firefox's copy from the app bundle.

**B. Reimplement the NSS crypto directly.** Read the global salt and
wrapped master key from `key4.db`, DER-decode the ASN.1 structure
around them, derive a key with PBKDF2, and decrypt with AES-256-CBC or
3DES-CBC depending on the OID found in the structure. Then decrypt each
`logins.json` field the same way. This is what `firepwd.py` and
`hack-browser-data` do, and it needs no NSS binary at all. The relevant
OIDs, confirmed from the `firepwd` source:

  - `1.2.840.113549.1.12.5.1.3` — PBE-SHA1-3DES (legacy master-key wrap).
  - `1.2.840.113549.1.5.13` — PBES2 (current master-key wrap container).
  - `1.2.840.113549.1.5.12` — PBKDF2.
  - `1.2.840.113549.2.9` — HMAC-SHA256 (PBKDF2 PRF).
  - `2.16.840.1.101.3.4.1.42` — AES-256-CBC.

**C. Shell out to Firefox itself.** Firefox's own `about:logins` page can
export all saved logins to a plaintext CSV file. This is the only method
Mozilla documents and supports. It needs Firefox installed and running,
and produces a plaintext file on disk, which the report's target tool
is meant to avoid.

Option B is the right fit for a standalone, low-footprint tool: no
dependency on a specific NSS build, no need for Firefox to be installed,
full control over memory handling of the decrypted secrets.

## 4. Building option B in Zig

- **SQLite access.** `key4.db` is a plain SQLite file. macOS ships
  `libsqlite3.dylib` in `/usr/lib`, linkable straight from Zig with no
  bundled copy needed. `vrischmann/zig-sqlite` wraps the C API; it works
  against system SQLite on macOS/Linux. Its own docs say to expect
  breaking changes on every Zig update until Zig reaches 1.0.
- **JSON.** `logins.json` parses with `std.json` from Zig's standard
  library. No extra dependency.
- **PBKDF2.** Built into `std.crypto` (`std.crypto.pbkdf2`), with SHA-1
  and SHA-256 both available as the PRF.
- **AES-256.** The raw block cipher is in `std.crypto.core.aes.Aes256`.
  CBC mode is not: Zig's standard library has no built-in block-cipher
  mode wrapper (open issue since 2020). CBC over AES-256 is short to
  write by hand — XOR the previous ciphertext block into the plaintext
  before each block encrypt/decrypt call — but it is code this project
  must own and test itself.
- **3DES.** Not in `std.crypto` at all. DES is a well-documented, fixed
  algorithm (16 rounds, a known S-box table, a 64-bit block); a from-
  scratch Zig implementation is a few hundred lines and needs test
  vectors from NIST or from the `firepwd` project to check against. This
  is required only to read entries created before Firefox 144.
- **ASN.1 DER parsing.** No existing Zig library was found for this. The
  structures inside `key4.db` and inside each `logins.json` blob are a
  small, fixed subset of DER (SEQUENCE, OCTET STRING, OBJECT IDENTIFIER,
  INTEGER). A minimal hand-written parser covering only this subset is
  practical and keeps the dependency count at zero.

None of the above blocks the project. It does mean the crypto and ASN.1
layers are original code, not a wrapped library, so they carry the
correctness and audit burden of any cryptographic code written in-house.

## 5. UI layer

**Zig core.** Export a small C ABI surface from Zig: open a profile
path, list logins (origin, username, decrypted or locked state), unlock
with a given Primary Password, decrypt one entry, and zero any buffer
holding decrypted data once the caller releases it. This matches the
pattern Mitchell Hashimoto documented for Zig-plus-SwiftUI projects:
the shared logic compiles to a static library with a C ABI, and each
platform's native UI links against it directly.

**Cross-platform TUI.** `rockorager/libvaxis` is an actively maintained
Zig TUI library, built for Zig 0.16, running on macOS, Linux, BSD, and
Windows. Its high-level `vxfw` API gives a widget-based application
runtime, a reasonable fit for a login list plus a detail/reveal view.

**macOS native UI.** A small SwiftUI app links the Zig static library
through a bridging header and calls the exported C functions directly.
No shared library loading step is needed; the Zig code becomes part of
the app binary.

**Windows/Linux native UI, later.** The same static library, compiled
for each target, can back a native Win32/WinUI front end later. Until
then the TUI already runs unmodified on Windows and Linux.

## 6. Security and distribution notes

- Read the profile files only; never copy `key4.db` or `logins.json` out
  of the profile folder, and never write decrypted values to disk.
- Zero the memory holding a decrypted password as soon as the UI is done
  displaying it, and re-derive it on demand rather than caching a full
  decrypted list.
- Prompt for the Primary Password only when `key4.db` shows one is set,
  and never store it.
- On macOS, distribute Developer-ID-signed and notarized, outside the
  Mac App Store. Mac App Store distribution would force App Sandbox,
  which blocks reading `~/Library/Application Support/Firefox/...`
  without the user picking the folder through an open panel each run,
  since no sandbox entitlement covers another app's data folder.
  Outside the sandbox, `~/Library/Application Support/` is not one of
  the TCC-protected folders (Desktop, Documents, Downloads, Photos,
  Mail, Messages, Safari, and similar are), so a signed, non-sandboxed
  app reads the profile with no extra permission prompt.
- Treat this as a single-user, local, offline tool: no telemetry, no
  network calls, so no server-side attack surface to consider.

## 7. Prior art, for comparison

- `firepwd.py` (lclevy) — pure Python, no NSS dependency, updated
  October 2025 for the Firefox 144 AES-256 change. The clearest
  reference implementation for the crypto in section 3, option B.
- `firefox_decrypt` (unode) — Python, links NSS, the option-A approach.
- `PasswordFox` (NirSoft) — closed-source, Windows-only, version 1.75
  (October 23, 2025) added Firefox 144 support; since version 1.60 it no
  longer needs Firefox installed, meaning it also reimplements the NSS
  crypto rather than loading `nss3.dll`.
- Firefox Lockwise — Mozilla's mobile companion app, discontinued in
  December 2021. Saved-login viewing on mobile now lives inside the
  Firefox app itself; there is no current Mozilla-made desktop
  equivalent, which is the gap this project fills.
- The Mozilla Support Forum page referenced
  (support.mozilla.org/pt-PT/questions/1350466) did not load through
  automated fetch, so its content could not be checked directly. Any
  guidance in that thread describing `key3.db` or Berkeley DB handling
  predates Firefox 58 and no longer applies; guidance describing the
  built-in `about:logins` CSV export (option C above) still works in
  every current release.

## 8. Risks

- Zig is pre-1.0. The current stable release, 0.16.0 (April 2026), still
  removed and redesigned major standard-library pieces this cycle. A
  project on Zig should pin an exact compiler version and budget time
  for migration on every Zig upgrade.
- `zig-sqlite` carries the same pre-1.0 churn risk as Zig itself; its own
  documentation says as much.
- The hand-written 3DES, AES-CBC, and DER parser are original
  cryptographic code. Each needs test vectors and a check against a
  known-good implementation (`firepwd.py` is the natural reference)
  before being trusted with real passwords.
- Firefox's encryption scheme changed as recently as October 2025. A
  future Firefox release could change it again, which would need a core
  update to keep reading new profiles.

## 9. Recommendation

Build the Zig core around option B (reimplemented crypto, no NSS
dependency), since it removes any runtime dependency on Firefox's own
NSS build or a system NSS package. Start with the TUI on `libvaxis`,
since it validates the C ABI surface and the crypto core on one
platform before the SwiftUI front end is written. Add the SwiftUI shell
once the core's list/unlock/decrypt functions are stable. Verify the
3DES and AES-256-CBC paths against `firepwd.py` output on a real test
profile before relying on either path for a live password store.

## 10. Minimal core module breakdown

A read-only viewer needs no general SQLite engine and no third-party
SQLite binding. `key4.db` needs exactly two lookups (the `metaData` row
and the `nssPrivate` row holding the wrapped master key), so the minimal
build calls the system `libsqlite3` C API directly through `@cImport`
(`sqlite3_open_v2`, `sqlite3_prepare_v2`, `sqlite3_step`,
`sqlite3_column_blob`) instead of pulling in `zig-sqlite`. This drops
one pre-1.0 dependency and keeps the SQL surface to two fixed queries.

The core splits into ten modules. Each is a single Zig file with one
job; arrows show what calls what.

1. **`oids`** — constant bytes for the OIDs in section 3 (PBE-SHA1-3DES,
   PBES2, PBKDF2, HMAC-SHA256, AES-256-CBC), plus a lookup function from
   raw OID bytes to an `enum`. No dependencies. ~40 lines.
2. **`der`** — a decoder for the DER subset Firefox uses: read a tag and
   length, walk into a SEQUENCE, pull out an OCTET STRING, INTEGER, or
   OBJECT IDENTIFIER. Depends on `oids` for OID recognition. ~150 lines.
3. **`des`** — DES block encrypt/decrypt (the core 16-round algorithm)
   and 3DES-CBC built on top of it. No dependencies. Needed only to read
   entries encrypted before Firefox 144. ~300 lines, checked against
   NIST or `firepwd.py` test vectors.
4. **`aescbc`** — CBC mode over `std.crypto.core.aes.Aes256`, plus
   PKCS7 padding removal. No dependencies. ~60 lines.
5. **`kdf`** — PBKDF2 key derivation, wrapping `std.crypto.pbkdf2` with
   the SHA-1 and SHA-256 variants Firefox picks between. No dependencies.
   ~30 lines.
6. **`sqlite3`** — the `@cImport` binding to the system C library, plus
   two functions: read the `metaData` row, read the `nssPrivate` row.
   Depends on the system `libsqlite3` (macOS: `/usr/lib/libsqlite3.dylib`,
   no bundling needed). ~80 lines.
7. **`keydb`** — opens `key4.db` through `sqlite3`, decodes the rows
   through `der`, derives a key through `kdf`, unwraps the master key
   through `des` or `aescbc` depending on the OID found, and returns the
   raw master key plus a verified/not-verified flag from the
   password-check value. Depends on `sqlite3`, `der`, `kdf`, `des`,
   `aescbc`. ~120 lines.
8. **`logins`** — reads `logins.json` with `std.json`, base64-decodes
   each encrypted field with `std.base64`, decodes its DER wrapper
   through `der`, and decrypts it with the master key from `keydb`
   through `des` or `aescbc` depending on its own OID. Depends on `der`,
   `des`, `aescbc`, `keydb`. ~100 lines.
9. **`profiles`** — parses `profiles.ini` and returns profile names and
   paths. No dependencies beyond `std.ini`-style key/value parsing
   (hand-written, the format is a few lines of INI). ~50 lines.
10. **`core`** — the exported C ABI: open a profile path, unlock with an
    optional Primary Password, list origins/usernames, decrypt one
    entry's password on request, and zero a returned buffer once the
    caller is done with it. Depends on `profiles`, `keydb`, `logins`.
    ~80 lines, and the only module a UI links against.

Suggested layout:

```
core/
  src/
    oids.zig
    der.zig
    des.zig
    aescbc.zig
    kdf.zig
    sqlite3.zig
    keydb.zig
    logins.zig
    profiles.zig
    core.zig        # exported C ABI, build target: static library
  build.zig
tui/
  src/main.zig       # libvaxis frontend, links core/
macos/
  Sources/           # SwiftUI frontend, links core/ through a bridging header
```

Explicitly out of scope for the minimal build: writing or editing
logins, `cert9.db`/certificate handling, Firefox Sync, form-autofill
data, and any data from other Mozilla products (Thunderbird,
SeaMonkey). Each can be added later without changing the module split
above.
