"""Rancher 管理员密码：Bootstrap / 设置 / 重置."""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
from typing import Sequence


def _euid() -> int:
    return os.geteuid()


def _has_tty() -> bool:
    return sys.stdin.isatty() and sys.stdout.isatty()


def _run_docker(args: list[str], *, input_text: str | None = None) -> subprocess.CompletedProcess[str]:
    cmd = ["docker", *args]
    if _euid() != 0 and _which("sudo"):
        cmd = ["sudo", *cmd]
    return subprocess.run(
        cmd,
        input=input_text,
        capture_output=True,
        text=True,
        check=False,
    )


def _which(name: str) -> str | None:
    from shutil import which

    return which(name)


def require_container(name: str) -> None:
    if not _which("docker"):
        print("未检测到 docker 命令。", file=sys.stderr)
        raise SystemExit(1)
    proc = _run_docker(["ps", "--format", "{{.Names}}"])
    names = proc.stdout.splitlines() if proc.returncode == 0 else []
    if name not in names:
        print(f"Rancher 容器未运行: {name}", file=sys.stderr)
        raise SystemExit(1)


def rancher_kubectl(container: str, kubeconfig: str, args: list[str]) -> subprocess.CompletedProcess[str]:
    return _run_docker(
        ["exec", "-i", container, "kubectl", "--kubeconfig", kubeconfig, *args],
    )


def bcrypt_hash_password(password: str, container: str) -> str:
    # 1) python bcrypt
    try:
        import bcrypt  # type: ignore[import-untyped]

        return bcrypt.hashpw(password.encode(), bcrypt.gensalt(rounds=10)).decode()
    except ImportError:
        pass

    # 2) htpasswd on host
    if _which("htpasswd"):
        proc = subprocess.run(
            ["htpasswd", "-bnBC", "10", "", password],
            capture_output=True,
            text=True,
            check=False,
        )
        if proc.returncode == 0:
            h = proc.stdout.strip().lstrip(":")
            if h.startswith("$2"):
                return h

    # 3) htpasswd in container
    proc = _run_docker(
        ["exec", "-i", container, "sh", "-c",
         'read -r p; command -v htpasswd >/dev/null || exit 2; '
         'htpasswd -bnBC 10 "" "$p" | tr -d "\\n\\r" | sed "s/^://"'],
        input_text=password,
    )
    if proc.returncode == 0:
        h = proc.stdout.strip()
        if h.startswith("$2"):
            return h

    print("无法生成 bcrypt 哈希。请在 master 安装其一:", file=sys.stderr)
    print("  apt install apache2-utils    # 提供 htpasswd", file=sys.stderr)
    print("  pip3 install bcrypt", file=sys.stderr)
    raise SystemExit(1)


def build_password_patch_json(password_hash: str) -> str:
    return json.dumps({"password": password_hash, "mustChangePassword": False})


def find_bootstrap_admin_user(container: str, kubeconfig: str) -> str:
    proc = rancher_kubectl(
        container,
        kubeconfig,
        [
            "get",
            "users.management.cattle.io",
            "-l",
            "authz.management.cattle.io/bootstrapping=admin-user",
            "-o",
            "jsonpath={.items[0].metadata.name}",
        ],
    )
    name = proc.stdout.strip() if proc.returncode == 0 else ""
    if name:
        return name
    proc = rancher_kubectl(
        container,
        kubeconfig,
        [
            "get",
            "users.management.cattle.io",
            "-o",
            "jsonpath={range .items[?(@.username==\"admin\")]}{.metadata.name}{end}",
        ],
    )
    return proc.stdout.strip() if proc.returncode == 0 else ""


def get_bootstrap_password(container: str) -> int:
    proc = _run_docker(["logs", container])
    output = (proc.stdout or "") + (proc.stderr or "")
    matches = re.findall(r"Bootstrap Password:\s*(\S+)", output)
    if matches:
        print(f"初始密码（Bootstrap Password）：{matches[-1]}")
        return 0
    print("未在日志中找到 Bootstrap Password。")
    print("可尝试：")
    print(f"  1) docker logs {container} | tail -n 100")
    print("  2) brew k8s password --reset")
    print("  3) brew k8s password --set '你的密码' -y")
    return 2


