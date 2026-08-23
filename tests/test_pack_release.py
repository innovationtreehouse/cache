"""Unit tests for scripts/pack-release.py: pack the real tree, verify the artifacts."""

from __future__ import annotations

import hashlib
import importlib.util
import json
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
        target = ROOT / "VERSION"
        expected = hashlib.sha256(target.read_bytes()).hexdigest()
        self.assertEqual(pack_release.sha256_file(target), expected)


class PackTest(unittest.TestCase):
    """Runs the real packer against the checkout; dist/ is gitignored."""

    @classmethod
    def setUpClass(cls):
        pack_release.main()
        cls.dist = pack_release.DIST
        cls.version = (ROOT / "VERSION").read_text().strip().lstrip("v")
        cls.prefix = f"facility-cache-client-{cls.version}"

    def test_all_assets_present(self):
        names = {p.name for p in self.dist.iterdir()}
        self.assertLessEqual(
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


if __name__ == "__main__":
    sys.exit(unittest.main())
