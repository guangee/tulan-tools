"""Rancher 节点注册命令（内网地址替换）."""

from __future__ import annotations

import json
import re
import sys
from typing import Any

_TOKEN_FIELDS = [
    ("insecureNodeCommand", "节点注册（自签证书，推荐）"),
    ("nodeCommand", "节点注册"),
    ("insecureCommand", "集群导入（自签证书）"),
    ("command", "集群导入"),
    ("insecureWindowsNodeCommand", "Windows 节点（自签）"),
    ("windowsNodeCommand", "Windows 节点"),
]


def cluster_display_map(clusters_json: str | dict[str, Any]) -> dict[str, str]:
    if isinstance(clusters_json, str):
        try:
            data = json.loads(clusters_json)
        except json.JSONDecodeError:
            return {}
    else:
        data = clusters_json
    out: dict[str, str] = {}
    for item in data.get("items") or []:
        cid = (item.get("metadata") or {}).get("name") or ""
        dname = ((item.get("spec") or {}).get("displayName") or "").strip()
        if cid:
            out[cid] = dname or cid
    return out


def _cluster_match(
    cluster_filter: str,
    cluster: str,
    ns: str,
    name: str,
    display: dict[str, str],
) -> bool:
    if not cluster_filter:
        return True
    keys = {cluster_filter, cluster, ns, name}
    for cid, dname in display.items():
        if cluster_filter in (cid, dname):
            keys.update({cid, dname})
    targets = {cluster, ns, name}
    return bool(keys & targets)


def list_registration_clusters(
    tokens_json: dict[str, Any],
    display: dict[str, str],
) -> None:
    items = tokens_json.get("items") or []
    if not items:
        print("  (无任何 ClusterRegistrationToken，请先在 UI 创建/导入集群)")
        return
    seen: set[tuple[str, str, str]] = set()
    for item in items:
        ns = item["metadata"]["namespace"]
        name = item["metadata"]["name"]
        cluster = item.get("spec", {}).get("clusterName") or ns
        key = (ns, name, cluster)
        if key in seen:
            continue
        seen.add(key)
        dname = display.get(cluster) or display.get(ns) or ""
        label = f"{cluster}"
        if dname and dname != cluster:
            label = f"{cluster} (UI: {dname})"
        if cluster == "local" or ns == "local":
            label += " [Rancher 内置 local 集群]"
        status = item.get("status") or {}
        ready = (
            "有命令"
            if any(status.get(f) for f in ("insecureNodeCommand", "nodeCommand", "insecureCommand", "command"))
            else "无命令"
        )
        hint = " ← worker 用这个" if name == "default-token" and cluster != "local" else ""
        print(f"  {label}  token={name}  ({ready}){hint}")


def tokens_to_delete(
    tokens_json: dict[str, Any],
    cluster_filter: str,
    display: dict[str, str],
) -> list[tuple[str, str]]:
    out: list[tuple[str, str]] = []
    for item in tokens_json.get("items", []):
        ns = item["metadata"]["namespace"]
        name = item["metadata"]["name"]
        cluster = item.get("spec", {}).get("clusterName") or ns
        if not _cluster_match(cluster_filter, cluster, ns, name, display):
            continue
        out.append((ns, name))
    return out


def _rewrite_command(
    text: str,
    lan: str,
    replacements: list[str],
    domain: str,
) -> str:
    if not text:
        return text
    out = text
    for u in replacements:
        out = out.replace(u, lan)
    if domain:
        out = re.sub(rf"https://{re.escape(domain)}(?=[/:?'\s\"]|$)", lan, out)
    return out


def _build_replacements(
    lan: str,
    public: str,
    current: str,
    extra: str,
    domain: str,
    port: str,
) -> list[str]:
    replacements: list[str] = []
    candidates = [
        public,
        current,
        extra,
        f"https://{domain}:{port}" if domain and port else "",
        f"https://{domain}" if domain else "",
    ]
    for u in candidates:
        u = (u or "").rstrip("/")
        if u and u != lan and u not in replacements:
            replacements.append(u)
    return replacements


def _display_label(cluster_id: str, display: dict[str, str]) -> str:
    dname = display.get(cluster_id) or ""
    if dname and dname != cluster_id:
        return f"{cluster_id} (UI: {dname})"
    return cluster_id


