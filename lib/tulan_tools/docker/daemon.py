"""daemon.json 与 docker-config 状态."""

from __future__ import annotations

import json
import time
from pathlib import Path
from typing import Any


def load_defaults_exports(defaults_file: str | Path) -> str:
    """输出可 eval 的 export 语句（与 bash tulan_docker_load_defaults 一致）."""
    data = json.loads(Path(defaults_file).read_text(encoding="utf-8"))
    lines: list[str] = []
    mirrors = data.get("registry-mirrors") or []
    if mirrors:
        lines.append(f"export TULAN_DOCKER_REGISTRY_MIRROR={mirrors[0]!r}")
    lines.append(f"export TULAN_DOCKER_LOG_DRIVER={data.get('log-driver', 'json-file')!r}")
    opts = data.get("log-opts") or {}
    lines.append(f"export TULAN_DOCKER_LOG_MAX_SIZE={opts.get('max-size', '10m')!r}")
    lines.append(f"export TULAN_DOCKER_LOG_MAX_FILE={opts.get('max-file', '3')!r}")
    lines.append(f"export TULAN_DOCKER_LOG_COMPRESS={opts.get('compress', 'true')!r}")
    return "\n".join(lines)


def build_daemon_json(
    mirror: str,
    log_driver: str,
    log_max_size: str,
    log_max_file: str,
    log_compress: str,
    daemon_path: str | Path,
) -> str:
    path = Path(daemon_path)
    data: dict[str, Any] = {}
    if path.exists():
        try:
            data = json.loads(path.read_text(encoding="utf-8"))
        except json.JSONDecodeError:
            data = {}

    mirrors = list(data.get("registry-mirrors") or [])
    if mirror and mirror not in mirrors:
        mirrors.insert(0, mirror)
    elif mirror:
        mirrors = [mirror] + [m for m in mirrors if m != mirror]
    if mirror:
        data["registry-mirrors"] = mirrors

    data["log-driver"] = log_driver
    opts = dict(data.get("log-opts") or {})
    opts["max-size"] = log_max_size
    opts["max-file"] = str(log_max_file)
    if log_driver == "json-file":
        opts["compress"] = str(log_compress).lower()
    elif "compress" in opts and log_driver != "json-file":
        opts.pop("compress", None)
    data["log-opts"] = opts

    return json.dumps(data, indent=2, ensure_ascii=False)


def save_state(
    mirror: str,
    log_driver: str,
    log_max_size: str,
    log_max_file: str,
    log_compress: str,
    state_path: str | Path,
    daemon_path: str | Path,
) -> None:
    data = {
        "registry_mirror": mirror,
        "log_driver": log_driver,
        "log_max_size": log_max_size,
        "log_max_file": log_max_file,
        "log_compress": log_compress,
        "daemon_path": str(daemon_path),
        "updated_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
    }
    p = Path(state_path)
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text(json.dumps(data, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")


def format_state_status(state_path: str | Path) -> str:
    data = json.loads(Path(state_path).read_text(encoding="utf-8"))
    lines = [
        "  最近配置（tulan-tools 写入）:",
        f"    镜像加速:   {data.get('registry_mirror', '-')}",
        f"    日志驱动:   {data.get('log_driver', '-')}",
        f"    单文件大小: {data.get('log_max_size', '-')}",
        f"    保留份数:   {data.get('log_max_file', '-')}",
        f"    压缩日志:   {data.get('log_compress', '-')}",
        f"    更新时间:   {data.get('updated_at', '-')}",
    ]
    return "\n".join(lines)


DOCKER_BIN_NAMES = [
    "docker",
    "dockerd",
    "containerd",
    "runc",
    "ctr",
    "docker-init",
    "docker-proxy",
    "containerd-shim",
    "containerd-shim-runc-v2",
]


def uninstall_docker(version: str, reg_path: str | Path, home: str | Path) -> None:
    import shutil

    reg = Path(reg_path)
    home_p = Path(home)
    data = json.loads(reg.read_text(encoding="utf-8"))
    entry = data.get("docker")
    if not entry:
        raise SystemExit(2)

    versions = list(entry.get("versions", {}).keys())
    remove = [version] if version else versions
    for ver in remove:
        cellar = home_p / "cellar" / "docker" / ver
        if cellar.exists():
            shutil.rmtree(cellar)
        entry.get("versions", {}).pop(ver, None)

    remaining = list(entry.get("versions", {}).keys())
    if version and version != entry.get("active"):
        pass
    elif remaining:
        entry["active"] = sorted(remaining)[-1]
        ver = entry["active"]
        docker_root = Path(entry["versions"][ver]["docker_root"])
        for name in DOCKER_BIN_NAMES:
            if (docker_root / name).exists():
                link = home_p / "bin" / name
                link.parent.mkdir(parents=True, exist_ok=True)
                if link.exists() or link.is_symlink():
                    link.unlink()
                link.symlink_to(f"../cellar/docker/{ver}/docker/{name}")
    else:
        entry["active"] = ""
        for name in DOCKER_BIN_NAMES:
            link = home_p / "bin" / name
            if link.exists() or link.is_symlink():
                link.unlink()
        if not entry.get("versions"):
            data.pop("docker", None)

    reg.write_text(json.dumps(data, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
