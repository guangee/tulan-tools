"""GitHub API 辅助."""

from __future__ import annotations

import json
import urllib.request


def contents_download_url(repo: str, branch: str, path: str) -> str:
    url = f"https://api.github.com/repos/{repo}/contents/{path}?ref={branch}"
    req = urllib.request.Request(url, headers={"Accept": "application/vnd.github+json"})
    with urllib.request.urlopen(req, timeout=60) as resp:
        data = json.load(resp)
    return str(data.get("download_url", "") or "")


def cmd_contents_url(argv: list[str]) -> int:
    import argparse

    parser = argparse.ArgumentParser()
    parser.add_argument("--repo", required=True)
    parser.add_argument("--branch", required=True)
    parser.add_argument("--path", required=True)
    args = parser.parse_args(argv)
    print(contents_download_url(args.repo, args.branch, args.path))
    return 0
