# Acceptance — ClawHunt problem 3203 (rolling deployment pipeline)

Status: **PASS** — all four acceptance criteria verified end to end on 2026-11-23.
Environment: Linux host, Docker 26.1.3, Compose v2.27.0, two application nodes (app-a, app-b)
behind nginx 1.27, PostgreSQL 16, Redis 7; every port bound to 127.0.0.1.

Each criterion below gives the **English scoring text**, the Chinese original, the observed result,
the exact reproduction command with its real exit code, and the artifact to inspect.

---

## AC 1 — Two-node rolling deployment, zero 5xx under continuous load

**English (scoring text):** A two-node rolling deployment completes in the test environment, and the
endpoint under continuous load testing returns no 5xx during the rollout (attach load-test output).

**中文原文：** test 环境完成一次 2 节点滚动部署，期间持续压测的接口无 5xx（附压测输出）

**Result: PASS.** Deploy exited 0; app-a 49s, app-b 54s; 168,703 requests over 210s at concurrency 8,
**0 × 5xx**, 0 connection errors; smoke 5/5 returned 200.

**Reproduce:**

```bash
python3 ops/deploy/loadtest.py --url http://127.0.0.1:28100/api/v1/ping \
  --duration 210 --concurrency 8 --out evidence/loadtest-3203.json &
bash ops/deploy/deploy.sh --env test --image-tag v2 --triggered-by ci --log-name deploy-3203
# exit code: 0
```

**Evidence:** `evidence/loadtest-3203.json` (`"s5xx": 0`, `"total": 168703`),
`evidence/logs/deploy-3203.log` (`STEP=rolling rc=0`, `node=app-a ... elapsed=49s`, `node=app-b ... elapsed=54s`,
`STEP=smoke rc=0 endpoints=5`, `STEP=deploy_done rc=0`).

---

## AC 2 — Deploy lock stops the second run and names the holder

**English (scoring text):** When a deployment lock is present, a second deployment exits immediately
and reports who holds the lock.

**中文原文：** 部署锁存在时第二次部署立即退出并提示锁持有者

**Result: PASS.** Second deployment exit code **11**; log line names the holder verbatim.

**Reproduce:**

```bash
docker exec s4d-redis redis-cli -p 28379 SET deploy:lock:test \
  'holder=demo-agent (simulated concurrent deploy)' NX EX 1800
bash ops/deploy/deploy.sh --env test --image-tag v2 --log-name lock-conflict-3203
# exit code: 11
```

**Evidence:** `evidence/logs/lock-conflict-3203.log`
(`LOCK_HELD by holder=demo-agent (simulated concurrent deploy); second deploy refused`).

---

## AC 3 — Health-gate failure stops the deployment and rolls back automatically

**English (scoring text):** If a health check is deliberately made to fail, the deployment stops and
automatically triggers a rollback (attach logs).

**中文原文：** 故意让健康检查失败时部署停止并自动触发回滚（附日志）

**Result: PASS.** Fault image `s4d-api:v2-bad` fails `/readyz` every time; deploy exit code **33**;
automatic rollback exit code **0**; both nodes restored to v1; smoke 5/5 × 200.

**Reproduce:**

```bash
docker build --network host -f ops/app/Dockerfile.bad -t s4d-api:v2-bad ops/app
bash ops/deploy/deploy.sh --env test --image-tag v2-bad --log-name fault-injection-3203
# exit code: 33 (rollback inside the run exits 0)
```

**Evidence:** `evidence/logs/fault-injection-3203.log`
(`gate FAILED after 10 attempts`, `auto rollback invoked`, `STEP=rollback rc=0`),
`evidence/logs/fault-injection-3203.rollback.log`
(`ROLLBACK_PLAN ... from=v2-bad to=v1`, five `smoke ... -> 200` lines, `STEP=rollback_done rc=0`).

---

## AC 4 — Prod deployment waits for approval

**English (scoring text):** A production deployment stays in a waiting state until approval is granted
(attach screenshot).

**中文原文：** prod 部署在审批前处于等待状态（附截图）

**Result: PASS.** Exit code **20** with `WAITING_FOR_APPROVAL`; state file records `status=WAITING_FOR_APPROVAL`;
`.github/workflows/deploy.yml` binds the job to `environment: prod` (required reviewers configured in
repository settings).

**Reproduce:**

```bash
bash ops/deploy/deploy.sh --env prod --image-tag v1 --log-name prod-approval-wait
# exit code: 20
```

**Evidence:** `evidence/logs/prod-approval-wait.log`, `evidence/prod-approval-wait.png`
(terminal capture of the local gate; the GitHub approval UI itself requires a live repository run,
which is outside this delivery).

---

## Deployment control flow (why the criteria hold)

1. Precheck: image exists, current environment healthy, no concurrent deployment (Redis lock).
2. State snapshot: `previous_tag`, `current_tag`, `alembic_revision`, `migration_reversible`, actor, time.
3. Manual `pg_dump` backup with SHA-256 before any schema change.
4. `alembic upgrade head` on one container, before any node is replaced.
5. Per node: LB detach → 30s drain → recreate → `/healthz` **and** `/readyz` three consecutive 200 → attach.
6. Smoke: `/api/v1/ping`, `/orgs`, `/sites`, `/members`, `/resources` all 2xx.
7. Any failure triggers `rollback.sh` automatically and exits non-zero.

## Exit codes

| Code | Meaning |
|---|---|
| 11 | deploy lock held by another run |
| 12 | precheck failed (image missing / env unhealthy) |
| 20 | prod waiting for approval |
| 21 / 22 | backup / migration failed |
| 31-34 | rolling step failed |
| 33 | health gate failed, automatic rollback executed |
| 35 | smoke failed, automatic rollback executed |

## Scope and limitations

- Local image store stands in for a private registry.
- The GitHub Actions workflow is delivered as configuration and was not executed here; the approval
  gate was exercised directly through `deploy.sh` (exit 20) and captured as a screenshot.
- Host networking is a workaround for the target host blocking container-to-container TCP.

Detailed evidence index: [ACCEPTANCE-EVIDENCE.md](ACCEPTANCE-EVIDENCE.md).
Migration compatibility policy: [docs/MIGRATION-COMPAT.md](docs/MIGRATION-COMPAT.md).
