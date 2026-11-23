#!/usr/bin/env bash
# 部署脚本：预检 → 部署锁 → state 快照 → 备份 → 迁移前置 → 逐台滚动 → 健康门禁 → 冒烟。
# 失败即停并自动调用 rollback.sh。脚本内不含任何私钥；节点命令经 docker/堡垒机（见 README）。
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"

ENV_NAME=""
IMAGE_TAG=""
TRIGGERED_BY="$(id -un)"
APPROVED_BY=""
LOCK_HELD=0
LOG_NAME=""

usage() {
  cat <<'EOF'
usage: deploy.sh --env test|prod --image-tag TAG [options]
  --triggered-by NAME     触发人（默认当前系统用户）
  --approved-by NAME      prod 必填；GitHub Environments 审批人账号
  --drain-seconds N       摘除后连接排空秒数（默认 30）
  --lock-held             内部使用：调用方已持锁（自动回滚链路）
  --log-name NAME         日志文件名（默认 deploy-<env>-<tag>-<ts>）
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --env) ENV_NAME="$2"; shift 2 ;;
    --image-tag) IMAGE_TAG="$2"; shift 2 ;;
    --triggered-by) TRIGGERED_BY="$2"; shift 2 ;;
    --approved-by) APPROVED_BY="$2"; shift 2 ;;
    --drain-seconds) DRAIN_SECONDS="$2"; shift 2 ;;
    --lock-held) LOCK_HELD=1; shift ;;
    --log-name) LOG_NAME="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

[ -n "$ENV_NAME" ] || { usage; exit 2; }
[ -n "$IMAGE_TAG" ] || { usage; exit 2; }

init_run_log "${LOG_NAME:-deploy-${ENV_NAME}-${IMAGE_TAG}-$(date -u +%Y%m%dT%H%M%SZ)}"
ARG_TAG="$IMAGE_TAG"
load_env_file
IMAGE_TAG="$ARG_TAG"   # 参数优先于 .env.deploy 的默认 IMAGE_TAG
START_TS=$SECONDS
STATE_FILE="$STATE_DIR/${ENV_NAME}.json"

# ── AC4：prod 审批门禁 ─────────────────────────────────────────────
if [ "$ENV_NAME" = "prod" ] && [ -z "$APPROVED_BY" ]; then
  state_set "$STATE_FILE" "{\"env\":\"prod\",\"pending_tag\":\"${IMAGE_TAG}\",\"status\":\"WAITING_FOR_APPROVAL\",\"updated_at\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"}"
  log WARN "WAITING_FOR_APPROVAL env=prod tag=${IMAGE_TAG} (GitHub Environments 审批人未批准；本脚本不越过门禁)"
  echo "WAITING_FOR_APPROVAL"
  exit 20
fi

auto_rollback() {
  local rc="$1" reason="$2" rrc
  log ERROR "auto rollback invoked reason=${reason}"
  bash "$SCRIPT_DIR/rollback.sh" --env "$ENV_NAME" --reason "$reason" --lock-held \
    --log-name "$(basename "${LOG_FILE%.log}").rollback"
  rrc=$?
  log INFO "STEP=rollback rc=${rrc} reason=${reason}"
  release_lock "$ENV_NAME"
  notify "$ENV_NAME" "$IMAGE_TAG" "FAILED(rc=${rc})" "$((SECONDS - START_TS))" "reason=${reason} rollback_rc=${rrc}"
  exit "$rc"
}

# ── ① 预检：镜像存在 / 环境当前健康 / 无并发部署 ────────────────────
if ! sudo -n docker image inspect "${IMAGE_REPO}:${IMAGE_TAG}" >/dev/null 2>&1; then
  log ERROR "STEP=precheck_image rc=1 image=${IMAGE_REPO}:${IMAGE_TAG} 不存在"
  exit 12
fi
log INFO "STEP=precheck_image rc=0 image=${IMAGE_REPO}:${IMAGE_TAG}"

if ! curl -fsS --max-time 3 "${LB_BASE}/healthz" >/dev/null 2>&1; then
  log ERROR "STEP=precheck_env_health rc=1 ${LB_BASE}/healthz 不可达"
  exit 12
fi
log INFO "STEP=precheck_env_health rc=0 lb=${LB_BASE}"

if [ "$LOCK_HELD" -ne 1 ]; then
  acquire_lock "$ENV_NAME" "${ENV_NAME}|${TRIGGERED_BY}|$(hostname)|$$" || exit 11
else
  log INFO "LOCK_REUSED (caller holds deploy:lock:${ENV_NAME})"
