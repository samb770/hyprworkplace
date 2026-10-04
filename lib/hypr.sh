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

# Wait until hyprctl answers. At login the compositor needs a moment before
# it reports its monitors, and asking too early yields an empty list.
hypr_wait() {
  local waited=0 step=0.2
  local limit=${HW_STARTUP_TIMEOUT:-30}

  command -v hyprctl >/dev/null 2>&1 || return 1

  while :; do
    if hyprctl monitors all -j >/dev/null 2>&1; then
      return 0
    fi
    awk -v w="$waited" -v l="$limit" 'BEGIN { exit !(w < l) }' || return 1
    sleep "$step"
    waited=$(awk -v w="$waited" -v s="$step" 'BEGIN { print w + s }')
  done
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

# A workspace_rule's `monitor` only takes effect when the workspace is
# (re)created; a workspace that is already visible on another monitor stays
# put until something moves it explicitly. Force every configured workspace
# onto its monitor so `apply` is idempotent regardless of prior state.
hypr_force_workspace_monitors() {
  local ws mon

  for ws in "${HW_WS_IDS[@]}"; do
    mon=${HW_WS[$ws]}
    [[ -n $mon ]] || continue

    if [[ $(hypr_api) == lua ]]; then
      hyprctl eval "return hl.dispatch(hl.dsp.workspace.move({ workspace = $(_lua_literal "$ws"), monitor = $(_lua_literal "$mon") }))" \
        >/dev/null 2>&1 ||
        warn "could not move workspace $ws to monitor $mon"
    else
      hyprctl dispatch moveworkspacetomonitor "$ws $mon" >/dev/null 2>&1 ||
        warn "could not move workspace $ws to monitor $mon"
    fi
  done
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

# Switch the input focus to a workspace, without moving any window.
hypr_focus_workspace() {
  local ws=$1
  if [[ $(hypr_api) == lua ]]; then
    hyprctl eval "return hl.dispatch(hl.dsp.focus({ workspace = $(_lua_literal "$ws") }))" \
      >/dev/null 2>&1
  else
    hyprctl dispatch workspace "$ws" >/dev/null 2>&1
  fi
}

# Focus a single window by address.
hypr_focus_window() {
  local addr=$1
  if [[ $(hypr_api) == lua ]]; then
    hyprctl eval "return hl.dispatch(hl.dsp.focus({ window = $(_lua_literal "address:$addr") }))" \
      >/dev/null 2>&1
  else
    hyprctl dispatch focuswindow "address:$addr" >/dev/null 2>&1
  fi
}

# Set the dwindle split ratio of the currently focused window's parent node.
# ratio is the raw splitratio value (0.1-1.9, 1.0 = 50/50).
hypr_set_splitratio() {
  local ratio=$1
  if [[ $(hypr_api) == lua ]]; then
    hyprctl eval "return hl.dispatch(hl.dsp.layout($(_lua_literal "splitratio $ratio exact")))" \
      >/dev/null 2>&1
  else
    hyprctl dispatch layoutmsg "splitratio $ratio exact" >/dev/null 2>&1
  fi
}

# Find the address of a window matching an app's rule on a specific
# workspace, polling briefly since a just-launched app maps asynchronously.
_hypr_find_window_on_workspace() {
  local field=$1 regex=$2 ws=$3
  local addr tries=0

  while ((tries < 20)); do
    addr=$(hypr_clients_json | jq -r --arg f "$field" --arg re "$regex" --arg ws "$ws" \
      '.[] | select(.workspace.id == ($ws | tonumber))
       | select(((.[$f] // "") | tostring) | test($re))
       | .address' | head -n1)
    if [[ -n $addr ]]; then
      printf '%s\n' "$addr"
      return 0
    fi
    sleep 0.1
    tries=$((tries + 1))
  done
  return 1
}

# Apply the left/right (or top/bottom) tiling ratio requested by apps that
# declare a 'split' percentage. Only workspaces with exactly two such apps
# qualify (config_validate already enforces that invariant).
hypr_apply_splits() {
  local app ws addr1 addr2 app1 app2 ratio target_pct actual_pct w1 w2
  local -A ws_apps=()
  local -a pair

  for app in "${HW_APPS[@]}"; do
    [[ -n $(app_split "$app") ]] || continue
    ws=${HW_APP[$app|workspace]}
    ws_apps[$ws]="${ws_apps[$ws]:-}${ws_apps[$ws]:+ }$app"
  done

  ((${#ws_apps[@]} > 0)) || return 0

  local restore_ws restore_addr
  restore_ws=$(hyprctl activeworkspace -j 2>/dev/null | jq -r '.id // empty')
  restore_addr=$(hyprctl activewindow -j 2>/dev/null | jq -r '.address // empty')

  for ws in "${!ws_apps[@]}"; do
    read -r -a pair <<<"${ws_apps[$ws]}"
    ((${#pair[@]} == 2)) || continue
    app1=${pair[0]}
    app2=${pair[1]}

    if ! addr1=$(_hypr_find_window_on_workspace "$(app_match_field "$app1")" "$(app_match_regex "$app1")" "$ws"); then
      warn "could not find a window for '$app1' to apply its split on workspace $ws"
      continue
    fi
    if ! addr2=$(_hypr_find_window_on_workspace "$(app_match_field "$app2")" "$(app_match_regex "$app2")" "$ws"); then
      warn "could not find a window for '$app2' to apply its split on workspace $ws"
      continue
    fi
    [[ $addr1 != "$addr2" ]] || continue

    hypr_focus_workspace "$ws"
    sleep 0.1
    hypr_focus_window "$addr1"
    sleep 0.1

    target_pct=$(app_split "$app1")
    ratio=$(awk -v p="$target_pct" 'BEGIN { printf "%.4f", p / 100 * 2 }')
    hypr_set_splitratio "$ratio"
    sleep 0.1

    # splitratio sets the tiling tree's first child's share, regardless of
    # which sibling is focused when it runs. Verify app1 actually ended up
    # with its requested share and flip the ratio once if the tree put it
    # in the other slot.
    w1=$(hyprctl clients -j 2>/dev/null | jq -r --arg a "$addr1" '.[] | select(.address == $a) | .size[0]')
    w2=$(hyprctl clients -j 2>/dev/null | jq -r --arg a "$addr2" '.[] | select(.address == $a) | .size[0]')
    if [[ -n $w1 && -n $w2 ]]; then
      actual_pct=$(awk -v a="$w1" -v b="$w2" 'BEGIN { printf "%d", (a / (a + b)) * 100 }')
      if ((actual_pct < target_pct - 5 || actual_pct > target_pct + 5)); then
        ratio=$(awk -v r="$ratio" 'BEGIN { printf "%.4f", 2 - r }')
        hypr_set_splitratio "$ratio"
      fi
    fi
  done

  [[ -n $restore_ws ]] && hypr_focus_workspace "$restore_ws"
  [[ -n $restore_addr ]] && hypr_focus_window "$restore_addr"
  return 0
}
