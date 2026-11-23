#!/usr/bin/env bash
# 回滚脚本：读 state → 默认回退 previous_tag → 逐台 摘除/切换/健康/挂回 →
# DB 默认不 downgrade（只加不删）→ 配置回退 → 冒烟 → 通知。
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"

ENV_NAME=""
TARGET_TAG=""
WITH_DB=0
CONFIRM_TOKEN=""
REASON="manual"
LOCK_HELD=0
LOG_NAME=""

usage() {
  cat <<'EOF'
usage: rollback.sh --env test|prod [options]
  --target-tag TAG        指定回退目标；缺省读 state/{env}.json 的 previous_tag
  --with-db-downgrade     显式执行 alembic downgrade（需 state migration_reversible=true）
  --confirm-token TOKEN   二次确认令牌，必须为 CONFIRM-DOWNGRADE
  --reason TEXT           回滚原因（deploy_failed / manual / ...）
  --drain-seconds N       摘除后连接排空秒数（默认 30）
  --lock-held             内部使用：调用方已持锁
  --log-name NAME         日志文件名
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --env) ENV_NAME="$2"; shift 2 ;;
    --target-tag) TARGET_TAG="$2"; shift 2 ;;
    --with-db-downgrade) WITH_DB=1; shift ;;
    --confirm-token) CONFIRM_TOKEN="$2"; shift 2 ;;
    --reason) REASON="$2"; shift 2 ;;
    --drain-seconds) DRAIN_SECONDS="$2"; shift 2 ;;
    --lock-held) LOCK_HELD=1; shift ;;
    --log-name) LOG_NAME="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

[ -n "$ENV_NAME" ] || { usage; exit 2; }

init_run_log "${LOG_NAME:-rollback-${ENV_NAME}-$(date -u +%Y%m%dT%H%M%SZ)}"
load_env_file
START_TS=$SECONDS
STATE_FILE="$STATE_DIR/${ENV_NAME}.json"

CURRENT_TAG="$(state_get "$STATE_FILE" current_tag)"
[ -n "$TARGET_TAG" ] || TARGET_TAG="$(state_get "$STATE_FILE" previous_tag)"
if [ -z "$TARGET_TAG" ] || [ "$TARGET_TAG" = "none" ]; then
  log ERROR "no rollback target (state previous_tag empty, --target-tag not given)"
  exit 12
fi
if ! sudo -n docker image inspect "${IMAGE_REPO}:${TARGET_TAG}" >/dev/null 2>&1; then
  log ERROR "target image ${IMAGE_REPO}:${TARGET_TAG} not found"
  exit 12
fi
log INFO "ROLLBACK_PLAN env=${ENV_NAME} from=${CURRENT_TAG:-unknown} to=${TARGET_TAG} reason=${REASON} with_db_downgrade=${WITH_DB} drain=${DRAIN_SECONDS}s"

if [ "$LOCK_HELD" -ne 1 ]; then
  acquire_lock "$ENV_NAME" "rollback|$(id -un)|$(hostname)|$$" || exit 11
else
  log INFO "LOCK_REUSED (caller holds deploy:lock:${ENV_NAME})"
fi

# ── ① 应用回退：逐台 摘除 → 排空 → 切换镜像 → 健康 3 连 → 挂回 ──────
rollback_node() {
  local node="$1" begin end elapsed
  begin=$(date -u +%s)
  log INFO "node_rollback_begin node=${node} ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  lb_detach "$node" || return 51
  log INFO "drain node=${node} seconds=${DRAIN_SECONDS}"
  sleep "$DRAIN_SECONDS"
  if ! dc_tag "$TARGET_TAG" up -d --no-deps --force-recreate "$node" >>"$LOG_FILE" 2>&1; then
    log ERROR "compose up failed node=${node} target=${TARGET_TAG}"
    return 52
  fi
  if ! wait_health "$node"; then
    log ERROR "rollback health gate failed node=${node}; 该节点保持摘除"
    return 53
  fi
  lb_attach "$node" || return 54
  end=$(date -u +%s)
  elapsed=$((end - begin))
  log INFO "node_rollback_end node=${node} ts=$(date -u +%Y-%m-%dT%H:%M:%SZ) elapsed=${elapsed}s (threshold 180s)"
  if [ "$elapsed" -gt 180 ]; then
    log ERROR "node ${node} rollback elapsed ${elapsed}s > 180s"
    return 55
  fi
  return 0
}

