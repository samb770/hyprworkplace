#!/usr/bin/env bash
# Optional Omarchy integration. Everything here degrades gracefully on a
# plain Hyprland system.

OMARCHY_MENU_FILE="${OMARCHY_MENU_FILE:-${XDG_CONFIG_HOME:-$HOME/.config}/omarchy/extensions/omarchy-menu.jsonc}"
OMARCHY_MENU_BEGIN='// >>> hyprworkplace >>>'
OMARCHY_MENU_END='// <<< hyprworkplace <<<'

omarchy_available() {
  command -v omarchy >/dev/null 2>&1
}

# Desktop notification, best effort.
omarchy_notify() {
  local message=$1
  if command -v omarchy-notification-send >/dev/null 2>&1; then
    omarchy-notification-send -u low "hyprworkplace" "$message" >/dev/null 2>&1 || true
  elif command -v notify-send >/dev/null 2>&1; then
    notify-send -u low "hyprworkplace" "$message" >/dev/null 2>&1 || true
  fi
}

# Let the user pick one of the given options. Prints the choice on stdout.
omarchy_pick() {
  local prompt=$1
  shift
  (($# > 0)) || return 1

  if omarchy_available && [[ -n ${HYPRLAND_INSTANCE_SIGNATURE:-} ]]; then
    omarchy menu select "$prompt" "$@" 2>/dev/null && return 0
  fi

  if command -v fzf >/dev/null 2>&1 && [[ -t 0 ]]; then
    printf '%s\n' "$@" | fzf --prompt="$prompt > " && return 0
  fi

  if [[ -t 0 ]]; then
    local choice
    select choice in "$@"; do
      [[ -n $choice ]] || continue
      printf '%s\n' "$choice"
      return 0
    done
  fi

  return 1
}

omarchy_menu_installed() {
  [[ -f $OMARCHY_MENU_FILE ]] &&
    grep -qF -- "$OMARCHY_MENU_BEGIN" "$OMARCHY_MENU_FILE"
}

# True when the menu object already contains at least one real key, i.e.
# when our entry has to be followed by a comma to stay valid JSON.
_omarchy_menu_has_entries() {
  [[ -f $OMARCHY_MENU_FILE ]] &&
    grep -qE '^[[:space:]]*"' "$OMARCHY_MENU_FILE"
}

_omarchy_menu_block() {
  local comma=""
  if _omarchy_menu_has_entries; then
    comma=","
  fi
  cat <<EOF
  $OMARCHY_MENU_BEGIN
  // Managed by hyprworkplace. Remove with: hyprworkplace uninstall
  "workplace": {
    "icon": "\uf26c",
    "label": "Workplace",
    "description": "Switch monitor, workspace and app layout",
    "action": "hyprworkplace menu"
  }$comma
  $OMARCHY_MENU_END
EOF
}

# Insert a single "Workplace" row into the Omarchy menu, right after the
# opening brace of the JSONC object.
omarchy_menu_install() {
  local tmp

  if ! omarchy_available; then
    warn "omarchy not found, skipping menu integration"
    return 0
  fi

  if omarchy_menu_installed; then
    return 0
  fi

  if [[ ! -f $OMARCHY_MENU_FILE ]]; then
    mkdir -p "$(dirname "$OMARCHY_MENU_FILE")" ||
      die "could not create $(dirname "$OMARCHY_MENU_FILE")"
    {
      printf '{\n'
      _omarchy_menu_block
      printf '}\n'
    } >"$OMARCHY_MENU_FILE" || die "could not write $OMARCHY_MENU_FILE"
    ok "Added the Workplace entry to the Omarchy menu"
    return 0
  fi

  grep -q '{' "$OMARCHY_MENU_FILE" ||
    die "unexpected format in $OMARCHY_MENU_FILE, add the menu entry by hand"

  cp -p "$OMARCHY_MENU_FILE" "$OMARCHY_MENU_FILE.bak.$(date +%s)" ||
    die "could not back up $OMARCHY_MENU_FILE"

  tmp=$(mktemp) || die "could not create a temporary file"
  if ! awk -v block="$(_omarchy_menu_block)" '
        !done && index($0, "{") { print; print block; done = 1; next }
        { print }
      ' "$OMARCHY_MENU_FILE" >"$tmp"; then
    rm -f "$tmp"
    die "could not rewrite $OMARCHY_MENU_FILE"
  fi

  mv -f "$tmp" "$OMARCHY_MENU_FILE" || die "could not rewrite $OMARCHY_MENU_FILE"
  ok "Added the Workplace entry to the Omarchy menu"
}

omarchy_menu_remove() {
  local tmp

  if ! omarchy_menu_installed; then
    return 0
  fi

  cp -p "$OMARCHY_MENU_FILE" "$OMARCHY_MENU_FILE.bak.$(date +%s)" ||
    die "could not back up $OMARCHY_MENU_FILE"

  tmp=$(mktemp) || die "could not create a temporary file"
  if ! awk -v b="$OMARCHY_MENU_BEGIN" -v e="$OMARCHY_MENU_END" '
        index($0, b) { skip = 1 }
        !skip { print }
        index($0, e) { skip = 0 }
      ' "$OMARCHY_MENU_FILE" >"$tmp"; then
    rm -f "$tmp"
    die "could not rewrite $OMARCHY_MENU_FILE"
  fi

  mv -f "$tmp" "$OMARCHY_MENU_FILE" || die "could not rewrite $OMARCHY_MENU_FILE"
  ok "Removed the Workplace entry from the Omarchy menu"
}
