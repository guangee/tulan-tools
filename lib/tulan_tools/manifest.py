"""binaries.manifest.json 读取."""

from __future__ import annotations

import argparse
import sys
from pathlib import Path
from typing import Any

from .jsonio import get_by_path, load_json


def branch(manifest_path: str | Path, default: str = "bin") -> str:
    return get_by_path(load_json(manifest_path), "branch", default) or default


def github_proxy(manifest_path: str | Path) -> str:
    return get_by_path(load_json(manifest_path), "github_proxy", "")


def repository(manifest_path: str | Path) -> str:
    return get_by_path(load_json(manifest_path), "repository", "")


def tool_field(manifest_path: str | Path, tool: str, field: str, default: str = "") -> str:
    data = load_json(manifest_path)
    tool_data: dict[str, Any] = (data.get("tools") or {}).get(tool) or {}
    val = tool_data.get(field, default)
    return "" if val is None else str(val)


def tool_install_name(manifest_path: str | Path, tool: str) -> str:
    name = tool_field(manifest_path, tool, "install_name", "")
    return name or tool


def tool_version(manifest_path: str | Path, tool: str) -> str:
    return tool_field(manifest_path, tool, "version", "")


def tool_platform_path(manifest_path: str | Path, tool: str, platform_key: str) -> str:
    data = load_json(manifest_path)
    tool_data = (data.get("tools") or {}).get(tool)
    if not tool_data:
        raise KeyError(tool)
    path = (tool_data.get("paths") or {}).get(platform_key, "")
    result = str(path or "")
    if not result:
        raise KeyError(f"{tool}:{platform_key}")
    return result


def tool_platform_sha256(manifest_path: str | Path, tool: str, platform_key: str) -> str:
    data = load_json(manifest_path)
    tool_data = (data.get("tools") or {}).get(tool) or {}
    sha = (tool_data.get("sha256") or {}).get(platform_key, "")
    return str(sha or "")


def cmd_branch(argv: list[str]) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("manifest", type=Path)
    parser.add_argument("--default", default="bin")
    args = parser.parse_args(argv)
    print(branch(args.manifest, args.default))
    return 0


def cmd_tool_field(argv: list[str]) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("manifest", type=Path)
    parser.add_argument("tool")
    parser.add_argument("field")
    parser.add_argument("--default", default="")
    args = parser.parse_args(argv)
    print(tool_field(args.manifest, args.tool, args.field, args.default))
    return 0


def cmd_tool_install_name(argv: list[str]) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("manifest", type=Path)
    parser.add_argument("tool")
    args = parser.parse_args(argv)
    print(tool_install_name(args.manifest, args.tool))
    return 0


def cmd_tool_version(argv: list[str]) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("manifest", type=Path)
    parser.add_argument("tool")
    args = parser.parse_args(argv)
    print(tool_version(args.manifest, args.tool))
    return 0


def cmd_tool_path(argv: list[str]) -> int:
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


def cmd_tool_sha256(argv: list[str]) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("manifest", type=Path)
    parser.add_argument("tool")
    parser.add_argument("platform")
    args = parser.parse_args(argv)
    print(tool_platform_sha256(args.manifest, args.tool, args.platform))
    return 0


def cmd_github_proxy(argv: list[str]) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("manifest", type=Path)
    args = parser.parse_args(argv)
    print(github_proxy(args.manifest))
    return 0


def cmd_get(argv: list[str]) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("manifest", type=Path)
    parser.add_argument("path")
    parser.add_argument("--default", default="")
    args = parser.parse_args(argv)
    data = load_json(args.manifest)
    print(get_by_path(data, args.path, args.default))
    return 0
