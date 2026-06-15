"""Apache Maven 上游版本."""

from __future__ import annotations

import re
import urllib.request

_METADATA_URL = (
    "https://repo.maven.apache.org/maven2/org/apache/maven/apache-maven/maven-metadata.xml"
)


def latest_stable_version() -> str:
    req = urllib.request.Request(_METADATA_URL, headers={"User-Agent": "tulan-tools"})
    with urllib.request.urlopen(req, timeout=30) as resp:
        text = resp.read().decode()

    def is_stable(v: str) -> bool:
        return not re.search(r"(alpha|beta|rc|snapshot)", v, re.I)

    m = re.search(r"<release>([^<]+)</release>", text)
    if m and is_stable(m.group(1)) and m.group(1).startswith("3."):
        return m.group(1)

    versions = re.findall(r"<version>([^<]+)</version>", text)
    stable = [v for v in versions if re.match(r"^3\.\d+\.\d+$", v)]
    if stable:
        return stable[-1]
    raise RuntimeError("无法从 Maven metadata 解析稳定版本")


def cmd_latest(_argv: list[str]) -> int:
    print(latest_stable_version())
    return 0