def build_register_results(
    tokens_json: dict[str, Any],
    display: dict[str, str],
    cluster_filter: str,
    lan: str,
    public: str,
    current: str,
    domain: str,
    port: str,
    extra: str,
) -> list[dict[str, Any]]:
    lan = lan.rstrip("/")
    replacements = _build_replacements(lan, public, current, extra, domain, port)
    results: list[dict[str, Any]] = []
    seen: set[tuple[str, str, str]] = set()

    for item in tokens_json.get("items", []):
        ns = item["metadata"]["namespace"]
        name = item["metadata"]["name"]
        cluster = item.get("spec", {}).get("clusterName") or ns
        if not _cluster_match(cluster_filter, cluster, ns, name, display):
            continue
        if name == "system" and cluster_filter:
            has_default = any(
                (it.get("spec", {}).get("clusterName") or it["metadata"]["namespace"]) == cluster
                and it["metadata"]["name"] == "default-token"
                for it in tokens_json.get("items", [])
            )
            if has_default:
                continue
        status = item.get("status") or {}
        for field, label in _TOKEN_FIELDS:
            raw = (status.get(field) or "").strip()
            if not raw:
                continue
            fixed = _rewrite_command(raw, lan, replacements, domain)
            key = (cluster, field, fixed)
            if key in seen:
                continue
            seen.add(key)
            results.append(
                {
                    "cluster": cluster,
                    "cluster_label": _display_label(cluster, display),
                    "namespace": ns,
                    "token": name,
                    "field": field,
                    "label": label,
                    "raw": raw,
                    "command": fixed,
                    "rewritten": raw != fixed,
                }
            )
    return results


def print_register_command(
    tokens_json: dict[str, Any],
    display: dict[str, str],
    cluster_filter: str,
    lan: str,
    public: str,
    current: str,
    domain: str,
    port: str,
    extra: str,
    fmt: str,
) -> int:
    results = build_register_results(
        tokens_json, display, cluster_filter, lan, public, current, domain, port, extra
    )
    if not results:
        print("NO_TOKENS", file=sys.stderr)
        return 2

    if fmt == "json":
        print(json.dumps(results, ensure_ascii=False, indent=2))
        return 0

    if fmt == "command":
        for prefer in ("insecureNodeCommand", "nodeCommand", "insecureCommand", "command"):
            for r in results:
                if r["field"] == prefer:
                    print(r["command"])
                    return 0
        print(results[0]["command"])
        return 0

    print("Rancher 节点注册命令（已替换为内网地址）")
    print(f"内网 server: {lan.rstrip('/')}")
    if current and current.rstrip("/") != lan.rstrip("/"):
        print(f"说明: UI 可能仍显示 {current}，因 token 创建时写入了外网域名")
    print("────────────────────────────────────")
    for r in results:
        print(f"集群: {r['cluster_label']} — {r['label']} (token: {r['token']})")
        if r["rewritten"]:
            print(f"  原 UI 命令: {r['raw']}")
            print(f"  内网命令:   {r['command']}")
        else:
            print(f"  {r['command']}")
        print()
    return 0


def cmd_cluster_display(argv: list[str]) -> int:
    data = json.load(sys.stdin)
    print(json.dumps(cluster_display_map(data), ensure_ascii=False))
    return 0


def cmd_list_tokens(argv: list[str]) -> int:
    import argparse

    parser = argparse.ArgumentParser()
    parser.add_argument("--display-json", default="{}")
    args = parser.parse_args(argv)
    tokens = json.load(sys.stdin)
    display = json.loads(args.display_json or "{}")
    list_registration_clusters(tokens, display)
    return 0


def cmd_tokens_delete(argv: list[str]) -> int:
    import argparse

    parser = argparse.ArgumentParser()
    parser.add_argument("--cluster", default="")
    parser.add_argument("--display-json", default="{}")
    args = parser.parse_args(argv)
    tokens = json.load(sys.stdin)
    display = json.loads(args.display_json or "{}")
    for ns, name in tokens_to_delete(tokens, args.cluster, display):
        print(f"{ns}\t{name}")
    return 0


def cmd_register_command(argv: list[str]) -> int:
    import argparse

    parser = argparse.ArgumentParser()
    parser.add_argument("--display-json", default="{}")
    parser.add_argument("--cluster", default="")
    parser.add_argument("--lan", required=True)
    parser.add_argument("--public", default="")
    parser.add_argument("--current", default="")
    parser.add_argument("--domain", default="")
    parser.add_argument("--port", default="")
    parser.add_argument("--extra-from", default="")
    parser.add_argument("--format", default="text", choices=("text", "json", "command"))
    args = parser.parse_args(argv)

    tokens = json.load(sys.stdin)
    display = json.loads(args.display_json or "{}")
    return print_register_command(
        tokens,
        display,
        args.cluster,
        args.lan,
        args.public,
        args.current,
        args.domain,
        args.port,
        args.extra_from,
        args.format,
    )
