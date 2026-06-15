"""Rancher 下游集群 kubeconfig 获取."""

from __future__ import annotations

import base64
import json
import os
import re
import ssl
import sys
import tempfile
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
    return [
        item
        for item in data.get("items") or []
        if cluster_matches_filter(item, cluster_filter, display)
    ]


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


def extract_config_from_response(payload: dict[str, Any]) -> str:
    config = (payload.get("config") or "").strip()
    if not config:
        raise RuntimeError(
            f"Rancher API 未返回 config 字段: {json.dumps(payload, ensure_ascii=False)[:300]}"
        )
    return config + "\n"


def extract_token_from_kubeconfig(text: str) -> str | None:
    for pat in (
        r"client-key-data:\s*\S+\s*\n\s*token:\s*['\"]?([^'\"#\s]+)",
        r"^\s*token:\s*['\"]?([^'\"#\s]+)",
    ):
        m = re.search(pat, text, re.M)
        if m:
            token = m.group(1).strip()
            if token:
                return token
    return None


def extract_client_cert_from_kubeconfig(text: str) -> tuple[bytes, bytes] | None:
    cert_m = re.search(r"client-certificate-data:\s*(\S+)", text)
    key_m = re.search(r"client-key-data:\s*(\S+)", text)
    if cert_m and key_m:
        return base64.b64decode(cert_m.group(1)), base64.b64decode(key_m.group(1))
    return None


def _ssl_context_with_client_cert(cert_pem: bytes, key_pem: bytes) -> ssl.SSLContext:
    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    with tempfile.NamedTemporaryFile("wb", delete=False) as cert_f, tempfile.NamedTemporaryFile(
        "wb", delete=False
    ) as key_f:
        cert_f.write(cert_pem)
        key_f.write(key_pem)
        cert_path, key_path = cert_f.name, key_f.name
    try:
        ctx.load_cert_chain(cert_path, key_path)
    finally:
        os.unlink(cert_path)
        os.unlink(key_path)
    return ctx


def _post_generate_kubeconfig(
    rancher_url: str,
    cluster_id: str,
    *,
    token: str | None = None,
    client_cert: tuple[bytes, bytes] | None = None,
    timeout: float = 30.0,
) -> dict[str, Any]:
    if cluster_id == "local":
        raise ValueError("local 集群请使用容器内 /etc/rancher/k3s/k3s.yaml")

    url = f"{rancher_url.rstrip('/')}/v3/clusters/{cluster_id}?action=generateKubeconfig"
    headers = {"Content-Type": "application/json"}
    if token:
        headers["Authorization"] = f"Bearer {token}"

    req = urllib.request.Request(url, data=b"{}", method="POST", headers=headers)

    if client_cert:
        ctx = _ssl_context_with_client_cert(client_cert[0], client_cert[1])
    else:
        ctx = ssl.create_default_context()
        ctx.check_hostname = False
        ctx.verify_mode = ssl.CERT_NONE

    try:
        with urllib.request.urlopen(req, context=ctx, timeout=timeout) as resp:
            return json.loads(resp.read().decode())
    except urllib.error.HTTPError as exc:
        body = exc.read().decode(errors="replace")
        raise RuntimeError(f"Rancher API HTTP {exc.code}: {body[:500]}") from exc
    except urllib.error.URLError as exc:
        raise RuntimeError(f"无法连接 Rancher API {rancher_url}: {exc}") from exc


def fetch_kubeconfig(
    rancher_url: str,
    token: str,
    cluster_id: str,
    *,
    timeout: float = 30.0,
) -> str:
    payload = _post_generate_kubeconfig(
        rancher_url, cluster_id, token=token, timeout=timeout
    )
    return extract_config_from_response(payload)


def fetch_kubeconfig_with_mgmt_kubeconfig(
    rancher_url: str,
    cluster_id: str,
    mgmt_kubeconfig: str,
    *,
    timeout: float = 30.0,
) -> str:
    errors: list[str] = []
    token = extract_token_from_kubeconfig(mgmt_kubeconfig)
    if token:
        try:
            return fetch_kubeconfig(rancher_url, token, cluster_id, timeout=timeout)
        except RuntimeError as exc:
            errors.append(f"token: {exc}")

    client_cert = extract_client_cert_from_kubeconfig(mgmt_kubeconfig)
    if client_cert:
        try:
            payload = _post_generate_kubeconfig(
                rancher_url,
                cluster_id,
                client_cert=client_cert,
                timeout=timeout,
            )
            return extract_config_from_response(payload)
        except RuntimeError as exc:
            errors.append(f"client-cert: {exc}")

    if errors:
        raise RuntimeError("; ".join(errors))
    raise RuntimeError(
        "管理集群 kubeconfig 中无 token 或 client-certificate-data，无法认证 Rancher API"
    )


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


def cmd_extract_config(argv: list[str]) -> int:
    payload = json.load(sys.stdin)
    sys.stdout.write(extract_config_from_response(payload))
    return 0


def cmd_kubeconfig(argv: list[str]) -> int:
    import argparse

    parser = argparse.ArgumentParser()
    parser.add_argument("--cluster", required=True)
    parser.add_argument("--rancher-url", required=True)
    parser.add_argument("--token", default="")
    parser.add_argument("--mgmt-kubeconfig-file", default="")
    parser.add_argument("--timeout", type=float, default=30.0)
    args = parser.parse_args(argv)

    data = json.load(sys.stdin)
    cluster_id = resolve_cluster_id(data, args.cluster)

    if args.mgmt_kubeconfig_file:
        mgmt = open(args.mgmt_kubeconfig_file, encoding="utf-8").read()
        config = fetch_kubeconfig_with_mgmt_kubeconfig(
            args.rancher_url, cluster_id, mgmt, timeout=args.timeout
        )
    elif args.token:
        config = fetch_kubeconfig(
            args.rancher_url, args.token, cluster_id, timeout=args.timeout
        )
    else:
        raise SystemExit("需要 --token 或 --mgmt-kubeconfig-file")

    sys.stdout.write(config)
    return 0
