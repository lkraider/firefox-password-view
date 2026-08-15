# Fixtures

Each directory holds a `key4.db` and a `logins.json` copied out of a profile
written by a real, installed Firefox driven over Marionette by
`tools/mkfixtures.py`. Every credential in every fixture is synthetic. See
the plan under milestone 0 for why a generator built from this project's own
reading of the format was rejected.

| Fixture | Documented password | Firefox version | Covers |
|---|---|---|---|
| `fresh` | none (empty Primary Password) | 152.0.6 | one AES-256 key row, 3 logins |
| `primary` | `fixture-primary-password-1` | 152.0.6 | a real Primary Password: a 48-byte SHA384 global salt, rejection of the empty and the wrong password |
| `two-profiles` | none | 152.0.6 | `profiles.ini` install-section precedence over the legacy `Default=1` flag |
| `sync-shaped` | none (empty Primary Password) | 152.0.6 | a `chrome://FirefoxAccounts` row, a `moz-extension://` row, and 2 sync deletion tombstones |

`two-profiles/profiles.ini` is hand-written, not produced by Marionette:
`profiles.ini` is plain text with no cryptographic content, so nothing here
is a claim about what the format reader has to agree with a writer on.
`Profiles/real.default-release` is a copy of the `fresh` fixture's
`key4.db` and `logins.json`; `Profiles/abandoned.default` is empty, standing
in for a profile the legacy `Default=1` flag points at that Firefox no
longer uses.

`sync-shaped`'s 2 tombstones are appended to `logins.json` as plain JSON
text after Firefox quits, not written by Firefox itself: a tombstone
carries no encrypted field, so nothing about the cryptographic format is
being faked, and a real Mozilla Account sign-in was never in scope for a
fixture.

Regenerate a fixture with, for example:

```
python3 tools/mkfixtures.py --profile /tmp/scratch fresh
cp /tmp/scratch/key4.db /tmp/scratch/logins.json core/testdata/fresh/
```

`core/src/tests.zig` asserts each fixture's password-check decrypts under its
documented password. A real profile dropped in here by mistake fails that
assertion loudly rather than silently leaking a real credential into a test
run.
