#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/mtproxy-fork-common.sh"

load_mtproxy_fork_defaults

required_var MTPROXY_FORK_CLIENT_SECRET_FILE
required_var MTPROXY_FORK_PROXY_SECRET_FILE
required_var MTPROXY_FORK_PROXY_CONFIG_FILE
required_var MTPROXY_FORK_ADMIN_TOKEN

[[ -x "${MTPROXY_FORK_BIN}" ]] || { echo "Binary is not executable: ${MTPROXY_FORK_BIN}" >&2; exit 1; }
[[ -f "${MTPROXY_FORK_CLIENT_SECRET_FILE}" ]] || { echo "Missing client secret file: ${MTPROXY_FORK_CLIENT_SECRET_FILE}" >&2; exit 1; }
[[ -f "${MTPROXY_FORK_PROXY_SECRET_FILE}" ]] || { echo "Missing proxy-secret file: ${MTPROXY_FORK_PROXY_SECRET_FILE}" >&2; exit 1; }
[[ -f "${MTPROXY_FORK_PROXY_CONFIG_FILE}" ]] || { echo "Missing proxy-multi.conf file: ${MTPROXY_FORK_PROXY_CONFIG_FILE}" >&2; exit 1; }

mkdir -p "${MTPROXY_FORK_WORKDIR}"
touch "${MTPROXY_FORK_ADMIN_STATE_FILE}" 2>/dev/null || true

client_secret="$(read_hex_secret_file "${MTPROXY_FORK_CLIENT_SECRET_FILE}")"
[[ "${#client_secret}" -eq 32 ]] || { echo "Client secret must contain exactly 32 hex chars" >&2; exit 1; }

if [[ -n "${MTPROXY_FORK_PROXY_TAG_FILE:-}" ]]; then
  proxy_tag="$(read_hex_secret_file "${MTPROXY_FORK_PROXY_TAG_FILE}")"
  [[ "${#proxy_tag}" -eq 32 ]] || { echo "Proxy tag must contain exactly 32 hex chars" >&2; exit 1; }
fi

echo "mtproxy-fork preflight ok"
