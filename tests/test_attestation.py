"""Unit tests for the attestation-bundle fetch/verify helpers in
linux/sbin/facility-cache-update.

These are the functions that turn a downloaded release archive's sha256
into a Sigstore bundle fetched from the PUBLIC (no-auth) GitHub attestations
API, and then verify that bundle offline with `gh attestation verify
--bundle`. Both must never raise (the caller only ever warns and falls back
to sha256), so most of this file is failure-mode coverage.
"""

from __future__ import annotations

import importlib.machinery
import importlib.util
import json
import subprocess
import tempfile
import unittest
import urllib.error
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
# The script has no .py extension, so name a SourceFileLoader explicitly.
_loader = importlib.machinery.SourceFileLoader(
    "facility_cache_update", str(ROOT / "linux" / "sbin" / "facility-cache-update")
)
_spec = importlib.util.spec_from_loader("facility_cache_update", _loader)
update = importlib.util.module_from_spec(_spec)
_loader.exec_module(update)

REPO = "innovationtreehouse/cache"


def _fake_response(body: bytes):
    """A minimal stand-in for the object urllib.request.urlopen(...) returns
    when used as a context manager."""
    resp = mock.MagicMock()
    resp.__enter__.return_value = resp
    resp.__exit__.return_value = False
    resp.read.return_value = body
    return resp


def _bundle_response(bundles, repository_id=1343160243):
    atts = [{"repository_id": repository_id, "bundle": b} for b in bundles]
    return _fake_response(json.dumps({"attestations": atts}).encode("utf-8"))


