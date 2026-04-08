#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="${ROOT_DIR}/objs/bin/mtproto-proxy"

ADMIN_TOKEN="${ADMIN_TOKEN:-test-admin-token}"
ADMIN_PORT="${ADMIN_PORT:-$((29081 + (RANDOM % 1000)))}"
PUBLIC_PORT="${PUBLIC_PORT:-$((25443 + (RANDOM % 1000)))}"
STATS_PORT="${STATS_PORT:-$((28888 + (RANDOM % 1000)))}"
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
RECONCILE_DRY_JSON="${WORK_DIR}/reconcile-dry.json"
RECONCILE_APPLY_JSON="${WORK_DIR}/reconcile-apply.json"
RECONCILE_REMOVE_JSON="${WORK_DIR}/reconcile-remove.json"
FINAL_LIST_JSON="${WORK_DIR}/final-list.json"
DELETE_CREATE_JSON="${WORK_DIR}/delete-create.json"
RUNTIME_CREATE_JSON="${WORK_DIR}/runtime-create.json"
RUNTIME_STATS_ACCEPT_JSON="${WORK_DIR}/runtime-stats-accept.json"
RUNTIME_STATS_REJECT_JSON="${WORK_DIR}/runtime-stats-reject.json"
RUNTIME_STATS_FINAL_JSON="${WORK_DIR}/runtime-stats-final.json"

mkdir -p "${WORK_DIR}"
rm -f "${HEALTH_JSON}" "${CREATE_JSON}" "${LIST_JSON}" "${PATCH_JSON}" "${DELETE_JSON}" "${RECONCILE_DRY_JSON}" "${RECONCILE_APPLY_JSON}" "${RECONCILE_REMOVE_JSON}" "${FINAL_LIST_JSON}" "${DELETE_CREATE_JSON}" "${RUNTIME_CREATE_JSON}" "${RUNTIME_STATS_ACCEPT_JSON}" "${RUNTIME_STATS_REJECT_JSON}" "${RUNTIME_STATS_FINAL_JSON}" "${LOG_FILE}"
rm -f "${STATE_FILE}"
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
  if [[ -n "${runtime_client_pid:-}" ]]; then
    kill "${runtime_client_pid}" 2>/dev/null || true
    wait "${runtime_client_pid}" 2>/dev/null || true
  fi
  if [[ -n "${proxy_pid:-}" ]]; then
    kill "${proxy_pid}" 2>/dev/null || true
    wait "${proxy_pid}" 2>/dev/null || true
  fi
  pkill -f "${BIN} -u nobody -p ${STATS_PORT} -H ${PUBLIC_PORT}" 2>/dev/null || true
}
trap cleanup EXIT

pkill -f "${BIN} -u nobody -p ${STATS_PORT} -H ${PUBLIC_PORT}" 2>/dev/null || true

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

LEGACY_SECRET_ID="$(python3 - <<'PY' "${LIST_JSON}" "${SECRET_ID}"
import json, sys
listing = json.load(open(sys.argv[1], "r", encoding="utf-8"))
created_id = sys.argv[2]
legacy = [item["secret_id"] for item in listing["secrets"] if item["secret_id"] != created_id]
print(legacy[0])
PY
)"

curl -fsS -H "Authorization: Bearer ${ADMIN_TOKEN}" \
  -H "X-HTTP-Method-Override: PATCH" \
  -H "Content-Type: application/json" \
  -d '{"label":"smoke-secret-updated","max_active_connections":3}' \
  "http://127.0.0.1:${ADMIN_PORT}/admin/secrets/${SECRET_ID}" > "${PATCH_JSON}"

curl -fsS -H "Authorization: Bearer ${ADMIN_TOKEN}" \
  -H "Content-Type: application/json" \
  -d "{\"dry_run\":true,\"secrets\":[{\"secret_id\":\"${LEGACY_SECRET_ID}\",\"label\":\"legacy\",\"max_active_connections\":0,\"max_new_conn_per_min\":0},{\"secret_id\":\"${SECRET_ID}\",\"label\":\"smoke-secret-reconciled\",\"max_active_connections\":4,\"max_new_conn_per_min\":9}]}" \
  "http://127.0.0.1:${ADMIN_PORT}/admin/reconcile" > "${RECONCILE_DRY_JSON}"

