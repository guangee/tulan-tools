"""tulan-tools Python CLI 入口."""

from __future__ import annotations

import sys


def main(argv: list[str] | None = None) -> int:
    args = list(argv if argv is not None else sys.argv[1:])
    if not args or args[0] in ("-h", "--help"):
        print(
            "用法: python3 -m tulan_tools <模块> <子命令> [选项]\n"
            "模块: json, manifest, registry, runtime, rancher",
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
            print("manifest 子命令: eval, get, tool-version, tool-path", file=sys.stderr)
            return 1
        sub = args.pop(0)
        handlers = {
            "eval": manifest.cmd_eval,
            "get": manifest.cmd_get,
            "tool-version": manifest.cmd_tool_version,
            "tool-path": manifest.cmd_tool_path,
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

    print(f"未知模块: {module}", file=sys.stderr)
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
