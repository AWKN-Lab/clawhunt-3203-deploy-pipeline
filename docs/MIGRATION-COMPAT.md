# 迁移兼容约定（只加不删）与例外审批

> 层级：系统 L1（发布策略）→ 组件 L2（ops/deploy 与数据库迁移）→ 模块 L3（rollback.sh 的 db_rollback 分支）。

## 1. 兼容约定（默认路径）

1. 所有 Alembic 迁移必须**向后兼容**：只新增表、列（可空或带默认值）、索引；删除列、改类型、改约束一律放到下一个版本窗口。
2. 回滚默认**只回退应用镜像，不回退数据库**。旧版本代码必须能在新 schema 上运行（`members.tier` 是示例：新增可空 + 默认值，v1 代码不读该列）。
3. `rollback.sh` 未传 `--with-db-downgrade` 时，固定输出 `DB_DOWNGRADE_SKIPPED`，不执行任何 `alembic downgrade`。

## 2. 例外审批流程（必须四步齐全）

| 步 | 要求 | 取证 |
|---|---|---|
| 1 | 确认该迁移 `downgrade()` 已实现且被测试覆盖 | 迁移文件 + 演练日志 |
| 2 | 部署时在 `state/{env}.json` 记录 `migration_reversible=true` | state 文件 |
| 3 | 回滚前再做一次手动备份 | `evidence/backups/pre-downgrade-*.sql.sha256` |
| 4 | 操作者显式传入 `--with-db-downgrade --confirm-token CONFIRM-DOWNGRADE`（双重确认） | 回滚日志 `alembic downgrade <revision>` |

任一缺失，`rollback.sh` 退出码 `43/44/45`，拒绝执行。

## 3. downgrade 目标 revision

- `state/{env}.json` 的 `alembic_revision` 记录的是**本次部署开始前**的 revision。
- `alembic downgrade <该 revision>` 即回到部署前 schema。
- 若 state 中为 `none`（空库首次部署），禁止 downgrade。

## 4. 演练记录

- 迁移往返：`upgrade head` → `downgrade 0001` → `upgrade head` 三步退出码见 `evidence/logs/migration-roundtrip.log`。
- 回滚默认跳过 downgrade 的日志见 `evidence/logs/rollback-manual.log`。
