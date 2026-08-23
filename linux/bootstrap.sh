#!/bin/bash
# First-install from GitHub Releases. Safe to curl | sudo bash
set -euo pipefail

# Minimal visuals before the package (and ui.sh) is on disk.
if [[ -t 1 && -z "${NO_COLOR:-}" && "${TERM:-}" != "dumb" ]]; then
  BOLD=$'\033[1m'
  DIM=$'\033[2m'
  CYN=$'\033[36m'
  GRN=$'\033[32m'
  RED=$'\033[31m'
  RST=$'\033[0m'
else
  BOLD=""
  DIM=""
  CYN=""
  GRN=""
  RED=""
  RST=""
fi
say() { printf '  %s\n' "$*"; }
ok() { printf '  %s%s%s %s\n' "$GRN" "✓" "$RST" "$*"; }
fail() { printf '  %s%s%s %s\n' "$RED" "✗" "$RST" "$*"; }

printf '\n  %s%s%s  %s\n' "$BOLD$CYN" "facility-cache-client" "$RST" "${DIM}bootstrap from GitHub${RST}"
printf '  %s\n' "${DIM}────────────────────────────────────────${RST}"

if [[ "$(id -u)" -ne 0 ]]; then
  fail "need root — re-run with sudo"
  exit 1
fi

REPO="${GITHUB_REPO:-innovationtreehouse/cache}"
TOKEN="${GITHUB_TOKEN:-}"
if [[ -z "$TOKEN" && -r /etc/facility-cache/github-token ]]; then
  TOKEN="$(tr -d ' \n' </etc/facility-cache/github-token)"
fi
export BOOTSTRAP_TOKEN="$TOKEN"

API="https://api.github.com/repos/${REPO}/releases/latest"
AUTH=()
if [[ -n "$TOKEN" ]]; then
  AUTH=(-H "Authorization: Bearer ${TOKEN}")
fi

TMP="$(mktemp -d)"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

say "${CYN}●${RST} ${BOLD}github${RST}  ${DIM}${REPO}${RST}"
if ! curl -fsSL "${AUTH[@]}" -H "User-Agent: facility-cache-client-bootstrap" \
  -H "Accept: application/vnd.github+json" \
  "$API" >"$TMP/release.json"; then
  fail "could not reach GitHub API for ${REPO}"
  exit 1
fi

python3 - "$TMP" <<'PY'
import hashlib, json, os, ssl, sys, urllib.request
from pathlib import Path

tmp = Path(sys.argv[1])
release = json.loads((tmp / "release.json").read_text())
assets = {a["name"]: a for a in release.get("assets") or []}
if "manifest.json" not in assets:
    sys.exit("release has no manifest.json")
token = os.environ.get("BOOTSTRAP_TOKEN", "")
headers = {
    "User-Agent": "facility-cache-client-bootstrap",
    "Accept": "application/octet-stream",
}
if token:
    headers["Authorization"] = f"Bearer {token}"
ctx = ssl.create_default_context()

def fetch(asset, dest=None, progress=True):
    req = urllib.request.Request(asset["url"], headers=headers)
    with urllib.request.urlopen(req, timeout=60, context=ctx) as resp:
        total = int(resp.headers.get("Content-Length") or 0)
        n = 0
        chunks = []
        tty = sys.stderr.isatty()
        while True:
            buf = resp.read(64 * 1024)
            if not buf:
                break
            if dest is None:
                chunks.append(buf)
            else:
                dest.write(buf)
            n += len(buf)
            if progress and tty and total:
                pct = min(100, n * 100 // total)
                width = 28
                filled = width * pct // 100
                bar = "█" * filled + "░" * (width - filled)
                sys.stderr.write(f"\r  ● {bar}  {pct:3d}%  {asset['name']}\033[K")
                sys.stderr.flush()
        if progress and tty:
            sys.stderr.write("\n")
        return b"".join(chunks) if dest is None else n

manifest = json.loads(fetch(assets["manifest.json"], progress=False))
linux = manifest["assets"]["linux"]
name, expect = linux["name"], linux["sha256"].lower()
path = tmp / name
with path.open("wb") as f:
    fetch(assets[name], dest=f, progress=True)
digest = hashlib.sha256(path.read_bytes()).hexdigest()
if digest != expect:
    sys.exit(f"sha256 mismatch: {digest} != {expect}")
(tmp / "asset-name").write_text(name)
(tmp / "version").write_text(str(manifest.get("version") or ""))
print(name)
PY

NAME="$(cat "$TMP/asset-name")"
VER="$(cat "$TMP/version" 2>/dev/null || true)"
ok "verified ${NAME}${VER:+  v$VER}"

tar -xzf "$TMP/$NAME" -C "$TMP"
INSTALLER="$(find "$TMP" -path '*/linux/install.sh' -print | head -n1)"
if [[ -z "$INSTALLER" ]]; then
  fail "tarball missing linux/install.sh"
  exit 1
fi
ok "extracted  running installer"
bash "$INSTALLER"
