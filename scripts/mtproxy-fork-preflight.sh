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
required_var MTPROXY_FORK_ADMIN_STATE_FILE

[[ -x "${MTPROXY_FORK_BIN}" ]] || { echo "Binary is not executable: ${MTPROXY_FORK_BIN}" >&2; exit 1; }
[[ -f "${MTPROXY_FORK_CLIENT_SECRET_FILE}" ]] || { echo "Missing client secret file: ${MTPROXY_FORK_CLIENT_SECRET_FILE}" >&2; exit 1; }
[[ -f "${MTPROXY_FORK_PROXY_SECRET_FILE}" ]] || { echo "Missing proxy-secret file: ${MTPROXY_FORK_PROXY_SECRET_FILE}" >&2; exit 1; }
[[ -f "${MTPROXY_FORK_PROXY_CONFIG_FILE}" ]] || { echo "Missing proxy-multi.conf file: ${MTPROXY_FORK_PROXY_CONFIG_FILE}" >&2; exit 1; }

mkdir -p "${MTPROXY_FORK_WORKDIR}"
mkdir -p "$(dirname "${MTPROXY_FORK_ADMIN_STATE_FILE}")"

if [[ ! -s "${MTPROXY_FORK_ADMIN_STATE_FILE}" ]]; then
  cat > "${MTPROXY_FORK_ADMIN_STATE_FILE}" <<'EOF'
{
  "version": 1,
  "secrets": []
}
EOF
fi

if [[ "${EUID:-$(id -u)}" -eq 0 ]] && id "${MTPROXY_FORK_USER}" >/dev/null 2>&1; then
  runtime_group="$(id -gn "${MTPROXY_FORK_USER}")"
  chown "${MTPROXY_FORK_USER}:${runtime_group}" "$(dirname "${MTPROXY_FORK_ADMIN_STATE_FILE}")" "${MTPROXY_FORK_ADMIN_STATE_FILE}" "${MTPROXY_FORK_WORKDIR}"
  chmod 0750 "$(dirname "${MTPROXY_FORK_ADMIN_STATE_FILE}")" "${MTPROXY_FORK_WORKDIR}"
  chmod 0640 "${MTPROXY_FORK_ADMIN_STATE_FILE}"
fi

client_secret="$(read_hex_secret_file "${MTPROXY_FORK_CLIENT_SECRET_FILE}")"
[[ "${#client_secret}" -eq 32 ]] || { echo "Client secret must contain exactly 32 hex chars" >&2; exit 1; }

if [[ -n "${MTPROXY_FORK_PROXY_TAG_FILE:-}" ]]; then
  proxy_tag="$(read_hex_secret_file "${MTPROXY_FORK_PROXY_TAG_FILE}")"
  [[ "${#proxy_tag}" -eq 32 ]] || { echo "Proxy tag must contain exactly 32 hex chars" >&2; exit 1; }
fi

echo "mtproxy-fork preflight ok"
