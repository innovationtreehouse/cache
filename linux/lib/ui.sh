# shellcheck shell=bash
# Terminal UI + fetchable JSONL log. Sourced, not executed.
# Visuals go to the TTY (or stderr). A JSON line is always appended to the log.

_UI_APP="${_UI_APP:-facility-cache}"
_UI_CMD="${_UI_CMD:-}"
_UI_SPIN_PID=""
_UI_STEP=""
_UI_N=0
_UI_I=0

_ui_log_candidates() {
  printf '%s\n' \
    /var/log/facility-cache/client.jsonl \
    /var/lib/facility-cache/logs/client.jsonl \
    "${XDG_STATE_HOME:-$HOME/.local/state}/facility-cache/client.jsonl" \
    "/tmp/facility-cache-${USER:-user}.jsonl"
}

ui_log_path() {
  local p dir
  if [[ -n "${FACILITY_CACHE_LOG:-}" ]]; then
    printf '%s\n' "$FACILITY_CACHE_LOG"
    return
  fi
  for p in $(_ui_log_candidates); do
    dir="$(dirname "$p")"
    if [[ -f "$p" && -w "$p" ]]; then
      printf '%s\n' "$p"
      return
    fi
    if mkdir -p "$dir" 2>/dev/null && [[ -w "$dir" ]]; then
      printf '%s\n' "$p"
      return
    fi
  done
  printf '%s\n' "/tmp/facility-cache-${USER:-user}.jsonl"
}

_ui_color=0
_ui_unicode=0
_ui_tty=0

_ui_init_caps() {
  _ui_color=0
  _ui_unicode=0
  _ui_tty=0
  if [[ -t 1 && -z "${NO_COLOR:-}" && "${TERM:-}" != "dumb" ]]; then
    _ui_color=1
    _ui_tty=1
  fi
  case "${LANG:-}${LC_ALL:-}${LC_CTYPE:-}" in
  *UTF-8* | *utf8* | *UTF8*) _ui_unicode=1 ;;
  esac
  if [[ "${FACILITY_CACHE_ASCII:-}" == 1 ]]; then
    _ui_unicode=0
  fi
}

_c() { # $1=code  rest=text
  local code="$1"
  shift
  if [[ "$_ui_color" -eq 1 ]]; then
    printf '\033[%sm%s\033[0m' "$code" "$*"
  else
    printf '%s' "$*"
  fi
}

_bold() { _c 1 "$*"; }
_dim() { _c 2 "$*"; }
_red() { _c 31 "$*"; }
_grn() { _c 32 "$*"; }
_ylw() { _c 33 "$*"; }
_blu() { _c 34 "$*"; }
_mag() { _c 35 "$*"; }
_cyn() { _c 36 "$*"; }

_g_ok() { if [[ "$_ui_unicode" -eq 1 ]]; then printf '✓'; else printf 'OK'; fi; }
_g_fail() { if [[ "$_ui_unicode" -eq 1 ]]; then printf '✗'; else printf 'X '; fi; }
_g_work() { if [[ "$_ui_unicode" -eq 1 ]]; then printf '●'; else printf '*'; fi; }
_g_off() { if [[ "$_ui_unicode" -eq 1 ]]; then printf '○'; else printf 'o'; fi; }
_g_warn() { if [[ "$_ui_unicode" -eq 1 ]]; then printf '!'; else printf '!'; fi; }
_g_info() { if [[ "$_ui_unicode" -eq 1 ]]; then printf 'i'; else printf 'i'; fi; }
_g_arr() { if [[ "$_ui_unicode" -eq 1 ]]; then printf '▸'; else printf '>'; fi; }

_ui_cols() {
  local c
  c="$(tput cols 2>/dev/null || true)"
  if [[ -z "$c" || "$c" -lt 40 ]]; then
    c=80
  fi
  printf '%s' "$c"
}

_ui_rule() {
  local n w i ch line=""
  w="$(_ui_cols)"
  [[ "$w" -gt 72 ]] && w=72
  n=$((w - 2))
  if [[ "$_ui_unicode" -eq 1 ]]; then
    ch='─'
  else
    ch='-'
  fi
  for ((i = 0; i < n; i++)); do
    line+="$ch"
  done
  printf '  %s\n' "$(_dim "$line")"
}

