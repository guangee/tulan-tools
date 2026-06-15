"""语义版本比较（vX.Y.Z / X.Y.Z）."""

from __future__ import annotations


def parse_version(version: str) -> tuple[int, int, int]:
    text = version.strip()
    if text.startswith("v"):
        text = text[1:]
    parts = text.split(".")
    while len(parts) < 3:
        parts.append("0")
    return int(parts[0]), int(parts[1]), int(parts[2])


def version_key(tag: str) -> tuple[int, int, int]:
    return parse_version(tag)


def normalize_tag(tag: str) -> str:
    tag = tag.strip()
    return tag if tag.startswith("v") else f"v{tag}"
