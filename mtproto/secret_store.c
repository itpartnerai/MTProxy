/*
    This file is part of MTProto-Server.

    MTProto-Server is free software: you can redistribute it and/or modify
    it under the terms of the GNU Lesser General Public License as published by
    the Free Software Foundation, either version 2 of the License, or
    (at your option) any later version.

    MTProto-Server is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU Lesser General Public License for more details.
*/

#include "mtproto/secret_store.h"

#include <assert.h>
#include <ctype.h>
#include <errno.h>
#include <limits.h>
#include <pthread.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

#include "common/sha256.h"

typedef struct secret_store_shared {
  int initialized;
  int total_entries;
  pthread_mutex_t mutex;
  char state_file[PATH_MAX];
  int suppress_flush;
  SecretEntry entries[SECRET_STORE_MAX_SECRETS];
} secret_store_shared_t;

static secret_store_shared_t *store;
static pthread_mutex_t store_init_mutex = PTHREAD_MUTEX_INITIALIZER;

static void secret_store_ensure_initialized (void) {
  if (store) {
    return;
  }

  pthread_mutex_lock (&store_init_mutex);
  if (!store) {
    secret_store_shared_t *mapped = mmap (0, sizeof (*mapped), PROT_READ | PROT_WRITE, MAP_SHARED | MAP_ANONYMOUS, -1, 0);
    assert (mapped != MAP_FAILED);
    memset (mapped, 0, sizeof (*mapped));

    pthread_mutexattr_t attr;
    assert (!pthread_mutexattr_init (&attr));
    assert (!pthread_mutexattr_setpshared (&attr, PTHREAD_PROCESS_SHARED));
    assert (!pthread_mutex_init (&mapped->mutex, &attr));
    assert (!pthread_mutexattr_destroy (&attr));

    mapped->initialized = 1;
    store = mapped;
  }
  pthread_mutex_unlock (&store_init_mutex);
}

static void bytes_to_hex (const unsigned char *input, int input_len, char *output, int output_len) {
  static const char hex_digits[] = "0123456789abcdef";
  int i;
  assert (output_len >= input_len * 2 + 1);

  for (i = 0; i < input_len; i++) {
    output[i * 2] = hex_digits[input[i] >> 4];
    output[i * 2 + 1] = hex_digits[input[i] & 15];
  }

  output[input_len * 2] = 0;
}

void secret_store_compute_id (const uint8_t secret[SECRET_STORE_SECRET_LEN], char out_id[SECRET_STORE_SECRET_ID_LEN]) {
  unsigned char digest[32];
  sha256 (secret, SECRET_STORE_SECRET_LEN, digest);
  bytes_to_hex (digest, 32, out_id, SECRET_STORE_SECRET_ID_LEN);
}

static int hex_to_bytes (const char *input, int input_len, uint8_t *output, int output_len) {
  int i;
  if (input_len != output_len * 2) {
    return -1;
  }

  for (i = 0; i < output_len; i++) {
    char hi = input[i * 2];
    char lo = input[i * 2 + 1];
    int hi_value = isdigit (hi) ? hi - '0' : (tolower (hi) - 'a' + 10);
    int lo_value = isdigit (lo) ? lo - '0' : (tolower (lo) - 'a' + 10);
    if (!isxdigit (hi) || !isxdigit (lo)) {
      return -1;
    }
    output[i] = (uint8_t) ((hi_value << 4) | lo_value);
  }

  return 0;
}

static SecretEntry *find_by_bytes_unlocked (const uint8_t secret[SECRET_STORE_SECRET_LEN]) {
  int i;
  for (i = 0; i < store->total_entries; i++) {
    SecretEntry *entry = &store->entries[i];
    if (entry->active && !memcmp (entry->secret, secret, SECRET_STORE_SECRET_LEN)) {
      return entry;
    }
  }

  return 0;
}

