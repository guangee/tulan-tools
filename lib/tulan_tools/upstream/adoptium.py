"""Eclipse Adoptium API."""

from __future__ import annotations

import json
import urllib.request


def fetch_asset(major: str, os_name: str, arch: str) -> tuple[str, str]:
    url = (
        f"https://api.adoptium.net/v3/assets/latest/{major}/hotspot"
        f"?architecture={arch}&image_type=jdk&os={os_name}"
    )
    req = urllib.request.Request(url, headers={"User-Agent": "tulan-tools"})
    with urllib.request.urlopen(req, timeout=60) as resp:
        data = json.load(resp)
    if not data:
        raise RuntimeError(f"Adoptium 无 Java {major} 资产")
    asset = data[0]
    version = asset.get("version", {}).get("semver") or asset.get("version", {}).get("openjdk_version", "")
    link = asset.get("binary", {}).get("package", {}).get("link", "")
    if not link or not version:
        raise RuntimeError(f"Adoptium 返回数据不完整: Java {major}")
    return str(version), str(link)


def cmd_fetch(argv: list[str]) -> int:
    import argparse

    parser = argparse.ArgumentParser()
    parser.add_argument("major")
    parser.add_argument("os_name")
    parser.add_argument("arch")
    args = parser.parse_args(argv)
    version, link = fetch_asset(args.major, args.os_name, args.arch)
    print(version)
    print(link)
    return 0
