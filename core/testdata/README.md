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

Regenerate a fixture with, for example:

```
python3 tools/mkfixtures.py --profile /tmp/scratch fresh
cp /tmp/scratch/key4.db /tmp/scratch/logins.json core/testdata/fresh/
```

`core/src/tests.zig` asserts each fixture's password-check decrypts under its
documented password. A real profile dropped in here by mistake fails that
assertion loudly rather than silently leaking a real credential into a test
run.
