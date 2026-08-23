"""Shared terminal UI + JSONL log for facility-cache-client."""

from __future__ import annotations

import json
import os
import shutil
import sys
import time
from pathlib import Path
from typing import Any, Callable, Optional, TextIO

CODES = {
    "reset": "\033[0m",
    "bold": "\033[1m",
    "dim": "\033[2m",
    "red": "\033[31m",
    "grn": "\033[32m",
    "ylw": "\033[33m",
    "blu": "\033[34m",
    "mag": "\033[35m",
    "cyn": "\033[36m",
}


def _want_color() -> bool:
    if os.environ.get("NO_COLOR"):
        return False
    if os.environ.get("TERM") == "dumb":
        return False
    return sys.stdout.isatty()


def _want_unicode() -> bool:
    if os.environ.get("FACILITY_CACHE_ASCII") == "1":
        return False
    enc = (sys.stdout.encoding or "").lower()
    loc = (os.environ.get("LC_ALL") or os.environ.get("LANG") or "").lower()
    return "utf" in enc or "utf-8" in loc


class Ui:
    def __init__(self, cmd: str = "", stream: Optional[TextIO] = None) -> None:
        self.cmd = cmd
        self.out = stream or sys.stdout
        self.color = _want_color()
        self.unicode = _want_unicode()
        self.tty = self.out.isatty()
        self.i = 0
        self.n = 0
        self.g_ok = "✓" if self.unicode else "OK"
        self.g_fail = "✗" if self.unicode else "X "
        self.g_work = "●" if self.unicode else "*"
        self.g_off = "○" if self.unicode else "o"
        self.g_warn = "!"
        self.g_info = "i"
        self.g_arr = "▸" if self.unicode else ">"
        self.fill = "█" if self.unicode else "#"
        self.empty = "░" if self.unicode else "-"
        self.rule_ch = "─" if self.unicode else "-"

    def _c(self, name: str, text: str) -> str:
        if not self.color:
            return text
        return f"{CODES[name]}{text}{CODES['reset']}"

    def cols(self) -> int:
        return max(40, min(72, shutil.get_terminal_size((80, 24)).columns))

    def log_path(self) -> Path:
        if os.environ.get("FACILITY_CACHE_LOG"):
            return Path(os.environ["FACILITY_CACHE_LOG"])
        home = Path.home()
        user = os.environ.get("USER") or os.environ.get("USERNAME") or "user"
        candidates = [
            Path("/var/log/facility-cache/client.jsonl"),
            Path("/var/lib/facility-cache/logs/client.jsonl"),
            Path(os.environ.get("XDG_STATE_HOME", str(home / ".local/state")))
            / "facility-cache"
            / "client.jsonl",
            Path(f"/tmp/facility-cache-{user}.jsonl"),
        ]
        for p in candidates:
            try:
                p.parent.mkdir(parents=True, exist_ok=True)
                if os.access(p.parent, os.W_OK):
                    return p
            except OSError:
                continue
        return candidates[-1]

    def log(
        self, level: str, event: str, msg: str, extra: Optional[dict] = None
    ) -> None:
        rec = {
            "ts": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
            "level": level,
            "cmd": self.cmd,
            "event": event,
            "msg": msg,
            "extra": extra or {},
        }
        path = self.log_path()
        try:
            path.parent.mkdir(parents=True, exist_ok=True)
            with path.open("a", encoding="utf-8") as f:
                f.write(json.dumps(rec, ensure_ascii=False) + "\n")
            if path.stat().st_size > 2_000_000:
                bak = path.with_suffix(path.suffix + ".1")
                bak.unlink(missing_ok=True)
                path.rename(bak)
        except OSError:
            pass

    def banner(self, title: str, subtitle: str = "") -> None:
        line = "  " + self._c("bold", self._c("cyn", title))
        if subtitle:
            line += "  " + self._c("dim", subtitle)
        self.out.write("\n" + line + "\n")
        self.rule()
        self.out.flush()
        self.log("info", "start", f"{title} {subtitle}".strip())

    def rule(self) -> None:
        self.out.write("  " + self._c("dim", self.rule_ch * (self.cols() - 2)) + "\n")

    def kv(self, key: str, val: str, kind: str = "") -> None:
        mark = ""
        glyphs = {
            "ok": self._c("grn", self.g_ok),
            "fail": self._c("red", self.g_fail),
            "warn": self._c("ylw", self.g_warn),
            "on": self._c("grn", self.g_work),
            "off": self._c("dim", self.g_off),
            "work": self._c("cyn", self.g_work),
        }
        if kind in glyphs:
            mark = " " + glyphs[kind]
        self.out.write(
            f"  {self._c('dim', self.g_arr)} {self._c('dim', f'{key:<12}')} {val}{mark}\n"
        )

    def info(self, msg: str) -> None:
        self.out.write(f"  {self._c('cyn', self.g_info)} {msg}\n")
        self.log("info", "info", msg)

    def ok(self, msg: str) -> None:
        self.out.write(f"  {self._c('grn', self.g_ok)} {msg}\n")
        self.log("info", "ok", msg)

    def warn(self, msg: str) -> None:
        self.out.write(f"  {self._c('ylw', self.g_warn)} {msg}\n")
        self.log("warn", "warn", msg)

    def fail(self, msg: str) -> None:
        self.out.write(f"  {self._c('red', self.g_fail)} {msg}\n")
        self.log("error", "fail", msg)

    def note(self, msg: str) -> None:
        self.out.write(f"    {self._c('dim', msg)}\n")

    def step(self, name: str, msg: str = "") -> None:
        self.i += 1
        self.log(
            "info",
            "step_start",
            f"{name}: {msg}",
            {"step": name, "i": self.i, "n": self.n},
        )
        prefix = f"{self.i}/{self.n}  " if self.n else ""
        self.out.write(
            f"  {self._c('cyn', self.g_work)} {self._c('dim', prefix)}{self._c('bold', name)}  {self._c('dim', msg)}\n"
        )
        self.out.flush()

    def step_ok(self, name: str, msg: str = "done") -> None:
        self.log("info", "step_ok", f"{name}: {msg}", {"step": name})
        if self.tty:
            self.out.write("\033[1A\r\033[2K")
        prefix = f"{self.i}/{self.n}  " if self.n else ""
        self.out.write(
            f"  {self._c('grn', self.g_ok)} {self._c('dim', prefix)}{self._c('bold', name)}  {msg}\n"
        )
        self.out.flush()

    def step_fail(self, name: str, msg: str) -> None:
        self.log("error", "step_fail", f"{name}: {msg}", {"step": name})
        self.out.write(
            f"  {self._c('red', self.g_fail)} {self._c('bold', name)}  {self._c('red', msg)}\n"
        )

    def bar(self, cur: int, tot: int, label: str = "") -> None:
        tot = tot or 1
        pct = min(100, int(cur * 100 / tot))
        width = 28
        filled = int(width * pct / 100)
        bar = self.fill * filled + self.empty * (width - filled)
        line = f"  {self._c('cyn', self.g_work)} {self._c('cyn', bar)}  {self._c('dim', f'{pct:3d}%')}  {self._c('dim', label)}"
        if self.tty:
            self.out.write("\r" + line + "\033[K")
            if cur >= tot:
                self.out.write("\n")
            self.out.flush()
        elif cur >= tot:
            self.out.write(line + "\n")

    def finish(self, ok: bool = True, msg: str = "") -> None:
        self.rule()
        if ok:
            text = msg or "done"
            self.out.write(f"  {self._c('grn', self.g_ok)} {text}\n")
            self.out.write(f"  {self._c('dim', 'log ' + str(self.log_path()))}\n\n")
            self.log("info", "finish", text, {"code": 0})
        else:
            text = msg or "failed"
            self.out.write(f"  {self._c('red', self.g_fail)} {text}\n")
            self.out.write(f"  {self._c('dim', 'log ' + str(self.log_path()))}\n\n")
            self.log("error", "finish", text, {"code": 1})
        self.out.flush()


