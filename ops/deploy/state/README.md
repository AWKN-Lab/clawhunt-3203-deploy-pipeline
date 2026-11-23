# state/{env}.json 格式说明

`deploy.sh` 在每次部署开始时写入本文件，`rollback.sh` 只读它决定回退目标。

| 字段 | 类型 | 来源 | 用途 |
|---|---|---|---|
| `env` | string | 部署参数 | 环境名（test/prod） |
| `previous_tag` | string | 部署开始前 state 的 `current_tag` | 回滚默认目标 |
| `current_tag` | string | 本次 `--image-tag` | 当前版本 |
| `alembic_revision` | string | 部署**开始前**的 `alembic current` | `--with-db-downgrade` 的目标 revision |
| `migration_reversible` | bool | `MIGRATION_REVERSIBLE`（默认 true） | DB downgrade 的硬门禁之一 |
| `triggered_by` | string | `--triggered-by` | 审计 |
| `started_at` | ISO8601 | 部署开始 | 审计 |
| `finished_at` | ISO8601 | 成功/失败收尾 | 审计 |
| `status` | string | `deploying` / `success` / `WAITING_FOR_APPROVAL` / `rolled_back` | 机器可读状态 |
| `last_rollback_from` | string | 回滚时写入 | 回滚血缘（不覆盖 previous_tag，避免回滚到故障版本） |
| `duration_seconds` | int | 收尾计算 | 耗时 |

示例（test）：

```json
{
  "env": "test",
  "previous_tag": "v1",
  "current_tag": "v2",
  "alembic_revision": "0001",
  "migration_reversible": true,
  "triggered_by": "clawhunt-deploy",
  "started_at": "2026-11-23T12:08:59Z",
  "status": "success",
  "finished_at": "2026-11-23T12:11:04Z",
  "duration_seconds": 125
}
```

写文件使用临时文件 + `os.replace` 原子替换；不存在时返回空串（脚本按 `none` 处理）。
