"""Rancher 下游集群 kubeconfig 获取."""

from __future__ import annotations

import json
import ssl
import sys
import urllib.error
import urllib.request
from typing import Any

from .register import cluster_display_map


def _cluster_label(item: dict[str, Any], display: dict[str, str]) -> str:
    cid = item["metadata"]["name"]
    dname = ((item.get("spec") or {}).get("displayName") or "").strip()
    if dname and dname != cid:
        return f"{cid} (UI: {dname})"
    return cid


def _cluster_state(item: dict[str, Any]) -> str:
    for path in (
        ("status", "conditions"),
        ("status", "summary"),
    ):
        cur: Any = item
        for key in path:
            cur = cur.get(key) if isinstance(cur, dict) else None
        if isinstance(cur, list):
            for cond in cur:
                if cond.get("type") == "Ready" and cond.get("status"):
                    return f"Ready={cond['status']}"
    phase = (item.get("status") or {}).get("phase") or ""
    return str(phase or "unknown")


def cluster_matches_filter(item: dict[str, Any], cluster_filter: str, display: dict[str, str]) -> bool:
    if not cluster_filter:
        return True
    cid = item["metadata"]["name"]
    dname = ((item.get("spec") or {}).get("displayName") or "").strip()
    return cluster_filter in (cid, dname)


def find_clusters(data: dict[str, Any], cluster_filter: str) -> list[dict[str, Any]]:
    display = cluster_display_map(data)
    matches = [
        item
        for item in data.get("items") or []
        if cluster_matches_filter(item, cluster_filter, display)
    ]
    return matches


def resolve_cluster_id(data: dict[str, Any], cluster_filter: str) -> str:
    matches = find_clusters(data, cluster_filter)
    if not matches:
        raise ValueError(f"未找到集群: {cluster_filter}")
    if len(matches) > 1:
        labels = [_cluster_label(item, cluster_display_map(data)) for item in matches]
        raise ValueError(f"集群名「{cluster_filter}」匹配多个: {', '.join(labels)}")
    return matches[0]["metadata"]["name"]


def list_clusters(data: dict[str, Any]) -> None:
    items = data.get("items") or []
    if not items:
        print("  (无下游集群)")
        return
    display = cluster_display_map(data)
    for item in items:
        cid = item["metadata"]["name"]
        dname = ((item.get("spec") or {}).get("displayName") or "").strip()
        label = dname or cid
        state = _cluster_state(item)
        extra = ""
        if cid == "local":
            extra = " [Rancher 内置 local 集群，kubeconfig 即 k3s.yaml]"
        print(f"  {label}\tid={cid}\t{state}{extra}")


def fetch_kubeconfig(rancher_url: str, token: str, cluster_id: str, *, timeout: float = 30.0) -> str:
    if cluster_id == "local":
        raise ValueError("local 集群请使用容器内 /etc/rancher/k3s/k3s.yaml")

    url = f"{rancher_url.rstrip('/')}/v3/clusters/{cluster_id}?action=generateKubeconfig"
    req = urllib.request.Request(
        url,
        data=b"{}",
        method="POST",
        headers={
            "Authorization": f"Bearer {token}",
            "Content-Type": "application/json",
        },
    )
    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    try:
        with urllib.request.urlopen(req, context=ctx, timeout=timeout) as resp:
            payload = json.loads(resp.read().decode())
    except urllib.error.HTTPError as exc:
        body = exc.read().decode(errors="replace")
        raise RuntimeError(f"Rancher API HTTP {exc.code}: {body[:500]}") from exc
    except urllib.error.URLError as exc:
        raise RuntimeError(f"无法连接 Rancher API {rancher_url}: {exc}") from exc

    config = (payload.get("config") or "").strip()
    if not config:
        raise RuntimeError(f"Rancher API 未返回 config 字段: {json.dumps(payload, ensure_ascii=False)[:300]}")
    return config + "\n"


def cmd_list_clusters(argv: list[str]) -> int:
    data = json.load(sys.stdin)
    list_clusters(data)
    return 0


def cmd_resolve_cluster(argv: list[str]) -> int:
    import argparse

    parser = argparse.ArgumentParser()
    parser.add_argument("--cluster", required=True)
    args = parser.parse_args(argv)
    data = json.load(sys.stdin)
    print(resolve_cluster_id(data, args.cluster))
    return 0


def cmd_kubeconfig(argv: list[str]) -> int:
    import argparse

    parser = argparse.ArgumentParser()
    parser.add_argument("--cluster", required=True)
    parser.add_argument("--rancher-url", required=True)
    parser.add_argument("--token", required=True)
    parser.add_argument("--timeout", type=float, default=30.0)
    args = parser.parse_args(argv)

    data = json.load(sys.stdin)
    cluster_id = resolve_cluster_id(data, args.cluster)
    config = fetch_kubeconfig(args.rancher_url, args.token, cluster_id, timeout=args.timeout)
    sys.stdout.write(config)
    return 0
