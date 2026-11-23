"""state/{env}.json 读写小工具（原子替换）。

用法：
  state.py <file> get <key>
  state.py <file> set '<json-object>'
"""
import json
import os
import sys


def main() -> int:
    path, op = sys.argv[1], sys.argv[2]
    data: dict = {}
    if os.path.exists(path):
        with open(path, encoding="utf-8") as fh:
            text = fh.read().strip()
            data = json.loads(text) if text else {}
    if op == "get":
        value = data.get(sys.argv[3], "")
        print("" if value is None else value)
        return 0
    if op == "set":
        data.update(json.loads(sys.argv[3]))
        tmp = f"{path}.tmp"
        with open(tmp, "w", encoding="utf-8") as fh:
            json.dump(data, fh, indent=2, ensure_ascii=False)
            fh.write("\n")
        os.replace(tmp, path)
        return 0
    print(f"unknown op: {op}", file=sys.stderr)
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
