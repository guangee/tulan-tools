#!/usr/bin/env python3
"""CI：下载 JDK / Maven / Node 归档到 STAGING/linux-*/archives/"""

import json
import re
import sys
import urllib.request
from pathlib import Path

JDK_MAJORS = (8, 11, 17)
NODE_MAJORS = (16, 18, 20, 22, 24)
ADOPTIUM_ARCH = {"amd64": "x64", "arm64": "aarch64"}
NODE_SUFFIX = {"amd64": "linux-x64", "arm64": "linux-arm64"}
DOCKER_ARCH = {"amd64": "x86_64", "arm64": "aarch64"}


def log(msg: str) -> None:
    print(f"[ci-archives] {msg}", flush=True)


def curl_download(url: str, dest: Path) -> None:
    dest.parent.mkdir(parents=True, exist_ok=True)
    log(f"下载: {url}")
    req = urllib.request.Request(url, headers={"User-Agent": "tulan-tools-ci"})
    with urllib.request.urlopen(req, timeout=600) as resp:
        data = resp.read()
    if not data:
        raise RuntimeError(f"空文件: {url}")
    dest.write_bytes(data)
    log(f"完成: {dest} ({len(data)} bytes)")


def fetch_adoptium(major: int, adoptium_arch: str) -> tuple[str, str]:
    for flavor in ("hotspot", "ga"):
        api = (
            f"https://api.adoptium.net/v3/assets/latest/{major}/{flavor}"
            f"?architecture={adoptium_arch}&image_type=jdk&os=linux"
        )
        try:
            req = urllib.request.Request(api, headers={"User-Agent": "tulan-tools-ci"})
            with urllib.request.urlopen(req, timeout=120) as resp:
                data = json.load(resp)
            if not data:
                continue
            asset = data[0]
            version = asset.get("version", {}).get("semver") or asset.get("version", {}).get(
                "openjdk_version", ""
            )
            link = asset.get("binary", {}).get("package", {}).get("link", "")
            if version and link:
                return version, link
        except Exception:
            continue
    raise RuntimeError(f"无法获取 OpenJDK {major} ({adoptium_arch})")


def node_latest(major: int) -> str:
    req = urllib.request.Request(
        "https://nodejs.org/dist/index.json", headers={"User-Agent": "tulan-tools-ci"}
    )
    with urllib.request.urlopen(req, timeout=120) as resp:
        data = json.load(resp)
    prefix = f"v{major}."
    for item in data:
        version = item.get("version", "")
        if version.startswith(prefix):
            return version
    raise RuntimeError(f"无法获取 Node.js {major} 最新版本")


def _maven_is_stable(version: str) -> bool:
    return not re.search(r"(alpha|beta|rc|snapshot)", version, re.I)


def docker_latest() -> str:
    url = "https://download.docker.com/linux/static/stable/x86_64/"
    req = urllib.request.Request(url, headers={"User-Agent": "tulan-tools-ci"})
    with urllib.request.urlopen(req, timeout=120) as resp:
        html = resp.read().decode()
    vers = []
    for v in re.findall(r"docker-(\d+\.\d+\.\d+)\.tgz", html):
        if v not in vers:
            vers.append(v)
    if not vers:
        raise RuntimeError("无法获取 Docker 静态包版本")
    return vers[-1]


def maven_latest() -> str:
    """取 Maven 3.x 稳定版；metadata 的 <latest> 可能指向 RC，改用 <release>。"""
    req = urllib.request.Request(
        "https://repo.maven.apache.org/maven2/org/apache/maven/apache-maven/maven-metadata.xml",
        headers={"User-Agent": "tulan-tools-ci"},
    )
    with urllib.request.urlopen(req, timeout=60) as resp:
        text = resp.read().decode()

    m = re.search(r"<release>([^<]+)</release>", text)
    if m and _maven_is_stable(m.group(1)) and m.group(1).startswith("3."):
        return m.group(1)

    versions = re.findall(r"<version>([^<]+)</version>", text)
    stable = [v for v in versions if re.match(r"^3\.\d+\.\d+$", v)]
    if stable:
        return stable[-1]

    raise RuntimeError("无法获取 Maven 3.x 稳定版本")


def main() -> int:
    if len(sys.argv) < 2:
        print("用法: ci-download-archives.py <staging_dir>", file=sys.stderr)
        return 1

    staging = Path(sys.argv[1])
    versions_path = staging / "versions.json"
    versions: dict[str, str] = {}
    if versions_path.exists():
        versions = json.loads(versions_path.read_text())

    for major in JDK_MAJORS:
        tool = f"openjdk-{major}"
        first_ver = ""
        for arch, adoptium_arch in ADOPTIUM_ARCH.items():
            ver, link = fetch_adoptium(major, adoptium_arch)
            first_ver = first_ver or ver
            dest = staging / f"linux-{arch}" / "archives" / f"{tool}.tar.gz"
            curl_download(link, dest)
        versions[tool] = first_ver
        log(f"{tool} -> {first_ver}")

    mvn_ver = maven_latest()
    mvn_url = (
        f"https://dlcdn.apache.org/maven/maven-3/{mvn_ver}/binaries/"
        f"apache-maven-{mvn_ver}-bin.tar.gz"
    )
    mvn_tmp = staging / "maven-download.tar.gz"
    try:
        curl_download(mvn_url, mvn_tmp)
    except Exception:
        mvn_url = (
            f"https://archive.apache.org/dist/maven/maven-3/{mvn_ver}/binaries/"
            f"apache-maven-{mvn_ver}-bin.tar.gz"
        )
        curl_download(mvn_url, mvn_tmp)
    for arch in ADOPTIUM_ARCH:
        dest = staging / f"linux-{arch}" / "archives" / "apache-maven-bin.tar.gz"
        dest.parent.mkdir(parents=True, exist_ok=True)
        dest.write_bytes(mvn_tmp.read_bytes())
    mvn_tmp.unlink(missing_ok=True)
    versions["maven"] = mvn_ver
    log(f"maven -> {mvn_ver}")

    for major in NODE_MAJORS:
        tool = f"node-{major}"
        ver = node_latest(major)
        for arch, suffix in NODE_SUFFIX.items():
            url = f"https://nodejs.org/dist/{ver}/node-{ver}-{suffix}.tar.gz"
            dest = staging / f"linux-{arch}" / "archives" / f"{tool}.tar.gz"
            curl_download(url, dest)
        versions[tool] = ver
        log(f"{tool} -> {ver}")

    docker_ver = docker_latest()
    for arch, docker_arch in DOCKER_ARCH.items():
        url = (
            f"https://download.docker.com/linux/static/stable/{docker_arch}/"
            f"docker-{docker_ver}.tgz"
        )
        dest = staging / f"linux-{arch}" / "archives" / "docker.tar.gz"
        curl_download(url, dest)
    versions["docker"] = docker_ver
    log(f"docker -> {docker_ver}")

    versions_path.write_text(json.dumps(versions, ensure_ascii=False) + "\n")
    log("归档下载完成")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
