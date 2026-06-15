"""JDK / Maven / Node 归档列表."""

from __future__ import annotations

import argparse
import json
from pathlib import Path


def _index_ver(tools: dict, tool: str, platform_key: str) -> str:
    info = tools.get(tool, {})
    ver = info.get("version", "") or ""
    path = (info.get("paths") or {}).get(platform_key, "") or ""
    if not path or not ver or ver == "上游最新":
        return "待同步"
    return ver


def _installed_text(registry: dict, tool: str) -> str:
    entry = registry.get(tool, {})
    active = entry.get("active", "")
    versions = sorted(entry.get("versions", {}).keys())
    if versions:
        return ", ".join(f"{v}{'*' if v == active else ''}" for v in versions)
    return ""


def _print_tool_row(tools: dict, registry: dict, platform_key: str, name: str, tool: str) -> None:
    idx = _index_ver(tools, tool, platform_key)
    inst = _installed_text(registry, tool)
    if inst:
        print(f"  {name:18s} 最新:{idx:16s} 已装:[{inst}]")
    else:
        print(f"  {name:18s} 最新:{idx:16s} 未安装")


def list_archive_tools(
    manifest_path: str | Path,
    reg_path: str | Path,
    java_state_path: str | Path,
    node_state_path: str | Path,
    platform_key: str,
    section: str = "all",
) -> None:
    tools = json.loads(Path(manifest_path).read_text(encoding="utf-8")).get("tools", {})
    reg_file = Path(reg_path)
    registry = json.loads(reg_file.read_text(encoding="utf-8")) if reg_file.exists() else {}

    if section in ("all", "java"):
        print("Java / Maven（bin 索引 / 上游）:")
        print("────────────────────────────────────")
        for major in ("8", "11", "17"):
            tool = f"openjdk-{major}"
            _print_tool_row(tools, registry, platform_key, f"openjdk-{major}", tool)
        java_state = Path(java_state_path)
        if java_state.exists():
            state = json.loads(java_state.read_text(encoding="utf-8"))
            am = state.get("active_major", "")
            if am:
                print(f"  JAVA_HOME 当前: Java {am} -> {state.get('java_home', '')}")
        _print_tool_row(tools, registry, platform_key, "maven", "maven")

    if section in ("all", "node"):
        if section == "all":
            print()
        print("Node.js（bin 索引 / 上游）:")
        print("────────────────────────────────────")
        for major in ("16", "18", "20", "22", "24"):
            tool = f"node-{major}"
            _print_tool_row(tools, registry, platform_key, f"node-{major}", tool)
        node_state = Path(node_state_path)
        if node_state.exists():
            state = json.loads(node_state.read_text(encoding="utf-8"))
            am = state.get("active_major", "")
            if am:
                print(f"  NODE_HOME 当前: Node {am} -> {state.get('node_home', '')}")


def uninstall_maven(version: str, reg_path: str | Path, home: str | Path) -> None:
    import shutil

    reg = Path(reg_path)
    home_p = Path(home)
    data = json.loads(reg.read_text(encoding="utf-8"))
    entry = data.get("maven")
    if not entry:
        raise SystemExit(2)

    remove = [version] if version else list(entry.get("versions", {}).keys())
    for ver in remove:
        cellar = home_p / "cellar" / "maven" / ver
        if cellar.exists():
            shutil.rmtree(cellar)
        entry.get("versions", {}).pop(ver, None)

    link = home_p / "bin" / "mvn"
    if not entry.get("versions"):
        data.pop("maven", None)
        if link.exists() or link.is_symlink():
            link.unlink()
    else:
        entry["active"] = sorted(entry["versions"].keys())[-1]
        ver = entry["active"]
        if entry["versions"][ver].get("maven_home"):
            rel = f"../cellar/maven/{ver}/apache-maven-{ver}/bin/mvn"
            link.parent.mkdir(parents=True, exist_ok=True)
            if link.exists() or link.is_symlink():
                link.unlink()
            link.symlink_to(rel)

    reg.write_text(json.dumps(data, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")


def cmd_list(argv: list[str]) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("manifest", type=Path)
    parser.add_argument("--reg-path", required=True)
    parser.add_argument("--java-state", required=True)
    parser.add_argument("--node-state", required=True)
    parser.add_argument("--platform-key", required=True)
    parser.add_argument("--section", default="all", choices=("all", "java", "node"))
    args = parser.parse_args(argv)
    list_archive_tools(
        args.manifest,
        args.reg_path,
        args.java_state,
        args.node_state,
        args.platform_key,
        args.section,
    )
    return 0


def cmd_uninstall_maven(argv: list[str]) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--version", default="")
    parser.add_argument("--reg-path", required=True)
    parser.add_argument("--home", required=True)
    args = parser.parse_args(argv)
    try:
        uninstall_maven(args.version, args.reg_path, args.home)
    except SystemExit as exc:
        return int(exc.code) if exc.code else 1
    return 0
