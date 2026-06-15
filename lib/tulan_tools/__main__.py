"""tulan-tools Python CLI 入口."""

from __future__ import annotations

import sys


def main(argv: list[str] | None = None) -> int:
    args = list(argv if argv is not None else sys.argv[1:])
    if not args or args[0] in ("-h", "--help"):
        print(
            "用法: python3 -m tulan_tools <模块> <子命令> [选项]\n"
            "模块: json, manifest, registry, runtime, rancher, docker, k8s, archives, github, upstream",
            file=sys.stderr,
        )
        return 0 if args and args[0] in ("-h", "--help") else (1 if not args else 0)

    module = args.pop(0)

    if module == "json":
        from . import jsonio

        if not args or args[0] in ("-h", "--help"):
            return jsonio.cmd_get([]) if not args else 0
        sub = args.pop(0)
        if sub == "get":
            return jsonio.cmd_get(args)
        print(f"未知 json 子命令: {sub}", file=sys.stderr)
        return 1

    if module == "manifest":
        from . import manifest

        if not args:
            print("manifest 子命令: branch, tool-version, tool-path, ...", file=sys.stderr)
            return 1
        sub = args.pop(0)
        handlers = {
            "branch": manifest.cmd_branch,
            "get": manifest.cmd_get,
            "github-proxy": manifest.cmd_github_proxy,
            "tool-field": manifest.cmd_tool_field,
            "tool-install-name": manifest.cmd_tool_install_name,
            "tool-version": manifest.cmd_tool_version,
            "tool-path": manifest.cmd_tool_path,
            "tool-sha256": manifest.cmd_tool_sha256,
        }
        fn = handlers.get(sub)
        if fn is None:
            print(f"未知 manifest 子命令: {sub}", file=sys.stderr)
            return 1
        return fn(args)

    if module == "registry":
        from . import registry

        if not args:
            print("registry 子命令: register, activate, install-name, ...", file=sys.stderr)
            return 1
        sub = args.pop(0)
        handlers = {
            "register": registry.cmd_register,
            "activate": registry.cmd_activate,
            "install-name": registry.cmd_install_name,
            "active-version": registry.cmd_active_version,
            "version-field": registry.cmd_version_field,
            "uninstall": registry.cmd_uninstall,
            "list": registry.cmd_list,
            "installed": registry.cmd_installed,
            "versions-display": registry.cmd_versions_display,
        }
        fn = handlers.get(sub)
        if fn is None:
            print(f"未知 registry 子命令: {sub}", file=sys.stderr)
            return 1
        return fn(args)

    if module == "runtime":
        from . import runtime

        if not args:
            print("runtime 子命令: state-field, save-java, save-node, relpath", file=sys.stderr)
            return 1
        sub = args.pop(0)
        handlers = {
            "state-field": runtime.cmd_state_field,
            "save-java": runtime.cmd_save_java,
            "save-node": runtime.cmd_save_node,
            "relpath": runtime.cmd_relpath,
        }
        fn = handlers.get(sub)
        if fn is None:
            print(f"未知 runtime 子命令: {sub}", file=sys.stderr)
            return 1
        return fn(args)

    if module == "rancher":
        if not args:
            print("rancher 子命令: password", file=sys.stderr)
            return 1
        sub = args.pop(0)
        if sub == "password":
            from .rancher import password as rancher_password

            return rancher_password.cmd_password(args)
        print(f"未知 rancher 子命令: {sub}", file=sys.stderr)
        return 1

    if module == "docker":
        from .docker import cli as docker_cli

        if not args:
            print("docker 子命令: latest, recent, load-defaults, build-daemon, ...", file=sys.stderr)
            return 1
        sub = args.pop(0)
        handlers = {
            "latest": docker_cli.cmd_latest,
            "recent": docker_cli.cmd_recent,
            "load-defaults": docker_cli.cmd_load_defaults,
            "build-daemon": docker_cli.cmd_build_daemon,
            "save-state": docker_cli.cmd_save_state,
            "show-state": docker_cli.cmd_show_state,
            "uninstall": docker_cli.cmd_uninstall,
            "register": docker_cli.cmd_register,
            "docker-root": docker_cli.cmd_docker_root,
        }
        fn = handlers.get(sub)
        if fn is None:
            print(f"未知 docker 子命令: {sub}", file=sys.stderr)
            return 1
        return fn(args)

    if module == "k8s":
        from .k8s import kubeconfig as k8s_kubeconfig
        from .k8s import register as k8s_register
        from .k8s import versions as k8s_versions

        if not args:
            print("k8s 子命令: read-versions, filter-ge, cluster-display, ...", file=sys.stderr)
            return 1
        sub = args.pop(0)
        handlers = {
            "read-versions": k8s_versions.cmd_read_versions,
            "filter-ge": k8s_versions.cmd_filter_ge,
            "cluster-display": k8s_register.cmd_cluster_display,
            "list-clusters": k8s_kubeconfig.cmd_list_clusters,
            "resolve-cluster": k8s_kubeconfig.cmd_resolve_cluster,
            "kubeconfig": k8s_kubeconfig.cmd_kubeconfig,
            "list-tokens": k8s_register.cmd_list_tokens,
            "tokens-delete": k8s_register.cmd_tokens_delete,
            "register-command": k8s_register.cmd_register_command,
        }
        fn = handlers.get(sub)
        if fn is None:
            print(f"未知 k8s 子命令: {sub}", file=sys.stderr)
            return 1
        return fn(args)

    if module == "archives":
        from . import archives as archives_mod

        if not args:
            print("archives 子命令: list, uninstall-maven", file=sys.stderr)
            return 1
        sub = args.pop(0)
        handlers = {
            "list": archives_mod.cmd_list,
            "uninstall-maven": archives_mod.cmd_uninstall_maven,
        }
        fn = handlers.get(sub)
        if fn is None:
            print(f"未知 archives 子命令: {sub}", file=sys.stderr)
            return 1
        return fn(args)

    if module == "github":
        from . import github as github_mod

        if not args:
            print("github 子命令: contents-url", file=sys.stderr)
            return 1
        sub = args.pop(0)
        if sub == "contents-url":
            return github_mod.cmd_contents_url(args)
        print(f"未知 github 子命令: {sub}", file=sys.stderr)
        return 1

    if module == "upstream":
        from .upstream import adoptium, maven as maven_upstream

        if not args:
            print("upstream 子命令: adoptium-fetch, maven-latest", file=sys.stderr)
            return 1
        sub = args.pop(0)
        handlers = {
            "adoptium-fetch": adoptium.cmd_fetch,
            "maven-latest": maven_upstream.cmd_latest,
        }
        fn = handlers.get(sub)
        if fn is None:
            print(f"未知 upstream 子命令: {sub}", file=sys.stderr)
            return 1
        return fn(args)

    print(f"未知模块: {module}", file=sys.stderr)
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