static SecretEntry *find_by_id_unlocked (const char *secret_id) {
  int i;
  for (i = 0; i < store->total_entries; i++) {
    SecretEntry *entry = &store->entries[i];
    if (entry->active && !strcmp (entry->secret_id, secret_id)) {
      return entry;
    }
  }

  return 0;
}

static int secret_store_flush_unlocked (void);
static int secret_store_add_unlocked (const uint8_t secret[SECRET_STORE_SECRET_LEN], secret_limits_t limits, const char *label, char out_id[SECRET_STORE_SECRET_ID_LEN], int flush_after);

static int ensure_parent_dir_for_file (const char *path) {
  char directory[PATH_MAX];
  char *slash;

  snprintf (directory, sizeof (directory), "%s", path);
  slash = strrchr (directory, '/');
  if (!slash) {
    return 0;
  }
  *slash = 0;
  if (!*directory) {
    return 0;
  }

  char *p = directory;
  if (*p == '/') {
    p++;
  }

  while (*p) {
    while (*p && *p != '/') {
      p++;
    }
    char saved = *p;
    *p = 0;
    if (*directory && mkdir (directory, 0755) < 0 && errno != EEXIST) {
      return -1;
    }
    *p = saved;
    if (!*p) {
      break;
    }
    p++;
  }

  return 0;
}

static void fill_snapshot_from_entry (const SecretEntry *entry, SecretEntrySnapshot *snapshot) {
  memset (snapshot, 0, sizeof (*snapshot));
  memcpy (snapshot->secret, entry->secret, SECRET_STORE_SECRET_LEN);
  memcpy (snapshot->secret_id, entry->secret_id, SECRET_STORE_SECRET_ID_LEN);
  memcpy (snapshot->label, entry->label, SECRET_STORE_LABEL_LEN);
  snapshot->limits = entry->limits;
  snapshot->active_conns = atomic_load (&entry->active_conns);
  snapshot->total_accepted = atomic_load (&entry->total_accepted);
  snapshot->total_rejected_limit = atomic_load (&entry->total_rejected_limit);
  snapshot->total_rejected_rate_limit = atomic_load (&entry->total_rejected_rate_limit);
  snapshot->created_at = (long long) entry->created_at;
  snapshot->last_seen = atomic_load (&entry->last_seen);
  snapshot->active = entry->active;
}

static int append_json_escaped (char **ptr, size_t *remaining, const char *value) {
  const unsigned char *s = (const unsigned char *) (value ? value : "");
  while (*s) {
    if (*remaining < 3) {
      return -1;
    }
    switch (*s) {
      case '\\':
      case '"':
        *(*ptr)++ = '\\';
        *(*ptr)++ = (char) *s;
        *remaining -= 2;
        break;
      case '\n':
        *(*ptr)++ = '\\';
        *(*ptr)++ = 'n';
        *remaining -= 2;
        break;
      case '\r':
        *(*ptr)++ = '\\';
        *(*ptr)++ = 'r';
        *remaining -= 2;
        break;
      case '\t':
        *(*ptr)++ = '\\';
        *(*ptr)++ = 't';
        *remaining -= 2;
        break;
      default:
        *(*ptr)++ = (char) *s;
        *remaining -= 1;
        break;
    }
    s++;
  }
  return 0;
}

static int append_jsonf (char **ptr, size_t *remaining, const char *pattern, ...) {
  va_list ap;
  va_start (ap, pattern);
  int written = vsnprintf (*ptr, *remaining, pattern, ap);
  va_end (ap);
  if (written < 0 || (size_t) written >= *remaining) {
    return -1;
  }
  *ptr += written;
  *remaining -= written;
  return 0;
}

static const char *skip_ws (const char *p) {
  while (*p && isspace ((unsigned char) *p)) {
    p++;
  }
  return p;
}