ui_log() {
  local level="$1" event="$2" msg="$3"
  local path extra ts
  path="$(ui_log_path)"
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date)"
  extra="${4:-{}}"
  mkdir -p "$(dirname "$path")" 2>/dev/null || true
  if [[ -w "$(dirname "$path")" ]] || [[ -w "$path" ]]; then
    printf '{"ts":"%s","level":"%s","cmd":"%s","event":"%s","msg":%s,"extra":%s}\n' \
      "$ts" "$level" "${_UI_CMD}" "$event" \
      "$(printf '%s' "$msg" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))' 2>/dev/null || printf '"%s"' "${msg//\"/\\\"}")" \
      "$extra" >>"$path" 2>/dev/null || true
    # rotate at ~2 MiB
    if [[ -f "$path" ]]; then
      local sz
      sz="$(wc -c <"$path" 2>/dev/null || echo 0)"
      if [[ "$sz" -gt 2000000 ]]; then
        mv -f "$path" "${path}.1" 2>/dev/null || true
      fi
    fi
  fi
}

ui_init() {
  _UI_CMD="$1"
  _UI_N="${2:-0}"
  _UI_I=0
  _ui_init_caps
  ui_log info start "start ${_UI_CMD}"
}

ui_banner() {
  local title="$1" subtitle="${2:-}"
  printf '\n  %s' "$(_bold "$(_cyn "$title")")"
  if [[ -n "$subtitle" ]]; then
    printf '  %s' "$(_dim "$subtitle")"
  fi
  printf '\n'
  _ui_rule
}

ui_kv() {
  local key="$1" val="$2" kind="${3:-}"
  local mark=""
  case "$kind" in
  ok) mark=" $(_grn "$(_g_ok)")" ;;
  fail) mark=" $(_red "$(_g_fail)")" ;;
  warn) mark=" $(_ylw "$(_g_warn)")" ;;
  on) mark=" $(_grn "$(_g_work)")" ;;
  off) mark=" $(_dim "$(_g_off)")" ;;
  work) mark=" $(_cyn "$(_g_work)")" ;;
  esac
  printf '  %s %-12s %s%s\n' "$(_dim "$(_g_arr)")" "$(_dim "$key")" "$val" "$mark"
}

ui_info() {
  printf '  %s %s\n' "$(_cyn "$(_g_info)")" "$*"
  ui_log info info "$*"
}
ui_ok() {
  printf '  %s %s\n' "$(_grn "$(_g_ok)")" "$*"
  ui_log info ok "$*"
}
ui_warn() {
  printf '  %s %s\n' "$(_ylw "$(_g_warn)")" "$*"
  ui_log warn warn "$*"
}
ui_fail() {
  printf '  %s %s\n' "$(_red "$(_g_fail)")" "$*"
  ui_log error fail "$*"
}
ui_note() { printf '  %s %s\n' "$(_dim " ")" "$*"; }

_ui_clear_line() {
  if [[ "$_ui_tty" -eq 1 ]]; then
    printf '\r\033[2K'
  fi
}

