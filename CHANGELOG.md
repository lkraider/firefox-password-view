# Changelog

Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [1.0.0] - 2026-08-16

First release. Binaries for Apple Silicon macOS.

### Added

- Core: reads `key4.db` and `logins.json`, unwraps the AES-256 and legacy
  3DES master keys, decrypts every entry, and reports which entries are
  still 3DES.
- Core: resolves and enumerates Firefox profiles from `profiles.ini`,
  reading the `[InstallXXXX]` section ahead of the legacy `Default=1`
  flag.
- Core: `store.zig`, the shared search filter and arena both front ends
  use.
- Core: a C ABI (`core/include/ffpw.h`) for Swift and other C callers.
  `ffpw_entries` fetches every entry's display data in one call.
- TUI: a search field, a masked-password list, reveal, copy, and a Primary
  Password prompt, built on libvaxis.
- macOS app: a SwiftUI equivalent of the TUI, linking the same C ABI. The
  entry list is an `NSTableView` with a fixed row height
  (`EntryTableView.swift`). It holds a steady scroll on a 1000+ row
  profile.
- Both front ends label the `chrome://FirefoxAccounts` row and ask for
  confirmation before revealing it. Its password is Mozilla Account sync
  key material.
- Fixtures written by an installed Firefox driven over Marionette,
  covering a fresh profile, a Primary Password, the pre- and
  post-Firefox-144 3DES-to-AES-256 migration, two profiles under one
  `profiles.ini`, and a synced profile's tombstones and non-web schemes.
- A fuzz corpus for the DER reader, mutating real SDR blobs through
  `sdr.parse` and `pbes2.parse`.
- `docs/DESIGN.md`: the on-disk format and the reasoning behind each
  implementation decision.
- `macos/scripts/bundle.sh`: wraps the Swift package's executable in a
  minimal ad-hoc-signed `.app` bundle.
- `scripts/package-release.sh`: builds both release artifacts. CI packages
  them twice and diffs the result on every push.
- `LICENSE`: MIT.
