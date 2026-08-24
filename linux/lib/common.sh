# shellcheck shell=bash
# Shared by facility-cache client scripts. Sourced, not executed.
# Package defaults (updated on each GitHub Release) then local overrides.

CACHE_HOST="${CACHE_HOST:-cache.facility.innovationtreehouse.org}"
EXPECTED_IP="${EXPECTED_IP:-192.168.1.200}"
APT_PORT="${APT_PORT:-3142}"
PYPI_PORT="${PYPI_PORT:-3141}"
NPM_PORT="${NPM_PORT:-4873}"
DOCKER_HUB_PORT="${DOCKER_HUB_PORT:-5000}"
DOCKER_GHCR_PORT="${DOCKER_GHCR_PORT:-5001}"
PROBE_TIMEOUT_SEC="${PROBE_TIMEOUT_SEC:-1}"
GITHUB_REPO="${GITHUB_REPO:-innovationtreehouse/cache}"
AUTO_UPDATE="${AUTO_UPDATE:-1}"

CONFIG_FILE="${FACILITY_CACHE_CONFIG:-/etc/facility-cache/config}"
RUN_DIR="${FACILITY_CACHE_RUN_DIR:-/run/facility-cache}"
# shellcheck disable=SC2034  # read by sourcing scripts
ENV_FILE="${RUN_DIR}/env"
# shellcheck disable=SC2034  # read by sourcing scripts
STAMP_FILE="${RUN_DIR}/on"
MANAGED_MARKER="facility-cache-managed"
# shellcheck disable=SC2034  # read by sourcing scripts
VERSION_FILE="/usr/local/lib/facility-cache/VERSION"
# shellcheck disable=SC2034  # read by sourcing scripts
STATE_FILE="/var/lib/facility-cache/state.json"

PIP_INDEX_PATH="/root/pypi/+simple/"

_COMMON_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)" || _COMMON_DIR=""
for _defaults in \
  /usr/local/lib/facility-cache/defaults \
  "${_COMMON_DIR}/defaults" \
  "${_COMMON_DIR}/../../defaults.env"; do
  if [[ -n "$_defaults" && -r "$_defaults" ]]; then
    # shellcheck disable=SC1090
    source "$_defaults"
    break
  fi
done
unset _defaults _COMMON_DIR

if [[ -r "$CONFIG_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$CONFIG_FILE"
fi

cache_base_url() {
  printf 'http://%s' "$CACHE_HOST"
}

apt_proxy_url() {
  printf 'http://%s:%s' "$CACHE_HOST" "$APT_PORT"
}

pypi_index_url() {
  printf 'http://%s:%s%s' "$CACHE_HOST" "$PYPI_PORT" "$PIP_INDEX_PATH"
}

npm_registry_url() {
  printf 'http://%s:%s/' "$CACHE_HOST" "$NPM_PORT"
}

docker_hub_mirror() {
  printf 'http://%s:%s' "$CACHE_HOST" "$DOCKER_HUB_PORT"
}

docker_hub_insecure() {
  printf '%s:%s' "$CACHE_HOST" "$DOCKER_HUB_PORT"
}

docker_ghcr_insecure() {
  printf '%s:%s' "$CACHE_HOST" "$DOCKER_GHCR_PORT"
}

# Print the IPv4 A records for CACHE_HOST, one per line. Empty if NXDOMAIN.
resolve_cache_ips() {
  local out=""
  out="$(getent ahostsv4 "$CACHE_HOST" 2>/dev/null || true)"
  if [[ -z "$out" ]]; then
    return 0
  fi
  printf '%s\n' "$out" | awk '{print $1}' | sort -u
}

# 0 if CACHE_HOST resolves to EXPECTED_IP.
dns_matches_expected() {
  local ip
  while read -r ip; do
    [[ "$ip" == "$EXPECTED_IP" ]] && return 0
  done < <(resolve_cache_ips)
  return 1
}

# TCP connect to EXPECTED_IP:port. Does not use the hostname (avoids extra DNS).
port_open() {
  local port="$1"
  timeout "$PROBE_TIMEOUT_SEC" bash -c "echo >/dev/tcp/${EXPECTED_IP}/${port}" >/dev/null 2>&1
}

# Full on-site check: our DNS name, our IP, and (optional) a port.
# Usage: on_facility [port]
on_facility() {
  dns_matches_expected || return 1
  if [[ $# -ge 1 ]]; then
    port_open "$1" || return 1
  fi
  return 0
}

file_is_managed() {
  local path="$1"
  [[ -f "$path" ]] && grep -q "$MANAGED_MARKER" "$path"
}

write_managed() {
  local path="$1"
  local dir tmp
  dir="$(dirname "$path")"
  mkdir -p "$dir"
  tmp="${path}.tmp"
  cat >"$tmp"
  if [[ -f "$path" ]] && cmp -s "$tmp" "$path"; then
    rm -f "$tmp"
    return 0
  fi
  mv -f "$tmp" "$path"
}

remove_managed() {
  local path="$1"
  if [[ -f "$path" ]] && file_is_managed "$path"; then
    rm -f "$path"
  fi
}

# True when apt's Proxy-Auto-Detect URI is already the cache itself.
# Rewritten HTTPS backends are http://CACHE_HOST:APT_PORT/https://… — proxying
# those through :3142 again would double-prefix the URL.
apt_proxy_should_direct() {
  local uri="${1:-}"
  local rest host
  rest="${uri#*://}"
  host="${rest%%[:/]*}"
  [[ -n "$host" && ("$host" == "$CACHE_HOST" || "$host" == "$EXPECTED_IP") ]]
}
