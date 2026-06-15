#!/usr/bin/env python3
"""从 Docker Hub 同步 rancher/rancher 可升级版本列表（仅 vX.Y.Z）。

数据来源:
  https://hub.docker.com/r/rancher/rancher/tags
  https://hub.docker.com/v2/repositories/rancher/rancher/tags
"""

from __future__ import annotations

import argparse
import json
import re
import sys
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

SEMVER_TAG_RE = re.compile(r"^v\d+\.\d+\.\d+$")
HUB_TAGS_URL = "https://hub.docker.com/v2/repositories/rancher/rancher/tags"
REGISTRY_TAGS_URL = "https://registry.hub.docker.com/v2/rancher/rancher/tags/list"
USER_AGENT = "tulan-tools/sync-rancher-versions"


def version_key(tag: str) -> tuple[int, int, int]:
    major, minor, patch = tag[1:].split(".")
    return int(major), int(minor), int(patch)


def fetch_json(url: str, timeout: int) -> dict:
    req = urllib.request.Request(
        url,
        headers={
            "Accept": "application/json",
            "User-Agent": USER_AGENT,
        },
    )
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return json.load(resp)


def fetch_tags_from_hub(page_size: int, max_pages: int, timeout: int) -> list[str]:
    tags: list[str] = []
    url: str | None = (
        f"{HUB_TAGS_URL}?page_size={page_size}&ordering=-last_updated"
    )
    pages = 0

    while url and (max_pages <= 0 or pages < max_pages):
        data = fetch_json(url, timeout)
        results = data.get("results") or []
        tags.extend(str(item.get("name", "")) for item in results if item.get("name"))
        url = data.get("next")
        pages += 1

    return tags


def fetch_tags_from_registry(page_size: int, max_pages: int, timeout: int) -> list[str]:
    tags: list[str] = []
    url: str | None = f"{REGISTRY_TAGS_URL}?n={page_size}"
    pages = 0

    while url and (max_pages <= 0 or pages < max_pages):
        data = fetch_json(url, timeout)
        batch = data.get("tags") or []
        if not batch:
            break
        tags.extend(str(name) for name in batch)
        if len(batch) < page_size:
            break
        last = urllib.parse.quote(batch[-1], safe="")
        url = f"{REGISTRY_TAGS_URL}?n={page_size}&last={last}"
        pages += 1

    return tags


def minor_key(tag: str) -> tuple[int, int]:
    major, minor, _patch = version_key(tag)
    return major, minor


def filter_max_per_minor(tags: list[str], max_per_minor: int) -> list[str]:
    if max_per_minor <= 0:
        return tags
    counts: dict[tuple[int, int], int] = {}
    kept: list[str] = []
    for tag in tags:
        key = minor_key(tag)
        count = counts.get(key, 0)
        if count >= max_per_minor:
            continue
        counts[key] = count + 1
        kept.append(tag)
    return kept


def collect_semver_tags(raw_tags: list[str], max_per_minor: int = 0) -> list[str]:
    seen: set[str] = set()
    stable: list[str] = []
    for name in raw_tags:
        if not SEMVER_TAG_RE.fullmatch(name):
            continue
        if name in seen:
            continue
        seen.add(name)
        stable.append(name)
    stable.sort(key=version_key, reverse=True)
    return filter_max_per_minor(stable, max_per_minor)


def fetch_semver_tags(
    page_size: int,
    max_pages: int,
    timeout: int,
    max_per_minor: int = 0,
) -> list[str]:
    errors: list[str] = []
    for name, fetcher in (
        ("Docker Hub API", fetch_tags_from_hub),
        ("Docker Registry API", fetch_tags_from_registry),
    ):
        try:
            raw = fetcher(page_size, max_pages, timeout)
            stable = collect_semver_tags(raw, max_per_minor)
            if stable:
                print(
                    f"[sync-rancher-versions] 已从 {name} 获取 {len(stable)} 个 vX.Y.Z 版本",
                    file=sys.stderr,
                )
                return stable
            errors.append(f"{name}: 未找到 vX.Y.Z 标签")
        except (urllib.error.URLError, TimeoutError, json.JSONDecodeError) as exc:
            errors.append(f"{name}: {exc}")

    raise RuntimeError("无法从 Docker Hub 拉取 Rancher 版本\n  - " + "\n  - ".join(errors))


