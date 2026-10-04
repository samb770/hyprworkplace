#!/usr/bin/env bash
# Shared paths, logging and small helpers.
#
# shellcheck disable=SC2034  # these are consumed by the other lib files

HW_CONFIG_HOME="${HW_CONFIG_HOME:-${XDG_CONFIG_HOME:-$HOME/.config}/hyprworkplace}"
HW_STATE_HOME="${HW_STATE_HOME:-${XDG_STATE_HOME:-$HOME/.local/state}/hyprworkplace}"
HW_HYPR_CONFIG="${HW_HYPR_CONFIG:-${XDG_CONFIG_HOME:-$HOME/.config}/hypr}"

HW_WORKPLACES_DIR="$HW_CONFIG_HOME/workplaces"
HW_GENERATED_LUA="$HW_STATE_HOME/workplace.lua"
HW_CURRENT_FILE="$HW_STATE_HOME/current"

HW_LOADER_BEGIN="-- >>> hyprworkplace >>>"
HW_LOADER_END="-- <<< hyprworkplace <<<"

# How long `startup` waits for Hyprland to answer, in seconds.
HW_STARTUP_TIMEOUT="${HW_STARTUP_TIMEOUT:-30}"

if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  HW_RED=$'\033[31m' HW_YELLOW=$'\033[33m' HW_GREEN=$'\033[32m'
  HW_BOLD=$'\033[1m' HW_DIM=$'\033[2m' HW_RESET=$'\033[0m'
else
  HW_RED='' HW_YELLOW='' HW_GREEN='' HW_BOLD='' HW_DIM='' HW_RESET=''
fi

die() {
  printf '%shyprworkplace:%s %s\n' "$HW_RED" "$HW_RESET" "$*" >&2
  exit 1
}

warn() {
  printf '%swarning:%s %s\n' "$HW_YELLOW" "$HW_RESET" "$*" >&2
}

info() {
  printf '%s\n' "$*" >&2
}

ok() {
  printf '%s✓%s %s\n' "$HW_GREEN" "$HW_RESET" "$*" >&2
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

ensure_dirs() {
  mkdir -p "$HW_WORKPLACES_DIR" "$HW_STATE_HOME"
}

# Validate a workplace name: lowercase letters, digits, dash, underscore.
validate_name() {
  local name="$1"
  [[ -n $name ]] || die "workplace name must not be empty"
  [[ $name =~ ^[a-zA-Z0-9][a-zA-Z0-9_-]*$ ]] ||
    die "invalid workplace name '$name' (use letters, digits, '-' and '_')"
}

workplace_file() {
  printf '%s/%s.conf' "$HW_WORKPLACES_DIR" "$1"
}

workplace_exists() {
  [[ -f $(workplace_file "$1") ]]
}

require_workplace() {
  validate_name "$1"
  workplace_exists "$1" ||
    die "unknown workplace '$1' (see: hyprworkplace list)"
}

list_workplace_names() {
  local f name
  [[ -d $HW_WORKPLACES_DIR ]] || return 0
  for f in "$HW_WORKPLACES_DIR"/*.conf; do
    [[ -e $f ]] || continue
    name=${f##*/}
    printf '%s\n' "${name%.conf}"
  done
}

current_workplace() {
  [[ -f $HW_CURRENT_FILE ]] || return 1
  local name
  name=$(<"$HW_CURRENT_FILE")
  [[ -n $name ]] || return 1
  printf '%s\n' "$name"
}

set_current_workplace() {
  mkdir -p "$HW_STATE_HOME"
  printf '%s\n' "$1" >"$HW_CURRENT_FILE"
}

# Quote a value for safe embedding in a Lua double-quoted string literal.
lua_quote() {
  local s=$1
  s=${s//\\/\\\\}
  s=${s//\"/\\\"}
  s=${s//$'\n'/\\n}
  printf '"%s"' "$s"
}

# Emit a Lua literal: bare for numbers/booleans, quoted otherwise.
lua_value() {
  local v=$1
  if [[ $v =~ ^-?[0-9]+(\.[0-9]+)?$ || $v == true || $v == false ]]; then
    printf '%s' "$v"
  else
    lua_quote "$v"
  fi
}
