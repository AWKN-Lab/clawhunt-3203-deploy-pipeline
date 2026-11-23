#!/usr/bin/env bash
# 清理本任务在 161 上创建的全部容器、网络、卷、镜像与临时文件，并报清理前后磁盘。
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"

init_run_log "cleanup-$(date -u +%Y%m%dT%H%M%SZ)"
log INFO "disk_before $(df -h / | awk 'NR==2{print $3" used / "$2" total, avail "$4}')"
log INFO "containers_before $(sudo -n docker ps -a --format '{{.Names}}' | tr '\n' ' ')"

dc down -v --remove-orphans >>"$LOG_FILE" 2>&1 || log WARN "compose down returned non-zero"

for img in s4d-api:v1 s4d-api:v2 s4d-api:v2-bad; do
  if sudo -n docker image inspect "$img" >/dev/null 2>&1; then
    # 仅当没有容器（含已停止）引用时才删除，避免影响他人
    if [ -z "$(sudo -n docker ps -aq --filter "ancestor=$img" | tr -d '\r')" ]; then
      sudo -n docker image rm "$img" >>"$LOG_FILE" 2>&1 && log INFO "image_removed $img" || log WARN "image_rm_failed $img"
    else
      log WARN "image_in_use_skip $img"
    fi
  fi
done

rm -rf "$EVIDENCE_DIR/tmp" "$REPO_DIR/.build"
log INFO "containers_after $(sudo -n docker ps -a --format '{{.Names}}' | tr '\n' ' ')"
log INFO "images_after $(sudo -n docker images --format '{{.Repository}}:{{.Tag}}' | tr '\n' ' ')"
log INFO "disk_after $(df -h / | awk 'NR==2{print $3" used / "$2" total, avail "$4}')"