static const char *parse_json_string_token (const char *p, char *out, size_t out_len) {
  size_t len = 0;

  p = skip_ws (p);
  if (*p != '"') {
    return 0;
  }
  p++;

  while (*p && *p != '"') {
    char ch = *p++;
    if (ch == '\\') {
      ch = *p++;
      switch (ch) {
        case '"':
        case '\\':
        case '/':
          break;
        case 'n':
          ch = '\n';
          break;
        case 'r':
          ch = '\r';
          break;
        case 't':
          ch = '\t';
          break;
        default:
          return 0;
      }
    }
    if (len + 1 >= out_len) {
      return 0;
    }
    out[len++] = ch;
  }

  if (*p != '"') {
    return 0;
  }
  out[len] = 0;
  return p + 1;
}

static const char *parse_json_int_token (const char *p, int *out) {
  char *end;
  long value;

  p = skip_ws (p);
  errno = 0;
  value = strtol (p, &end, 10);
  if (end == p || errno) {
    return 0;
  }
  *out = (int) value;
  return end;
}

static int parse_secret_object (const char *p, const char **out_end, uint8_t secret[SECRET_STORE_SECRET_LEN], secret_limits_t *limits, char label[SECRET_STORE_LABEL_LEN]) {
  int has_secret = 0;
  char key[64];
  char value[256];
  int number = 0;

  memset (secret, 0, SECRET_STORE_SECRET_LEN);
  memset (label, 0, SECRET_STORE_LABEL_LEN);
  limits->max_active_connections = 0;
  limits->max_new_conn_per_min = 0;

  p = skip_ws (p);
  if (*p != '{') {
    return -1;
  }
  p++;

  for (;;) {
    p = skip_ws (p);
    if (*p == '}') {
      p++;
      break;
    }

    p = parse_json_string_token (p, key, sizeof (key));
    if (!p) {
      return -1;
    }
    p = skip_ws (p);
    if (*p != ':') {
      return -1;
    }
    p++;

    if (!strcmp (key, "secret")) {
      p = parse_json_string_token (p, value, sizeof (value));
      if (!p || hex_to_bytes (value, strlen (value), secret, SECRET_STORE_SECRET_LEN) < 0) {
        return -1;
      }
      has_secret = 1;
    } else if (!strcmp (key, "label")) {
      p = parse_json_string_token (p, label, SECRET_STORE_LABEL_LEN);
      if (!p) {
        return -1;
      }
    } else if (!strcmp (key, "max_active_connections")) {
      p = parse_json_int_token (p, &number);
      if (!p) {
        return -1;
      }
      limits->max_active_connections = number;
    } else if (!strcmp (key, "max_new_conn_per_min")) {
      p = parse_json_int_token (p, &number);
      if (!p) {
        return -1;
      }
      limits->max_new_conn_per_min = number;
    } else {
      return -1;
    }

    p = skip_ws (p);
    if (*p == ',') {
      p++;
      continue;
    }
    if (*p == '}') {
      p++;
      break;
    }
    return -1;
  }

  *out_end = p;
  return has_secret ? 0 : -1;
}

int secret_store_add (const uint8_t secret[SECRET_STORE_SECRET_LEN], secret_limits_t limits, const char *label, char out_id[SECRET_STORE_SECRET_ID_LEN]) {
  secret_store_ensure_initialized ();
  pthread_mutex_lock (&store->mutex);
  int result = secret_store_add_unlocked (secret, limits, label, out_id, 1);
  pthread_mutex_unlock (&store->mutex);
  return result;
}

