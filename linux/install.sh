#!/bin/bash
# Install facility cache client settings on Ubuntu.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
# shellcheck source=/dev/null
source "$HERE/lib/ui.sh"

if [[ "$(id -u)" -ne 0 ]]; then
  ui_init install
  ui_banner "facility-cache-client" "install"
  ui_fail "need root — re-run with sudo"
  ui_hint_log
  exit 1
fi

PREFIX="${PREFIX:-/usr/local}"
NO_DOCKER=0
NO_RESTART_DOCKER=0
FROM_UPDATE=0

while [[ $# -gt 0 ]]; do
  case "$1" in
  --no-docker)
    NO_DOCKER=1
    shift
    ;;
  --no-restart-docker)
    NO_RESTART_DOCKER=1
    shift
    ;;
  --from-update)
    FROM_UPDATE=1
    NO_RESTART_DOCKER=1
    shift
    ;;
  -h | --help)
    cat <<EOF
Usage: sudo $0 [--no-docker] [--no-restart-docker] [--from-update]
EOF
    exit 0
    ;;
  *)
    echo "unknown arg: $1" >&2
    exit 2
    ;;
  esac
done

VER="unknown"
[[ -f "$ROOT/VERSION" ]] && VER="$(tr -d ' v\n' <"$ROOT/VERSION")"
ui_init install 7
if [[ "$FROM_UPDATE" -eq 0 ]]; then
  ui_banner "facility-cache-client" "install  v${VER}"
fi

ui_step "config" "directories and local overrides"
install -d -m 0755 /etc/facility-cache /var/lib/facility-cache /var/log/facility-cache
if [[ ! -f /etc/facility-cache/config ]]; then
  cat >/etc/facility-cache/config <<'EOF'
# Local overrides. Package defaults are in /usr/local/lib/facility-cache/defaults
# and are replaced on each GitHub Release.
#
# EXPECTED_IP=192.168.1.200
# GITHUB_REPO=innovationtreehouse/cache
# AUTO_UPDATE=1
EOF
  chmod 644 /etc/facility-cache/config
  ui_step_ok "wrote /etc/facility-cache/config"
else
  ui_step_ok "kept existing /etc/facility-cache/config"
fi

ui_step "files" "binaries, defaults, UI"
install -d -m 0755 "${PREFIX}/lib/facility-cache" "${PREFIX}/bin" "${PREFIX}/sbin"
# Stage every file under PREFIX first (same filesystem, so the final move is
# a plain rename), then move it all into place in one quick pass. A failure
# while staging (disk full, bad tarball, killed mid-copy) never touches the
# live install; set -e + this trap unwinds to the old, fully-working files.
rm -rf "${PREFIX}"/.facility-cache-stage.* 2>/dev/null || true
STAGE="$(mktemp -d "${PREFIX}/.facility-cache-stage.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
install -d -m 0755 "${STAGE}/lib" "${STAGE}/bin" "${STAGE}/sbin"
install -m 0644 "${HERE}/lib/common.sh" "${STAGE}/lib/common.sh"
install -m 0644 "${HERE}/lib/ui.sh" "${STAGE}/lib/ui.sh"
install -m 0644 "${HERE}/lib/facility_ui.py" "${STAGE}/lib/facility_ui.py"
if [[ -f "${ROOT}/defaults.env" ]]; then
  install -m 0644 "${ROOT}/defaults.env" "${STAGE}/lib/defaults"
fi
if [[ -f "${ROOT}/VERSION" ]]; then
  install -m 0644 "${ROOT}/VERSION" "${STAGE}/lib/VERSION"
