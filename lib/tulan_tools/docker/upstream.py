"""Docker 上游版本查询."""

from __future__ import annotations

import re
import urllib.request

_DOCKER_STATIC_URL = "https://download.docker.com/linux/static/stable/x86_64/"
_USER_AGENT = "tulan-tools"


def _fetch_versions() -> list[str]:
    req = urllib.request.Request(_DOCKER_STATIC_URL, headers={"User-Agent": _USER_AGENT})
    with urllib.request.urlopen(req, timeout=60) as resp:
        html = resp.read().decode()
    vers: list[str] = []
    for v in re.findall(r"docker-(\d+\.\d+\.\d+)\.tgz", html):
        if v not in vers:
            vers.append(v)
    if not vers:
        raise RuntimeError("未在 Docker 静态包目录找到版本")
    return vers


def latest_version() -> str:
    return _fetch_versions()[-1]


def recent_versions(count: int = 8) -> str:
    vers = _fetch_versions()
    return " ".join(vers[-count:])
