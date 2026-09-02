#!/bin/bash
# Self-check for linux/lib/common.sh helpers. No root, no network:
# every var is pinned via FACILITY_CACHE_CONFIG (sourced last, always wins),
# so an installed /usr/local/lib/facility-cache/defaults can't skew results.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

cat >"$TMP/config" <<'EOF'
CACHE_HOST="cache.test.example"
EXPECTED_IP="10.9.9.9"
APT_PORT="1111"
PYPI_PORT="2222"
NPM_PORT="3333"
DOCKER_HUB_PORT="4444"
DOCKER_GHCR_PORT="5555"
EOF
export FACILITY_CACHE_CONFIG="$TMP/config"
# shellcheck disable=SC1091
source "$ROOT/linux/lib/common.sh"

pass=0 fail=0
check() { # check <name> <expected> <actual>
  if [[ "$2" == "$3" ]]; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    echo "FAIL $1: expected [$2] got [$3]" >&2
  fi
}

check config-override "cache.test.example" "$CACHE_HOST"
check cache_base_url "http://cache.test.example" "$(cache_base_url)"
check apt_proxy_url "http://cache.test.example:1111" "$(apt_proxy_url)"
check pypi_index_url "http://cache.test.example:2222/root/pypi/+simple/" "$(pypi_index_url)"
check npm_registry_url "http://cache.test.example:3333/" "$(npm_registry_url)"
check docker_hub_mirror "http://cache.test.example:4444" "$(docker_hub_mirror)"
check docker_hub_insecure "cache.test.example:4444" "$(docker_hub_insecure)"
check docker_ghcr_insecure "cache.test.example:5555" "$(docker_ghcr_insecure)"

# apt_proxy_should_direct: rewritten HTTPS backends already target the cache
apt_proxy_should_direct "http://cache.test.example:1111/cli.github.com/packages" && r=0 || r=1
check proxy-direct-cache-host 0 "$r"
apt_proxy_should_direct "http://10.9.9.9:1111/ubuntu" && r=0 || r=1
check proxy-direct-expected-ip 0 "$r"
apt_proxy_should_direct "http://archive.ubuntu.com/ubuntu" && r=0 || r=1
check proxy-proxy-ubuntu 1 "$r"
apt_proxy_should_direct "https://cli.github.com/packages" && r=0 || r=1
check proxy-proxy-cli-https 1 "$r"

# shellcheck disable=SC1091
source "$ROOT/linux/lib/ensure_gh.sh"
on_facility() { return 1; }
check gh-url-offsite "https://cli.github.com/packages" "$(github_cli_packages_url)"
on_facility() { return 0; }
check gh-url-onsite "http://cache.test.example:1111/cli.github.com/packages" "$(github_cli_packages_url)"

# file_is_managed: marker present / absent / missing file
printf '# %s\nkey=1\n' "$MANAGED_MARKER" >"$TMP/managed"
printf 'key=1\n' >"$TMP/unmanaged"
file_is_managed "$TMP/managed" && r=0 || r=1
check managed-detected 0 "$r"
file_is_managed "$TMP/unmanaged" && r=0 || r=1
check unmanaged-detected 1 "$r"
file_is_managed "$TMP/absent" && r=0 || r=1
check missing-detected 1 "$r"

# write_managed: creates parent dirs and writes stdin verbatim
printf 'line1\nline2\n' | write_managed "$TMP/deep/nested/file.conf"
check write_managed-content "line1
line2" "$(cat "$TMP/deep/nested/file.conf")"

# remove_managed: deletes only files carrying the marker
remove_managed "$TMP/managed"
[[ -f "$TMP/managed" ]] && r=present || r=gone
check remove-managed gone "$r"
remove_managed "$TMP/unmanaged"
[[ -f "$TMP/unmanaged" ]] && r=present || r=gone
check spare-unmanaged present "$r"

echo "test_common.sh: $pass passed, $fail failed"
[[ "$fail" -eq 0 ]]