def show_log(
    follow: bool = False, limit: int = 40, as_json: bool = False, path: bool = False
) -> int:
    ui = Ui("log")
    log = ui.log_path()
    if path:
        print(log)
        return 0
    if not log.is_file():
        ui.warn(f"no log yet at {log}")
        return 0
    if as_json and not follow:
        sys.stdout.write(log.read_text(encoding="utf-8", errors="replace"))
        return 0

    def emit(line: str) -> None:
        line = line.strip()
        if not line:
            return
        if as_json:
            print(line)
            return
        try:
            rec = json.loads(line)
        except json.JSONDecodeError:
            print("  " + line)
            return
        ts = rec.get("ts", "")[11:19]
        level = rec.get("level", "info")
        msg = rec.get("msg", "")
        event = rec.get("event", "")
        if level == "error":
            mark = ui._c("red", ui.g_fail)
        elif level == "warn":
            mark = ui._c("ylw", ui.g_warn)
        elif event in ("ok", "step_ok", "finish") and level != "error":
            mark = ui._c("grn", ui.g_ok)
        else:
            mark = ui._c("cyn", ui.g_work)
        cmd = rec.get("cmd") or ""
        left = f"{ts}  {cmd:<8}" if cmd else ts
        print(f"  {mark} {ui._c('dim', left)}  {msg}")

    ui.banner("facility-cache log", str(log))
    lines = log.read_text(encoding="utf-8", errors="replace").splitlines()
    for line in lines[-limit:]:
        emit(line)
    if not follow:
        print()
        return 0
    print(ui._c("dim", "  following…  Ctrl-C to stop"))
    with log.open("r", encoding="utf-8", errors="replace") as f:
        f.seek(0, os.SEEK_END)
        while True:
            line = f.readline()
            if line:
                emit(line)
            else:
                time.sleep(0.3)
    return 0


def main(argv: Optional[list[str]] = None) -> int:
    import argparse

    parser = argparse.ArgumentParser(prog="facility-cache log")
    parser.add_argument("-n", type=int, default=40, help="lines to show")
    parser.add_argument("-f", "--follow", action="store_true")
    parser.add_argument("--json", action="store_true")
    parser.add_argument("--path", action="store_true")
    args = parser.parse_args(argv)
    try:
        return show_log(
            follow=args.follow, limit=args.n, as_json=args.json, path=args.path
        )
    except KeyboardInterrupt:
        print()
        return 0


def download_with_progress(
    urlopen: Callable,
    req: Any,
    dest: Path,
    ui: Ui,
    label: str,
    timeout: int = 60,
    context: Any = None,
) -> None:
    with urlopen(req, timeout=timeout, context=context) as resp:
        total = int(resp.headers.get("Content-Length") or 0)
        n = 0
        dest.parent.mkdir(parents=True, exist_ok=True)
        with dest.open("wb") as f:
            while True:
                chunk = resp.read(64 * 1024)
                if not chunk:
                    break
                f.write(chunk)
                n += len(chunk)
                if total:
                    ui.bar(n, total, label)
                else:
                    ui.bar(n, max(n, 1), f"{label}  {n} B")
        if total:
            ui.bar(total, total, label)
        else:
            ui.bar(n, n or 1, label)


if __name__ == "__main__":
    sys.exit(main())
