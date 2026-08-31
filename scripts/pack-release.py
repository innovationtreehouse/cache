#!/usr/bin/env python3
"""Build GitHub Release assets in ./dist.

The version is not stored in the repo: release.yml passes the pushed tag in
FC_RELEASE_VERSION, and local/dev builds fall back to `git describe`. The
archives still ship a generated VERSION file so installed clients keep their
existing layout (/usr/local/lib/facility-cache/VERSION, ProgramData\\...\\VERSION).
"""

from __future__ import annotations

import hashlib
import json
import os
import subprocess
import tarfile
import tempfile
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DIST = ROOT / "dist"
LINUX_FILES = [
    "linux/install.sh",
    "linux/uninstall.sh",
    "linux/lib/common.sh",
    "linux/lib/ui.sh",
    "linux/lib/facility_ui.py",
    "linux/lib/ensure_gh.sh",
    "linux/bin/facility-cache",
    "linux/bin/facility-cache-probe",
    "linux/bin/facility-apt-proxy",
    "linux/sbin/facility-cache-apply",
    "linux/sbin/facility-cache-update",
    "linux/sbin/facility-cache-ensure-gh",
    "linux/apt/00facility-cache",
    "linux/profile.d/facility-cache.sh",
    "linux/nm-dispatcher/99-facility-cache",
    "linux/systemd/facility-cache-apply.service",
    "linux/systemd/facility-cache-apply.timer",
    "linux/systemd/facility-cache-update.service",
    "linux/systemd/facility-cache-update.timer",
    "linux/bootstrap.sh",
]
WINDOWS_FILES = [
    "windows/FacilityCache.psm1",
    "windows/FacilityCache-Apply.ps1",
    "windows/FacilityCache-Update.ps1",
    "windows/Install-FacilityCache.ps1",
    "windows/Uninstall-FacilityCache.ps1",
    "windows/Status-FacilityCache.ps1",
    "windows/Install-FromGitHub.ps1",
]


def resolve_version() -> str:
    """FC_RELEASE_VERSION (set from the tag by release.yml), else git describe."""
    env = os.environ.get("FC_RELEASE_VERSION", "").strip().lstrip("v")
    if env:
        return env
    try:
        described = subprocess.run(
            ["git", "-C", str(ROOT), "describe", "--tags", "--match", "v*", "--dirty"],
            capture_output=True,
            text=True,
            check=True,
        ).stdout.strip()
        if described:
            return described.lstrip("v")
    except (OSError, subprocess.CalledProcessError):
        pass
    return "0.0.0-dev"


def sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def main() -> None:
    version = resolve_version()
    prefix = f"facility-cache-client-{version}"
    DIST.mkdir(exist_ok=True)
    for old in DIST.iterdir():
        old.unlink()

    with tempfile.TemporaryDirectory() as tmp:
        # Generated, shipped inside the archives only — never a loose dist/
        # asset, so everything in dist/ stays covered by attestation.
        version_file = Path(tmp) / "VERSION"
        version_file.write_text(version + "\n", encoding="utf-8")

        linux_tar = DIST / "facility-cache-client-linux.tar.gz"
        with tarfile.open(linux_tar, "w:gz") as tar:
            tar.add(version_file, arcname=f"{prefix}/VERSION")
            for rel in ["README.md", "defaults.env"]:
                tar.add(ROOT / rel, arcname=f"{prefix}/{rel}")
            for rel in LINUX_FILES:
                tar.add(ROOT / rel, arcname=f"{prefix}/{rel}")

        win_zip = DIST / "facility-cache-client-windows.zip"
        with zipfile.ZipFile(win_zip, "w", zipfile.ZIP_DEFLATED) as zf:
            zf.write(version_file, arcname=f"{prefix}/VERSION")
            for rel in ["README.md", "defaults.json"]:
                zf.write(ROOT / rel, arcname=f"{prefix}/{rel}")
            for rel in WINDOWS_FILES:
                zf.write(ROOT / rel, arcname=f"{prefix}/{rel}")

    linux_sha = sha256_file(linux_tar)
    win_sha = sha256_file(win_zip)
    manifest = {
        "name": "facility-cache-client",
        "version": version,
        "min_client_version": "1.0.0",
        "assets": {
            "linux": {"name": linux_tar.name, "sha256": linux_sha},
            "windows": {"name": win_zip.name, "sha256": win_sha},
        },
    }
    man_path = DIST / "manifest.json"
    man_path.write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")

    sums = DIST / "SHA256SUMS"
    lines = [
        f"{linux_sha}  {linux_tar.name}",
        f"{win_sha}  {win_zip.name}",
        f"{sha256_file(man_path)}  {man_path.name}",
    ]
    sums.write_text("\n".join(lines) + "\n", encoding="utf-8")

    (DIST / "install-linux.sh").write_bytes(
        (ROOT / "linux" / "bootstrap.sh").read_bytes()
    )
    (DIST / "install-windows.ps1").write_bytes(
        (ROOT / "windows" / "Install-FromGitHub.ps1").read_bytes()
    )
    print(f"packed {version} -> {DIST}")


if __name__ == "__main__":
    main()
