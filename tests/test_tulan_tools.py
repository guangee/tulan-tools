from __future__ import annotations

import json
import tempfile
import unittest
from pathlib import Path

from tulan_tools.docker.daemon import build_daemon_json
from tulan_tools.k8s.kubeconfig import (
    extract_client_cert_from_kubeconfig,
    extract_token_from_kubeconfig,
    find_clusters,
    resolve_cluster_id,
)
from tulan_tools.k8s.register import build_register_results
from tulan_tools.k8s.versions import filter_versions_ge, read_versions_from_json
from tulan_tools.manifest import (
    branch,
    tool_install_name,
    tool_platform_path,
    tool_platform_sha256,
    tool_version,
)
from tulan_tools.registry import register, uninstall, versions_display
from tulan_tools.semver import parse_version, version_key


class SemverTests(unittest.TestCase):
    def test_parse_and_compare(self) -> None:
        self.assertEqual(parse_version("v2.10.0"), (2, 10, 0))
        self.assertGreater(version_key("v2.11.0"), version_key("v2.10.9"))


class ManifestTests(unittest.TestCase):
    def setUp(self) -> None:
        self.manifest = {
            "branch": "bin",
            "tools": {
                "kubectl": {
                    "version": "1.32.0",
                    "install_name": "kubectl",
                    "paths": {"linux-amd64": "linux-amd64/bin/kubectl"},
                    "sha256": {"linux-amd64": "abc123"},
                }
            },
        }
        self.tmp = tempfile.NamedTemporaryFile(mode="w", suffix=".json", delete=False)
        json.dump(self.manifest, self.tmp)
        self.tmp.close()
        self.path = Path(self.tmp.name)

    def tearDown(self) -> None:
        self.path.unlink(missing_ok=True)

    def test_branch_and_tool_fields(self) -> None:
        self.assertEqual(branch(self.path), "bin")
        self.assertEqual(tool_version(self.path, "kubectl"), "1.32.0")
        self.assertEqual(tool_install_name(self.path, "kubectl"), "kubectl")
        self.assertEqual(tool_platform_path(self.path, "kubectl", "linux-amd64"), "linux-amd64/bin/kubectl")
        self.assertEqual(tool_platform_sha256(self.path, "kubectl", "linux-amd64"), "abc123")


class RegistryTests(unittest.TestCase):
    def test_register_and_uninstall(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            reg = Path(td) / "registry.json"
            home = Path(td)
            register("kubectl", "1.32.0", "kubectl", "github", True, reg)
            self.assertEqual(versions_display("kubectl", reg), "1.32.0*")
            (home / "cellar" / "kubectl" / "1.32.0").mkdir(parents=True)
            uninstall("kubectl", "", reg, home)
            data = json.loads(reg.read_text()) if reg.exists() else {}
            self.assertNotIn("kubectl", data)


class DockerDaemonTests(unittest.TestCase):
    def test_merge_mirror(self) -> None:
        with tempfile.NamedTemporaryFile(mode="w", suffix=".json", delete=False) as f:
            json.dump({"registry-mirrors": ["https://old.example"]}, f)
            path = f.name
        out = json.loads(
            build_daemon_json(
                "https://hub.example",
                "json-file",
                "10m",
                "3",
                "true",
                path,
            )
        )
        self.assertEqual(out["registry-mirrors"][0], "https://hub.example")
        Path(path).unlink(missing_ok=True)


class K8sRegisterTests(unittest.TestCase):
    def test_rewrite_public_to_lan(self) -> None:
        tokens = {
            "items": [
                {
                    "metadata": {"namespace": "c-m-abc", "name": "default-token"},
                    "spec": {"clusterName": "c-m-abc"},
                    "status": {
                        "insecureNodeCommand": "curl -fk https://rancher.example:8443/system-agent-install.sh | sudo sh",
                    },
                }
            ]
        }
        display = {"c-m-abc": "prod"}
        results = build_register_results(
            tokens,
            display,
            "",
            "https://192.168.1.10:8443",
            "https://rancher.example:8443",
            "",
            "rancher.example",
            "8443",
            "",
        )
        self.assertEqual(len(results), 1)
        self.assertIn("192.168.1.10", results[0]["command"])
        self.assertNotIn("rancher.example", results[0]["command"])


class K8sVersionTests(unittest.TestCase):
    def test_read_and_filter(self) -> None:
        with tempfile.NamedTemporaryFile(mode="w", suffix=".json", delete=False) as f:
            json.dump(
                {"min_version": "v2.10.0", "tags": ["v2.9.0", "v2.10.1", "v2.11.0"]},
                f,
            )
            path = Path(f.name)
        tags = read_versions_from_json(path)
        self.assertEqual(tags, ["v2.10.1", "v2.11.0"])
        filtered = filter_versions_ge("v2.10.1", ["v2.10.0", "v2.10.1", "v2.11.0"])
        self.assertEqual(filtered, ["v2.10.1", "v2.11.0"])
        path.unlink(missing_ok=True)


class K8sKubeconfigTests(unittest.TestCase):
    def test_resolve_by_display_name(self) -> None:
        data = {
            "items": [
                {
                    "metadata": {"name": "c-m-abc"},
                    "spec": {"displayName": "prod"},
                    "status": {},
                },
                {
                    "metadata": {"name": "c-m-xyz"},
                    "spec": {"displayName": "staging"},
                    "status": {},
                },
            ]
        }
        self.assertEqual(resolve_cluster_id(data, "prod"), "c-m-abc")
        self.assertEqual(len(find_clusters(data, "c-m-xyz")), 1)


    def test_extract_client_cert(self) -> None:
        sample = """
users:
- name: default
  user:
    client-certificate-data: Y2VydA==
    client-key-data: a2V5
"""
        certs = extract_client_cert_from_kubeconfig(sample)
        self.assertIsNotNone(certs)
        assert certs is not None
        self.assertEqual(certs[0], b"cert")
        self.assertEqual(certs[1], b"key")
        self.assertIsNone(extract_token_from_kubeconfig(sample))


if __name__ == "__main__":
    unittest.main()
