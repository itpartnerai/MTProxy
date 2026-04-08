# MTProxy Fork Runbook

## Purpose

This runbook describes how to build, test, and run the forked MTProxy binary that adds:

- scalable secret storage
- loopback-only admin API
- persistent secret state
- per-secret stats
- single-worker per-secret runtime limits

Base upstream commit:

- `cafc3380a81671579ce366d0594b9a8e450827e9`

## Build

```bash
make clean && make
```

Binary:

- `objs/bin/mtproto-proxy`

## Smoke test

```bash
make test
```

What it validates:

- admin API health
- secret create/list/update/delete
- reconcile dry-run and apply
- state file persistence
- real obfuscated client connection
- `max_active_connections` rejection
- `max_new_conn_per_min` rejection

## Runtime requirements

Required MTProxy inputs remain unchanged:

- `proxy-secret`
- `proxy-multi.conf`
- public host/port
- raw client secret

New admin runtime settings:

- `MTPROXY_ADMIN_TOKEN`
- `MTPROXY_ADMIN_PORT`
- `MTPROXY_ADMIN_STATE_FILE`

Recommended MVP mode:

- `--slaves 0` or `--slaves 1`

Rationale:

- current per-secret counters and enforcement are validated for single-worker mode
- exact global multi-worker enforcement is not implemented in this milestone

## Example local run

```bash
MTPROXY_ADMIN_TOKEN="replace-me" \
MTPROXY_ADMIN_PORT="7081" \
MTPROXY_ADMIN_STATE_FILE="state/admin-secrets.json" \
objs/bin/mtproto-proxy \
  -u nobody \
  -p 8888 \
  -H 5443 \
  -S "$(cat /opt/mtproxy-node/config/user-secret)" \
  --aes-pwd /opt/mtproxy-node/config/proxy-secret /opt/mtproxy-node/config/proxy-multi.conf \
  -M 0 \
  --http-stats \
  --slaves 0
```

## Admin API

Bind:

- `127.0.0.1:<admin-port>`

Auth:

- `Authorization: Bearer <MTPROXY_ADMIN_TOKEN>`

Endpoints:

- `GET /admin/health`
- `GET /admin/secrets`
- `GET /admin/stats/secrets`
- `POST /admin/secrets`
- `POST /admin/secrets/{id}` with `X-HTTP-Method-Override: PATCH`
- `POST /admin/secrets/{id}` with `X-HTTP-Method-Override: DELETE`
- `POST /admin/reconcile`

Security rules:

- admin API stays disabled when token is not set
- admin API must not be exposed on a public interface
- list endpoints do not return raw secrets
- generated raw secret is returned only once on create

## Operational limitations

- true HTTP `PATCH` / `DELETE` is not implemented
- no unix socket listener yet
- no exact global multi-worker enforcement
- no packaged systemd/deploy assets in this fork yet

## Recommended production pattern

- keep Telegram client contract unchanged: `host + port + raw secret`
- run forked proxy in single-worker mode until multi-worker accounting exists
- place an external control plane in front of the loopback admin API
- manage secrets through desired-state reconcile rather than imperative edits