static int secret_store_add_unlocked (const uint8_t secret[SECRET_STORE_SECRET_LEN], secret_limits_t limits, const char *label, char out_id[SECRET_STORE_SECRET_ID_LEN], int flush_after) {
  char computed_id[SECRET_STORE_SECRET_ID_LEN];
  secret_store_compute_id (secret, computed_id);

  SecretEntry *existing = find_by_bytes_unlocked (secret);
  if (existing) {
    if (out_id) {
      memcpy (out_id, existing->secret_id, SECRET_STORE_SECRET_ID_LEN);
    }
    return 1;
  }

  if (store->total_entries >= SECRET_STORE_MAX_SECRETS) {
    return -1;
  }

  SecretEntry *entry = &store->entries[store->total_entries++];
  memset (entry, 0, sizeof (*entry));

  memcpy (entry->secret, secret, SECRET_STORE_SECRET_LEN);
  memcpy (entry->secret_id, computed_id, SECRET_STORE_SECRET_ID_LEN);
  if (label && *label) {
    snprintf (entry->label, sizeof (entry->label), "%s", label);
  }
  entry->limits = limits;
  atomic_init (&entry->active_conns, 0);
  atomic_init (&entry->total_accepted, 0);
  atomic_init (&entry->total_rejected_limit, 0);
  atomic_init (&entry->total_rejected_rate_limit, 0);
  entry->created_at = time (0);
  atomic_init (&entry->last_seen, (long long) entry->created_at);
  entry->rate_tokens = limits.max_new_conn_per_min > 0 ? limits.max_new_conn_per_min : 0;
  entry->rate_updated_at_ms = 0;
  entry->active = 1;

  if (out_id) {
    memcpy (out_id, entry->secret_id, SECRET_STORE_SECRET_ID_LEN);
  }

  if (flush_after && !store->suppress_flush && secret_store_flush_unlocked () < 0) {
    return -1;
  }
  return 0;
}

int secret_store_remove (const char *secret_id) {
  secret_store_ensure_initialized ();
  pthread_mutex_lock (&store->mutex);

  SecretEntry *entry = find_by_id_unlocked (secret_id);
  if (!entry) {
    pthread_mutex_unlock (&store->mutex);
    return -1;
  }

  entry->active = 0;
  if (!store->suppress_flush && secret_store_flush_unlocked () < 0) {
    pthread_mutex_unlock (&store->mutex);
    return -1;
  }
  pthread_mutex_unlock (&store->mutex);
  return 0;
}

int secret_store_update (const char *secret_id, const secret_limits_t *limits, const char *label) {
  secret_store_ensure_initialized ();
  pthread_mutex_lock (&store->mutex);

  SecretEntry *entry = find_by_id_unlocked (secret_id);
  if (!entry) {
    pthread_mutex_unlock (&store->mutex);
    return -1;
  }

  if (limits) {
    entry->limits = *limits;
    if (entry->limits.max_new_conn_per_min <= 0) {
      entry->rate_tokens = 0;
    } else if (entry->rate_tokens > entry->limits.max_new_conn_per_min) {
      entry->rate_tokens = entry->limits.max_new_conn_per_min;
    }
  }

  if (label) {
    snprintf (entry->label, sizeof (entry->label), "%s", label);
  }

  if (!store->suppress_flush && secret_store_flush_unlocked () < 0) {
    pthread_mutex_unlock (&store->mutex);
    return -1;
  }

  pthread_mutex_unlock (&store->mutex);
  return 0;
}

SecretEntry *secret_store_find_by_bytes (const uint8_t secret[SECRET_STORE_SECRET_LEN]) {
  SecretEntry *result;

  secret_store_ensure_initialized ();
  pthread_mutex_lock (&store->mutex);
  result = find_by_bytes_unlocked (secret);
  pthread_mutex_unlock (&store->mutex);

  return result;
}

SecretEntry *secret_store_find_by_id (const char *secret_id) {
  SecretEntry *result;

  secret_store_ensure_initialized ();
  pthread_mutex_lock (&store->mutex);
  result = find_by_id_unlocked (secret_id);
  pthread_mutex_unlock (&store->mutex);

  return result;
}

int secret_store_count (void) {
  int i, count = 0;

  secret_store_ensure_initialized ();
  pthread_mutex_lock (&store->mutex);
  for (i = 0; i < store->total_entries; i++) {
    SecretEntry *entry = &store->entries[i];
    if (entry->active) {
      count++;
    }
  }
  pthread_mutex_unlock (&store->mutex);

  return count;
}

