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

_hypr_batch() {
  # Join the given dispatch commands with " ; " and send them in one go.
  local joined=""
  local cmd
  for cmd in "$@"; do
    if [[ -n $joined ]]; then
      joined+=" ; "
    fi
    joined+="$cmd"
  done
  [[ -n $joined ]] || return 0
  hyprctl --batch "$joined" >/dev/null 2>&1 ||
    warn "some hyprctl dispatches failed"
}

# Move already-running windows to their workspace and launch missing apps.
hypr_apply_apps() {
  local clients app field regex ws exec_cmd addr
  local -a addrs=() batch=()
  local moved=0 launched=0 skipped=0

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
        batch+=("dispatch movetoworkspacesilent $ws,address:$addr")
      done
      moved=$((moved + ${#addrs[@]}))
      continue
    fi

    if [[ ${HW_APP[$app|autostart]:-true} != true ]]; then
      skipped=$((skipped + 1))
      continue
    fi

    exec_cmd=${HW_APP[$app|exec]}
    # Launched separately: exec arguments may contain the batch separator.
    if hyprctl dispatch exec "[workspace $ws silent] $exec_cmd" >/dev/null 2>&1; then
      launched=$((launched + 1))
    else
      warn "could not launch '$app': $exec_cmd"
    fi
  done

  _hypr_batch "${batch[@]}"

  printf 'apps: %d moved, %d launched, %d skipped\n' \
    "$moved" "$launched" "$skipped" >&2
}
