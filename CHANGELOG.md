# Changelog

Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [1.0.0] - 2026-08-16

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
- `ffpw_entries`, a C ABI call that fetches every entry's display data in
  one round trip instead of one call per entry.
- `LICENSE`: MIT.
- `docs/DESIGN.md`: the byte-level format details and the reasoning behind
  each implementation decision, replacing the retired `FEASIBILITY.md`.
- `macos/scripts/bundle.sh`: wraps the Swift package's executable in a
  minimal ad-hoc-signed `.app` bundle.

### Changed

- macOS app: the entry list is backed by `NSTableView` directly
  (`EntryTableView.swift`) instead of SwiftUI's `List`, with a fixed row
  height, to remove a stutter when dragging the scrollbar knob over a
  1000+ row profile.
- macOS app: every entry's display data is fetched once when a profile
  opens, instead of one async fetch per row as it scrolled into view.
- macOS app: search cancellation uses SwiftUI's `.task(id:)` instead of a
  hand-rolled `Task`.
- `core.zig`'s `ffpw_profile_count` and `ffpw_profile_at` share one
  profiles.ini read instead of each reading and parsing it separately.
- `profiles.zig`'s `resolveDefault` and `enumerate` share one INI parse.

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
- macOS app: run outside a proper `.app` bundle, the window opened but
  could not take keyboard focus from the launching terminal.
- macOS app: the profile picker logged an invalid-selection warning at
  launch, before `AppModel.start()` had picked a profile.
- macOS app: every keystroke in the search field raced the previous one,
  so a slower search could overwrite a newer one's results.
