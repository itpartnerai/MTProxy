# MTProxy Fork Test-Host Rollout

## Goal

This runbook stages the forked `MTProxy` package on a separate Linux test host before any production rollout.

It is intentionally designed around:

- package install from `dist/mtproxy-fork-package.tar.gz`
- host-side backup on the target machine
- explicit validation after deploy
- explicit rollback using the captured backup directory

## Build the package

Run this on a supported Linux build host:

```bash
make clean && make package
```

Expected artifact:

- `dist/mtproxy-fork-package.tar.gz`

## Deploy to a test host

Local-side helper:

```bash
TEST_HOST=192.0.2.10 \
TEST_HOST_SSH_USER=root \
TEST_HOST_SSH_PORT=22 \
TEST_HOST_ACTIVATE=1 \
bash scripts/mtproxy-fork-test-host-deploy.sh
```

What it does remotely:

- uploads the package to `/tmp/mtproxy-fork-rollout`
- creates a backup under `/var/backups/mtproxy-fork-rollout/<timestamp>`
- extracts the package into `/`
- copies `mtproxy-fork.env.example` to `mtproxy-fork.env` if needed
- runs `mtproxy-fork-preflight.sh`
- optionally restarts `mtproxy-fork.service` when `TEST_HOST_ACTIVATE=1`

The script prints the remote `backup_dir`. Save it for rollback.

## Validate the staged host

```bash
TEST_HOST=192.0.2.10 \
TEST_HOST_SSH_USER=root \
bash scripts/mtproxy-fork-test-host-validate.sh
```

Validation covers:

- env file present
- preflight success
- `systemctl is-active mtproxy-fork.service`
- local admin health check via bearer token
- local `/stats` response
- listening ports for public, stats, and admin listeners

## Roll back the test host

Use the `backup_dir` printed during deploy:

```bash
TEST_HOST=192.0.2.10 \
TEST_HOST_SSH_USER=root \
TEST_HOST_BACKUP_DIR=/var/backups/mtproxy-fork-rollout/20260408-123456 \
bash scripts/mtproxy-fork-test-host-rollback.sh
```

Rollback restores:

- `/usr/local/libexec/mtproxy-fork`
- `/usr/local/share/doc/mtproxy-fork`
- `/etc/mtproxy-fork`
- `/etc/systemd/system/mtproxy-fork.service`

Then it reloads `systemd` and restarts the service by default.

## Recommended test-host policy

- use a non-production IP and non-production Telegram secret inventory
- keep the same worker count you plan to use later in production
- validate `GET /admin/health` and `GET /admin/stats/secrets` locally only
- do not expose the admin listener publicly
- keep the printed backup directory until rollout is accepted
