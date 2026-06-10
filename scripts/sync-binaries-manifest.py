#!/usr/bin/env python3
"""更新 config/binaries.manifest.json 中的版本号和 SHA256"""

import hashlib
import json
import sys
from datetime import datetime, timezone
from pathlib import Path


def sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(8192), b""):
            h.update(chunk)
    return h.hexdigest()


def main() -> int:
    if len(sys.argv) < 3:
        print("用法: sync-binaries-manifest.py <manifest.json> <binaries_dir>", file=sys.stderr)
        return 1

    manifest_path = Path(sys.argv[1])
    binaries_dir = Path(sys.argv[2])
    repo = sys.argv[3] if len(sys.argv) > 3 else ""

    with open(manifest_path) as f:
        data = json.load(f)

    if repo:
        data["repository"] = repo

    data["updated_at"] = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

    versions = {}
    if len(sys.argv) > 4:
        versions = json.loads(sys.argv[4])

    for tool_name, tool in data.get("tools", {}).items():
        if tool_name in versions:
            tool["version"] = versions[tool_name]

        if "sha256" not in tool:
            tool["sha256"] = {}

        for platform_key, rel_path in tool.get("paths", {}).items():
            file_path = binaries_dir / rel_path
            if file_path.exists():
                tool["sha256"][platform_key] = sha256_file(file_path)

    with open(manifest_path, "w") as f:
        json.dump(data, f, indent=2, ensure_ascii=False)
        f.write("\n")

    print(f"已更新: {manifest_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
