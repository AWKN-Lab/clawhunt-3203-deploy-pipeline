# Acceptance evidence — problem 3203

Run date: 2026-11-23 (UTC). Host: Linux, Docker 26.1.3, Compose v2.27.0.
Paths below are sanitized (`$REPO` = repository root, `<docker-bridge-ip>` = private address).

## AC 1 — two-node rolling deploy with zero 5xx under load

Command (load generator ran for the whole deployment):

```bash
python3 ops/deploy/loadtest.py --url http://127.0.0.1:28100/api/v1/ping \
  --duration 210 --concurrency 8 --out evidence/loadtest-3203.json
bash ops/deploy/deploy.sh --env test --image-tag v2 --triggered-by ci --log-name deploy-3203
```

Exit code: **0**

```text
2026-11-23T12:08:56Z [INFO] STEP=precheck_image rc=0 image=s4d-api:v2
2026-11-23T12:08:56Z [INFO] STEP=precheck_env_health rc=0 lb=http://127.0.0.1:28100
2026-11-23T12:09:03Z [INFO] STEP=backup rc=0
2026-11-23T12:09:09Z [INFO] STEP=migration rc=0 tag=v2 target=head
2026-11-23T12:09:13Z [INFO] lb_detach node=app-a
2026-11-23T12:09:13Z [INFO] drain node=app-a seconds=30
2026-11-23T12:09:52Z [INFO] health node=app-a attempt=3 consec=1/3 ok
2026-11-23T12:09:56Z [INFO] health node=app-a attempt=5 consec=3/3 ok
2026-11-23T12:09:58Z [INFO] node=app-a rolled ts=2026-11-23T12:09:58Z elapsed=49s
2026-11-23T12:10:36Z [INFO] node=app-b image=s4d-api:v2 started
2026-11-23T12:10:44Z [INFO] health node=app-b attempt=5 consec=3/3 ok
2026-11-23T12:10:52Z [INFO] node=app-b rolled ts=2026-11-23T12:10:52Z elapsed=54s
2026-11-23T12:10:52Z [INFO] STEP=rolling rc=0 nodes=2 tag=v2
2026-11-23T12:10:53Z [INFO] STEP=smoke rc=0 endpoints=5
2026-11-23T12:11:04Z [INFO] STEP=deploy_done rc=0 env=test tag=v2 revision=0002 duration=125s
```

Load result (`evidence/loadtest-3203.json`):

```json
{ "total": 168703, "ok": 168703, "s5xx": 0, "other": 0, "errors": 0, "elapsed_seconds": 210.0 }
```

## AC 2 — deploy lock refuses the second deploy and prints the holder

```bash
docker exec s4d-redis redis-cli -p 28379 SET deploy:lock:test \
  'holder=demo-agent (simulated concurrent deploy)' NX EX 1800
bash ops/deploy/deploy.sh --env test --image-tag v2 --log-name lock-conflict-3203
```

Exit code: **11**

```text
2026-11-23T12:12:54Z [INFO] STEP=precheck_image rc=0 image=s4d-api:v2
2026-11-23T12:12:54Z [INFO] STEP=precheck_env_health rc=0 lb=http://127.0.0.1:28100
2026-11-23T12:12:54Z [ERROR] LOCK_HELD by holder=demo-agent (simulated concurrent deploy); second deploy refused
```

## AC 3 — health-gate failure stops the deploy and rolls back automatically

`ops/app/Dockerfile.bad` builds an image whose `/readyz` always returns 500.

```bash
docker build --network host -f ops/app/Dockerfile.bad -t s4d-api:v2-bad ops/app
bash ops/deploy/deploy.sh --env test --image-tag v2-bad --log-name fault-injection-3203
```

Exit code: **33** (deployment stopped), automatic rollback exit code: **0**

```text
2026-11-23T12:25:32Z [WARN] health node=app-a attempt=1 FAIL (healthz/readyz not both 200)
...
2026-11-23T12:25:51Z [WARN] health node=app-a attempt=10 FAIL (healthz/readyz not both 200)
2026-11-23T12:25:53Z [ERROR] health node=app-a gate FAILED after 10 attempts
2026-11-23T12:25:53Z [ERROR] auto rollback invoked reason=health_gate_failed_app-a
2026-11-23T12:27:27Z [INFO] STEP=rollback rc=0 reason=health_gate_failed_app-a
```

Rollback detail (same run):

```text
2026-11-23T12:25:54Z [INFO] ROLLBACK_PLAN env=test from=v2-bad to=v1 reason=health_gate_failed_app-a with_db_downgrade=0 drain=30s
2026-11-23T12:26:42Z [INFO] node_rollback_end node=app-a ts=2026-11-23T12:26:42Z elapsed=48s (threshold 180s)
2026-11-23T12:27:27Z [INFO] node_rollback_end node=app-b ts=2026-11-23T12:27:27Z elapsed=45s (threshold 180s)
2026-11-23T12:27:27Z [INFO] smoke /api/v1/ping -> 200
2026-11-23T12:27:27Z [INFO] smoke /api/v1/orgs -> 200
2026-11-23T12:27:27Z [INFO] smoke /api/v1/sites -> 200
2026-11-23T12:27:27Z [INFO] smoke /api/v1/members -> 200
2026-11-23T12:27:27Z [INFO] smoke /api/v1/resources -> 200
2026-11-23T12:27:27Z [INFO] STEP=rollback_done rc=0 from=v2-bad to=v1 duration=94s
```

Artifacts: `evidence/logs/fault-injection-3203.log`, `evidence/logs/fault-injection-3203.rollback.log`.

## AC 4 — prod deploy waits for approval

```bash
bash ops/deploy/deploy.sh --env prod --image-tag v1 --log-name prod-approval-wait
```

Exit code: **20**

```text
2026-11-23T12:13:06Z [WARN] WAITING_FOR_APPROVAL env=prod tag=v1 (GitHub Environments approval required; the script does not bypass the gate)
WAITING_FOR_APPROVAL
```

State written: `{ "env": "prod", "pending_tag": "v1", "status": "WAITING_FOR_APPROVAL" }`.
Screenshot: `evidence/prod-approval-wait.png`.

Note: the GitHub Actions approval UI cannot be screenshotted without a live repository run
(out of scope for this delivery). The screenshot captures the equivalent local gate.

## Artifact index

| File | Content |
|---|---|
| `evidence/logs/deploy-3203.log` | full rolling deployment (125s) |
| `evidence/logs/lock-conflict-3203.log` | second deploy refused, exit 11 |
| `evidence/logs/fault-injection-3203.log` | health gate failure + auto-rollback trigger |
| `evidence/logs/fault-injection-3203.rollback.log` | rollback of both nodes + smoke |
| `evidence/loadtest-3203.json` | 168,703 requests, 0 × 5xx |
| `evidence/logs/prod-approval-wait.log` | prod approval gate, exit 20 |
| `evidence/prod-approval-wait.png` | approval wait terminal capture |

## Repository verification

- `bash scripts/secret-scan.sh` → `scan_result=PASS` (private keys, GitHub/cloud tokens, password
  values, private IPs, local absolute paths, e-mails, bid/agent identifiers, hostname leaks, `.env`
  files: all zero findings).
- `sha256sum -c MANIFEST.sha256` executed on a fresh clone of this repository → 0 failures.
