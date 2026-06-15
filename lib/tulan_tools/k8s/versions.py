"""Rancher 版本列表解析与过滤."""

from __future__ import annotations

import json
import sys
from pathlib import Path


def ver_key(tag: str) -> tuple[int, int, int]:
    tag = tag.strip()
    if tag.startswith("v"):
        tag = tag[1:]
    parts = tag.split(".")
    while len(parts) < 3:
        parts.append("0")
    return tuple(int(p) for p in parts[:3])


def read_versions_from_json(path: str | Path) -> list[str]:
    data = json.loads(Path(path).read_text(encoding="utf-8"))
    min_raw = (data.get("min_version") or "v2.8.5").strip()
    min_key = ver_key(min_raw)
    tags: list[str] = []
    for tag in data.get("tags") or []:
        tag = str(tag).strip()
        if tag and ver_key(tag) >= min_key:
            tags.append(tag)
    return tags


def filter_versions_ge(current_tag: str, lines: list[str]) -> list[str]:
    current = current_tag.strip()
    cur_key = None if not current or current == "unknown" else ver_key(current)
    out: list[str] = []
    for line in lines:
        tag = line.strip()
        if not tag:
            continue
        if cur_key is None or ver_key(tag) >= cur_key:
            out.append(tag)
    return out


def cmd_read_versions(argv: list[str]) -> int:
    import argparse

    parser = argparse.ArgumentParser()
    parser.add_argument("versions_file", type=Path)
    args = parser.parse_args(argv)
    if not args.versions_file.exists():
        return 1
    for tag in read_versions_from_json(args.versions_file):
        print(tag)
    return 0


def cmd_filter_ge(argv: list[str]) -> int:
    import argparse

    parser = argparse.ArgumentParser()
    parser.add_argument("--current", default="")
    args = parser.parse_args(argv)
    lines = sys.stdin.read().splitlines()
    for tag in filter_versions_ge(args.current, lines):
        print(tag)
    return 0
