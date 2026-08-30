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
# Immutable numeric id of REPO. A rename leaves the old name redirecting, so a
# re-registered name could serve someone else's release; the id cannot.
REPO_ID="${GITHUB_REPO_ID:-1343160243}"
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
  "https://api.github.com/repos/${REPO}" >"$TMP/repo.json"; then
  fail "could not reach GitHub API for ${REPO}"
  exit 1
fi
ACTUAL_ID="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("id",""))' "$TMP/repo.json")"
if [[ "$ACTUAL_ID" != "$REPO_ID" ]]; then
  fail "repo id ${ACTUAL_ID} does not match pinned ${REPO_ID} — the name may have been re-registered; refusing to install"
  exit 1
fi
ok "repo id ${REPO_ID}"
if ! curl -fsSL "${AUTH[@]}" -H "User-Agent: facility-cache-client-bootstrap" \
  -H "Accept: application/vnd.github+json" \
  "$API" >"$TMP/release.json"; then
  fail "could not reach GitHub API for ${REPO}"
  exit 1
fi

python3 - "$TMP" "$REPO" "$REPO_ID" <<'PY'
import hashlib, json, os, ssl, sys, urllib.error, urllib.request
from pathlib import Path

tmp = Path(sys.argv[1])
repo = sys.argv[2]
repo_id = sys.argv[3]
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

# Fetch every attestation bundle for this exact digest from the PUBLIC
# (no-auth) GitHub attestations API, filtered to repo_id when pinned, and
# write them out as JSON Lines for `gh attestation verify --bundle` (that
# form accepts one bundle object per line). This is what actually needs no
# `gh auth login`, unlike the bare `gh attestation verify --repo` form. A
# token, when set, only lifts the unauthenticated 60/hr/IP rate limit on
# this GET, and a stale one is retried without (see fetch_att below) rather
# than silently disabling attestation.
att_headers = {
    "User-Agent": "facility-cache-client-bootstrap",
    "Accept": "application/vnd.github+json",
}
att_url = f"https://api.github.com/repos/{repo}/attestations/sha256:{digest}"

def fetch_att(url, hdrs):
    req = urllib.request.Request(url, headers=hdrs)
    with urllib.request.urlopen(req, timeout=30, context=ctx) as resp:
        return json.loads(resp.read().decode("utf-8"))

att_data = None
try:
    if token:
        auth_headers = dict(att_headers, Authorization=f"Bearer {token}")
        try:
            att_data = fetch_att(att_url, auth_headers)
        except urllib.error.HTTPError as exc:
            if exc.code not in (401, 403):
                raise
    if att_data is None:
        att_data = fetch_att(att_url, att_headers)
except (urllib.error.URLError, OSError, ValueError):
    att_data = None

if att_data is not None:
    bundles = []
    for att in att_data.get("attestations") or []:
        if repo_id and str(att.get("repository_id")) != str(repo_id):
            continue
        bundle = att.get("bundle")
        if isinstance(bundle, dict):
            bundles.append(bundle)
    if bundles:
        with (tmp / "bundle.jsonl").open("w", encoding="utf-8") as bf:
            for b in bundles:
                bf.write(json.dumps(b) + "\n")

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
ok "extracted"

LINUX_DIR="$(dirname "$INSTALLER")"
if [[ -r "$LINUX_DIR/lib/common.sh" && -r "$LINUX_DIR/lib/ensure_gh.sh" ]]; then
  # shellcheck disable=SC1091
  source "$LINUX_DIR/lib/common.sh"
  # shellcheck disable=SC1091
  source "$LINUX_DIR/lib/ensure_gh.sh"
  say "${CYN}●${RST} ${BOLD}gh${RST}  ${DIM}GitHub CLI${RST}"
  if github_cli_ensure; then
    ok "$(gh --version 2>/dev/null | head -n1 | tr -d '\r' || echo gh)"
  else
    say "${DIM}gh not installed — continuing on sha256 only${RST}"
  fi
fi

# The bare `gh attestation verify --repo` form needs `gh auth login` even
# for a public repo, which a fresh install never has. The python3 step above
# already fetched the Sigstore bundle(s) from the PUBLIC (no-auth)
# attestations API and wrote them as $TMP/bundle.jsonl, so verify offline
# with --bundle instead — that genuinely needs no login.
if command -v gh >/dev/null 2>&1; then
  if [[ -s "$TMP/bundle.jsonl" ]] && gh attestation verify "$TMP/$NAME" \
    --repo "$REPO" \
    --bundle "$TMP/bundle.jsonl" \
    --signer-workflow "${REPO}/.github/workflows/release.yml" \
    --deny-self-hosted-runners >/dev/null 2>&1; then
    ok "attested  ${NAME}"
  else
    say "${DIM}attestation unavailable — continuing on sha256 only${RST}"
  fi
fi

ok "running installer"
bash "$INSTALLER"
