"""JSON 读写工具."""

from __future__ import annotations

import json
import sys
from pathlib import Path
from typing import Any


def load_json(path: str | Path) -> Any:
    return json.loads(Path(path).read_text(encoding="utf-8"))


def save_json(path: str | Path, data: Any) -> None:
    p = Path(path)
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text(json.dumps(data, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")


def get_by_path(data: Any, path: str, default: str = "") -> str:
    cur = data
    for part in path.split("."):
        if not part:
            continue
        if isinstance(cur, dict) and part in cur:
            cur = cur[part]
        else:
            return default
    if cur is None:
        return default
    return str(cur)


def cmd_get(argv: list[str]) -> int:
    import argparse

    parser = argparse.ArgumentParser(description="从 JSON 文件读取点分路径字段")
    parser.add_argument("file", type=Path)
    parser.add_argument("path", help="点分路径，如 repository 或 tools.kubectl.version")
    parser.add_argument("--default", default="", help="缺失时的默认值")
    args = parser.parse_args(argv)

    if not args.file.exists():
        print(f"文件不存在: {args.file}", file=sys.stderr)
        return 1

    data = load_json(args.file)
    print(get_by_path(data, args.path, args.default))
    return 0