curl -fsS -H "Authorization: Bearer ${ADMIN_TOKEN}" \
  -H "Content-Type: application/json" \
  -d "{\"secrets\":[{\"secret_id\":\"${LEGACY_SECRET_ID}\",\"label\":\"legacy\",\"max_active_connections\":0,\"max_new_conn_per_min\":0},{\"secret_id\":\"${SECRET_ID}\",\"label\":\"smoke-secret-reconciled\",\"max_active_connections\":4,\"max_new_conn_per_min\":9}]}" \
  "http://127.0.0.1:${ADMIN_PORT}/admin/reconcile" > "${RECONCILE_APPLY_JSON}"

curl -fsS -H "Authorization: Bearer ${ADMIN_TOKEN}" \
  -H "Content-Type: application/json" \
  -d "{\"secrets\":[{\"secret_id\":\"${LEGACY_SECRET_ID}\",\"label\":\"legacy\",\"max_active_connections\":0,\"max_new_conn_per_min\":0}]}" \
  "http://127.0.0.1:${ADMIN_PORT}/admin/reconcile" > "${RECONCILE_REMOVE_JSON}"

curl -fsS -H "Authorization: Bearer ${ADMIN_TOKEN}" \
  "http://127.0.0.1:${ADMIN_PORT}/admin/secrets" > "${FINAL_LIST_JSON}"

curl -fsS -H "Authorization: Bearer ${ADMIN_TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{"label":"delete-me","max_active_connections":1,"max_new_conn_per_min":1}' \
  "http://127.0.0.1:${ADMIN_PORT}/admin/secrets" > "${DELETE_CREATE_JSON}"

DELETE_SECRET_ID="$(python3 - <<'PY' "${DELETE_CREATE_JSON}"
import json, sys
payload = json.load(open(sys.argv[1], "r", encoding="utf-8"))
print(payload["created"]["secret_id"])
PY
)"

curl -fsS -H "Authorization: Bearer ${ADMIN_TOKEN}" \
  -H "X-HTTP-Method-Override: DELETE" \
  -H "Content-Type: application/json" \
  -d '{}' \
  "http://127.0.0.1:${ADMIN_PORT}/admin/secrets/${DELETE_SECRET_ID}" > "${DELETE_JSON}"

curl -fsS -H "Authorization: Bearer ${ADMIN_TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{"label":"runtime-limit-secret","max_active_connections":1,"max_new_conn_per_min":10}' \
  "http://127.0.0.1:${ADMIN_PORT}/admin/secrets" > "${RUNTIME_CREATE_JSON}"

RUNTIME_SECRET_ID="$(python3 - <<'PY' "${RUNTIME_CREATE_JSON}"
import json, sys
with open(sys.argv[1], "r", encoding="utf-8") as f:
    data = json.load(f)
print(data["created"]["secret_id"])
PY
)"

RUNTIME_SECRET_HEX="$(python3 - <<'PY' "${RUNTIME_CREATE_JSON}"
import json, sys
with open(sys.argv[1], "r", encoding="utf-8") as f:
    data = json.load(f)
print(data["created"]["secret"])
PY
)"

python3 "${ROOT_DIR}/tests/obfuscated_client.py" \
  --host 127.0.0.1 \
  --port "${PUBLIC_PORT}" \
  --secret "${RUNTIME_SECRET_HEX}" \
  --expect open \
  --hold-seconds 2.5 &
runtime_client_pid=$!

for _ in {1..20}; do
  curl -fsS -H "Authorization: Bearer ${ADMIN_TOKEN}" \
    "http://127.0.0.1:${ADMIN_PORT}/admin/stats/secrets" > "${RUNTIME_STATS_ACCEPT_JSON}"
  if python3 - <<'PY' "${RUNTIME_STATS_ACCEPT_JSON}" "${RUNTIME_SECRET_ID}"
