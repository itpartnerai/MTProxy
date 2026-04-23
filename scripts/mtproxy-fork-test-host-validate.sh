#!/usr/bin/env bash

set -euo pipefail

TEST_HOST="${TEST_HOST:?Set TEST_HOST to the target hostname or IP}"
TEST_HOST_SSH_USER="${TEST_HOST_SSH_USER:-root}"
TEST_HOST_SSH_PORT="${TEST_HOST_SSH_PORT:-22}"
TEST_HOST_SERVICE="${TEST_HOST_SERVICE:-mtproxy-fork.service}"

remote="${TEST_HOST_SSH_USER}@${TEST_HOST}"
ssh_cmd=(ssh -p "${TEST_HOST_SSH_PORT}" "${remote}")

"${ssh_cmd[@]}" "SERVICE='${TEST_HOST_SERVICE}' bash -s" <<'EOF'
set -euo pipefail

if [[ ! -f /etc/mtproxy-fork/mtproxy-fork.env ]]; then
  echo "Missing env file: /etc/mtproxy-fork/mtproxy-fork.env" >&2
  exit 1
fi

set -a
# shellcheck disable=SC1091
. /etc/mtproxy-fork/mtproxy-fork.env
set +a

/usr/local/libexec/mtproxy-fork/mtproxy-fork-preflight.sh
systemctl is-active --quiet "${SERVICE}"
/usr/local/libexec/mtproxy-fork/mtproxy-fork-healthcheck.sh

curl -fsS "http://127.0.0.1:${MTPROXY_FORK_STATS_PORT}/stats" >/dev/null
ss -ltn "( sport = :${MTPROXY_FORK_PUBLIC_PORT} or sport = :${MTPROXY_FORK_STATS_PORT} or sport = :${MTPROXY_FORK_ADMIN_PORT} )"

echo "mtproxy-fork test-host validation ok"
echo "service=${SERVICE}"
echo "public_port=${MTPROXY_FORK_PUBLIC_PORT}"
echo "stats_port=${MTPROXY_FORK_STATS_PORT}"
echo "admin_port=${MTPROXY_FORK_ADMIN_PORT}"
EOF
