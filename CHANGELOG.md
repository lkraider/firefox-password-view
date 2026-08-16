# Changelog

Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added

- Core: reads `key4.db` and `logins.json`, unwraps the AES-256 and legacy
  3DES master keys, decrypts every entry, and reports which entries are
  still 3DES rather than decrypting them incorrectly.
- Core: resolves and enumerates Firefox profiles from `profiles.ini`.
- Core: `store.zig`, the shared search filter and arena both front ends use.
- Core: a C ABI (`core/include/ffpw.h`) for Swift and other C callers.
- TUI: a search field, a masked-password list, reveal, copy, and a Primary
  Password prompt, built on libvaxis.
- macOS app: a SwiftUI equivalent of the TUI, linking the same C ABI.
- Fixtures written by a real, installed Firefox driven over Marionette,
  covering a fresh profile, a Primary Password, the pre- and
  post-Firefox-144 3DES-to-AES-256 migration, two profiles under one
  `profiles.ini`, and a synced profile's tombstones and non-web schemes.
- A fuzz corpus for the DER reader, mutating real SDR blobs through
  `sdr.parse` and `pbes2.parse`.

### Fixed

- The PBES2 key derivation used SHA-1 for the seed hash unconditionally;
  a profile with a real Primary Password uses a 48-byte global salt and
  needs SHA-384 there instead, or every password looks wrong.
- `logins.zig` asked for the AES-256 key before checking an entry's
  cipher, so a profile with no AES-256 key at all (one Firefox 144 has
  never opened) reported every entry as a generic failure instead of the
  more useful "legacy 3DES".
- The C ABI mapped a wrong Primary Password passed to `ffpw_unlock` to
  "needs a password" instead of "wrong password".
