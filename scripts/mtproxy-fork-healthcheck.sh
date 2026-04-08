#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/mtproxy-fork-common.sh"

load_mtproxy_fork_defaults

required_var MTPROXY_FORK_ADMIN_TOKEN

for _ in {1..20}; do
  if curl -fsS -H "Authorization: Bearer ${MTPROXY_FORK_ADMIN_TOKEN}" \
    "http://127.0.0.1:${MTPROXY_FORK_ADMIN_PORT}/admin/health" >/dev/null; then
    echo "mtproxy-fork healthcheck ok"
    exit 0
  fi
  sleep 1
done

echo "mtproxy-fork healthcheck failed" >&2
exit 1
