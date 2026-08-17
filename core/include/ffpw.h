/* C ABI for the Firefox password viewer core.
 *
 * One ffpw_store belongs to one thread. Two threads calling into the same
 * store race.
 */
#ifndef FFPW_H
#define FFPW_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct ffpw_store ffpw_store;

typedef enum {
  FFPW_OK = 0,
  FFPW_ERR_NO_PROFILE,
  FFPW_ERR_OPEN,
  FFPW_ERR_NEEDS_PASSWORD,
  FFPW_ERR_WRONG_PASSWORD,
  FFPW_ERR_LEGACY_3DES,
  FFPW_ERR_OOM,
  FFPW_ERR_IO,
  FFPW_ERR_RANGE
} ffpw_status;

enum {
  FFPW_FLAG_ACCOUNT_CREDENTIAL = 1u << 0, /* chrome://FirefoxAccounts */
  FFPW_FLAG_EXTENSION          = 1u << 1, /* moz-extension:// origin  */
  /* Remaining bits are reserved. Setting one later does not move a field. */
};

typedef struct {
  const char *hostname; size_t hostname_len;
  const char *username; size_t username_len;
  int64_t  time_password_changed;
  uint32_t flags;
} ffpw_entry;

/* Pass buf=NULL to learn the size through *needed. */
size_t      ffpw_profile_count(void);
ffpw_status ffpw_profile_at(uint32_t i, char *buf, size_t cap, size_t *needed);

/* Opens profile_path and tries an empty Primary Password immediately, since
 * most profiles carry none. On FFPW_OK *out is ready to use.
 * FFPW_ERR_NEEDS_PASSWORD means the profile has a Primary Password. *out is
 * a valid handle then too. ffpw_unlock must succeed on it before
 * ffpw_count, ffpw_search, ffpw_entry_at or ffpw_reveal. Every handle
 * written to *out is released with ffpw_close. */
ffpw_status ffpw_open(const char *profile_path, ffpw_store **out);
ffpw_status ffpw_unlock(ffpw_store *, const char *pw, size_t pw_len);
void        ffpw_close(ffpw_store *);

size_t      ffpw_count(ffpw_store *);
/* Writes at most cap indices. Returns the total match count. That total
   may exceed cap. */
size_t      ffpw_search(ffpw_store *, const char *q, size_t q_len,
                        uint32_t *out, size_t cap);
ffpw_status ffpw_entry_at(ffpw_store *, uint32_t i, ffpw_entry *out);
/* Writes at most cap entries, in index order starting at 0. Returns the
 * total entry count. That total may exceed cap. ffpw_open and ffpw_unlock
 * decrypt every hostname and username before they return, so this call
 * costs one struct copy per entry. Calling ffpw_entry_at per row costs one
 * FFI call per row. */
size_t      ffpw_entries(ffpw_store *, ffpw_entry *out, size_t cap);

ffpw_status ffpw_reveal(ffpw_store *, uint32_t i, char **out, size_t *len);
/* Zeroes the buffer, then frees it with the store's allocator. An
 * ffpw_reveal buffer is released here and nowhere else. */
void        ffpw_secret_free(ffpw_store *, char *buf, size_t len);

#ifdef __cplusplus
}
#endif

#endif /* FFPW_H */