fi
install -m 0755 "${HERE}/bin/facility-cache" "${STAGE}/bin/facility-cache"
install -m 0755 "${HERE}/bin/facility-cache-probe" "${STAGE}/bin/facility-cache-probe"
install -m 0755 "${HERE}/bin/facility-apt-proxy" "${STAGE}/bin/facility-apt-proxy"
install -m 0755 "${HERE}/sbin/facility-cache-apply" "${STAGE}/sbin/facility-cache-apply"
install -m 0755 "${HERE}/sbin/facility-cache-update" "${STAGE}/sbin/facility-cache-update"
for f in "${STAGE}"/lib/*; do mv -f "$f" "${PREFIX}/lib/facility-cache/$(basename "$f")"; done
for f in "${STAGE}"/bin/*; do mv -f "$f" "${PREFIX}/bin/$(basename "$f")"; done
for f in "${STAGE}"/sbin/*; do mv -f "$f" "${PREFIX}/sbin/$(basename "$f")"; done
rm -rf "$STAGE"
trap - EXIT
ui_step_ok "v${VER} → ${PREFIX}"

ui_step "apt" "proxy auto-detect"
install -d -m 0755 /etc/apt/apt.conf.d
install -m 0644 "${HERE}/apt/00facility-cache" /etc/apt/apt.conf.d/00facility-cache
install -d -m 0755 /etc/profile.d
install -m 0644 "${HERE}/profile.d/facility-cache.sh" /etc/profile.d/facility-cache.sh
ui_step_ok "DIRECT off-site, cache on-site"

ui_step "hooks" "NetworkManager + systemd"
if [[ -d /etc/NetworkManager/dispatcher.d ]]; then
  install -m 0755 "${HERE}/nm-dispatcher/99-facility-cache" \
    /etc/NetworkManager/dispatcher.d/99-facility-cache
  nm_msg="NetworkManager dispatcher"
else
  nm_msg="no NetworkManager (timer only)"
fi
install -d -m 0755 /etc/systemd/system
install -m 0644 "${HERE}/systemd/facility-cache-apply.service" /etc/systemd/system/facility-cache-apply.service
install -m 0644 "${HERE}/systemd/facility-cache-apply.timer" /etc/systemd/system/facility-cache-apply.timer
install -m 0644 "${HERE}/systemd/facility-cache-update.service" /etc/systemd/system/facility-cache-update.service
install -m 0644 "${HERE}/systemd/facility-cache-update.timer" /etc/systemd/system/facility-cache-update.timer
systemctl daemon-reload
systemctl enable --now facility-cache-apply.timer >/dev/null
systemctl enable --now facility-cache-update.timer >/dev/null
systemctl start facility-cache-apply.service >/dev/null 2>&1 || true
ui_step_ok "$nm_msg · apply 5m · update daily"

merge_docker() {
  python3 - <<'PY'
import json
from pathlib import Path

path = Path("/etc/docker/daemon.json")
backup = Path("/etc/docker/daemon.json.facility-cache.bak")
host = "cache.facility.innovationtreehouse.org"
mirror = f"http://{host}:5000"
insecure = [f"{host}:5000", f"{host}:5001"]

path.parent.mkdir(parents=True, exist_ok=True)
if path.exists():
    data = json.loads(path.read_text() or "{}")
    if not backup.exists():
        backup.write_text(path.read_text())
else:
    data = {}

mirrors = list(data.get("registry-mirrors") or [])
if mirror not in mirrors:
    mirrors.insert(0, mirror)
data["registry-mirrors"] = mirrors

regs = list(data.get("insecure-registries") or [])
for item in insecure:
    if item not in regs:
        regs.append(item)
data["insecure-registries"] = regs

new = json.dumps(data, indent=2) + "\n"
old = path.read_text() if path.exists() else ""
path.write_text(new)
print("changed" if new != old else "unchanged")
PY
}

ui_step "docker" "registry-mirrors"
if [[ "$NO_DOCKER" -eq 1 ]]; then
  ui_step_skip "disabled by --no-docker"
elif ! command -v python3 >/dev/null 2>&1; then
  ui_step_skip "python3 not found"
else
  changed="$(merge_docker)"
  if [[ "$changed" == changed && "$NO_RESTART_DOCKER" -eq 0 ]]; then
    if systemctl is-active --quiet docker 2>/dev/null; then
      systemctl restart docker
      ui_step_ok "mirrors written · docker restarted"
    else
      ui_step_ok "mirrors written · docker not running"
    fi
  elif [[ "$changed" == changed ]]; then
    ui_step_ok "mirrors written · restart docker when convenient"
  else
    ui_step_ok "already configured"
  fi
fi

ui_step "apply" "LAN drop-ins"
if [[ -x "${PREFIX}/sbin/facility-cache-apply" ]]; then
  "${PREFIX}/sbin/facility-cache-apply" >/dev/null 2>&1 || true
fi
ui_step_ok "probe on next network change"

if [[ "$FROM_UPDATE" -eq 1 ]]; then
  ui_ok "package files v${VER}"
else
  ui_finish 0 "v${VER} ready"
  ui_note "facility-cache status     dashboard"
  ui_note "facility-cache update     GitHub Releases"
  ui_note "facility-cache log        fetchable event log"
  printf '\n'
fi
