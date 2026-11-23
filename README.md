# clawhunt-3203-deploy-pipeline

Rolling deployment pipeline: **manual DB backup → migration on a single node → drain-aware
two-node rotation → /healthz + /readyz gate (3 consecutive 200) → 5-endpoint smoke test →
automatic rollback on failure**. Includes a Redis-backed deploy lock and a prod approval gate.

- Verification record: [ACCEPTANCE.md](ACCEPTANCE.md)
- Evidence: [ACCEPTANCE-EVIDENCE.md](ACCEPTANCE-EVIDENCE.md)
- Original AC mapping with implementation locations: [docs/ac-3203.md](docs/ac-3203.md)

## Repository layout

```
ops/deploy/deploy.sh              deployment orchestration (lock, backup, migration, rolling, gates)
ops/deploy/rollback.sh            failure handler invoked automatically by deploy.sh
ops/deploy/bootstrap.sh           first-time environment bring-up
ops/deploy/loadtest.py            zero-dependency load generator (5xx counter)
ops/deploy/cleanup.sh             removes containers, volumes and built images
ops/deploy/compose/               PostgreSQL 16, Redis 7, app-a/app-b, nginx LB
ops/deploy/lib/common.sh          logging, lock, LB drain/attach, health, smoke, backup
ops/deploy/lib/state.py           atomic state/{env}.json read/write
ops/deploy/state/README.md        state file contract
ops/app/                          FastAPI + SQLAlchemy 2 + Alembic demo service
.github/workflows/deploy.yml      workflow_dispatch (env/image_tag), prod via Environments approval
scripts/secret-scan.sh            key / private-IP / local-path / email / id scanner
```

## Quick start (Linux host, Docker 26.1.3, compose v2.27.0)

```bash
# 161-style hosts have no container DNS; build with host networking.
docker build --network host -t s4d-api:v1 ops/app
docker build --network host -t s4d-api:v2 ops/app
docker build --network host -f ops/app/Dockerfile.bad -t s4d-api:v2-bad ops/app

bash ops/deploy/bootstrap.sh
bash ops/deploy/deploy.sh --env test --image-tag v2 --triggered-by ci
python3 ops/deploy/loadtest.py --url http://127.0.0.1:28100/api/v1/ping \
  --duration 210 --concurrency 8 --out evidence/loadtest-3203.json
```

Ports are loopback-only: 28100 (LB), 28101/28102 (nodes), 28379 (Redis), 28432 (PostgreSQL).

## Exit codes

| Code | Meaning |
|---|---|
| 11 | deploy lock held by another run (holder printed) |
| 12 | precheck failed (image missing / current env unhealthy) |
| 20 | prod waiting for approval (GitHub Environments) |
| 21 / 22 | backup / migration failed |
| 31-34 | rolling step failed (detach / up / health / attach) |
| 33 | health gate failed, automatic rollback executed |
| 35 | smoke test failed, automatic rollback executed |

## Scope and honest limitations

1. **Image registry**: this delivery uses the local image store (`docker image inspect`) instead of
   a private registry. Swap the precheck for `docker manifest inspect $REGISTRY/$IMAGE:$TAG` in production.
2. **GitHub Actions**: `.github/workflows/deploy.yml` is delivered as configuration but was not executed
   in this environment; the prod approval gate was verified through `deploy.sh` itself (exit 20 +
   `evidence/prod-approval-wait.png`).
3. **Networking**: the target host blocks container-to-container TCP (ICMP works), so compose runs
   services with `network_mode: host` on loopback ports. Replace with a normal bridge network and a
   real LB/Ingress API in production.
4. **Secrets**: no `.env`, no tokens, no private keys. State snapshots that may contain environment
   values are excluded by `.gitignore`. Run `bash scripts/secret-scan.sh` to confirm zero findings.

Migration compatibility policy (add-only) and the exception approval flow: [docs/MIGRATION-COMPAT.md](docs/MIGRATION-COMPAT.md).