int secret_store_copy_secret_at (int index, uint8_t secret_out[SECRET_STORE_SECRET_LEN], char secret_id_out[SECRET_STORE_SECRET_ID_LEN]) {
  int i, current = 0;

  secret_store_ensure_initialized ();
  pthread_mutex_lock (&store->mutex);
  for (i = 0; i < store->total_entries; i++) {
    SecretEntry *entry = &store->entries[i];
    if (!entry->active) {
      continue;
    }

    if (current == index) {
      memcpy (secret_out, entry->secret, SECRET_STORE_SECRET_LEN);
      if (secret_id_out) {
        memcpy (secret_id_out, entry->secret_id, SECRET_STORE_SECRET_ID_LEN);
      }
      pthread_mutex_unlock (&store->mutex);
      return 0;
    }
    current++;
  }
  pthread_mutex_unlock (&store->mutex);

  return -1;
}

int secret_store_copy_snapshot_at (int index, SecretEntrySnapshot *snapshot_out) {
  int i, current = 0;

  secret_store_ensure_initialized ();
  pthread_mutex_lock (&store->mutex);
  for (i = 0; i < store->total_entries; i++) {
    SecretEntry *entry = &store->entries[i];
    if (!entry->active) {
      continue;
    }

    if (current == index) {
      fill_snapshot_from_entry (entry, snapshot_out);
      pthread_mutex_unlock (&store->mutex);
      return 0;
    }
    current++;
  }
  pthread_mutex_unlock (&store->mutex);
  return -1;
}

int secret_store_copy_snapshot_by_id (const char *secret_id, SecretEntrySnapshot *snapshot_out) {
  secret_store_ensure_initialized ();
  pthread_mutex_lock (&store->mutex);
  SecretEntry *entry = find_by_id_unlocked (secret_id);
  if (!entry) {
    pthread_mutex_unlock (&store->mutex);
    return -1;
  }
  fill_snapshot_from_entry (entry, snapshot_out);
  pthread_mutex_unlock (&store->mutex);
  return 0;
}

void secret_store_set_state_file (const char *path) {
  secret_store_ensure_initialized ();
  pthread_mutex_lock (&store->mutex);
  snprintf (store->state_file, sizeof (store->state_file), "%s", path ? path : "");
  pthread_mutex_unlock (&store->mutex);
}

const char *secret_store_get_state_file (void) {
  secret_store_ensure_initialized ();
  return store->state_file;
}

static int secret_store_flush_unlocked (void) {
  if (!store->state_file[0]) {
    return 0;
  }

  char tmp_path[PATH_MAX];
  snprintf (tmp_path, sizeof (tmp_path), "%s.tmp", store->state_file);

  if (ensure_parent_dir_for_file (store->state_file) < 0) {
    return -1;
  }

  FILE *f = fopen (tmp_path, "w");
  if (!f) {
    return -1;
  }

  if (fprintf (f, "{\n  \"version\": %d,\n  \"secrets\": [\n", SECRET_STORE_STATE_VERSION) < 0) {
    fclose (f);
    unlink (tmp_path);
    return -1;
  }

  int i;
  int first = 1;
  for (i = 0; i < store->total_entries; i++) {
    SecretEntry *entry = &store->entries[i];
    if (!entry->active) {
      continue;
    }

    char secret_hex[SECRET_STORE_SECRET_LEN * 2 + 1];
    char object_buffer[1024];
    char *ptr = object_buffer;
    size_t remaining = sizeof (object_buffer);

    bytes_to_hex (entry->secret, SECRET_STORE_SECRET_LEN, secret_hex, sizeof (secret_hex));
    if (append_jsonf (&ptr, &remaining,
        "%s    {\"secret\":\"%s\",\"label\":\"",
        first ? "" : ",\n", secret_hex) < 0 ||
        append_json_escaped (&ptr, &remaining, entry->label) < 0 ||
        append_jsonf (&ptr, &remaining,
        "\",\"max_active_connections\":%d,\"max_new_conn_per_min\":%d}",
        entry->limits.max_active_connections,
        entry->limits.max_new_conn_per_min) < 0) {
      fclose (f);
      unlink (tmp_path);
      return -1;
    }

    if (fputs (object_buffer, f) == EOF) {
      fclose (f);
      unlink (tmp_path);
      return -1;
    }
    first = 0;
  }

  if (fprintf (f, "\n  ]\n}\n") < 0 || fflush (f) != 0 || fsync (fileno (f)) != 0 || fclose (f) != 0) {
    unlink (tmp_path);
    return -1;
  }

  if (rename (tmp_path, store->state_file) < 0) {
    unlink (tmp_path);
    return -1;
  }

  return 0;
}

