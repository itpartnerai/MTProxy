#!/usr/bin/env bash

set -euo pipefail

TEST_HOST="${TEST_HOST:?Set TEST_HOST to the target hostname or IP}"
TEST_HOST_SSH_USER="${TEST_HOST_SSH_USER:-root}"
TEST_HOST_SSH_PORT="${TEST_HOST_SSH_PORT:-22}"
TEST_HOST_SERVICE="${TEST_HOST_SERVICE:-mtproxy-fork.service}"
TEST_HOST_BACKUP_DIR="${TEST_HOST_BACKUP_DIR:?Set TEST_HOST_BACKUP_DIR to the remote backup dir produced by deploy}"
TEST_HOST_ACTIVATE="${TEST_HOST_ACTIVATE:-1}"

remote="${TEST_HOST_SSH_USER}@${TEST_HOST}"
ssh_cmd=(ssh -p "${TEST_HOST_SSH_PORT}" "${remote}")

"${ssh_cmd[@]}" "BACKUP_DIR='${TEST_HOST_BACKUP_DIR}' SERVICE='${TEST_HOST_SERVICE}' ACTIVATE='${TEST_HOST_ACTIVATE}' bash -s" <<'EOF'
set -euo pipefail

[[ -d "${BACKUP_DIR}" ]] || { echo "Backup directory not found: ${BACKUP_DIR}" >&2; exit 1; }

restore_tar_if_exists() {
  local archive="$1"
  if [[ -f "${archive}" ]]; then
    tar -C / -xzf "${archive}"
  fi
}

restore_tar_if_exists "${BACKUP_DIR}/usr-local-libexec-mtproxy-fork.tar.gz"
restore_tar_if_exists "${BACKUP_DIR}/usr-local-share-doc-mtproxy-fork.tar.gz"
restore_tar_if_exists "${BACKUP_DIR}/etc-mtproxy-fork.tar.gz"

if [[ -f "${BACKUP_DIR}/${SERVICE}" ]]; then
  cp "${BACKUP_DIR}/${SERVICE}" "/etc/systemd/system/${SERVICE}"
fi

systemctl daemon-reload

if [[ "${ACTIVATE}" == "1" ]]; then
  systemctl restart "${SERVICE}"
  systemctl --no-pager --full status "${SERVICE}" || true
fi

echo "mtproxy-fork test-host rollback ok"
echo "backup_dir=${BACKUP_DIR}"
EOF
