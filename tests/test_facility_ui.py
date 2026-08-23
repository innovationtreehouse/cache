"""Unit tests for linux/lib/facility_ui.py (pure-Python, no network/root)."""

from __future__ import annotations

import importlib.util
import io
import json
import os
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location(
    "facility_ui", ROOT / "linux" / "lib" / "facility_ui.py"
)
facility_ui = importlib.util.module_from_spec(spec)
spec.loader.exec_module(facility_ui)


class UiTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.log = Path(self.tmp.name) / "client.jsonl"
        self.env = {
            "FACILITY_CACHE_LOG": str(self.log),
            "NO_COLOR": "1",
            "FACILITY_CACHE_ASCII": "1",
        }
        self.saved = {k: os.environ.get(k) for k in self.env}
        os.environ.update(self.env)

    def tearDown(self):
        for k, v in self.saved.items():
            if v is None:
                os.environ.pop(k, None)
            else:
                os.environ[k] = v
        self.tmp.cleanup()

    def make_ui(self):
        return facility_ui.Ui("test", stream=io.StringIO())

    def test_log_path_honors_env(self):
        self.assertEqual(self.make_ui().log_path(), self.log)

    def test_log_writes_jsonl_record(self):
        ui = self.make_ui()
        ui.log("info", "unit", "hello", {"k": 1})
        rec = json.loads(self.log.read_text().strip())
        self.assertEqual(rec["level"], "info")
        self.assertEqual(rec["cmd"], "test")
        self.assertEqual(rec["event"], "unit")
        self.assertEqual(rec["msg"], "hello")
        self.assertEqual(rec["extra"], {"k": 1})
        self.assertRegex(rec["ts"], r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$")

    def test_log_rotates_over_2mb(self):
        self.log.write_text("x" * 2_000_001)
        ui = self.make_ui()
        ui.log("info", "unit", "rotate")
        # the oversized file (including this record) moves aside; the next
        # write starts a fresh log holding only that newest record
        self.assertTrue(self.log.with_suffix(".jsonl.1").exists())
        self.assertFalse(self.log.exists())
        ui.log("info", "unit", "fresh")
        self.assertEqual(len(self.log.read_text().splitlines()), 1)

    def test_no_color_and_ascii_glyphs(self):
        ui = self.make_ui()
        self.assertFalse(ui.color)
        self.assertFalse(ui.unicode)
        ui.ok("fine")
        ui.fail("broke")
        out = ui.out.getvalue()
        self.assertNotIn("\033[", out)
        self.assertIn("OK fine", out)
        self.assertIn("X  broke", out)

    def test_kv_renders_key_and_value(self):
        ui = self.make_ui()
        ui.kv("apt", "http://host:3142", "ok")
        self.assertIn("apt", ui.out.getvalue())
        self.assertIn("http://host:3142", ui.out.getvalue())

    def test_step_counter(self):
        ui = self.make_ui()
        ui.n = 2
        ui.step("first")
        ui.step("second")
        self.assertEqual(ui.i, 2)
        self.assertIn("2/2", ui.out.getvalue())


class FakeResp:
    def __init__(self, payload: bytes, content_length: bool = True):
        self._buf = io.BytesIO(payload)
        self.headers = {"Content-Length": str(len(payload))} if content_length else {}

    def read(self, n):
        return self._buf.read(n)

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        return False


class DownloadTest(unittest.TestCase):
    def test_download_writes_dest_and_creates_parent(self):
        payload = os.urandom(200_000)
        with tempfile.TemporaryDirectory() as tmp:
            dest = Path(tmp) / "nested" / "artifact.bin"
            ui = facility_ui.Ui("test", stream=io.StringIO())

            def urlopen(req, timeout=None, context=None):
                return FakeResp(payload)

            facility_ui.download_with_progress(urlopen, "req", dest, ui, "dl")
            self.assertEqual(dest.read_bytes(), payload)

    def test_download_without_content_length(self):
        payload = b"abc" * 1000
        with tempfile.TemporaryDirectory() as tmp:
            dest = Path(tmp) / "artifact.bin"
            ui = facility_ui.Ui("test", stream=io.StringIO())

            def urlopen(req, timeout=None, context=None):
                return FakeResp(payload, content_length=False)

            facility_ui.download_with_progress(urlopen, "req", dest, ui, "dl")
            self.assertEqual(dest.read_bytes(), payload)


if __name__ == "__main__":
    sys.exit(unittest.main())
