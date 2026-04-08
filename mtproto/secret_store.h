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

#pragma once

#include <stdatomic.h>
#include <stdint.h>
#include <time.h>

#define SECRET_STORE_SECRET_LEN 16
#define SECRET_STORE_SECRET_ID_LEN 65
#define SECRET_STORE_LABEL_LEN 64
#define SECRET_STORE_MAX_SECRETS 1024

typedef struct secret_limits {
  int max_active_connections;
  int max_new_conn_per_min;
} secret_limits_t;

typedef struct secret_entry {
  uint8_t secret[SECRET_STORE_SECRET_LEN];
  char secret_id[SECRET_STORE_SECRET_ID_LEN];
  char label[SECRET_STORE_LABEL_LEN];
  secret_limits_t limits;
  atomic_int active_conns;
  atomic_ullong total_accepted;
  atomic_ullong total_rejected_limit;
  atomic_ullong total_rejected_rate_limit;
  time_t created_at;
  atomic_llong last_seen;
  double rate_tokens;
  long long rate_updated_at_ms;
  int active;
} SecretEntry;

int secret_store_add (const uint8_t secret[SECRET_STORE_SECRET_LEN], secret_limits_t limits, const char *label, char out_id[SECRET_STORE_SECRET_ID_LEN]);
int secret_store_remove (const char *secret_id);
SecretEntry *secret_store_find_by_bytes (const uint8_t secret[SECRET_STORE_SECRET_LEN]);
SecretEntry *secret_store_find_by_id (const char *secret_id);
int secret_store_count (void);
int secret_store_copy_secret_at (int index, uint8_t secret_out[SECRET_STORE_SECRET_LEN], char secret_id_out[SECRET_STORE_SECRET_ID_LEN]);
void secret_store_on_accept (SecretEntry *entry, long long now_ms);
void secret_store_on_close (SecretEntry *entry, long long now_ms);
int secret_store_check_limits (SecretEntry *entry, long long now_ms);