int secret_store_flush (void) {
  int result;
  secret_store_ensure_initialized ();
  pthread_mutex_lock (&store->mutex);
  result = secret_store_flush_unlocked ();
  pthread_mutex_unlock (&store->mutex);
  return result;
}

int secret_store_load (void) {
  char *buffer = 0;
  long file_size = 0;

  secret_store_ensure_initialized ();
  pthread_mutex_lock (&store->mutex);
  if (!store->state_file[0]) {
    pthread_mutex_unlock (&store->mutex);
    return 0;
  }
  FILE *f = fopen (store->state_file, "r");
  if (!f) {
    int err = errno;
    pthread_mutex_unlock (&store->mutex);
    return err == ENOENT ? 0 : -1;
  }
  if (fseek (f, 0, SEEK_END) != 0) {
    fclose (f);
    pthread_mutex_unlock (&store->mutex);
    return -1;
  }
  file_size = ftell (f);
  if (file_size < 0 || fseek (f, 0, SEEK_SET) != 0) {
    fclose (f);
    pthread_mutex_unlock (&store->mutex);
    return -1;
  }

  buffer = calloc ((size_t) file_size + 1, 1);
  if (!buffer) {
    fclose (f);
    pthread_mutex_unlock (&store->mutex);
    return -1;
  }
  if (file_size > 0 && fread (buffer, 1, (size_t) file_size, f) != (size_t) file_size) {
    free (buffer);
    fclose (f);
    pthread_mutex_unlock (&store->mutex);
    return -1;
  }
  fclose (f);

  const char *p = strstr (buffer, "\"secrets\"");
  if (!p) {
    free (buffer);
    pthread_mutex_unlock (&store->mutex);
    return -1;
  }

  p = strchr (p, '[');
  if (!p) {
    free (buffer);
    pthread_mutex_unlock (&store->mutex);
    return -1;
  }
  p++;

  store->suppress_flush++;
  while (1) {
    uint8_t secret[SECRET_STORE_SECRET_LEN];
    secret_limits_t limits;
    char label[SECRET_STORE_LABEL_LEN];

    p = skip_ws (p);
    if (*p == ']') {
      p++;
      break;
    }

    const char *next = 0;
    if (parse_secret_object (p, &next, secret, &limits, label) < 0 ||
        secret_store_add_unlocked (secret, limits, label, 0, 0) < 0) {
      store->suppress_flush--;
      free (buffer);
      pthread_mutex_unlock (&store->mutex);
      return -1;
    }
    p = skip_ws (next);
    if (*p == ',') {
      p++;
      continue;
    }
    if (*p == ']') {
      p++;
      break;
    }
  }
  store->suppress_flush--;

  free (buffer);
  pthread_mutex_unlock (&store->mutex);
  return 0;
}

