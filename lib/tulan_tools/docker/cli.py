"""Docker 模块 CLI."""

from __future__ import annotations

import argparse
import sys

from . import daemon, upstream


def cmd_latest(_argv: list[str]) -> int:
    try:
        print(upstream.latest_version())
    except RuntimeError as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 1
    return 0


def cmd_recent(argv: list[str]) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--count", type=int, default=8)
    args = parser.parse_args(argv)
    try:
        print(upstream.recent_versions(args.count))
    except RuntimeError as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 1
    return 0


def cmd_load_defaults(argv: list[str]) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("defaults_file")
    args = parser.parse_args(argv)
    print(daemon.load_defaults_exports(args.defaults_file))
    return 0


def cmd_build_daemon(argv: list[str]) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--mirror", required=True)
    parser.add_argument("--log-driver", required=True)
    parser.add_argument("--log-max-size", required=True)
    parser.add_argument("--log-max-file", required=True)
    parser.add_argument("--log-compress", required=True)
    parser.add_argument("--daemon-path", required=True)
    args = parser.parse_args(argv)
    print(
        daemon.build_daemon_json(
            args.mirror,
            args.log_driver,
            args.log_max_size,
            args.log_max_file,
            args.log_compress,
            args.daemon_path,
        )
    )
    return 0


def cmd_save_state(argv: list[str]) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--mirror", required=True)
    parser.add_argument("--log-driver", required=True)
    parser.add_argument("--log-max-size", required=True)
    parser.add_argument("--log-max-file", required=True)
    parser.add_argument("--log-compress", required=True)
    parser.add_argument("--state-path", required=True)
    parser.add_argument("--daemon-path", required=True)
    args = parser.parse_args(argv)
    daemon.save_state(
        args.mirror,
        args.log_driver,
        args.log_max_size,
        args.log_max_file,
        args.log_compress,
        args.state_path,
        args.daemon_path,
    )
    return 0


def cmd_show_state(argv: list[str]) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("state_file")
    args = parser.parse_args(argv)
    print(daemon.format_state_status(args.state_file))
    return 0


def cmd_uninstall(argv: list[str]) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--version", default="")
    parser.add_argument("--reg-path", required=True)
    parser.add_argument("--home", required=True)
    args = parser.parse_args(argv)
    try:
        daemon.uninstall_docker(args.version, args.reg_path, args.home)
    except SystemExit as exc:
        return int(exc.code) if exc.code else 1
    return 0


def cmd_register(argv: list[str]) -> int:
    from ..registry import register

    parser = argparse.ArgumentParser()
    parser.add_argument("--version", required=True)
    parser.add_argument("--docker-dir", required=True)
    parser.add_argument("--source", default="upstream")
    parser.add_argument("--reg-path", required=True)
    args = parser.parse_args(argv)
    register(
        "docker",
        args.version,
        "docker",
        args.source,
        True,
        args.reg_path,
        {"docker_root": args.docker_dir},
    )
    return 0


def cmd_docker_root(argv: list[str]) -> int:
    from ..registry import version_field

    parser = argparse.ArgumentParser()
    parser.add_argument("--version", required=True)
    parser.add_argument("--reg-path", required=True)
    args = parser.parse_args(argv)
    root = version_field("docker", args.version, args.reg_path, "docker_root")
    if not root:
        return 1
    print(root)
    return 0