fi

# ── ② state 快照：previous/current/revision/触发人/时间 ─────────────
PREV_TAG="$(state_get "$STATE_FILE" current_tag)"
[ -n "$PREV_TAG" ] || PREV_TAG="none"
PREV_REV="$(state_get "$STATE_FILE" alembic_revision)"
[ -n "$PREV_REV" ] || PREV_REV="none"
MIG_REVERSIBLE="${MIGRATION_REVERSIBLE:-true}"

cp -p "$ENV_FILE" "$STATE_DIR/${ENV_NAME}.env.prev" 2>/dev/null || true
state_set "$STATE_DIR/${ENV_NAME}.secrets.json" '{"credential_version":"v1","source":"env-file-snapshot"}'
state_set "$STATE_FILE" "{\"env\":\"${ENV_NAME}\",\"previous_tag\":\"${PREV_TAG}\",\"current_tag\":\"${IMAGE_TAG}\",\"alembic_revision\":\"${PREV_REV}\",\"migration_reversible\":${MIG_REVERSIBLE},\"triggered_by\":\"${TRIGGERED_BY}\",\"started_at\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"status\":\"deploying\"}"
log INFO "STATE_BEFORE previous_tag=${PREV_TAG} current_tag=${IMAGE_TAG} alembic_revision=${PREV_REV} migration_reversible=${MIG_REVERSIBLE} triggered_by=${TRIGGERED_BY}"

# ── ③ 迁移前置：手动备份 ──────────────────────────────────────────
if ! backup_db "pre-deploy-${ENV_NAME}"; then
  log ERROR "STEP=backup rc=1"
  auto_rollback 21 "backup_failed"
fi
log INFO "STEP=backup rc=0"

# ── ④ 迁移：单节点用新镜像 alembic upgrade head（向后兼容：只加不删）──
if ! run_migration "$IMAGE_TAG" head; then
  log ERROR "STEP=migration rc=1"
  auto_rollback 22 "migration_failed"
fi
log INFO "STEP=migration rc=0 tag=${IMAGE_TAG} target=head"

# ── ⑤ 滚动发布：逐台 摘除 → 排空 30s → 切换镜像 → 健康 3 连 → 挂回 ──
for node in app-a app-b; do
  NODE_START=$(date -u +%s)
  lb_detach "$node" || auto_rollback 31 "lb_detach_failed_${node}"
  log INFO "drain node=${node} seconds=${DRAIN_SECONDS}"
  sleep "$DRAIN_SECONDS"
  if ! dc_tag "$IMAGE_TAG" up -d --no-deps --force-recreate "$node" >>"$LOG_FILE" 2>&1; then
    log ERROR "compose up failed node=${node}"
    auto_rollback 32 "compose_up_failed_${node}"
  fi
  log INFO "node=${node} image=${IMAGE_REPO}:${IMAGE_TAG} started"
  if ! wait_health "$node"; then
    log ERROR "health gate failed node=${node} (部署停止，保留摘除状态)"
    auto_rollback 33 "health_gate_failed_${node}"
  fi
  lb_attach "$node" || auto_rollback 34 "lb_attach_failed_${node}"
  log INFO "node=${node} rolled ts=$(date -u +%Y-%m-%dT%H:%M:%SZ) elapsed=$(( $(date -u +%s) - NODE_START ))s"
done
log INFO "STEP=rolling rc=0 nodes=2 tag=${IMAGE_TAG}"

# ── ⑥ 冒烟：5 个只读接口全部 2xx ───────────────────────────────────
if ! smoke_test "$ENV_NAME"; then
  log ERROR "STEP=smoke rc=1"
  auto_rollback 35 "smoke_failed"
fi
log INFO "STEP=smoke rc=0 endpoints=5"

# ── ⑦ 收尾：state / 通知 / 解锁 ───────────────────────────────────
NEW_REV="$(alembic_revision "$IMAGE_TAG")"
[ -n "$NEW_REV" ] || NEW_REV="$PREV_REV"
DUR=$((SECONDS - START_TS))
state_set "$STATE_FILE" "{\"current_tag\":\"${IMAGE_TAG}\",\"alembic_revision\":\"${NEW_REV}\",\"status\":\"success\",\"finished_at\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"duration_seconds\":${DUR}}"
notify "$ENV_NAME" "$IMAGE_TAG" "SUCCESS" "$DUR"
release_lock "$ENV_NAME"
log INFO "STEP=deploy_done rc=0 env=${ENV_NAME} tag=${IMAGE_TAG} revision=${NEW_REV} duration=${DUR}s"
exit 0