def confirm_set_password(assume_yes: bool) -> None:
    if assume_yes:
        return
    if not _has_tty():
        print("当前无交互终端，请使用 -y 跳过确认: brew k8s password --set '密码' -y", file=sys.stderr)
        raise SystemExit(1)
    confirm = input("\n将把 Rancher 管理员密码设置为指定值。确认继续? [y/N]: ").strip()
    if confirm.lower() != "y":
        print("已取消")
        raise SystemExit(0)


def set_admin_password(
    password: str,
    container: str,
    kubeconfig: str,
    assume_yes: bool,
) -> int:
    if not password:
        print("请提供密码: brew k8s password --set 'YourPassword'", file=sys.stderr)
        return 1
    if len(password) < 8:
        print("密码至少 8 位（Rancher 要求）。", file=sys.stderr)
        return 1
    confirm_set_password(assume_yes)

    admin_name = find_bootstrap_admin_user(container, kubeconfig)
    if not admin_name:
        print("未找到 bootstrap 管理员用户。", file=sys.stderr)
        print(f"可尝试: docker exec -it {container} ensure-default-admin", file=sys.stderr)
        return 1

    print(f"正在设置 Rancher 管理员密码（用户: {admin_name}）...")
    pwd_hash = bcrypt_hash_password(password, container)
    patch_json = build_password_patch_json(pwd_hash)
    proc = rancher_kubectl(
        container,
        kubeconfig,
        ["patch", f"users.management.cattle.io/{admin_name}", "--type=merge", "-p", patch_json],
    )
    if proc.returncode != 0:
        print("kubectl patch 失败，请检查 Rancher 容器内 kubectl 与 kubeconfig。", file=sys.stderr)
        if proc.stderr:
            print(proc.stderr, file=sys.stderr)
        return 1

    proc = rancher_kubectl(
        container,
        kubeconfig,
        ["get", f"users.management.cattle.io/{admin_name}", "-o", "jsonpath={.username}"],
    )
    username = proc.stdout.strip() if proc.returncode == 0 else ""
    print()
    print("管理员密码已设置为指定值。")
    print(f"登录用户名: {username or 'admin'}")
    return 0


def reset_password_random(container: str) -> int:
    print("Rancher reset-password 将生成随机密码（不支持自行指定）...")
    proc = _run_docker(["exec", "-i", container, "reset-password"])
    output = (proc.stdout or "") + (proc.stderr or "")
    if proc.returncode != 0:
        print(output, file=sys.stderr)
        return proc.returncode
    print(output, end="" if output.endswith("\n") else "\n")

    admin_hint = ""
    for line in output.splitlines():
        m = re.match(r"^New password for default admin user \((.*)\):$", line)
        if m:
            admin_hint = m.group(1)

    new_pass = ""
    for line in output.splitlines():
        if not line.strip():
            continue
        if line.startswith("New password for default admin user"):
            continue
        if re.match(r"^W[0-9]", line):
            continue
        new_pass = line.strip()

    if new_pass:
        print()
        print(f"新随机密码: {new_pass}")
        if admin_hint:
            print(f"用户 ID: {admin_hint}（登录名见 Rancher UI 或 users 资源 .username 字段）")
        print("请保存并用于 Rancher UI 登录。")
    return 0


def cmd_password(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Rancher 管理员密码：Bootstrap / 设置 / 重置",
    )
    parser.add_argument("--set", dest="set_password", metavar="密码", default="")
    parser.add_argument("--reset", action="store_true")
    parser.add_argument("-y", "--yes", action="store_true")
    parser.add_argument("--container", default=os.environ.get("CONTAINER_NAME", "rancher"))
    parser.add_argument(
        "--kubeconfig",
        default=os.environ.get("RANCHER_KUBECONFIG", "/etc/rancher/k3s/k3s.yaml"),
    )
    args = parser.parse_args(list(argv) if argv is not None else None)

    assume_yes = args.yes or os.environ.get("PASSWORD_ASSUME_YES", "false").lower() == "true"
    container = args.container
    kubeconfig = args.kubeconfig

    require_container(container)

    if args.set_password:
        return set_admin_password(args.set_password, container, kubeconfig, assume_yes)
    if args.reset:
        return reset_password_random(container)
    return get_bootstrap_password(container)
