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

In progress.

The first foundation layer in this fork introduces:

- `secret_store`
- scalable runtime secret registry
- removal of the upstream fixed `16` secret storage assumption