for node in app-a app-b; do
  rollback_node "$node"
  RC=$?
  if [ "$RC" -ne 0 ]; then
    log ERROR "STEP=rollback_app rc=${RC} node=${node}"
    [ "$LOCK_HELD" -ne 1 ] && release_lock "$ENV_NAME"
    notify "$ENV_NAME" "$TARGET_TAG" "ROLLBACK_FAILED" "$((SECONDS - START_TS))" "reason=${REASON} node=${node}"
    exit "$RC"
  fi
done
log INFO "STEP=rollback_app rc=0 nodes=2 target=${TARGET_TAG}"

# ── ② 数据库：默认跳过；仅显式授权 + reversible 才 downgrade ─────────
if [ "$WITH_DB" -ne 1 ]; then
  log INFO "DB_DOWNGRADE_SKIPPED (no --with-db-downgrade); 迁移遵循只加不删，旧代码可运行在新 schema 上"
else
  REV="$(state_get "$STATE_FILE" alembic_revision)"
  REVERSIBLE="$(state_get "$STATE_FILE" migration_reversible)"
  if [ "$REVERSIBLE" != "True" ] && [ "$REVERSIBLE" != "true" ]; then
    log ERROR "DB downgrade refused: state migration_reversible=${REVERSIBLE}"
    [ "$LOCK_HELD" -ne 1 ] && release_lock "$ENV_NAME"
    exit 43
  fi
  if [ "$CONFIRM_TOKEN" != "CONFIRM-DOWNGRADE" ]; then
    log ERROR "DB downgrade needs second confirmation: --confirm-token CONFIRM-DOWNGRADE"
    [ "$LOCK_HELD" -ne 1 ] && release_lock "$ENV_NAME"
    exit 44
  fi
  if ! backup_db "pre-downgrade-${ENV_NAME}"; then
    log ERROR "STEP=db_backup rc=1"
    [ "$LOCK_HELD" -ne 1 ] && release_lock "$ENV_NAME"
    exit 45
  fi
  log INFO "alembic downgrade ${REV} (explicit, reversible=true, confirmed)"
  if ! sudo -n docker run --rm --network host \
    -e DATABASE_URL="$DATABASE_URL" "${IMAGE_REPO}:${TARGET_TAG}" alembic downgrade "$REV" 2>&1 | tee -a "$LOG_FILE"; then
    log ERROR "STEP=db_downgrade rc=1 target_revision=${REV}"
    [ "$LOCK_HELD" -ne 1 ] && release_lock "$ENV_NAME"
    exit 46
  fi
  state_set "$STATE_FILE" "{\"alembic_revision\":\"${REV}\"}"
  log INFO "STEP=db_downgrade rc=0 revision=${REV}"
fi

# ── ③ 配置回退：env 快照 + 凭据版本指针 ─────────────────────────────
if [ -f "$STATE_DIR/${ENV_NAME}.env.prev" ]; then
  cp -p "$STATE_DIR/${ENV_NAME}.env.prev" "$ENV_FILE"
  chmod 600 "$ENV_FILE"
  log INFO "config_restored env_snapshot=$STATE_DIR/${ENV_NAME}.env.prev"
else
  log WARN "config snapshot missing for env=${ENV_NAME}; skip env restore"
fi
CRED_VER="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get("credential_version","unknown"))' "$STATE_DIR/${ENV_NAME}.secrets.json" 2>/dev/null || echo unknown)"
log INFO "config_restored credential_version=${CRED_VER} (凭据管家适配点，见 README)"

# ── ④ 回退后冒烟 + state + 通知 ────────────────────────────────────
if ! smoke_test "$ENV_NAME"; then
  log ERROR "STEP=rollback_smoke rc=1"
  [ "$LOCK_HELD" -ne 1 ] && release_lock "$ENV_NAME"
  notify "$ENV_NAME" "$TARGET_TAG" "ROLLBACK_SMOKE_FAILED" "$((SECONDS - START_TS))" "reason=${REASON}"
  exit 47
fi
log INFO "STEP=rollback_smoke rc=0 endpoints=5"

DUR=$((SECONDS - START_TS))
state_set "$STATE_FILE" "{\"current_tag\":\"${TARGET_TAG}\",\"last_rollback_from\":\"${CURRENT_TAG}\",\"status\":\"rolled_back\",\"reason\":\"${REASON}\",\"rolled_back_at\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"duration_seconds\":${DUR}}"
notify "$ENV_NAME" "$TARGET_TAG" "ROLLED_BACK" "$DUR" "from=${CURRENT_TAG} reason=${REASON}"
[ "$LOCK_HELD" -ne 1 ] && release_lock "$ENV_NAME"
log INFO "STEP=rollback_done rc=0 from=${CURRENT_TAG} to=${TARGET_TAG} duration=${DUR}s"
exit 0
