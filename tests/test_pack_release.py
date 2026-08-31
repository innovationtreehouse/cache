"""Unit tests for scripts/pack-release.py: pack the real tree, verify the artifacts."""

from __future__ import annotations

import hashlib
import importlib.util
import json
import os
import sys
import tarfile
import unittest
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location(
    "pack_release", ROOT / "scripts" / "pack-release.py"
)
pack_release = importlib.util.module_from_spec(spec)
spec.loader.exec_module(pack_release)


class Sha256FileTest(unittest.TestCase):
    def test_matches_hashlib(self):
        target = ROOT / "README.md"
        expected = hashlib.sha256(target.read_bytes()).hexdigest()
        self.assertEqual(pack_release.sha256_file(target), expected)


class ResolveVersionTest(unittest.TestCase):
    def test_env_wins_and_v_prefix_stripped(self):
        os.environ["FC_RELEASE_VERSION"] = "v9.9.9"
        try:
            self.assertEqual(pack_release.resolve_version(), "9.9.9")
        finally:
            del os.environ["FC_RELEASE_VERSION"]

    def test_fallback_is_git_describe_or_dev_marker(self):
        os.environ.pop("FC_RELEASE_VERSION", None)
        v = pack_release.resolve_version()
        self.assertTrue(v)
        self.assertFalse(v.startswith("v"))


class PackTest(unittest.TestCase):
    """Runs the real packer against the checkout; dist/ is gitignored."""

    @classmethod
    def setUpClass(cls):
        os.environ["FC_RELEASE_VERSION"] = "9.9.9"
        try:
            pack_release.main()
        finally:
            del os.environ["FC_RELEASE_VERSION"]
        cls.dist = pack_release.DIST
        cls.version = "9.9.9"
        cls.prefix = f"facility-cache-client-{cls.version}"

    def test_all_assets_present_and_nothing_unattested(self):
        # Exactly the attested set: a stray file (e.g. the generated VERSION)
        # would be published by `gh release upload dist/*` without provenance.
        names = {p.name for p in self.dist.iterdir()}
        self.assertEqual(
            {
                "facility-cache-client-linux.tar.gz",
                "facility-cache-client-windows.zip",
                "manifest.json",
                "SHA256SUMS",
                "install-linux.sh",
                "install-windows.ps1",
            },
            names,
        )

    def test_archives_ship_generated_version_file(self):
        with tarfile.open(self.dist / "facility-cache-client-linux.tar.gz") as tar:
            fh = tar.extractfile(f"{self.prefix}/VERSION")
            self.assertEqual(fh.read().decode().strip(), self.version)
        with zipfile.ZipFile(self.dist / "facility-cache-client-windows.zip") as zf:
            self.assertEqual(
                zf.read(f"{self.prefix}/VERSION").decode().strip(), self.version
            )

    def test_manifest_hashes_match_artifacts(self):
        manifest = json.loads((self.dist / "manifest.json").read_text())
        self.assertEqual(manifest["version"], self.version)
        for platform, artifact in (
            ("linux", "facility-cache-client-linux.tar.gz"),
            ("windows", "facility-cache-client-windows.zip"),
        ):
            entry = manifest["assets"][platform]
            self.assertEqual(entry["name"], artifact)
            self.assertEqual(
                entry["sha256"], pack_release.sha256_file(self.dist / artifact)
            )

    def test_sha256sums_covers_manifest_and_archives(self):
        lines = (self.dist / "SHA256SUMS").read_text().splitlines()
        parsed = {name: sha for sha, name in (line.split(None, 1) for line in lines)}
        for name in (
            "facility-cache-client-linux.tar.gz",
            "facility-cache-client-windows.zip",
            "manifest.json",
        ):
            self.assertEqual(
                parsed[name.strip()], pack_release.sha256_file(self.dist / name)
            )

    def test_tar_members_match_declared_file_list(self):
        with tarfile.open(self.dist / "facility-cache-client-linux.tar.gz") as tar:
            members = set(tar.getnames())
        expected = {
            f"{self.prefix}/{rel}"
            for rel in ["VERSION", "README.md", "defaults.env"]
            + pack_release.LINUX_FILES
        }
        self.assertEqual(members, expected)

    def test_zip_members_match_declared_file_list(self):
        with zipfile.ZipFile(self.dist / "facility-cache-client-windows.zip") as zf:
            members = set(zf.namelist())
        expected = {
            f"{self.prefix}/{rel}"
            for rel in ["VERSION", "README.md", "defaults.json"]
            + pack_release.WINDOWS_FILES
        }
        self.assertEqual(members, expected)

    def test_bootstrap_shipped_verbatim(self):
        self.assertEqual(
            (self.dist / "install-linux.sh").read_bytes(),
            (ROOT / "linux" / "bootstrap.sh").read_bytes(),
        )
        self.assertEqual(
            (self.dist / "install-windows.ps1").read_bytes(),
            (ROOT / "windows" / "Install-FromGitHub.ps1").read_bytes(),
        )

    def test_release_workflow_attests_every_published_asset(self):
        workflow = (ROOT / ".github/workflows/release.yml").read_text(encoding="utf-8")
        for name in (
            "facility-cache-client-linux.tar.gz",
            "facility-cache-client-windows.zip",
            "manifest.json",
            "SHA256SUMS",
            "install-linux.sh",
            "install-windows.ps1",
        ):
            self.assertIn(
                f"dist/{name}",
                workflow,
                f"{name} is packed and published but not attested",
            )


if __name__ == "__main__":
    sys.exit(unittest.main())
