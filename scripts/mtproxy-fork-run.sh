#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/mtproxy-fork-common.sh"

load_mtproxy_fork_defaults

export MTPROXY_ADMIN_TOKEN="${MTPROXY_FORK_ADMIN_TOKEN}"
export MTPROXY_ADMIN_PORT="${MTPROXY_FORK_ADMIN_PORT}"
export MTPROXY_ADMIN_STATE_FILE="${MTPROXY_FORK_ADMIN_STATE_FILE}"

mkdir -p "${MTPROXY_FORK_WORKDIR}"
cd "${MTPROXY_FORK_WORKDIR}"

mapfile -d '' -t MTProxyForkArgs < <(build_mtproxy_fork_args)
exec "${MTProxyForkArgs[@]}"
