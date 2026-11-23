#!/usr/bin/env bash
# 公共库：日志、部署锁、负载均衡摘挂、健康门禁、冒烟、备份、通知、state 读写。
# 只读环境变量，不内置任何凭据。
set -uo pipefail

OPS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DEPLOY_DIR="$OPS_DIR/deploy"
REPO_DIR="$(cd "$OPS_DIR/.." && pwd)"
COMPOSE_FILE="$DEPLOY_DIR/compose/docker-compose.deploy.yml"
ENV_FILE="$DEPLOY_DIR/.env.deploy"
LB_DIR="$DEPLOY_DIR/lb/upstream.d"
SMOKE_DIR="$DEPLOY_DIR/smoke"
STATE_DIR="$DEPLOY_DIR/state"
EVIDENCE_DIR="$REPO_DIR/evidence"
LOG_DIR="$EVIDENCE_DIR/logs"
BACKUP_DIR="$EVIDENCE_DIR/backups"
PROJECT="s4d"
LB_BASE="http://127.0.0.1:28100"
DRAIN_SECONDS="${DRAIN_SECONDS:-30}"
IMAGE_REPO="${IMAGE_REPO:-s4d-api}"

log() {
  local level="$1"; shift
  printf '%s [%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$level" "$*" | tee -a "${LOG_FILE:-/dev/null}"
}

init_run_log() {
  local name
  name="$(basename "$1")"
  mkdir -p "$LOG_DIR" "$BACKUP_DIR" "$STATE_DIR"
  LOG_FILE="$LOG_DIR/${name}.log"
  : > "$LOG_FILE"
  log INFO "run_begin name=${name} host=$(hostname) user=$(id -un)"
}

die() {
  local rc="$1"; shift
  log ERROR "$*"
  exit "$rc"
}

dc() {
  sudo -n docker compose -f "$COMPOSE_FILE" -p "$PROJECT" --env-file "$ENV_FILE" "$@"
}

dc_tag() {
  local tag="$1"; shift
  sudo -n env IMAGE_TAG="$tag" IMAGE_REPO="$IMAGE_REPO" \
    docker compose -f "$COMPOSE_FILE" -p "$PROJECT" --env-file "$ENV_FILE" "$@"
}

node_port() {
  case "$1" in
    app-a) echo 28101 ;;
    app-b) echo 28102 ;;
    *) echo "" ;;
  esac
}

load_env_file() {
  [ -f "$ENV_FILE" ] || die 13 "missing $ENV_FILE (run bootstrap.sh first)"
  set -a
  # shellcheck disable=SC1090
  . "$ENV_FILE"
  set +a
  DATABASE_URL="postgresql+psycopg://app:${POSTGRES_PASSWORD}@127.0.0.1:28432/appdb"
}

acquire_lock() {
  local env="$1" holder="$2" out current
  out="$(dc exec -T redis redis-cli -p 28379 SET "deploy:lock:${env}" "$holder" NX EX 1800 2>/dev/null | tr -d '\r')"
  if [ "$out" = "OK" ]; then
    log INFO "LOCK_ACQUIRED key=deploy:lock:${env} holder=${holder}"
    return 0
  fi
  current="$(dc exec -T redis redis-cli -p 28379 GET "deploy:lock:${env}" 2>/dev/null | tr -d '\r')"
  log ERROR "LOCK_HELD by ${current:-unknown}; second deploy refused"
  return 11
}

release_lock() {
  local env="$1"
  dc exec -T redis redis-cli -p 28379 DEL "deploy:lock:${env}" >/dev/null 2>&1 || true
  log INFO "LOCK_RELEASED key=deploy:lock:${env}"
}

lb_reload() {
  if ! dc exec -T lb nginx -t -q >>"$LOG_FILE" 2>&1; then
    log ERROR "nginx config test failed"
    return 1
  fi
  dc exec -T lb nginx -s reload >>"$LOG_FILE" 2>&1
  log INFO "lb_reload ok servers=$(cat "$LB_DIR"/*.conf 2>/dev/null | grep -c '^server')"
}

lb_detach() {
  local node="$1"
  rm -f "$LB_DIR/${node}.conf"
  lb_reload
  log INFO "lb_detach node=${node}"
}