import json, sys
payload = json.load(open(sys.argv[1], "r", encoding="utf-8"))
secret_id = sys.argv[2]
for item in payload["secrets"]:
    if item["secret_id"] == secret_id and item["active_conns"] >= 1 and item["total_accepted"] >= 1:
        raise SystemExit(0)
raise SystemExit(1)
PY
  then
    break
  fi
  sleep 0.2
done

python3 "${ROOT_DIR}/tests/obfuscated_client.py" \
  --host 127.0.0.1 \
  --port "${PUBLIC_PORT}" \
  --secret "${RUNTIME_SECRET_HEX}" \
  --expect closed

wait "${runtime_client_pid}"
unset runtime_client_pid

curl -fsS -H "Authorization: Bearer ${ADMIN_TOKEN}" \
  "http://127.0.0.1:${ADMIN_PORT}/admin/stats/secrets" > "${RUNTIME_STATS_REJECT_JSON}"

for _ in {1..20}; do
  curl -fsS -H "Authorization: Bearer ${ADMIN_TOKEN}" \
    "http://127.0.0.1:${ADMIN_PORT}/admin/stats/secrets" > "${RUNTIME_STATS_FINAL_JSON}"
  if python3 - <<'PY' "${RUNTIME_STATS_FINAL_JSON}" "${RUNTIME_SECRET_ID}"
import json, sys
payload = json.load(open(sys.argv[1], "r", encoding="utf-8"))
secret_id = sys.argv[2]
for item in payload["secrets"]:
    if item["secret_id"] == secret_id and item["active_conns"] == 0:
        raise SystemExit(0)
raise SystemExit(1)
PY
  then
    break
  fi
  sleep 0.2
done

python3 - <<'PY' "${HEALTH_JSON}" "${CREATE_JSON}" "${LIST_JSON}" "${PATCH_JSON}" "${DELETE_JSON}" "${RECONCILE_DRY_JSON}" "${RECONCILE_APPLY_JSON}" "${RECONCILE_REMOVE_JSON}" "${FINAL_LIST_JSON}" "${DELETE_CREATE_JSON}" "${STATE_FILE}" "${RUNTIME_STATS_ACCEPT_JSON}" "${RUNTIME_STATS_REJECT_JSON}" "${RUNTIME_STATS_FINAL_JSON}" "${RUNTIME_SECRET_ID}"
import json, sys
health, create, listing, patch, delete, reconcile_dry, reconcile_apply, reconcile_remove, final_list, delete_create, state, runtime_accept, runtime_reject, runtime_final = [json.load(open(path, "r", encoding="utf-8")) for path in sys.argv[1:15]]
runtime_secret_id = sys.argv[15]

assert health["ok"] is True
assert create["ok"] is True
assert "created" in create and len(create["created"]["secret"]) == 32
assert listing["count"] >= 2
assert patch["ok"] is True
assert delete["ok"] is True
assert delete_create["ok"] is True
assert reconcile_dry["ok"] is True and reconcile_dry["dry_run"] is True
assert reconcile_apply["ok"] is True and reconcile_apply["dry_run"] is False
assert reconcile_remove["ok"] is True and reconcile_remove["summary"]["to_remove"] >= 1
assert final_list["count"] == 1
assert state["version"] == 1

runtime_accept_entry = next(item for item in runtime_accept["secrets"] if item["secret_id"] == runtime_secret_id)
runtime_reject_entry = next(item for item in runtime_reject["secrets"] if item["secret_id"] == runtime_secret_id)
runtime_final_entry = next(item for item in runtime_final["secrets"] if item["secret_id"] == runtime_secret_id)
assert runtime_accept_entry["active_conns"] >= 1
assert runtime_accept_entry["total_accepted"] >= 1
assert runtime_reject_entry["total_rejected_limit"] >= 1
assert runtime_final_entry["active_conns"] == 0
print("smoke-ok")
PY

echo "Smoke test passed."
