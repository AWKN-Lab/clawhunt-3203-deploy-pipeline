#!/usr/bin/env bash
# 一次性初始化：env 文件、state、LB 上游、PG/Redis、v1 基线镜像上线。
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"

init_run_log "bootstrap-$(date -u +%Y%m%dT%H%M%SZ)"

mkdir -p "$STATE_DIR" "$LB_DIR" "$EVIDENCE_DIR"

if [ ! -f "$ENV_FILE" ]; then
  POSTGRES_PASSWORD="$(openssl rand -hex 16)"
  printf 'POSTGRES_PASSWORD=%s\nIMAGE_REPO=s4d-api\nIMAGE_TAG=v1\n' "$POSTGRES_PASSWORD" > "$ENV_FILE"
  chmod 600 "$ENV_FILE"
  log INFO "env file created $ENV_FILE (0600)"
else
  log INFO "env file exists $ENV_FILE"
fi
load_env_file

if [ ! -f "$STATE_DIR/test.json" ]; then
  state_set "$STATE_DIR/test.json" "{\"env\":\"test\",\"previous_tag\":\"none\",\"current_tag\":\"v1\",\"alembic_revision\":\"none\",\"migration_reversible\":true,\"triggered_by\":\"bootstrap\",\"updated_at\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"}"
  log INFO "state initialized"
fi
state_set "$STATE_DIR/test.secrets.json" '{"credential_version":"v1","source":"env-file-snapshot"}'

for node in app-a app-b; do
  port="$(node_port "$node")"
  [ -f "$LB_DIR/${node}.conf" ] || printf 'server 127.0.0.1:%s max_fails=2 fail_timeout=2s;\n' "$port" > "$LB_DIR/${node}.conf"
done

log INFO "starting pg + redis"
dc up -d pg redis >>"$LOG_FILE" 2>&1 || { log ERROR "pg/redis start failed"; exit 10; }
for _ in $(seq 1 40); do
  if dc exec -T pg pg_isready -h 127.0.0.1 -p 28432 -U app -d appdb >/dev/null 2>&1; then break; fi
  sleep 2
done
dc exec -T pg pg_isready -h 127.0.0.1 -p 28432 -U app -d appdb >>"$LOG_FILE" 2>&1 || { log ERROR "pg not ready"; exit 11; }
log INFO "pg ready"

log INFO "baseline migration v1 -> head"
run_migration v1 head || { log ERROR "baseline migration failed"; exit 12; }
REV="$(alembic_revision v1)"
state_set "$STATE_DIR/test.json" "{\"alembic_revision\":\"${REV:-0002}\",\"current_tag\":\"v1\",\"status\":\"baseline\"}"
log INFO "baseline revision=${REV:-0002}"

log INFO "starting app-a app-b lb on v1"
dc_tag v1 up -d app-a app-b lb >>"$LOG_FILE" 2>&1 || { log ERROR "app/lb start failed"; exit 13; }

for node in app-a app-b; do
  wait_health "$node" || { log ERROR "baseline health failed node=${node}"; exit 14; }
done
smoke_test test || { log ERROR "baseline smoke failed"; exit 15; }
log INFO "STEP=bootstrap rc=0"
