"""Cellar 二进制注册表（state/binaries/registry.json）."""

from __future__ import annotations

import json
import os
import shutil
import sys
import time
from pathlib import Path
from typing import Any


def _load(reg_path: Path) -> dict[str, Any]:
    if reg_path.exists():
        return json.loads(reg_path.read_text(encoding="utf-8"))
    return {}


def _save(reg_path: Path, data: dict[str, Any]) -> None:
    reg_path.parent.mkdir(parents=True, exist_ok=True)
    reg_path.write_text(json.dumps(data, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")


def register(
    tool: str,
    version: str,
    install_name: str,
    source: str,
    activate: bool,
    reg_path: str | Path,
    extra: dict[str, Any] | None = None,
) -> None:
    reg = Path(reg_path)
    data = _load(reg)
    entry = data.setdefault(tool, {"install_name": install_name, "active": "", "versions": {}})
    entry["install_name"] = install_name
    version_info: dict[str, Any] = {
        "source": source,
        "installed_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
    }
    if extra:
        version_info.update(extra)
    elif "cellar" not in version_info:
        version_info["cellar"] = f"cellar/{tool}/{version}/{install_name}"
    entry["versions"][version] = version_info
    if activate:
        entry["active"] = version
    _save(reg, data)


def activate(tool: str, version: str, reg_path: str | Path) -> None:
    reg = Path(reg_path)
    data = _load(reg)
    if tool not in data or version not in data[tool].get("versions", {}):
        raise SystemExit(1)
    data[tool]["active"] = version
    _save(reg, data)


def install_name(tool: str, reg_path: str | Path) -> str:
    data = _load(Path(reg_path))
    return str(data.get(tool, {}).get("install_name", tool))


def active_version(tool: str, reg_path: str | Path) -> str:
    data = _load(Path(reg_path))
    return str(data.get(tool, {}).get("active", "") or "")


def version_field(tool: str, version: str, reg_path: str | Path, field: str) -> str:
    data = _load(Path(reg_path))
    ver = (data.get(tool, {}).get("versions") or {}).get(version) or {}
    val = ver.get(field, "")
    return "" if val is None else str(val)


def uninstall(tool: str, version: str, reg_path: str | Path, home: str | Path) -> str:
    reg = Path(reg_path)
    home_p = Path(home)
    if not reg.exists():
        raise SystemExit(2)
    data = _load(reg)
    entry = data.get(tool)
    if not entry:
        raise SystemExit(2)
    install = entry.get("install_name", tool)
    versions = list(entry.get("versions", {}).keys())
    remove = [version] if version else versions
    for ver in remove:
        cellar = home_p / "cellar" / tool / ver
        if cellar.exists():
            shutil.rmtree(cellar)
        entry.get("versions", {}).pop(ver, None)
    remaining = list(entry.get("versions", {}).keys())
    link = home_p / "bin" / install
    if version and version != entry.get("active"):
        pass
    elif remaining:
        entry["active"] = sorted(remaining)[-1]
        ver = entry["active"]
        rel = f"../cellar/{tool}/{ver}/{install}"
        link.parent.mkdir(parents=True, exist_ok=True)
        if link.exists() or link.is_symlink():
            link.unlink()
        link.symlink_to(rel)
    else:
        entry["active"] = ""
        if link.exists() or link.is_symlink():
            link.unlink()
        if not entry.get("versions"):
            data.pop(tool, None)
    if not remaining and not version:
        data.pop(tool, None)
    _save(reg, data)
    return str(install)


def list_binaries(
    manifest_path: str | Path,
    reg_path: str | Path,
    bin_dir: str | Path,
    installed_only: bool,
) -> None:
    with open(manifest_path, encoding="utf-8") as f:
        manifest = json.load(f)
    registry = _load(Path(reg_path))
    found = False
    for tool, info in manifest.get("tools", {}).items():
        if tool != "docker" and (
            info.get("artifact_type") == "archive"
            or tool.startswith("openjdk-")
            or tool.startswith("node-")
            or tool == "maven"
        ):
            continue
        inst_name = info.get("install_name", tool)
        index_ver = info.get("version", "") or "待同步"
        reg = registry.get(tool, {})
        active = reg.get("active", "")
        versions = sorted(reg.get("versions", {}).keys())
        linked = os.path.join(str(bin_dir), inst_name)
        is_linked = os.path.islink(linked) or (os.path.isfile(linked) and os.access(linked, os.X_OK))
        if installed_only and not versions and not is_linked:
            continue
        found = True
        if versions:
            ver_text = ", ".join(f"{v}{'*' if v == active else ''}" for v in versions)
            print(f"  {inst_name:18s} 最新:{index_ver:<12} 已装:[{ver_text}]")
        else:
            status = "已安装" if is_linked else "未安装"
            print(f"  {inst_name:18s} 最新:{index_ver:<12} {status}")
    if not found:
        print("  (无)" if installed_only else "  (manifest 中无工具定义)")


def installed_tools(reg_path: str | Path) -> list[str]:
    data = _load(Path(reg_path))
    return sorted(data.keys())


def cmd_register(argv: list[str]) -> int:
    import argparse

    parser = argparse.ArgumentParser()
    parser.add_argument("--tool", required=True)
    parser.add_argument("--version", required=True)
    parser.add_argument("--install-name", required=True)
    parser.add_argument("--source", required=True)
    parser.add_argument("--activate", choices=("true", "false"), default="true")
    parser.add_argument("--reg-path", required=True)
    parser.add_argument("--extra-json", default="{}")
    args = parser.parse_args(argv)
    extra = json.loads(args.extra_json)
    register(
        args.tool,
        args.version,
        args.install_name,
        args.source,
        args.activate == "true",
        args.reg_path,
        extra or None,
    )
    return 0


def cmd_activate(argv: list[str]) -> int:
    import argparse

    parser = argparse.ArgumentParser()
    parser.add_argument("--tool", required=True)
    parser.add_argument("--version", required=True)
    parser.add_argument("--reg-path", required=True)
    args = parser.parse_args(argv)
    try:
        activate(args.tool, args.version, args.reg_path)
    except SystemExit:
        return 1
    return 0


def cmd_install_name(argv: list[str]) -> int:
    import argparse

    parser = argparse.ArgumentParser()
    parser.add_argument("--tool", required=True)
    parser.add_argument("--reg-path", required=True)
    args = parser.parse_args(argv)
    print(install_name(args.tool, args.reg_path))
    return 0


def cmd_active_version(argv: list[str]) -> int:
    import argparse

    parser = argparse.ArgumentParser()
    parser.add_argument("--tool", required=True)
    parser.add_argument("--reg-path", required=True)
    args = parser.parse_args(argv)
    print(active_version(args.tool, args.reg_path))
    return 0


def cmd_version_field(argv: list[str]) -> int:
    import argparse

    parser = argparse.ArgumentParser()
    parser.add_argument("--tool", required=True)
    parser.add_argument("--version", required=True)
    parser.add_argument("--field", required=True)
    parser.add_argument("--reg-path", required=True)
    args = parser.parse_args(argv)
    print(version_field(args.tool, args.version, args.reg_path, args.field))
    return 0


def cmd_uninstall(argv: list[str]) -> int:
    import argparse

    parser = argparse.ArgumentParser()
    parser.add_argument("--tool", required=True)
    parser.add_argument("--version", default="")
    parser.add_argument("--reg-path", required=True)
    parser.add_argument("--home", required=True)
    args = parser.parse_args(argv)
    try:
        print(uninstall(args.tool, args.version, args.reg_path, args.home))
    except SystemExit as exc:
        return int(exc.code) if exc.code else 1
    return 0


def cmd_list(argv: list[str]) -> int:
    import argparse

    parser = argparse.ArgumentParser()
    parser.add_argument("manifest", type=Path)
    parser.add_argument("--reg-path", required=True)
    parser.add_argument("--bin-dir", required=True)
    parser.add_argument("--installed-only", choices=("true", "false"), default="false")
    args = parser.parse_args(argv)
    list_binaries(args.manifest, args.reg_path, args.bin_dir, args.installed_only == "true")
    return 0


def versions_display(tool: str, reg_path: str | Path) -> str:
    data = _load(Path(reg_path))
    entry = data.get(tool, {})
    active = entry.get("active", "")
    versions = sorted(entry.get("versions", {}).keys())
    if versions:
        return ", ".join(f"{v}{'*' if v == active else ''}" for v in versions)
    return ""


def cmd_versions_display(argv: list[str]) -> int:
    import argparse

    parser = argparse.ArgumentParser()
    parser.add_argument("--tool", required=True)
    parser.add_argument("--reg-path", required=True)
    args = parser.parse_args(argv)
    print(versions_display(args.tool, args.reg_path))
    return 0


def cmd_installed(argv: list[str]) -> int:
    import argparse

    parser = argparse.ArgumentParser()
    parser.add_argument("--tool", required=True)
    parser.add_argument("--reg-path", required=True)
    args = parser.parse_args(argv)
    tools = installed_tools(args.reg_path)
    print("yes" if args.tool in tools else "no")
    return 0
