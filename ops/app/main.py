"""会员空间平台最小 API 桩：健康端点 + 5 个只读接口。

/healthz  进程存活
/readyz   依赖就绪（PostgreSQL + Redis），连续 3 次 200 才允许挂回负载均衡
"""
import os

import redis
from fastapi import FastAPI, Response
from sqlalchemy import text

from db import engine

APP_VERSION = os.getenv("APP_VERSION", "dev")
FORCE_FAIL = os.getenv("READYZ_FORCE_FAIL", "0") == "1"

redis_client = redis.Redis.from_url(
    os.getenv("REDIS_URL", "redis://redis:6379/0"), socket_timeout=2, socket_connect_timeout=2
)

app = FastAPI(title="member-space-api-stub")


@app.get("/healthz")
def healthz() -> dict:
    return {"status": "ok", "version": APP_VERSION, "pid": os.getpid()}


@app.get("/readyz")
def readyz(response: Response) -> dict:
    checks: dict[str, str] = {}
    ok = True
    try:
        with engine.connect() as conn:
            conn.execute(text("SELECT 1"))
        checks["database"] = "ok"
    except Exception as exc:  # noqa: BLE001 - 就绪检查需报告任意失败类型
        ok = False
        checks["database"] = f"error:{type(exc).__name__}"
    try:
        redis_client.ping()
        checks["redis"] = "ok"
    except Exception as exc:  # noqa: BLE001
        ok = False
        checks["redis"] = f"error:{type(exc).__name__}"
    if FORCE_FAIL:
        ok = False
        checks["forced"] = "READYZ_FORCE_FAIL"
    response.status_code = 200 if ok else 500
    return {"ready": ok, "version": APP_VERSION, "checks": checks}


def _rows(sql: str) -> list[dict]:
    with engine.connect() as conn:
        return [dict(r._mapping) for r in conn.execute(text(sql))]


@app.get("/api/v1/ping")
def ping() -> dict:
    return {"pong": True, "version": APP_VERSION}


@app.get("/api/v1/orgs")
def orgs() -> list[dict]:
    return _rows("SELECT id::text, name FROM orgs WHERE deleted_at IS NULL ORDER BY name")


@app.get("/api/v1/sites")
def sites() -> list[dict]:
    return _rows("SELECT id::text, org_id::text, name FROM sites WHERE deleted_at IS NULL ORDER BY name")


@app.get("/api/v1/members")
def members() -> list[dict]:
    return _rows("SELECT id::text, org_id::text, display_name FROM members WHERE deleted_at IS NULL ORDER BY display_name")


@app.get("/api/v1/resources")
def resources() -> list[dict]:
    return _rows("SELECT id::text, site_id::text, name FROM resources WHERE deleted_at IS NULL ORDER BY name")