ui_spin_start() {
  _UI_STEP="$1"
  [[ "$_ui_tty" -eq 1 ]] || return 0
  [[ -z "$_UI_SPIN_PID" ]] || ui_spin_stop
  (
    local frames
    if [[ "$_ui_unicode" -eq 1 ]]; then
      frames='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
    else
      frames="|/-\\"
    fi
    local i=0 n=${#frames} ch
    while :; do
      ch="${frames:i%n:1}"
      printf '\r  %s %s  %s' "$(_cyn "$ch")" "$(_bold "$_UI_STEP")" "$(_dim "${2:-}")" >&2
      i=$((i + 1))
      sleep 0.08
    done
  ) &
  _UI_SPIN_PID=$!
  disown "$_UI_SPIN_PID" 2>/dev/null || true
}

ui_spin_stop() {
  if [[ -n "$_UI_SPIN_PID" ]]; then
    kill "$_UI_SPIN_PID" 2>/dev/null || true
    wait "$_UI_SPIN_PID" 2>/dev/null || true
    _UI_SPIN_PID=""
  fi
  _ui_clear_line >&2 || true
}

ui_step() {
  # ui_step NAME MESSAGE
  _UI_I=$((_UI_I + 1))
  _UI_STEP="$1"
  local msg="${2:-}"
  ui_log info step_start "$1: $msg" "{\"step\":\"$1\",\"i\":$_UI_I,\"n\":$_UI_N}"
  if [[ "$_ui_tty" -eq 1 && $_UI_N -gt 0 ]]; then
    printf '  %s %s/%s  %s  %s\n' \
      "$(_cyn "$(_g_work)")" "$(_dim "$_UI_I")" "$(_dim "$_UI_N")" \
      "$(_bold "$1")" "$(_dim "$msg")"
  else
    printf '  %s %s  %s\n' "$(_cyn "$(_g_work)")" "$(_bold "$1")" "$(_dim "$msg")"
  fi
}

_ui_replace_step_line() {
  if [[ "$_ui_tty" -eq 1 ]]; then
    printf '\033[1A\r\033[2K'
  fi
}

ui_step_ok() {
  local msg="${1:-done}"
  ui_spin_stop
  ui_log info step_ok "${_UI_STEP}: $msg" "{\"step\":\"$_UI_STEP\"}"
  _ui_replace_step_line
  if [[ $_UI_N -gt 0 ]]; then
    printf '  %s %s/%s  %s  %s\n' \
      "$(_grn "$(_g_ok)")" "$(_dim "$_UI_I")" "$(_dim "$_UI_N")" \
      "$(_bold "$_UI_STEP")" "$msg"
  else
    printf '  %s %s  %s\n' "$(_grn "$(_g_ok)")" "$(_bold "$_UI_STEP")" "$msg"
  fi
}

ui_step_fail() {
  local msg="${1:-failed}"
  ui_spin_stop
  ui_log error step_fail "${_UI_STEP}: $msg" "{\"step\":\"$_UI_STEP\"}"
  _ui_replace_step_line
  printf '  %s %s  %s\n' "$(_red "$(_g_fail)")" "$(_bold "$_UI_STEP")" "$(_red "$msg")"
}

ui_step_skip() {
  local msg="${1:-skipped}"
  ui_spin_stop
  ui_log info step_skip "${_UI_STEP}: $msg" "{\"step\":\"$_UI_STEP\"}"
  _ui_replace_step_line
  printf '  %s %s  %s\n' "$(_dim "$(_g_off)")" "$(_bold "$_UI_STEP")" "$(_dim "$msg")"
}

ui_bar() {
  # ui_bar CURRENT TOTAL LABEL
  local cur="$1" tot="$2" label="${3:-}"
  local width=24 pct filled rest i bar
  if [[ "$tot" -le 0 ]]; then
    tot=1
  fi
  pct=$((cur * 100 / tot))
  [[ "$pct" -gt 100 ]] && pct=100
  filled=$((width * pct / 100))
  rest=$((width - filled))
  bar=""
  for ((i = 0; i < filled; i++)); do bar+="█"; done
  for ((i = 0; i < rest; i++)); do bar+="░"; done
  if [[ "$_ui_unicode" -eq 0 ]]; then
    bar=""
    for ((i = 0; i < filled; i++)); do bar+="#"; done
    for ((i = 0; i < rest; i++)); do bar+="-"; done
  fi
  if [[ "$_ui_tty" -eq 1 ]]; then
    printf '\r  %s %s  %s %3d%%  %s' "$(_cyn "$(_g_work)")" "$(_cyn "$bar")" "$(_dim "${cur}/${tot}")" "$pct" "$(_dim "$label")"
    if [[ "$cur" -ge "$tot" ]]; then
      printf '\n'
    fi
  fi
}

ui_finish() {
  local code="${1:-0}" msg="${2:-}"
  ui_spin_stop
  _ui_rule
  if [[ "$code" -eq 0 ]]; then
    printf '  %s %s\n\n' "$(_grn "$(_g_ok)")" "${msg:-done}"
    ui_log info finish "${msg:-done}" "{\"code\":0}"
  else
    printf '  %s %s\n' "$(_red "$(_g_fail)")" "${msg:-failed}"
    printf '  %s %s\n\n' "$(_dim " ")" "$(_dim "log: $(ui_log_path)")"
    ui_log error finish "${msg:-failed}" "{\"code\":$code}"
  fi
  return "$code"
}

ui_hint_log() {
  printf '  %s %s\n' "$(_dim " ")" "$(_dim "log: $(ui_log_path)")"
}

_ui_init_caps
