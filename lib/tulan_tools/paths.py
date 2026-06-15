"""路径与环境变量."""

from __future__ import annotations

import os
from pathlib import Path


def tulan_home() -> Path:
    raw = os.environ.get("TULAN_TOOLS_HOME") or os.environ.get("TULAN_TOOLS_DEFAULT_HOME")
    if raw:
        return Path(raw).expanduser()
    return Path.home() / ".tulan-tools"
