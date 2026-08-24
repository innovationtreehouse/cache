# shellcheck shell=bash
# GitHub CLI (gh) via GitHub's apt repo. Sourced, not executed.
# On the facility LAN the source URL is rewritten through apt-cacher-ng
# (http://CACHE_HOST:APT_PORT/https://cli.github.com/packages) so the .deb
# is cached; off-site it is vanilla HTTPS.

GH_CLI_KEYRING="${GH_CLI_KEYRING:-/etc/apt/keyrings/facility-cache-githubcli.gpg}"
GH_CLI_LIST="${GH_CLI_LIST:-/etc/apt/sources.list.d/facility-cache-github-cli.list}"
GH_CLI_UPSTREAM="${GH_CLI_UPSTREAM:-https://cli.github.com/packages}"
GH_CLI_KEY_UPSTREAM="${GH_CLI_KEY_UPSTREAM:-https://cli.github.com/packages/githubcli-archive-keyring.gpg}"

github_cli_rewrite() {
  # $1 = https://host/path → http://CACHE_HOST:APT_PORT/https://host/path
  printf 'http://%s:%s/%s' "$CACHE_HOST" "$APT_PORT" "$1"
}

github_cli_packages_url() {
  if [[ "${GH_CLI_FORCE_UPSTREAM:-}" == 1 ]]; then
    printf '%s' "$GH_CLI_UPSTREAM"
    return
  fi
  if on_facility "$APT_PORT"; then
    github_cli_rewrite "$GH_CLI_UPSTREAM"
  else
    printf '%s' "$GH_CLI_UPSTREAM"
  fi
}

github_cli_http_get() {
  # github_cli_http_get <url> <dest> <timeout-sec>
  local url="$1" dest="$2" t="${3:-30}"
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL --max-time "$t" "$url" -o "$dest"
  elif command -v wget >/dev/null 2>&1; then
    wget -q -T "$t" -O "$dest" "$url"
  else
    return 1
  fi
}

github_cli_fetch() {
  # github_cli_fetch <upstream-url> <dest> — cache URL first when on-site.
  local upstream="$1" dest="$2"
  local timeout="${3:-30}"
  if on_facility "$APT_PORT"; then
    github_cli_http_get "$(github_cli_rewrite "$upstream")" "$dest" 20 && return 0
  fi
  github_cli_http_get "$upstream" "$dest" "$timeout"
}

github_cli_install_keyring() {
  local force="${1:-}" tmp
  if [[ -s "$GH_CLI_KEYRING" && "$force" != force ]]; then
    return 0
  fi
  tmp="$(mktemp)"
  if github_cli_fetch "$GH_CLI_KEY_UPSTREAM" "$tmp" 30 && [[ -s "$tmp" ]]; then
    install -d -m 0755 "$(dirname "$GH_CLI_KEYRING")"
    install -m 0644 "$tmp" "$GH_CLI_KEYRING"
    rm -f "$tmp"
    return 0
  fi
  rm -f "$tmp"
  [[ -s "$GH_CLI_KEYRING" ]]
}

github_cli_write_source() {
  local arch url
  github_cli_install_keyring "${1:-}" || return 1
  arch="$(dpkg --print-architecture 2>/dev/null || echo amd64)"
  url="$(github_cli_packages_url)"
  write_managed "$GH_CLI_LIST" <<EOF
# ${MANAGED_MARKER} — do not edit; facility-cache-apply rewrites the URL.
deb [arch=${arch} signed-by=${GH_CLI_KEYRING}] ${url} stable main
EOF
}

github_cli_apt_install() {
  export DEBIAN_FRONTEND=noninteractive
  apt-get update \
    -o Dir::Etc::sourcelist="$GH_CLI_LIST" \
    -o Dir::Etc::sourceparts=- \
    -o APT::Get::List-Cleanup=0 >/dev/null 2>&1 || return 1
  apt-get install -y \
    -o Dpkg::Options::=--force-confdef \
    -o Dpkg::Options::=--force-confold \
    gh >/dev/null 2>&1 || return 1
  hash -r 2>/dev/null || true
  command -v gh >/dev/null 2>&1
}

github_cli_ensure() {
  # Install gh if missing; upgrade if GitHub's apt repo has a newer version.
  # Never throws the caller off a cliff: return 1 on failure, 0 if gh is on PATH.
  if ! command -v apt-get >/dev/null 2>&1; then
    return 1
  fi
  if [[ "$(id -u)" -ne 0 ]]; then
    return 1
  fi
  github_cli_write_source force || return 1
  if github_cli_apt_install; then
    return 0
  fi
  # apt-cacher-ng may not map /https://… — fall back to vanilla GitHub HTTPS.
  if on_facility "$APT_PORT"; then
    GH_CLI_FORCE_UPSTREAM=1 github_cli_write_source force || true
    github_cli_apt_install && return 0
    github_cli_write_source || true
  fi
  return 1
}
