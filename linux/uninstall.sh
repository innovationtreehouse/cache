#!/bin/bash
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
if [[ -r "$HERE/lib/ui.sh" ]]; then
  # shellcheck source=/dev/null
  source "$HERE/lib/ui.sh"
elif [[ -r /usr/local/lib/facility-cache/ui.sh ]]; then
  # shellcheck source=/dev/null
  source /usr/local/lib/facility-cache/ui.sh
fi

ui_init uninstall 4
ui_banner "facility-cache-client" "uninstall"

if [[ "$(id -u)" -ne 0 ]]; then
  ui_fail "need root — re-run with sudo"
  ui_finish 1 "aborted"
  exit 1
fi

KEEP_DOCKER=0
if [[ "${1:-}" == "--keep-docker" ]]; then
  KEEP_DOCKER=1
fi

ui_step "timers" "stopping systemd units"
systemctl disable --now facility-cache-apply.timer 2>/dev/null || true
systemctl disable --now facility-cache-apply.service 2>/dev/null || true
systemctl disable --now facility-cache-update.timer 2>/dev/null || true
systemctl disable --now facility-cache-update.service 2>/dev/null || true
rm -f /etc/systemd/system/facility-cache-apply.service
rm -f /etc/systemd/system/facility-cache-apply.timer
rm -f /etc/systemd/system/facility-cache-update.service
rm -f /etc/systemd/system/facility-cache-update.timer
systemctl daemon-reload
ui_step_ok "timers and units removed"

ui_step "files" "binaries and drop-ins"
rm -f /etc/apt/apt.conf.d/00facility-cache
rm -f /etc/profile.d/facility-cache.sh
rm -f /etc/NetworkManager/dispatcher.d/99-facility-cache
rm -f /usr/local/bin/facility-cache
rm -f /usr/local/bin/facility-cache-probe
rm -f /usr/local/bin/facility-apt-proxy
rm -f /usr/local/sbin/facility-cache-apply
rm -f /usr/local/sbin/facility-cache-update
rm -rf /usr/local/lib/facility-cache
rm -rf /run/facility-cache
rm -rf /var/lib/facility-cache
for f in /etc/pip.conf /etc/xdg/pip/pip.conf /etc/npmrc /etc/uv/uv.toml /etc/environment.d/60-facility-cache.conf; do
  if [[ -f "$f" ]] && grep -q facility-cache-managed "$f"; then
    rm -f "$f"
  fi
done
ui_step_ok "client files removed"

ui_step "docker" "registry-mirrors"
if [[ "$KEEP_DOCKER" -eq 1 ]]; then
  ui_step_skip "kept (--keep-docker)"
else
  python3 - <<'PY'
import json
from pathlib import Path

path = Path("/etc/docker/daemon.json")
host = "cache.facility.innovationtreehouse.org"
mirror = f"http://{host}:5000"
insecure = {f"{host}:5000", f"{host}:5001"}
if not path.exists():
    raise SystemExit(0)
data = json.loads(path.read_text() or "{}")
mirrors = [m for m in (data.get("registry-mirrors") or []) if m != mirror]
regs = [r for r in (data.get("insecure-registries") or []) if r not in insecure]
if mirrors:
    data["registry-mirrors"] = mirrors
else:
    data.pop("registry-mirrors", None)
if regs:
    data["insecure-registries"] = regs
else:
    data.pop("insecure-registries", None)
if data:
    path.write_text(json.dumps(data, indent=2) + "\n")
else:
    path.unlink()
PY
  ui_step_ok "facility mirrors stripped"
fi

ui_step "keep" "local config"
ui_step_ok "/etc/facility-cache/config left in place"

ui_finish 0 "uninstalled"
ui_note "logs remain at $(ui_log_path 2>/dev/null || echo /var/log/facility-cache/)"
printf '\n'
