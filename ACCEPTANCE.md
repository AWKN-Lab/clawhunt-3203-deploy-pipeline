# Acceptance — ClawHunt problem 3203 (rolling deployment pipeline)

Status: **PASS** — four acceptance criteria, verified end to end on 2026-11-23.

Environment: Linux server, Docker 26.1.3, Docker Compose v2.27.0, two application nodes
(`app-a`, `app-b`) behind nginx 1.27, PostgreSQL 16 and Redis 7. All ports bound to 127.0.0.1.

| # | Acceptance criterion (verbatim) | Implementation | Result |
|---|---|---|---|
| 1 | test 环境完成一次 2 节点滚动部署，期间持续压测的接口无 5xx（附压测输出） | `ops/deploy/deploy.sh`, `ops/deploy/loadtest.py`, `ops/deploy/compose/docker-compose.deploy.yml` | **PASS** — deploy exit 0; app-a 49s, app-b 54s; 168,703 requests over 210s, **0 × 5xx**, 0 connection errors |
| 2 | 部署锁存在时第二次部署立即退出并提示锁持有者 | `ops/deploy/lib/common.sh::acquire_lock` (Redis `SET deploy:lock:{env} ... NX EX 1800`) | **PASS** — second deploy exit **11**, log prints `LOCK_HELD by holder=demo-agent (simulated concurrent deploy)` |
| 3 | 故意让健康检查失败时部署停止并自动触发回滚（附日志） | `deploy.sh::wait_health` failure branch → `rollback.sh --lock-held`; fault image `s4d-api:v2-bad` (`READYZ_FORCE_FAIL=1`) | **PASS** — deploy exit **33**; health gate failed after 10 attempts; auto rollback exit 0; both nodes back on v1; smoke 5/5 × 200 |
| 4 | prod 部署在审批前处于等待状态（附截图） | `deploy.sh` prod branch (no `--approved-by` → exit 20); `deploy.yml` uses `environment: prod` with required reviewers | **PASS** — exit **20**, `WAITING_FOR_APPROVAL`, screenshot `evidence/prod-approval-wait.png` |

## Control flow that the criteria exercise

1. Precheck: image exists, current environment healthy at the LB, no concurrent deploy (Redis lock).
2. State snapshot: `previous_tag`, `current_tag`, `alembic_revision`, `migration_reversible`,
   `triggered_by`, timestamps — written to `ops/deploy/state/{env}.json`.
3. Manual `pg_dump` backup with SHA-256 recorded before any schema change.
4. `alembic upgrade head` on a single container, before any node is replaced.
5. Per node: remove from LB upstream → reload → drain 30s → recreate with the new tag →
   `/healthz` **and** `/readyz` (PostgreSQL + Redis) must return 200 three consecutive times →
   attach back to the LB.
6. Smoke: `/api/v1/ping`, `/orgs`, `/sites`, `/members`, `/resources` must all return 2xx.
7. Any failure after step 3 triggers `rollback.sh` automatically and exits non-zero.

## Reproduce

```bash
bash ops/deploy/bootstrap.sh
bash ops/deploy/deploy.sh --env test --image-tag v2 --triggered-by ci
# lock test: hold the key, then run again → exit 11
bash ops/deploy/deploy.sh --env test --image-tag v2-bad   # → exit 33 + auto rollback
bash ops/deploy/deploy.sh --env prod --image-tag v1        # → exit 20 (approval gate)
```

Expected outputs and the exact log lines are in [ACCEPTANCE-EVIDENCE.md](ACCEPTANCE-EVIDENCE.md).

## Limitations (unchanged from the delivery note)

- Local image store stands in for a private registry.
- GitHub Actions workflow is delivered but not executed in this environment; the approval gate was
  exercised through `deploy.sh` (exit 20) and captured as a terminal screenshot.
- Host networking is a workaround for the target host blocking container-to-container TCP.
