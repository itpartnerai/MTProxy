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
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "common/sha256.h"

typedef struct secret_store_state {
  SecretEntry **entries;
  int capacity;
  int total_entries;
  pthread_mutex_t mutex;
} secret_store_state_t;

static secret_store_state_t store = {
  .entries = 0,
  .capacity = 0,
  .total_entries = 0,
  .mutex = PTHREAD_MUTEX_INITIALIZER
};

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

static void secret_store_fill_id (const uint8_t secret[SECRET_STORE_SECRET_LEN], char out_id[SECRET_STORE_SECRET_ID_LEN]) {
  unsigned char digest[32];
  sha256 (secret, SECRET_STORE_SECRET_LEN, digest);
  bytes_to_hex (digest, 32, out_id, SECRET_STORE_SECRET_ID_LEN);
}

static int ensure_store_capacity_unlocked (int required) {
  if (required <= store.capacity) {
    return 0;
  }

  int new_capacity = store.capacity ? store.capacity : 16;
  while (new_capacity < required) {
    new_capacity <<= 1;
  }

  if (new_capacity > SECRET_STORE_MAX_SECRETS) {
    new_capacity = SECRET_STORE_MAX_SECRETS;
  }

  if (required > new_capacity) {
    return -1;
  }

  SecretEntry **new_entries = realloc (store.entries, sizeof (*new_entries) * new_capacity);
  if (!new_entries) {
    return -1;
  }

  memset (new_entries + store.capacity, 0, sizeof (*new_entries) * (new_capacity - store.capacity));
  store.entries = new_entries;
  store.capacity = new_capacity;
  return 0;
}

static SecretEntry *find_by_bytes_unlocked (const uint8_t secret[SECRET_STORE_SECRET_LEN]) {
  int i;
  for (i = 0; i < store.total_entries; i++) {
    SecretEntry *entry = store.entries[i];
    if (entry && entry->active && !memcmp (entry->secret, secret, SECRET_STORE_SECRET_LEN)) {
      return entry;
    }
  }

  return 0;
}

static SecretEntry *find_by_id_unlocked (const char *secret_id) {
  int i;
  for (i = 0; i < store.total_entries; i++) {
    SecretEntry *entry = store.entries[i];
    if (entry && entry->active && !strcmp (entry->secret_id, secret_id)) {
      return entry;
    }
  }

  return 0;
}

int secret_store_add (const uint8_t secret[SECRET_STORE_SECRET_LEN], secret_limits_t limits, const char *label, char out_id[SECRET_STORE_SECRET_ID_LEN]) {
  char computed_id[SECRET_STORE_SECRET_ID_LEN];
  secret_store_fill_id (secret, computed_id);

  pthread_mutex_lock (&store.mutex);

  SecretEntry *existing = find_by_bytes_unlocked (secret);
  if (existing) {
    if (out_id) {
      memcpy (out_id, existing->secret_id, SECRET_STORE_SECRET_ID_LEN);
    }
    pthread_mutex_unlock (&store.mutex);
    return 1;
  }

  if (store.total_entries >= SECRET_STORE_MAX_SECRETS) {
    pthread_mutex_unlock (&store.mutex);
    return -1;
  }

  if (ensure_store_capacity_unlocked (store.total_entries + 1) < 0) {
    pthread_mutex_unlock (&store.mutex);
    return -1;
  }

  SecretEntry *entry = calloc (1, sizeof (*entry));
  if (!entry) {
    pthread_mutex_unlock (&store.mutex);
    return -1;
  }

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

  store.entries[store.total_entries++] = entry;

  if (out_id) {
    memcpy (out_id, entry->secret_id, SECRET_STORE_SECRET_ID_LEN);
  }

  pthread_mutex_unlock (&store.mutex);
  return 0;
}

int secret_store_remove (const char *secret_id) {
  pthread_mutex_lock (&store.mutex);

  SecretEntry *entry = find_by_id_unlocked (secret_id);
  if (!entry) {
    pthread_mutex_unlock (&store.mutex);
    return -1;
  }

  entry->active = 0;
  pthread_mutex_unlock (&store.mutex);
  return 0;
}

SecretEntry *secret_store_find_by_bytes (const uint8_t secret[SECRET_STORE_SECRET_LEN]) {
  SecretEntry *result;

  pthread_mutex_lock (&store.mutex);
  result = find_by_bytes_unlocked (secret);
  pthread_mutex_unlock (&store.mutex);

  return result;
}

SecretEntry *secret_store_find_by_id (const char *secret_id) {
  SecretEntry *result;

  pthread_mutex_lock (&store.mutex);
  result = find_by_id_unlocked (secret_id);
  pthread_mutex_unlock (&store.mutex);

  return result;
}

int secret_store_count (void) {
  int i, count = 0;

  pthread_mutex_lock (&store.mutex);
  for (i = 0; i < store.total_entries; i++) {
    SecretEntry *entry = store.entries[i];
    if (entry && entry->active) {
      count++;
    }
  }
  pthread_mutex_unlock (&store.mutex);

  return count;
}

int secret_store_copy_secret_at (int index, uint8_t secret_out[SECRET_STORE_SECRET_LEN], char secret_id_out[SECRET_STORE_SECRET_ID_LEN]) {
  int i, current = 0;

  pthread_mutex_lock (&store.mutex);
  for (i = 0; i < store.total_entries; i++) {
    SecretEntry *entry = store.entries[i];
    if (!entry || !entry->active) {
      continue;
    }

    if (current == index) {
      memcpy (secret_out, entry->secret, SECRET_STORE_SECRET_LEN);
      if (secret_id_out) {
        memcpy (secret_id_out, entry->secret_id, SECRET_STORE_SECRET_ID_LEN);
      }
      pthread_mutex_unlock (&store.mutex);
      return 0;
    }
    current++;
  }
  pthread_mutex_unlock (&store.mutex);

  return -1;
}

int secret_store_check_limits (SecretEntry *entry, long long now_ms) {
  if (!entry || !entry->active) {
    return -1;
  }

  if (entry->limits.max_active_connections > 0 &&
      atomic_load (&entry->active_conns) >= entry->limits.max_active_connections) {
    atomic_fetch_add (&entry->total_rejected_limit, 1);
    return -1;
  }

  if (entry->limits.max_new_conn_per_min > 0) {
    pthread_mutex_lock (&store.mutex);

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
      pthread_mutex_unlock (&store.mutex);
      return -1;
    }

    entry->rate_tokens -= 1.0;
    pthread_mutex_unlock (&store.mutex);
  }

  return 0;
}

void secret_store_on_accept (SecretEntry *entry, long long now_ms) {
  if (!entry) {
    return;
  }

  atomic_fetch_add (&entry->active_conns, 1);
  atomic_fetch_add (&entry->total_accepted, 1);
  atomic_store (&entry->last_seen, now_ms / 1000);
}

void secret_store_on_close (SecretEntry *entry, long long now_ms) {
  if (!entry) {
    return;
  }

  int current = atomic_load (&entry->active_conns);
  while (current > 0 && !atomic_compare_exchange_weak (&entry->active_conns, &current, current - 1)) {
  }
  atomic_store (&entry->last_seen, now_ms / 1000);
}
