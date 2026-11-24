# 交付物路径对照表（DELIVERABLE PATH MAP）

> **为什么有这张表**：投标时提交的第一版提案里写的是"计划中的文件路径"；本仓落地时
> 部分文件做了更准确的命名或换了位置（**同一实现**）。买家若按提案里的路径找会找不到，
> 本表给出**一一对应**。
>
> - 提案原文（第一版）：`proposals/3203-proposal.md`
> - 平台现行提案：2026-11-24 修订版，`sha256=d2ca9aa5edad8d28c1b528c127f451fa2b1759bee7bc44a59d868a3aa56985c1`
>   （修订后即按本表"本仓实际路径"书写）
> - 逐条验收对照见 `ACCEPTANCE.md` / `docs/ac-3203.md`；证据见 `ACCEPTANCE-EVIDENCE.md`

## 一、路径对照

| 提案里写的路径 | 本仓实际路径 | 说明 |
|---|---|---|
| `ops/deploy/deploy.sh` | `ops/deploy/deploy.sh` | 同名：预检 → 写 state → 备份+迁移 → 逐台滚动 → 冒烟 → 失败即回滚 → 日志与通知 |
| `.github/workflows/deploy.yml` | `.github/workflows/deploy.yml` | 同名：`workflow_dispatch`，inputs `env` / `image_tag`；prod 走 GitHub Environments 审批 |
| `ops/deploy/state/README.md` | `ops/deploy/state/README.md` | 同名：`state/{env}.json` 字段说明（`previous_tag` / `current_tag` / `alembic_revision` / `migration_reversible` / 触发人 / 时间） |
| `ops/deploy/smoke_endpoints.yml` | `ops/deploy/smoke/test.json` | 冒烟接口清单改为 JSON（5 个只读接口） |
| `ops/deploy/deploy.lock`（示例） | `ops/deploy/lib/state.py`（state 写入）+ `ops/deploy/lib/common.sh` | 锁与 state 由 lib 统一实现，仓内不再放 `.lock` 示例文件 |
| `tests/test_deploy_script.sh` | **本仓无 `tests/` 目录** ⇒ 见"实测证据" | 脚本级回归以**真实运行日志**交付（见下） |
| `tests/loadtest.py` | `ops/deploy/loadtest.py`<br>`evidence/logs/loadtest-3203.log`<br>`evidence/loadtest-3203.json` | AC1 压测脚本与压测输出 |
| `docs/test-env-deploy-log.md` | `evidence/logs/deploy-3203.log` | test 环境 2 节点滚动部署的完整日志（原始日志，未包装成 Markdown 叙述） |

## 二、"脚本级回归"这条 AC 的实测证据（替代未入库的 `tests/`）

| 证据文件 | 对应场景 |
|---|---|
| `evidence/logs/lock-conflict-3203.log` | 并发锁冲突被拒（互斥生效） |
| `evidence/logs/fault-injection-3203.log` + `evidence/logs/fault-injection-3203.rollback.log` | 健康检查失败 ⇒ 自动回滚（含回滚后日志） |
| `evidence/logs/prod-approval-wait.log` + `evidence/logs/prod-approval-wait.png` | prod 审批人等待（无人审批即不推进） |
| `evidence/logs/deploy-3203.log` | test 环境 2 节点滚动部署主流程 |
| `evidence/logs/loadtest-3203.log` | 压测期间 5xx 统计 |

## 三、提案未列、但本仓实际提供

| 路径 | 用途 |
|---|---|
| `ACCEPTANCE.md` / `ACCEPTANCE-EVIDENCE.md` / `docs/ac-3203.md` | 逐条 AC ↔ 实现 ↔ 复跑命令 ↔ 实测输出 |
| `docs/MIGRATION-COMPAT.md` | **只加不删**的迁移兼容约定与例外审批（AC4） |
| `ops/app/*`（`Dockerfile`、`Dockerfile.bad`、`alembic/`、`db.py`、`main.py`、`requirements.txt`） | 被部署的应用本体与"坏镜像"对照（故障注入用） |
| `ops/deploy/bootstrap.sh`、`ops/deploy/cleanup.sh` | 环境准备与收尾 |
| `ops/deploy/lb/nginx.conf`、`ops/deploy/lb/upstream.d/app-{a,b}.conf` | 两节点负载均衡配置 |
| `ops/deploy/compose/docker-compose.deploy.yml` | 部署用 compose |
| `scripts/secret-scan.sh` | 秘密扫描 |

## 四、复跑命令（与提案一致）

```bash
docker build --network host -t s4d-api:v1 ops/app
docker build --network host -f ops/app/Dockerfile.bad -t s4d-api:v2-bad ops/app
bash ops/deploy/bootstrap.sh
bash ops/deploy/deploy.sh --env test --image-tag v2 --triggered-by ci
python3 ops/deploy/loadtest.py --url http://127.0.0.1:28100/api/v1/ping
```

## 五、变更说明

本表为**新增说明文件**，不改动任何实现、脚本或证据；
`MANIFEST.sha256` 已重算并可用 `sha256sum -c MANIFEST.sha256` 复核。