def render_versions_json(tags: list[str], max_per_minor: int) -> str:
    payload = {
        "version": 1,
        "updated_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "source": "https://hub.docker.com/r/rancher/rancher/tags",
        "image": "rancher/rancher",
        "tag_pattern": "vX.Y.Z",
        "max_per_minor": max_per_minor,
        "tags": tags,
    }
    return json.dumps(payload, indent=2, ensure_ascii=False) + "\n"


def render_versions_file(tags: list[str], max_per_minor: int) -> str:
    ts = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    lines = [
        "# 由 CI / brew k8s sync-versions 自动生成",
        "# 来源: https://hub.docker.com/r/rancher/rancher/tags",
        "# 仅保留 vX.Y.Z 稳定版本（排除 -head、-alpha、-amd64 等）",
        f"# 同一 vX.Y 最多保留 {max_per_minor} 个 patch",
        f"# 更新时间: {ts}",
        "",
    ]
    lines.extend(tags)
    lines.append("")
    return "\n".join(lines)


def main() -> int:
    parser = argparse.ArgumentParser(
        description="从 Docker Hub 同步 rancher/rancher 的 vX.Y.Z 版本列表",
    )
    parser.add_argument(
        "-o",
        "--output",
        type=Path,
        help="输出文件（默认: <tulan-home>/config/k8s.rancher.versions）",
    )
    parser.add_argument(
        "--format",
        choices=("json", "text"),
        default="json",
        help="输出格式（默认 json，供 bin 分支缓存）",
    )
    parser.add_argument(
        "--max-per-minor",
        type=int,
        default=3,
        help="同一 vX.Y 最多保留几个 patch 版本（默认 3，0 表示不限制）",
    )
    parser.add_argument(
        "--limit",
        type=int,
        default=0,
        help="最多保留多少个版本（0 表示不限制，默认 0）",
    )
    parser.add_argument(
        "--page-size",
        type=int,
        default=100,
        help="API 分页大小（默认 100）",
    )
    parser.add_argument(
        "--max-pages",
        type=int,
        default=200,
        help="最多请求页数，0 表示不限制（默认 200）",
    )
    parser.add_argument(
        "--timeout",
        type=int,
        default=60,
        help="单次 HTTP 请求超时秒数（默认 60）",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="仅输出到 stdout，不写文件",
    )
    args = parser.parse_args()

    if args.page_size < 1 or args.page_size > 1000:
        print("page-size 需在 1-1000 之间", file=sys.stderr)
        return 1

    tags = fetch_semver_tags(
        args.page_size,
        args.max_pages,
        args.timeout,
        args.max_per_minor,
    )
    if args.limit > 0:
        tags = tags[: args.limit]

    if not tags:
        print("未找到任何 vX.Y.Z 版本", file=sys.stderr)
        return 1

    if args.format == "json":
        content = render_versions_json(tags, args.max_per_minor)
        default_name = "k8s.rancher.versions.json"
    else:
        content = render_versions_file(tags, args.max_per_minor)
        default_name = "k8s.rancher.versions"

    if args.dry_run:
        sys.stdout.write(content)
        return 0

    output = args.output
    if output is None:
        tulan_home = Path.home() / ".tulan-tools"
        if (Path.cwd() / "lib" / "common.sh").exists():
            tulan_home = Path.cwd()
        output = tulan_home / "config" / default_name

    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(content, encoding="utf-8")
    print(f"已写入 {len(tags)} 个版本到 {output}", file=sys.stderr)
    print(f"最新版本: {tags[0]}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except RuntimeError as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        raise SystemExit(1)
