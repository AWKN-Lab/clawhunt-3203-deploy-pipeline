#!/usr/bin/env python3
"""持续压测：滚动发布期间对 LB 打只读接口，统计 5xx。零第三方依赖。"""
import argparse
import json
import threading
import time
import urllib.error
import urllib.request

RESULTS = {"total": 0, "ok": 0, "s5xx": 0, "other": 0, "errors": 0}
LOCK = threading.Lock()


def worker(url: str, deadline: float) -> None:
    while time.time() < deadline:
        try:
            req = urllib.request.Request(url, headers={"User-Agent": "s4d-loadtest"})
            with urllib.request.urlopen(req, timeout=5) as resp:
                code = resp.status
        except urllib.error.HTTPError as exc:
            code = exc.code
        except Exception:  # noqa: BLE001 - 连接层失败单独记
            code = 0
        with LOCK:
            RESULTS["total"] += 1
            if 200 <= code < 300:
                RESULTS["ok"] += 1
            elif code >= 500:
                RESULTS["s5xx"] += 1
            elif code == 0:
                RESULTS["errors"] += 1
            else:
                RESULTS["other"] += 1


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--url", required=True)
    parser.add_argument("--duration", type=int, default=120)
    parser.add_argument("--concurrency", type=int, default=8)
    parser.add_argument("--out", required=True)
    args = parser.parse_args()

    deadline = time.time() + args.duration
    threads = [threading.Thread(target=worker, args=(args.url, deadline), daemon=True)
               for _ in range(args.concurrency)]
    started = time.time()
    for t in threads:
        t.start()
    for t in threads:
        t.join()
    RESULTS["elapsed_seconds"] = round(time.time() - started, 1)
    RESULTS["url"] = args.url
    with open(args.out, "w", encoding="utf-8") as fh:
        json.dump(RESULTS, fh, indent=2)
        fh.write("\n")
    print(json.dumps(RESULTS, ensure_ascii=False))
    return 1 if RESULTS["s5xx"] > 0 else 0


if __name__ == "__main__":
    raise SystemExit(main())
