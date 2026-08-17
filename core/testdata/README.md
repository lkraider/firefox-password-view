# Fixtures

Each directory holds a `key4.db` and a `logins.json` copied out of a profile
written by an installed Firefox driven over Marionette by
`tools/mkfixtures.py`. Every credential in every fixture is synthetic.

Firefox writes these files, so a test against them checks this reader
against Firefox's own output. A generator built from this project's own
reading of the format would only show the reader agrees with itself.

| Fixture | Documented password | Firefox version | Covers |
|---|---|---|---|
| `fresh` | none (empty Primary Password) | 152.0.6 | one AES-256 key row, 3 logins |
| `primary` | `fixture-primary-password-1` | 152.0.6 | a Primary Password set by the user: a 48-byte SHA384 global salt, rejection of the empty and the wrong password |
| `two-profiles` | none | 152.0.6 | `profiles.ini` install-section precedence over the legacy `Default=1` flag |
| `sync-shaped` | none (empty Primary Password) | 152.0.6 | a `chrome://FirefoxAccounts` row, a `moz-extension://` row, and 2 sync deletion tombstones |
| `unmigrated` | none | 143.0.4 | a 24-byte 3DES key, no AES-256 key, and 3 `des_ede3_cbc` entries |
| `migrated` | none | `unmigrated`'s profile, opened once by 152.0.6 | both key rows under one CKA_ID, and every entry re-encrypted to AES-256 |

Firefox writes every fixture above. `tools/mkfixtures.py overflow` writes
`overflow.db` through Python's own `sqlite3`. It is a bare SQLite database
and it stands outside any profile directory. Its page size is 512 bytes. Its
rows therefore spill onto overflow pages, and its table b-tree grows 6
interior pages. Every `key4.db` here has a 32768-byte page and rows of about
400 bytes, and each of its tables fits on one leaf page. Each row of
`overflow.db` holds content derived from its row number, so two runs of the
generator write the same bytes. `core/test/oracle.zig` reads the file through
`core/src/sqlitedb.zig` and through the system sqlite3, then compares every
column.

Some fixtures carry hand-written parts. Every such edit stays outside the
encrypted bytes, so the crypto in each fixture is still Firefox's own
output.

`two-profiles/profiles.ini` is hand-written, since `profiles.ini` is
plain text and carries no encrypted field.
`Profiles/real.default-release` is a copy of the `fresh` fixture's
`key4.db` and `logins.json`. `Profiles/abandoned.default` is empty. It
stands in for a profile that the legacy `Default=1` flag points at and
Firefox no longer uses.

`sync-shaped`'s tombstones are appended to `logins.json` as plain JSON
text after Firefox quits. A tombstone carries no encrypted field. Getting
Firefox to write them needs a sign-in to a Mozilla Account, and no
account is used to build these fixtures.

`unmigrated` needs Firefox 143.0.4, from
`ftp.mozilla.org/pub/firefox/releases/143.0.4/mac/en-US/`, since Firefox 144
adds the AES-256 key. `migrated` is `unmigrated`'s profile directory,
copied and then opened once by the installed Firefox 152 with `mkfixtures.py
--profile <copy> migrate`. Nothing is added to it.

Regenerate a fixture with, for example:

```
python3 tools/mkfixtures.py --profile /tmp/scratch fresh
cp /tmp/scratch/key4.db /tmp/scratch/logins.json core/testdata/fresh/
```

Regenerate `overflow.db` in place with:

```
python3 tools/mkfixtures.py overflow
```

`core/src/tests.zig` asserts each fixture's password-check decrypts under its
documented password. A profile from this machine dropped in here fails that
assertion, since the documented password does not unlock it. The failure
stops that profile's credentials from reaching a test run.
