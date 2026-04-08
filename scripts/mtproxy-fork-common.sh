#!/usr/bin/env bash

set -euo pipefail

required_var() {
  local name="$1"
  if [[ -z "${!name:-}" ]]; then
    echo "Missing required environment variable: ${name}" >&2
    exit 1
  fi
}

load_mtproxy_fork_defaults() {
  : "${MTPROXY_FORK_USER:=nobody}"
  : "${MTPROXY_FORK_BIN:=/usr/local/libexec/mtproxy-fork/mtproto-proxy}"
  : "${MTPROXY_FORK_WORKDIR:=/var/lib/mtproxy-fork}"
  : "${MTPROXY_FORK_PUBLIC_PORT:=5443}"
  : "${MTPROXY_FORK_STATS_PORT:=8888}"
  : "${MTPROXY_FORK_WORKERS:=2}"
  : "${MTPROXY_FORK_ADMIN_PORT:=7081}"
  : "${MTPROXY_FORK_ADMIN_STATE_FILE:=/var/lib/mtproxy-fork/admin-secrets.json}"
}

read_hex_secret_file() {
  local path="$1"
  tr -d '\r\n\t ' < "${path}"
}

build_mtproxy_fork_args() {
  load_mtproxy_fork_defaults

  required_var MTPROXY_FORK_BIN
  required_var MTPROXY_FORK_WORKDIR
  required_var MTPROXY_FORK_PUBLIC_PORT
  required_var MTPROXY_FORK_STATS_PORT
  required_var MTPROXY_FORK_WORKERS
  required_var MTPROXY_FORK_CLIENT_SECRET_FILE
  required_var MTPROXY_FORK_PROXY_SECRET_FILE
  required_var MTPROXY_FORK_PROXY_CONFIG_FILE
  required_var MTPROXY_FORK_ADMIN_TOKEN
  required_var MTPROXY_FORK_ADMIN_PORT
  required_var MTPROXY_FORK_ADMIN_STATE_FILE

  local client_secret
  client_secret="$(read_hex_secret_file "${MTPROXY_FORK_CLIENT_SECRET_FILE}")"

  local -a args=(
    "${MTPROXY_FORK_BIN}"
    -u "${MTPROXY_FORK_USER}"
    -p "${MTPROXY_FORK_STATS_PORT}"
    -H "${MTPROXY_FORK_PUBLIC_PORT}"
    -S "${client_secret}"
    --aes-pwd "${MTPROXY_FORK_PROXY_SECRET_FILE}" "${MTPROXY_FORK_PROXY_CONFIG_FILE}"
    -M "${MTPROXY_FORK_WORKERS}"
    --http-stats
  )

  if [[ -n "${MTPROXY_FORK_PROXY_TAG_FILE:-}" ]]; then
    args+=( -P "$(read_hex_secret_file "${MTPROXY_FORK_PROXY_TAG_FILE}")" )
  fi

  if [[ -n "${MTPROXY_FORK_EXTRA_ARGS:-}" ]]; then
    # shellcheck disable=SC2206
    local extra=( ${MTPROXY_FORK_EXTRA_ARGS} )
    args+=( "${extra[@]}" )
  fi

  printf '%s\0' "${args[@]}"
}