class TestFetchAttestationBundles(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.NamedTemporaryFile(delete=False)
        self._tmp.write(b"some release archive bytes")
        self._tmp.close()
        self.tar_path = Path(self._tmp.name)

    def tearDown(self):
        self.tar_path.unlink(missing_ok=True)

    def test_http_error_returns_none(self):
        with mock.patch(
            "urllib.request.urlopen",
            side_effect=urllib.error.URLError("no route to host"),
        ):
            result = update.fetch_attestation_bundles(self.tar_path, REPO, "")
        self.assertIsNone(result)

    def test_non_json_body_returns_none(self):
        with mock.patch(
            "urllib.request.urlopen", return_value=_fake_response(b"not json{{{")
        ):
            result = update.fetch_attestation_bundles(self.tar_path, REPO, "")
        self.assertIsNone(result)

    def test_empty_attestations_returns_none(self):
        body = json.dumps({"attestations": []}).encode("utf-8")
        with mock.patch("urllib.request.urlopen", return_value=_fake_response(body)):
            result = update.fetch_attestation_bundles(self.tar_path, REPO, "")
        self.assertIsNone(result)

    def test_missing_bundle_key_returns_none(self):
        body = json.dumps({"attestations": [{"repository_id": 1343160243}]}).encode(
            "utf-8"
        )
        with mock.patch("urllib.request.urlopen", return_value=_fake_response(body)):
            result = update.fetch_attestation_bundles(self.tar_path, REPO, "")
        self.assertIsNone(result)

    def test_non_dict_bundle_returns_none(self):
        body = json.dumps(
            {"attestations": [{"repository_id": 1343160243, "bundle": "not-a-dict"}]}
        ).encode("utf-8")
        with mock.patch("urllib.request.urlopen", return_value=_fake_response(body)):
            result = update.fetch_attestation_bundles(self.tar_path, REPO, "")
        self.assertIsNone(result)

    def test_repository_id_mismatch_is_filtered_out(self):
        good = {"mediaType": "keep-me"}
        bad = {"mediaType": "drop-me"}
        body = json.dumps(
            {
                "attestations": [
                    {"repository_id": 999999999, "bundle": bad},
                    {"repository_id": 1343160243, "bundle": good},
                ]
            }
        ).encode("utf-8")
        with mock.patch("urllib.request.urlopen", return_value=_fake_response(body)):
            result = update.fetch_attestation_bundles(
                self.tar_path, REPO, "", repo_id="1343160243"
            )
        self.assertEqual(result, [good])

    def test_repository_id_mismatch_on_all_entries_returns_none(self):
        body = json.dumps(
            {"attestations": [{"repository_id": 1, "bundle": {"a": 1}}]}
        ).encode("utf-8")
        with mock.patch("urllib.request.urlopen", return_value=_fake_response(body)):
            result = update.fetch_attestation_bundles(
                self.tar_path, REPO, "", repo_id="999"
            )
        self.assertIsNone(result)

    def test_all_bundles_returned_when_no_repo_id_pinned(self):
        bundles = [{"n": 1}, {"n": 2}, {"n": 3}]
        with mock.patch(
            "urllib.request.urlopen", return_value=_bundle_response(bundles)
        ):
            result = update.fetch_attestation_bundles(self.tar_path, REPO, "")
        self.assertEqual(result, bundles)

    def test_stale_token_401_retries_once_without_authorization(self):
        good_body = _bundle_response([{"n": 1}])
        calls = []

        def fake_urlopen(req, timeout=30, context=None):
            calls.append(dict(req.header_items()))
            if "Authorization" in dict(req.header_items()):
                raise urllib.error.HTTPError(
                    req.full_url, 401, "Unauthorized", {}, None
                )
            return good_body

        with mock.patch("urllib.request.urlopen", side_effect=fake_urlopen):
            result = update.fetch_attestation_bundles(
                self.tar_path, REPO, "stale-token"
            )
        self.assertEqual(result, [{"n": 1}])
        self.assertEqual(len(calls), 2)
        self.assertIn("Authorization", calls[0])
        self.assertNotIn("Authorization", calls[1])

    def test_stale_token_403_retries_once_without_authorization(self):
        good_body = _bundle_response([{"n": 1}])

        def fake_urlopen(req, timeout=30, context=None):
            if "Authorization" in dict(req.header_items()):
                raise urllib.error.HTTPError(req.full_url, 403, "Forbidden", {}, None)
            return good_body

        with mock.patch("urllib.request.urlopen", side_effect=fake_urlopen):
            result = update.fetch_attestation_bundles(
                self.tar_path, REPO, "stale-token"
            )
        self.assertEqual(result, [{"n": 1}])

    def test_non_auth_http_error_is_not_retried_and_returns_none(self):
        def fake_urlopen(req, timeout=30, context=None):
            raise urllib.error.HTTPError(req.full_url, 500, "Server Error", {}, None)

        with mock.patch("urllib.request.urlopen", side_effect=fake_urlopen):
            result = update.fetch_attestation_bundles(self.tar_path, REPO, "some-token")
        self.assertIsNone(result)


class TestVerifyAttestation(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.NamedTemporaryFile(delete=False)
        self._tmp.write(b"some release archive bytes")
        self._tmp.close()
        self.tar_path = Path(self._tmp.name)

    def tearDown(self):
        self.tar_path.unlink(missing_ok=True)

    def test_returns_false_when_gh_missing(self):
        with mock.patch("shutil.which", return_value=None):
            result = update.verify_attestation(self.tar_path, REPO, "")
        self.assertFalse(result)

    def test_returns_false_when_no_bundles_fetched(self):
        with (
            mock.patch("shutil.which", return_value="/usr/bin/gh"),
            mock.patch.object(update, "fetch_attestation_bundles", return_value=None),
        ):
            result = update.verify_attestation(self.tar_path, REPO, "")
        self.assertFalse(result)

    def test_temp_file_removed_even_when_subprocess_raises(self):
        captured_path = {}

        def fake_run(cmd, **kwargs):
            idx = cmd.index("--bundle")
            captured_path["path"] = cmd[idx + 1]
            raise subprocess.CalledProcessError(1, cmd)

        with (
            mock.patch("shutil.which", return_value="/usr/bin/gh"),
            mock.patch.object(
                update,
                "fetch_attestation_bundles",
                return_value=[{"n": 1}],
            ),
            mock.patch("subprocess.run", side_effect=fake_run),
        ):
            result = update.verify_attestation(self.tar_path, REPO, "")
        self.assertFalse(result)
        self.assertIn("path", captured_path)
        self.assertFalse(Path(captured_path["path"]).exists())

    def test_argv_contains_bundle_and_signer_workflow_and_deny_self_hosted(self):
        captured_cmd = {}

        def fake_run(cmd, **kwargs):
            captured_cmd["cmd"] = cmd
            return subprocess.CompletedProcess(cmd, 0)

        with (
            mock.patch("shutil.which", return_value="/usr/bin/gh"),
            mock.patch.object(
                update,
                "fetch_attestation_bundles",
                return_value=[{"n": 1}],
            ),
            mock.patch("subprocess.run", side_effect=fake_run),
        ):
            result = update.verify_attestation(self.tar_path, REPO, "")
        self.assertTrue(result)
        cmd = captured_cmd["cmd"]
        self.assertIn("--bundle", cmd)
        self.assertIn("--deny-self-hosted-runners", cmd)
        idx = cmd.index("--signer-workflow")
        self.assertEqual(cmd[idx + 1], f"{REPO}/.github/workflows/release.yml")

    def test_all_bundles_written_as_jsonl_lines(self):
        bundles = [{"n": 1}, {"n": 2}, {"n": 3}, {"n": 4}]
        captured_content = {}

        def fake_run(cmd, **kwargs):
            idx = cmd.index("--bundle")
            captured_content["text"] = Path(cmd[idx + 1]).read_text(encoding="utf-8")
            return subprocess.CompletedProcess(cmd, 0)

        with (
            mock.patch("shutil.which", return_value="/usr/bin/gh"),
            mock.patch.object(
                update, "fetch_attestation_bundles", return_value=bundles
            ),
            mock.patch("subprocess.run", side_effect=fake_run),
        ):
            result = update.verify_attestation(self.tar_path, REPO, "")
        self.assertTrue(result)
        lines = captured_content["text"].splitlines()
        self.assertEqual(len(lines), len(bundles))
        parsed = [json.loads(line) for line in lines]
        self.assertEqual(parsed, bundles)


if __name__ == "__main__":
    unittest.main()
