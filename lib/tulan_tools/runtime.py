"""Java / Node 运行时状态读写."""

from __future__ import annotations

import json
import sys
from pathlib import Path
from typing import Any


def _load_state(path: Path) -> dict[str, Any]:
    if path.exists():
        return json.loads(path.read_text(encoding="utf-8"))
    return {}


def state_field(state_path: str | Path, field: str) -> str:
    data = _load_state(Path(state_path))
    val = data.get(field, "")
    return "" if val is None else str(val)


def save_java_state(major: str, version: str, java_home: str, state_path: str | Path) -> None:
    state = Path(state_path)
    state.parent.mkdir(parents=True, exist_ok=True)
    data = _load_state(state) if state.exists() else {"active_major": "", "java_home": "", "runtimes": {}}
    data["active_major"] = major
    data["java_home"] = java_home
    data.setdefault("runtimes", {})[major] = {"version": version, "java_home": java_home}
    state.write_text(json.dumps(data, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")


def save_node_state(major: str, version: str, node_home: str, state_path: str | Path) -> None:
    state = Path(state_path)
    state.parent.mkdir(parents=True, exist_ok=True)
    data = _load_state(state) if state.exists() else {"active_major": "", "node_home": "", "runtimes": {}}
    data["active_major"] = major
    data["node_home"] = node_home
    data.setdefault("runtimes", {})[major] = {"version": version, "node_home": node_home}
    state.write_text(json.dumps(data, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")


def relpath(target: str, base: str) -> str:
    import os

    return os.path.relpath(target, base)


def cmd_state_field(argv: list[str]) -> int:
    import argparse

    parser = argparse.ArgumentParser()
    parser.add_argument("state_file", type=Path)
    parser.add_argument("field")
    args = parser.parse_args(argv)
    if not args.state_file.exists():
        return 0
    print(state_field(args.state_file, args.field))
    return 0


def cmd_save_java(argv: list[str]) -> int:
    import argparse

    parser = argparse.ArgumentParser()
    parser.add_argument("--major", required=True)
    parser.add_argument("--version", required=True)
    parser.add_argument("--java-home", required=True)
    parser.add_argument("--state-path", required=True)
    args = parser.parse_args(argv)
    save_java_state(args.major, args.version, args.java_home, args.state_path)
    return 0


def cmd_save_node(argv: list[str]) -> int:
    import argparse

    parser = argparse.ArgumentParser()
    parser.add_argument("--major", required=True)
    parser.add_argument("--version", required=True)
    parser.add_argument("--node-home", required=True)
    parser.add_argument("--state-path", required=True)
    args = parser.parse_args(argv)
    save_node_state(args.major, args.version, args.node_home, args.state_path)
    return 0


def cmd_relpath(argv: list[str]) -> int:
    import argparse

    parser = argparse.ArgumentParser()
    parser.add_argument("target")
    parser.add_argument("base")
    args = parser.parse_args(argv)
    print(relpath(args.target, args.base))
    return 0
