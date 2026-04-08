#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="${ROOT_DIR}/objs/bin/mtproto-proxy"

ADMIN_TOKEN="${ADMIN_TOKEN:-test-admin-token}"
ADMIN_PORT="${ADMIN_PORT:-29081}"
PUBLIC_PORT="${PUBLIC_PORT:-25443}"
STATS_PORT="${STATS_PORT:-28888}"
STATE_FILE="${STATE_FILE:-${ROOT_DIR}/state/admin-secrets.json}"

PROXY_SECRET_FILE="${PROXY_SECRET_FILE:-/opt/mtproxy-node/config/proxy-secret}"
PROXY_CONFIG_FILE="${PROXY_CONFIG_FILE:-/opt/mtproxy-node/config/proxy-multi.conf}"
LEGACY_SECRET_FILE="${LEGACY_SECRET_FILE:-/opt/mtproxy-node/config/user-secret}"

WORK_DIR="${ROOT_DIR}/tests/.tmp-smoke"
LOG_FILE="${WORK_DIR}/mtproxy.log"
HEALTH_JSON="${WORK_DIR}/health.json"
CREATE_JSON="${WORK_DIR}/create.json"
LIST_JSON="${WORK_DIR}/list.json"
PATCH_JSON="${WORK_DIR}/patch.json"
DELETE_JSON="${WORK_DIR}/delete.json"

mkdir -p "${WORK_DIR}"
rm -f "${HEALTH_JSON}" "${CREATE_JSON}" "${LIST_JSON}" "${PATCH_JSON}" "${DELETE_JSON}" "${LOG_FILE}"
mkdir -p "$(dirname "${STATE_FILE}")"

if [[ ! -x "${BIN}" ]]; then
  echo "Binary not found: ${BIN}" >&2
  exit 1
fi

if [[ ! -f "${PROXY_SECRET_FILE}" || ! -f "${PROXY_CONFIG_FILE}" || ! -f "${LEGACY_SECRET_FILE}" ]]; then
  echo "Smoke test requires PROXY_SECRET_FILE, PROXY_CONFIG_FILE and LEGACY_SECRET_FILE." >&2
  exit 1
fi

cleanup() {
  if [[ -n "${proxy_pid:-}" ]]; then
    kill "${proxy_pid}" 2>/dev/null || true
    wait "${proxy_pid}" 2>/dev/null || true
  fi
}
trap cleanup EXIT

MTPROXY_ADMIN_TOKEN="${ADMIN_TOKEN}" \
MTPROXY_ADMIN_PORT="${ADMIN_PORT}" \
MTPROXY_ADMIN_STATE_FILE="${STATE_FILE}" \
"${BIN}" \
  -u nobody \
  -p "${STATS_PORT}" \
  -H "${PUBLIC_PORT}" \
  -S "$(tr -d '\r\n\t ' < "${LEGACY_SECRET_FILE}")" \
  --aes-pwd "${PROXY_SECRET_FILE}" "${PROXY_CONFIG_FILE}" \
  -M 0 \
  --http-stats \
  > "${LOG_FILE}" 2>&1 &
proxy_pid=$!

for _ in {1..20}; do
  if curl -fsS -H "Authorization: Bearer ${ADMIN_TOKEN}" "http://127.0.0.1:${ADMIN_PORT}/admin/health" > "${HEALTH_JSON}"; then
    break
  fi
  sleep 1
done

curl -fsS -H "Authorization: Bearer ${ADMIN_TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{"label":"smoke-secret","max_active_connections":2,"max_new_conn_per_min":5}' \
  "http://127.0.0.1:${ADMIN_PORT}/admin/secrets" > "${CREATE_JSON}"

SECRET_ID="$(python3 - <<'PY' "${CREATE_JSON}"
import json, sys
with open(sys.argv[1], "r", encoding="utf-8") as f:
    data = json.load(f)
print(data["created"]["secret_id"])
PY
)"

curl -fsS -H "Authorization: Bearer ${ADMIN_TOKEN}" \
  "http://127.0.0.1:${ADMIN_PORT}/admin/secrets" > "${LIST_JSON}"

curl -fsS -H "Authorization: Bearer ${ADMIN_TOKEN}" \
  -H "X-HTTP-Method-Override: PATCH" \
  -H "Content-Type: application/json" \
  -d '{"label":"smoke-secret-updated","max_active_connections":3}' \
  "http://127.0.0.1:${ADMIN_PORT}/admin/secrets/${SECRET_ID}" > "${PATCH_JSON}"

curl -fsS -H "Authorization: Bearer ${ADMIN_TOKEN}" \
  -H "X-HTTP-Method-Override: DELETE" \
  -H "Content-Type: application/json" \
  -d '{}' \
  "http://127.0.0.1:${ADMIN_PORT}/admin/secrets/${SECRET_ID}" > "${DELETE_JSON}"

python3 - <<'PY' "${HEALTH_JSON}" "${CREATE_JSON}" "${LIST_JSON}" "${PATCH_JSON}" "${DELETE_JSON}" "${STATE_FILE}"
import json, sys
health, create, listing, patch, delete, state = [json.load(open(path, "r", encoding="utf-8")) for path in sys.argv[1:7]]

assert health["ok"] is True
assert create["ok"] is True
assert "created" in create and len(create["created"]["secret"]) == 32
assert listing["count"] >= 2
assert patch["ok"] is True
assert delete["ok"] is True
assert state["version"] == 1
print("smoke-ok")
PY

echo "Smoke test passed."
