#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PACKAGE_PATH="${MTPROXY_FORK_PACKAGE_PATH:-${ROOT_DIR}/dist/mtproxy-fork-package.tar.gz}"
TEST_HOST="${TEST_HOST:?Set TEST_HOST to the target hostname or IP}"
TEST_HOST_SSH_USER="${TEST_HOST_SSH_USER:-root}"
TEST_HOST_SSH_PORT="${TEST_HOST_SSH_PORT:-22}"
TEST_HOST_STAGE_DIR="${TEST_HOST_STAGE_DIR:-/tmp/mtproxy-fork-rollout}"
TEST_HOST_SERVICE="${TEST_HOST_SERVICE:-mtproxy-fork.service}"
TEST_HOST_ACTIVATE="${TEST_HOST_ACTIVATE:-0}"

if [[ ! -f "${PACKAGE_PATH}" ]]; then
  echo "Package not found: ${PACKAGE_PATH}" >&2
  echo "Build it first with: make package" >&2
  exit 1
fi

timestamp="$(date +%Y%m%d-%H%M%S)"
remote="${TEST_HOST_SSH_USER}@${TEST_HOST}"
remote_pkg="${TEST_HOST_STAGE_DIR}/mtproxy-fork-package-${timestamp}.tar.gz"

ssh_cmd=(ssh -p "${TEST_HOST_SSH_PORT}" "${remote}")
scp_cmd=(scp -P "${TEST_HOST_SSH_PORT}")

"${ssh_cmd[@]}" "mkdir -p '${TEST_HOST_STAGE_DIR}'"
"${scp_cmd[@]}" "${PACKAGE_PATH}" "${remote}:${remote_pkg}"

"${ssh_cmd[@]}" "REMOTE_PKG='${remote_pkg}' SERVICE='${TEST_HOST_SERVICE}' ACTIVATE='${TEST_HOST_ACTIVATE}' bash -s" <<'EOF'
set -euo pipefail

backup_root="/var/backups/mtproxy-fork-rollout/$(date +%Y%m%d-%H%M%S)"
mkdir -p "${backup_root}"

backup_tar_if_exists() {
  local src="$1"
  local dst="$2"
  if [[ -e "${src}" ]]; then
    tar -C / -czf "${backup_root}/${dst}" "${src#/}"
  fi
}

backup_tar_if_exists /usr/local/libexec/mtproxy-fork usr-local-libexec-mtproxy-fork.tar.gz
backup_tar_if_exists /usr/local/share/doc/mtproxy-fork usr-local-share-doc-mtproxy-fork.tar.gz
backup_tar_if_exists /etc/mtproxy-fork etc-mtproxy-fork.tar.gz

if [[ -f /etc/systemd/system/${SERVICE} ]]; then
  cp /etc/systemd/system/${SERVICE} "${backup_root}/${SERVICE}"
fi

systemctl status "${SERVICE}" > "${backup_root}/service-status.txt" 2>&1 || true
systemctl is-enabled "${SERVICE}" > "${backup_root}/service-enabled.txt" 2>&1 || true

tar -C / -xzf "${REMOTE_PKG}"

if [[ -f /etc/mtproxy-fork/mtproxy-fork.env.example && ! -f /etc/mtproxy-fork/mtproxy-fork.env ]]; then
  cp /etc/mtproxy-fork/mtproxy-fork.env.example /etc/mtproxy-fork/mtproxy-fork.env
fi

systemctl daemon-reload

if [[ -f /etc/mtproxy-fork/mtproxy-fork.env ]]; then
  set -a
  # shellcheck disable=SC1091
  . /etc/mtproxy-fork/mtproxy-fork.env
  set +a
  /usr/local/libexec/mtproxy-fork/mtproxy-fork-preflight.sh
else
  echo "Warning: /etc/mtproxy-fork/mtproxy-fork.env is missing, service was staged but not preflighted." >&2
fi

if [[ "${ACTIVATE}" == "1" ]]; then
  systemctl restart "${SERVICE}"
  systemctl --no-pager --full status "${SERVICE}" || true
fi

echo "mtproxy-fork test-host deploy ok"
echo "backup_dir=${backup_root}"
echo "package=${REMOTE_PKG}"
EOF
