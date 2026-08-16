/* Links libffpw.a and exercises every function in ffpw.h once. Prints
 * lengths and counts only, never a hostname, a username or a password, so
 * this is safe to run against a real profile as well as a fixture.
 *
 * Run under `leaks --atExit --` to confirm ffpw_close and ffpw_secret_free
 * release everything they allocate.
 */

#include <ffpw.h>

#include <stdio.h>
#include <string.h>

static int fail(const char *what, ffpw_status status) {
  fprintf(stderr, "FAIL: %s (status %d)\n", what, (int)status);
  return 1;
}

int main(int argc, char **argv) {
  const char *profile_path = argc > 1 ? argv[1] : "core/testdata/fresh";

  size_t profile_count = ffpw_profile_count();
  printf("profiles: %zu\n", profile_count);
  for (uint32_t i = 0; i < profile_count && i < 8; i++) {
    size_t needed = 0;
    ffpw_status st = ffpw_profile_at(i, NULL, 0, &needed);
    if (st != FFPW_OK) return fail("ffpw_profile_at (size probe)", st);
    printf("  profile %u path length: %zu\n", i, needed);
  }

  ffpw_store *store = NULL;
  ffpw_status st = ffpw_open(profile_path, &store);
  if (st != FFPW_OK && st != FFPW_ERR_NEEDS_PASSWORD) {
    return fail("ffpw_open", st);
  }
  if (!store) {
    fprintf(stderr, "FAIL: ffpw_open returned no store\n");
    return 1;
  }

  if (st == FFPW_ERR_NEEDS_PASSWORD) {
    /* The fresh fixture needs no password; the primary fixture would. */
    st = ffpw_unlock(store, "", 0);
    if (st != FFPW_OK) {
      fprintf(stderr, "note: profile needs a real Primary Password (status %d)\n", (int)st);
      ffpw_close(store);
      return 0;
    }
  }

  size_t count = ffpw_count(store);
  printf("entries: %zu\n", count);

  uint32_t matches[16];
  size_t total = ffpw_search(store, "", 0, matches, 16);
  printf("empty query matches: %zu\n", total);

  size_t narrow = ffpw_search(store, "example", strlen("example"), matches, 16);
  printf("'example' matches: %zu\n", narrow);

  if (count > 0) {
    ffpw_entry entry;
    st = ffpw_entry_at(store, 0, &entry);
    if (st != FFPW_OK) return fail("ffpw_entry_at", st);
    printf("entry 0: hostname_len=%zu username_len=%zu flags=%u\n",
           entry.hostname_len, entry.username_len, entry.flags);

    char *secret = NULL;
    size_t secret_len = 0;
    st = ffpw_reveal(store, 0, &secret, &secret_len);
    if (st == FFPW_OK) {
      printf("revealed length: %zu\n", secret_len);
      ffpw_secret_free(store, secret, secret_len);
    } else if (st == FFPW_ERR_LEGACY_3DES) {
      printf("entry 0 is legacy 3DES, correctly not revealed\n");
    } else {
      return fail("ffpw_reveal", st);
    }
  }

  ffpw_close(store);
  printf("ok\n");
  return 0;
}
