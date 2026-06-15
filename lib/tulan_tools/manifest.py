"""binaries.manifest.json 读取（替代 bash 内联 python -c）."""

from __future__ import annotations

import io
import sys
from contextlib import redirect_stdout
from pathlib import Path
from typing import Any

from .jsonio import get_by_path, load_json


def eval_expr(manifest_path: str | Path, expr: str) -> str:
    """执行与历史 bash tulan_manifest_read 兼容的 print 表达式."""
    data = load_json(manifest_path)
    buf = io.StringIO()
    namespace = {"data": data, "sys": sys}
    with redirect_stdout(buf):
        exec(expr, namespace)  # noqa: S102 — 仅内部 manifest 表达式
    return buf.getvalue().rstrip("\n")


def tool_field(manifest_path: str | Path, tool: str, field: str, default: str = "") -> str:
    data = load_json(manifest_path)
    tool_data: dict[str, Any] = (data.get("tools") or {}).get(tool) or {}
    val = tool_data.get(field, default)
    return "" if val is None else str(val)


def tool_platform_path(manifest_path: str | Path, tool: str, platform_key: str) -> str:
    data = load_json(manifest_path)
    tool_data = (data.get("tools") or {}).get(tool)
    if not tool_data:
        raise KeyError(tool)
    path = (tool_data.get("paths") or {}).get(platform_key, "")
    return str(path or "")


def tool_platform_sha256(manifest_path: str | Path, tool: str, platform_key: str) -> str:
    data = load_json(manifest_path)
    tool_data = (data.get("tools") or {}).get(tool) or {}
    sha = (tool_data.get("sha256") or {}).get(platform_key, "")
    return str(sha or "")


def cmd_eval(argv: list[str]) -> int:
    import argparse

    parser = argparse.ArgumentParser(description="执行 manifest 读取表达式（兼容旧接口）")
    parser.add_argument("manifest", type=Path)
    parser.add_argument("expr", help="如 print(data.get('branch', 'bin'))")
    args = parser.parse_args(argv)
    try:
        print(eval_expr(args.manifest, args.expr))
    except Exception as exc:  # noqa: BLE001
        print(f"ERROR: {exc}", file=sys.stderr)
        return 1
    return 0


def cmd_tool_version(argv: list[str]) -> int:
    import argparse

    parser = argparse.ArgumentParser()
    parser.add_argument("manifest", type=Path)
    parser.add_argument("tool")
    args = parser.parse_args(argv)
    print(tool_field(args.manifest, args.tool, "version"))
    return 0


def cmd_tool_path(argv: list[str]) -> int:
    import argparse

    parser = argparse.ArgumentParser()
    parser.add_argument("manifest", type=Path)
    parser.add_argument("tool")
    parser.add_argument("platform")
    args = parser.parse_args(argv)
    try:
        print(tool_platform_path(args.manifest, args.tool, args.platform))
    except KeyError:
        return 1
    return 0


def cmd_get(argv: list[str]) -> int:
    import argparse

    parser = argparse.ArgumentParser()
    parser.add_argument("manifest", type=Path)
    parser.add_argument("path")
    parser.add_argument("--default", default="")
    args = parser.parse_args(argv)
    data = load_json(args.manifest)
    print(get_by_path(data, args.path, args.default))
    return 0
