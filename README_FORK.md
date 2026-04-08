# MTProxy Fork Notes

## Scope

This fork extends upstream `TelegramMessenger/MTProxy` to support:

- more than 16 secrets
- local authenticated admin API
- per-secret stats
- per-secret limits

## Upstream baseline

Base upstream commit is recorded in:

- `FORK_BASE_COMMIT`

Current baseline:

- `cafc3380a81671579ce366d0594b9a8e450827e9`

## Compatibility requirement

All changes must remain compatible with the built-in MTProto proxy client in Telegram.

This means the client contract must remain:

- `host`
- `port`
- `raw secret`

No client-side handshake changes are allowed.

## Current implementation status

Implemented and validated for shared-memory multi-worker runtime.

Current implemented fork layers:

- `secret_store`
- scalable runtime secret registry
- mmap-backed shared-memory secret store
- removal of the upstream fixed `16` secret storage assumption
- persistent local state file for admin-managed secrets
- dedicated loopback-only admin API listener
- Bearer token authentication via `MTPROXY_ADMIN_TOKEN`
- binding of matched runtime secret to connection lifecycle
- per-secret `active_conns` accounting on accept/close
- atomic per-secret limit reservation at accept time across workers
- JSON endpoints:
  - `GET /admin/health`
  - `GET /admin/secrets`
- `GET /admin/stats/secrets`
- `POST /admin/secrets`
- `POST /admin/secrets/{id}` with `X-HTTP-Method-Override: PATCH`
- `POST /admin/secrets/{id}` with `X-HTTP-Method-Override: DELETE`
- `POST /admin/reconcile`

## Current admin API configuration

Environment variables:

- `MTPROXY_ADMIN_TOKEN`
- `MTPROXY_ADMIN_PORT` (default `7081` when token is set)
- `MTPROXY_ADMIN_STATE_FILE` (default `state/admin-secrets.json`)

CLI flags:

- `--admin-port <port>`
- `--admin-state-file <path>`

Security model:

- admin API listens only on `127.0.0.1`
- if `MTPROXY_ADMIN_TOKEN` is not set, admin API stays disabled
- list/get endpoints never return raw secrets
- raw secret is returned only once in create response when server generates it

## Current limitations

- true HTTP `PATCH` / `DELETE` methods are not wired yet through the upstream parser
- current MVP uses `POST` plus `X-HTTP-Method-Override`
- `POST /admin/reconcile` applies full desired-state semantics and supports `dry_run`
- per-secret runtime enforcement is wired for matched secrets only after successful handshake selection
- current validation covers `WORKERS=0` and `WORKERS=2`; higher worker counts are not separately stress-tested yet
- there is no production-ready service wrapper in this fork yet; current validation uses isolated test runs
- the admin API is intentionally local-only and is expected to sit behind loopback access controls or an external management plane

## Smoke test

Available command:

- `make test`

The smoke test builds the fork, starts a temporary MTProxy instance on high ports, and validates:

- `GET /admin/health`
- `POST /admin/secrets`
- `GET /admin/secrets`
- `POST /admin/reconcile` (dry-run and apply)
- update/delete via method override
- state file persistence
- real obfuscated client connect for a generated secret
- `max_active_connections` reject on the second concurrent connection for the same secret
- `active_conns` returns to `0` after the first client closes
- `max_new_conn_per_min` reject on the second immediate reconnect for the same secret
- all of the above in both `WORKERS=0` and `WORKERS=2`

## Recommended next integration step

Before using this fork in production, add a thin management wrapper outside the proxy process that:

- owns the desired-state secret inventory
- writes the admin state file path explicitly
- exposes authenticated operations to trusted internal systems only
- starts MTProxy with an explicitly chosen worker count and health checks that match that topology
- performs health checks and rollback around binary upgrades