int secret_store_check_limits (SecretEntry *entry, long long now_ms) {
  secret_store_ensure_initialized ();
  if (!entry || !entry->active) {
    return -1;
  }

  if (entry->limits.max_active_connections > 0 &&
      atomic_load (&entry->active_conns) >= entry->limits.max_active_connections) {
    atomic_fetch_add (&entry->total_rejected_limit, 1);
    return -1;
  }

  if (entry->limits.max_new_conn_per_min > 0) {
    pthread_mutex_lock (&store->mutex);

    if (entry->rate_updated_at_ms <= 0) {
      entry->rate_updated_at_ms = now_ms;
      entry->rate_tokens = entry->limits.max_new_conn_per_min;
    } else if (now_ms > entry->rate_updated_at_ms) {
      double elapsed_ms = (double)(now_ms - entry->rate_updated_at_ms);
      double refill = elapsed_ms * ((double) entry->limits.max_new_conn_per_min / 60000.0);
      entry->rate_tokens += refill;
      if (entry->rate_tokens > entry->limits.max_new_conn_per_min) {
        entry->rate_tokens = entry->limits.max_new_conn_per_min;
      }
      entry->rate_updated_at_ms = now_ms;
    }

    if (entry->rate_tokens < 1.0) {
      atomic_fetch_add (&entry->total_rejected_rate_limit, 1);
      pthread_mutex_unlock (&store->mutex);
      return -1;
    }

    entry->rate_tokens -= 1.0;
    pthread_mutex_unlock (&store->mutex);
  }

  return 0;
}

int secret_store_try_accept (SecretEntry *entry, long long now_ms) {
  secret_store_ensure_initialized ();
  if (!entry || !entry->active) {
    return -1;
  }

  pthread_mutex_lock (&store->mutex);

  if (!entry->active) {
    pthread_mutex_unlock (&store->mutex);
    return -1;
  }

  if (entry->limits.max_active_connections > 0 &&
      atomic_load (&entry->active_conns) >= entry->limits.max_active_connections) {
    atomic_fetch_add (&entry->total_rejected_limit, 1);
    pthread_mutex_unlock (&store->mutex);
    return -1;
  }

  if (entry->limits.max_new_conn_per_min > 0) {
    if (entry->rate_updated_at_ms <= 0) {
      entry->rate_updated_at_ms = now_ms;
      entry->rate_tokens = entry->limits.max_new_conn_per_min;
    } else if (now_ms > entry->rate_updated_at_ms) {
      double elapsed_ms = (double)(now_ms - entry->rate_updated_at_ms);
      double refill = elapsed_ms * ((double) entry->limits.max_new_conn_per_min / 60000.0);
      entry->rate_tokens += refill;
      if (entry->rate_tokens > entry->limits.max_new_conn_per_min) {
        entry->rate_tokens = entry->limits.max_new_conn_per_min;
      }
      entry->rate_updated_at_ms = now_ms;
    }

    if (entry->rate_tokens < 1.0) {
      atomic_fetch_add (&entry->total_rejected_rate_limit, 1);
      pthread_mutex_unlock (&store->mutex);
      return -1;
    }

    entry->rate_tokens -= 1.0;
  }

  atomic_fetch_add (&entry->active_conns, 1);
  atomic_fetch_add (&entry->total_accepted, 1);
  atomic_store (&entry->last_seen, now_ms / 1000);
  pthread_mutex_unlock (&store->mutex);
  return 0;
}

void secret_store_on_accept (SecretEntry *entry, long long now_ms) {
  secret_store_ensure_initialized ();
  if (!entry) {
    return;
  }

  atomic_fetch_add (&entry->active_conns, 1);
  atomic_fetch_add (&entry->total_accepted, 1);
  atomic_store (&entry->last_seen, now_ms / 1000);
}

void secret_store_on_close (SecretEntry *entry, long long now_ms) {
  secret_store_ensure_initialized ();
  if (!entry) {
    return;
  }

  int current = atomic_load (&entry->active_conns);
  while (current > 0 && !atomic_compare_exchange_weak (&entry->active_conns, &current, current - 1)) {
  }
  atomic_store (&entry->last_seen, now_ms / 1000);
}
