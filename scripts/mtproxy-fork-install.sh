#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DESTDIR="${DESTDIR:-}"
PREFIX="${PREFIX:-/usr/local/libexec/mtproxy-fork}"
SYSCONFDIR="${SYSCONFDIR:-/etc/mtproxy-fork}"
SYSTEMD_DIR="${SYSTEMD_DIR:-/etc/systemd/system}"
DOCSDIR="${DOCSDIR:-/usr/local/share/doc/mtproxy-fork}"

install -d "${DESTDIR}${PREFIX}" "${DESTDIR}${SYSCONFDIR}" "${DESTDIR}${SYSTEMD_DIR}" "${DESTDIR}${DOCSDIR}"

install -m 0755 "${ROOT_DIR}/objs/bin/mtproto-proxy" "${DESTDIR}${PREFIX}/mtproto-proxy"
install -m 0755 "${ROOT_DIR}/scripts/mtproxy-fork-common.sh" "${DESTDIR}${PREFIX}/mtproxy-fork-common.sh"
install -m 0755 "${ROOT_DIR}/scripts/mtproxy-fork-preflight.sh" "${DESTDIR}${PREFIX}/mtproxy-fork-preflight.sh"
install -m 0755 "${ROOT_DIR}/scripts/mtproxy-fork-run.sh" "${DESTDIR}${PREFIX}/mtproxy-fork-run.sh"
install -m 0755 "${ROOT_DIR}/scripts/mtproxy-fork-healthcheck.sh" "${DESTDIR}${PREFIX}/mtproxy-fork-healthcheck.sh"
install -m 0755 "${ROOT_DIR}/scripts/mtproxy-fork-test-host-deploy.sh" "${DESTDIR}${PREFIX}/mtproxy-fork-test-host-deploy.sh"
install -m 0755 "${ROOT_DIR}/scripts/mtproxy-fork-test-host-validate.sh" "${DESTDIR}${PREFIX}/mtproxy-fork-test-host-validate.sh"
install -m 0755 "${ROOT_DIR}/scripts/mtproxy-fork-test-host-rollback.sh" "${DESTDIR}${PREFIX}/mtproxy-fork-test-host-rollback.sh"

install -m 0644 "${ROOT_DIR}/deploy/systemd/mtproxy-fork.service" "${DESTDIR}${SYSTEMD_DIR}/mtproxy-fork.service"
install -m 0644 "${ROOT_DIR}/deploy/config/mtproxy-fork.env.example" "${DESTDIR}${SYSCONFDIR}/mtproxy-fork.env.example"
install -m 0644 "${ROOT_DIR}/README_FORK.md" "${DESTDIR}${DOCSDIR}/README_FORK.md"
install -m 0644 "${ROOT_DIR}/RUNBOOK_FORK.md" "${DESTDIR}${DOCSDIR}/RUNBOOK_FORK.md"
install -m 0644 "${ROOT_DIR}/TEST_HOST_ROLLOUT.md" "${DESTDIR}${DOCSDIR}/TEST_HOST_ROLLOUT.md"
install -m 0644 "${ROOT_DIR}/FORK_BASE_COMMIT" "${DESTDIR}${DOCSDIR}/FORK_BASE_COMMIT"

echo "Installed MTProxy fork package layout under ${DESTDIR:-/}"
