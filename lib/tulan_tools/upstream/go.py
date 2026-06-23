"""Go 官方发行版查询与下载 URL（go.dev / golang.google.cn）."""

from __future__ import annotations

import json
import re
import sys
import urllib.error
import urllib.request
from typing import Any

USER_AGENT = "tulan-tools"
GO_DL_JSON = "https://go.dev/dl/?mode=json"
GO_DL_CN_JSON = "https://golang.google.cn/dl/?mode=json"
GO_DL_BASE = "https://go.dev/dl/"
GO_DL_CN_BASE = "https://golang.google.cn/dl/"


def _fetch_json(url: str) -> list[dict[str, Any]]:
    req = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    with urllib.request.urlopen(req, timeout=60) as resp:
        data = json.load(resp)
    if not isinstance(data, list):
        raise RuntimeError(f"Go 版本列表格式异常: {url}")
    return data


def fetch_releases(prefer_cn: bool = True) -> list[dict[str, Any]]:
    urls = [GO_DL_CN_JSON, GO_DL_JSON] if prefer_cn else [GO_DL_JSON, GO_DL_CN_JSON]
    last_err: Exception | None = None
    for url in urls:
        try:
            return _fetch_json(url)
        except (urllib.error.URLError, TimeoutError, RuntimeError, json.JSONDecodeError) as exc:
            last_err = exc
            continue
    raise RuntimeError(f"无法获取 Go 版本列表: {last_err}")


def _version_key(version: str) -> tuple[int, ...]:
    m = re.match(r"^go(\d+)\.(\d+)(?:\.(\d+))?", version)
    if not m:
        return (0,)
    parts = [int(m.group(1)), int(m.group(2))]
    if m.group(3):
        parts.append(int(m.group(3)))
    return tuple(parts)


def list_versions(
    *,
    stable_only: bool = True,
    count: int = 20,
    prefer_cn: bool = True,
) -> list[str]:
    releases = fetch_releases(prefer_cn=prefer_cn)
    versions: list[str] = []
    for item in releases:
        version = str(item.get("version", ""))
        if not version.startswith("go"):
            continue
        if stable_only and not item.get("stable", False):
            continue
        versions.append(version)
    versions.sort(key=_version_key, reverse=True)
    return versions[: max(count, 1)]


def latest_stable(prefer_cn: bool = True) -> str:
    versions = list_versions(stable_only=True, count=1, prefer_cn=prefer_cn)
    if not versions:
        raise RuntimeError("未找到 Go 稳定版")
    return versions[0]


def _platform_parts(platform_key: str) -> tuple[str, str]:
    os_name, arch = platform_key.split("-", 1)
    if arch == "amd64":
        go_arch = "amd64"
    elif arch == "arm64":
        go_arch = "arm64"
    else:
        raise RuntimeError(f"不支持的 Go 平台: {platform_key}")
    if os_name not in ("linux", "darwin"):
        raise RuntimeError(f"不支持的 Go 操作系统: {os_name}")
    return os_name, go_arch


def resolve_download(
    version: str,
    platform_key: str,
    *,
    prefer_cn: bool = True,
) -> tuple[str, str, str]:
    if not version.startswith("go"):
        version = f"go{version}"

    os_name, go_arch = _platform_parts(platform_key)
    releases = fetch_releases(prefer_cn=prefer_cn)

    for item in releases:
        if str(item.get("version", "")) != version:
            continue
        for file_info in item.get("files") or []:
            if file_info.get("os") != os_name:
                continue
            if file_info.get("arch") != go_arch:
                continue
            if file_info.get("kind") not in ("archive", None):
                continue
            filename = str(file_info.get("filename", ""))
            sha256 = str(file_info.get("sha256", ""))
            if not filename:
                continue
            base = GO_DL_CN_BASE if prefer_cn else GO_DL_BASE
            return f"{base}{filename}", sha256, filename

    filename = f"{version}.{platform_key}.tar.gz"
    base = GO_DL_CN_BASE if prefer_cn else GO_DL_BASE
    return f"{base}{filename}", "", filename


def cmd_latest(argv: list[str]) -> int:
    import argparse

    parser = argparse.ArgumentParser()
    parser.add_argument("--no-cn", action="store_true")
    args = parser.parse_args(argv)
    print(latest_stable(prefer_cn=not args.no_cn))
    return 0


def cmd_list(argv: list[str]) -> int:
    import argparse

    parser = argparse.ArgumentParser()
    parser.add_argument("--count", type=int, default=20)
    parser.add_argument("--all", action="store_true", help="包含非 stable 版本")
    parser.add_argument("--no-cn", action="store_true")
    args = parser.parse_args(argv)
    for version in list_versions(
        stable_only=not args.all,
        count=args.count,
        prefer_cn=not args.no_cn,
    ):
        print(version)
    return 0


def cmd_download_url(argv: list[str]) -> int:
    import argparse

    parser = argparse.ArgumentParser()
    parser.add_argument("version")
    parser.add_argument("platform_key")
    parser.add_argument("--no-cn", action="store_true")
    args = parser.parse_args(argv)
    url, sha256, filename = resolve_download(
        args.version,
        args.platform_key,
        prefer_cn=not args.no_cn,
    )
    print(url)
    print(sha256)
    print(filename)
    return 0
