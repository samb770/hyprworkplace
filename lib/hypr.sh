#!/usr/bin/env bash
# Thin wrappers around hyprctl.

hypr_available() {
  [[ -n ${HYPRLAND_INSTANCE_SIGNATURE:-} ]] &&
    command -v hyprctl >/dev/null 2>&1
}

hypr_require() {
  hypr_available ||
    die "Hyprland does not seem to be running (HYPRLAND_INSTANCE_SIGNATURE is unset)"
}

hypr_monitors_json() {
  hyprctl monitors all -j 2>/dev/null || die "could not read monitors from hyprctl"
}

hypr_clients_json() {
  hyprctl clients -j 2>/dev/null || die "could not read clients from hyprctl"
}

# Names of every physically connected output, one per line.
hypr_connected_outputs() {
  hypr_monitors_json | jq -r '.[].name' | sort
}

# Reload the Hyprland config and surface configuration errors.
hypr_reload() {
  local errors
  hyprctl reload >/dev/null 2>&1 || die "hyprctl reload failed"

  errors=$(hyprctl configerrors 2>/dev/null) || return 0
  if [[ -n $errors && $errors != "no errors" ]]; then
    warn "Hyprland reported configuration errors:"
    printf '%s\n' "$errors" >&2
    return 1
  fi
  return 0
}

# Hyprland 0.52+ parses `hyprctl dispatch` as Lua, so the legacy
# "dispatcher args" form is a syntax error there. Detect which API this
# compositor speaks and cache the answer for the rest of the run.
HW_HYPR_API=""

hypr_api() {
  if [[ -z $HW_HYPR_API ]]; then
    if hyprctl eval 'return 1' >/dev/null 2>&1; then
      HW_HYPR_API=lua
    else
      HW_HYPR_API=legacy
    fi
  fi
  printf '%s\n' "$HW_HYPR_API"
}

# Wrap an arbitrary string as a Lua long-bracket literal. The level grows
# until the closing sequence does not occur inside the payload, so no
# escaping of quotes or backslashes is ever needed.
_lua_literal() {
  local s=$1 eq=""
  while [[ $s == *"]$eq]"* ]]; do
    eq+="="
  done
  printf '[%s[%s]%s]' "$eq" "$s" "$eq"
}

# Move a single window to a workspace without following it.
hypr_move_window() {
  local ws=$1 addr=$2 lua

  if [[ $(hypr_api) == lua ]]; then
    lua="return hl.dispatch(hl.dsp.window.move({ workspace = $(_lua_literal "$ws"),"
    lua+=" window = $(_lua_literal "address:$addr"), follow = false }))"
    hyprctl eval "$lua" >/dev/null 2>&1
  else
    hyprctl dispatch movetoworkspacesilent "$ws,address:$addr" >/dev/null 2>&1
  fi
}

# Launch a command directly on a workspace, without switching to it.
hypr_exec_on_workspace() {
  local ws=$1 cmd=$2 rule

  rule="[workspace $ws silent] $cmd"
  if [[ $(hypr_api) == lua ]]; then
    hyprctl eval "return hl.dispatch(hl.dsp.exec_cmd($(_lua_literal "$rule")))" \
      >/dev/null 2>&1
  else
    hyprctl dispatch exec "$rule" >/dev/null 2>&1
  fi
}

# Move already-running windows to their workspace and launch missing apps.
hypr_apply_apps() {
  local clients app field regex ws exec_cmd addr
  local -a addrs=()
  local moved=0 launched=0 skipped=0 failed=0

  ((${#HW_APPS[@]} > 0)) || return 0

  clients=$(hypr_clients_json)

  for app in "${HW_APPS[@]}"; do
    field=$(app_match_field "$app")
    regex=$(app_match_regex "$app")
    ws=${HW_APP[$app|workspace]}

    mapfile -t addrs < <(
      jq -r --arg f "$field" --arg re "$regex" \
        '.[] | select(((.[$f] // "") | tostring) | test($re)) | .address' \
        <<<"$clients"
    )

    if ((${#addrs[@]} > 0)); then
      for addr in "${addrs[@]}"; do
        [[ -n $addr ]] || continue
        if hypr_move_window "$ws" "$addr"; then
          moved=$((moved + 1))
        else
          failed=$((failed + 1))
          warn "could not move a window of '$app' to workspace $ws"
        fi
      done
      continue
    fi

    if [[ ${HW_APP[$app|autostart]:-true} != true ]]; then
      skipped=$((skipped + 1))
      continue
    fi

    exec_cmd=${HW_APP[$app|exec]}
    if hypr_exec_on_workspace "$ws" "$exec_cmd"; then
      launched=$((launched + 1))
    else
      failed=$((failed + 1))
      warn "could not launch '$app': $exec_cmd"
    fi
  done

  if ((failed > 0)); then
    printf 'apps: %d moved, %d launched, %d skipped, %d failed\n' \
      "$moved" "$launched" "$skipped" "$failed" >&2
    return 1
  fi

  printf 'apps: %d moved, %d launched, %d skipped\n' \
    "$moved" "$launched" "$skipped" >&2
}