lb_attach() {
  local node="$1" port
  port="$(node_port "$node")"
  printf 'server 127.0.0.1:%s max_fails=2 fail_timeout=2s;\n' "$port" > "$LB_DIR/${node}.conf"
  lb_reload
  log INFO "lb_attach node=${node} addr=127.0.0.1:${port}"
}

wait_health() {
  local node="$1" port attempt=0 consec=0 max_attempts="${2:-10}"
  port="$(node_port "$node")"
  while [ "$attempt" -lt "$max_attempts" ]; do
    attempt=$((attempt + 1))
    if curl -fsS --max-time 3 "http://127.0.0.1:${port}/healthz" >/dev/null 2>&1 \
      && curl -fsS --max-time 3 "http://127.0.0.1:${port}/readyz" >/dev/null 2>&1; then
      consec=$((consec + 1))
      log INFO "health node=${node} attempt=${attempt} consec=${consec}/3 ok"
      [ "$consec" -ge 3 ] && return 0
    else
      consec=0
      log WARN "health node=${node} attempt=${attempt} FAIL (healthz/readyz not both 200)"
    fi
    sleep 2
  done
  log ERROR "health node=${node} gate FAILED after ${max_attempts} attempts"
  return 1
}

smoke_test() {
  local env="$1" fail=0 path code
  local smoke_file="$SMOKE_DIR/${env}.json"
  [ -f "$smoke_file" ] || smoke_file="$SMOKE_DIR/test.json"
  while IFS= read -r path; do
    code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "${LB_BASE}${path}" || echo 000)"
    log INFO "smoke ${path} -> ${code}"
    case "$code" in
      2*) ;;
      *) fail=1 ;;
    esac
  done < <(python3 -c 'import json,sys;print("\n".join(json.load(open(sys.argv[1]))["endpoints"]))' "$smoke_file")
  return "$fail"
}

backup_db() {
  local label="$1"
  local out="$BACKUP_DIR/${label}-$(date -u +%Y%m%dT%H%M%SZ).sql"
  mkdir -p "$BACKUP_DIR"
  if ! dc exec -T pg pg_dump -h 127.0.0.1 -p 28432 -U app -d appdb --no-owner > "$out"; then
    log ERROR "backup failed: $out"
    return 1
  fi
  sha256sum "$out" | tee "${out}.sha256" >> "$LOG_FILE"
  log INFO "backup ok file=${out} bytes=$(wc -c < "$out")"
}

# state 读写：json 单文件，原子替换
state_get() {
  python3 "$DEPLOY_DIR/lib/state.py" "$1" get "$2"
}

state_set() {
  python3 "$DEPLOY_DIR/lib/state.py" "$1" set "$2"
}

alembic_revision() {
  local tag="$1" out
  out="$(sudo -n docker run --rm --network host \
    -e DATABASE_URL="$DATABASE_URL" "${IMAGE_REPO}:${tag}" alembic current 2>&1)" || true
  printf '%s\n' "$out" >>"$LOG_FILE"
  # 只认 "Current revision(s) ... : 0002 (head)" 这一行，避免误匹配连接串里的十六进制
  printf '%s\n' "$out" | grep -i 'current revision' | sed -E 's/.*: *([0-9a-f]{4,}).*/\1/' | head -1
}

run_migration() {
  local tag="$1" target="${2:-head}"
  sudo -n docker run --rm --network host \
    -e DATABASE_URL="$DATABASE_URL" "${IMAGE_REPO}:${tag}" alembic upgrade "$target" 2>&1 | tee -a "$LOG_FILE"
  return "${PIPESTATUS[0]}"
}

notify() {
  local env="$1" tag="$2" result="$3" seconds="$4" extra="${5:-}"
  local line="env=${env} version=${tag} result=${result} duration=${seconds}s ${extra}"
  printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$line" | tee -a "$EVIDENCE_DIR/ops-notify.log"
  if [ -n "${OPS_WEBHOOK_URL:-}" ]; then
    curl -fsS -X POST -H 'Content-Type: application/json' \
      -d "{\"text\":\"${line//\"/\\\"}\"}" "$OPS_WEBHOOK_URL" >/dev/null 2>&1 || log WARN "webhook notify failed"
  fi
}
