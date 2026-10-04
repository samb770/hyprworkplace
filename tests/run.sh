#!/usr/bin/env bash
#
# Test suite for hyprworkplace. No dependencies beyond bash, awk, sed and jq.
#
#   tests/run.sh            run everything
#   tests/run.sh lua        run only tests whose name contains "lua"

set -uo pipefail

ROOT=$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)
CLI="$ROOT/bin/hyprworkplace"
FILTER=${1:-}

PASS=0
FAIL=0
FAILED_NAMES=()

if [[ -t 1 ]]; then
  GREEN=$'\033[32m' RED=$'\033[31m' DIM=$'\033[2m' RESET=$'\033[0m'
else
  GREEN='' RED='' DIM='' RESET=''
fi

setup_sandbox() {
  SANDBOX=$(mktemp -d)
  export HW_CONFIG_HOME="$SANDBOX/config/hyprworkplace"
  export HW_STATE_HOME="$SANDBOX/state/hyprworkplace"
  export HW_HYPR_CONFIG="$SANDBOX/config/hypr"
  export OMARCHY_MENU_FILE="$SANDBOX/config/omarchy/extensions/omarchy-menu.jsonc"
  export NO_COLOR=1
  mkdir -p "$HW_CONFIG_HOME/workplaces" "$HW_STATE_HOME" "$HW_HYPR_CONFIG"
  # Pretend Hyprland is not running so tests never touch a live session.
  unset HYPRLAND_INSTANCE_SIGNATURE
}

teardown_sandbox() {
  [[ -n ${SANDBOX:-} && -d $SANDBOX ]] && rm -rf "$SANDBOX"
}

it() {
  local name=$1
  shift
  if [[ -n $FILTER && $name != *"$FILTER"* ]]; then
    return 0
  fi

  setup_sandbox
  local output status
  output=$("$@" 2>&1)
  status=$?
  teardown_sandbox

  if ((status == 0)); then
    PASS=$((PASS + 1))
    printf '%s✓%s %s\n' "$GREEN" "$RESET" "$name"
  else
    FAIL=$((FAIL + 1))
    FAILED_NAMES+=("$name")
    printf '%s✗%s %s\n' "$RED" "$RESET" "$name"
    printf '%s%s%s\n' "$DIM" "${output//$'\n'/$'\n'  }" "$RESET"
  fi
}

assert_contains() {
  local haystack=$1 needle=$2
  if [[ $haystack != *"$needle"* ]]; then
    printf 'expected to contain: %s\ngot:\n%s\n' "$needle" "$haystack" >&2
    return 1
  fi
}

assert_not_contains() {
  local haystack=$1 needle=$2
  if [[ $haystack == *"$needle"* ]]; then
    printf 'expected NOT to contain: %s\ngot:\n%s\n' "$needle" "$haystack" >&2
    return 1
  fi
}

assert_eq() {
  if [[ $1 != "$2" ]]; then
    printf 'expected: %s\ngot:      %s\n' "$2" "$1" >&2
    return 1
  fi
}

# Write a workplace file into the sandbox.
write_workplace() {
  local name=$1
  cat >"$HW_CONFIG_HOME/workplaces/$name.conf"
}

valid_workplace() {
  cat <<'EOF'
[workplace]
name        = Desk
description = Two monitors
unlisted    = disable
gdk_scale   = 2

[monitor.eDP-1]
mode     = 1920x1200
position = 0x1440
scale    = 1

[monitor.HDMI-A-1]
mode     = 3440x1440@59.97
position = 0x0
scale    = 1
transform = 1

[monitor.DP-5]
enabled = false

[workspaces]
1 = eDP-1
2 = HDMI-A-1

[app.browser]
workspace = 2
match     = class:^chromium$
exec      = uwsm-app -- chromium

[app.editor]
workspace = 1
match     = title:^.*VSCode$
autostart = false
EOF
}

# --------------------------------------------------------------------------
# parser and validation
# --------------------------------------------------------------------------

test_valid_workplace_passes() {
  valid_workplace | write_workplace desk
  local out
  out=$("$CLI" validate desk 2>&1) || {
    printf '%s\n' "$out" >&2
    return 1
  }
  assert_contains "$out" "is valid"
}

test_unknown_section_is_rejected() {
  write_workplace bad <<'EOF'
[monitor.eDP-1]
mode = preferred

[bogus]
key = value
EOF
  local out
  out=$("$CLI" validate bad 2>&1) && return 1
  assert_contains "$out" "unknown section [bogus]"
}

test_unknown_key_is_rejected() {
  write_workplace bad <<'EOF'
[monitor.eDP-1]
mode = preferred
resolution = 1920x1080
EOF
  local out
  out=$("$CLI" validate bad 2>&1) && return 1
  assert_contains "$out" "unknown key 'resolution'"
}

test_duplicate_key_is_rejected() {
  write_workplace bad <<'EOF'
[monitor.eDP-1]
mode = preferred
mode = 1920x1080
EOF
  local out
  out=$("$CLI" validate bad 2>&1) && return 1
  assert_contains "$out" "duplicate key"
}

test_duplicate_section_is_rejected() {
  write_workplace bad <<'EOF'
[monitor.eDP-1]
mode = preferred

[monitor.eDP-1]
mode = 1920x1080
EOF
  local out
  out=$("$CLI" validate bad 2>&1) && return 1
  assert_contains "$out" "duplicate section"
}

test_missing_mode_is_rejected() {
  write_workplace bad <<'EOF'
[monitor.eDP-1]
position = 0x0
EOF
  local out
  out=$("$CLI" validate bad 2>&1) && return 1
  assert_contains "$out" "missing required key 'mode'"
}

test_invalid_mode_is_rejected() {
  write_workplace bad <<'EOF'
[monitor.eDP-1]
mode = 1920*1080
EOF
  local out
  out=$("$CLI" validate bad 2>&1) && return 1
  assert_contains "$out" "invalid mode"
}

test_workspace_on_unknown_monitor_is_rejected() {
  write_workplace bad <<'EOF'
[monitor.eDP-1]
mode = preferred

[workspaces]
1 = DP-9
EOF
  local out
  out=$("$CLI" validate bad 2>&1) && return 1
  assert_contains "$out" "unknown monitor 'DP-9'"
}

test_workspace_on_disabled_monitor_is_rejected() {
  write_workplace bad <<'EOF'
[monitor.eDP-1]
mode = preferred

[monitor.DP-2]
enabled = false

[workspaces]
1 = DP-2
EOF
  local out
  out=$("$CLI" validate bad 2>&1) && return 1
  assert_contains "$out" "disabled monitor 'DP-2'"
}

test_all_monitors_disabled_is_rejected() {
  write_workplace bad <<'EOF'
[monitor.eDP-1]
enabled = false
EOF
  local out
  out=$("$CLI" validate bad 2>&1) && return 1
  assert_contains "$out" "at least one must stay enabled"
}

test_app_without_match_is_rejected() {
  write_workplace bad <<'EOF'
[monitor.eDP-1]
mode = preferred

[workspaces]
1 = eDP-1

[app.term]
workspace = 1
exec      = alacritty
EOF
  local out
  out=$("$CLI" validate bad 2>&1) && return 1
  assert_contains "$out" "missing required key 'match'"
}

test_app_with_bad_match_field_is_rejected() {
  write_workplace bad <<'EOF'
[monitor.eDP-1]
mode = preferred

[workspaces]
1 = eDP-1

[app.term]
workspace = 1
match     = appid:^foo$
exec      = alacritty
EOF
  local out
  out=$("$CLI" validate bad 2>&1) && return 1
  assert_contains "$out" "invalid match"
}

test_autostart_without_exec_is_rejected() {
  write_workplace bad <<'EOF'
[monitor.eDP-1]
mode = preferred

[workspaces]
1 = eDP-1

[app.term]
workspace = 1
match     = class:^Alacritty$
EOF
  local out
  out=$("$CLI" validate bad 2>&1) && return 1
  assert_contains "$out" "autostart requires 'exec'"
}

test_comments_and_blank_lines_are_ignored() {
  write_workplace tidy <<'EOF'

# a comment
; another comment

[monitor.eDP-1]
mode = preferred

EOF
  "$CLI" validate tidy >/dev/null 2>&1
}

test_hash_inside_a_value_is_kept() {
  write_workplace hashy <<'EOF'
[monitor.eDP-1]
mode = preferred

[workspaces]
1 = eDP-1

[app.term]
workspace = 1
match     = title:^issue #1$
exec      = alacritty
EOF
  local out
  out=$("$CLI" apply hashy --dry-run 2>&1) || {
    printf '%s\n' "$out" >&2
    return 1
  }
  assert_contains "$out" 'issue #1'
}

# --------------------------------------------------------------------------
# lua generation
# --------------------------------------------------------------------------

test_lua_contains_monitors_workspaces_and_apps() {
  valid_workplace | write_workplace desk
  local out
  out=$("$CLI" apply desk --dry-run 2>&1) || {
    printf '%s\n' "$out" >&2
    return 1
  }
  assert_contains "$out" 'hl.monitor({ output = "eDP-1", mode = "1920x1200", position = "0x1440", scale = 1 })' || return 1
  assert_contains "$out" 'transform = 1' || return 1
  assert_contains "$out" 'hl.monitor({ output = "DP-5", disabled = true })' || return 1
  assert_contains "$out" 'hl.workspace_rule({ workspace = "1", monitor = "eDP-1" })' || return 1
  assert_contains "$out" 'o.window({ class = "^chromium$" }, { workspace = "2" })' || return 1
  assert_contains "$out" 'o.window({ title = "^.*VSCode$" }, { workspace = "1" })' || return 1
  assert_contains "$out" 'hl.env("GDK_SCALE", "2")'
}

test_lua_disables_unlisted_monitors_when_asked() {
  valid_workplace | write_workplace desk
  local out
  out=$("$CLI" apply desk --dry-run 2>&1) || return 1
  assert_contains "$out" 'hl.monitor({ output = "", disabled = true })'
}

test_lua_keeps_unlisted_monitors_on_auto() {
  write_workplace loose <<'EOF'
[workplace]
unlisted = auto

[monitor.eDP-1]
mode = preferred
EOF
  local out
  out=$("$CLI" apply loose --dry-run 2>&1) || return 1
  assert_contains "$out" 'hl.monitor({ output = "", mode = "preferred", position = "auto", scale = "auto" })'
}

test_lua_escapes_quotes_in_values() {
  write_workplace quoted <<'EOF'
[monitor.eDP-1]
mode = preferred

[workspaces]
1 = eDP-1

[app.term]
workspace = 1
match     = title:^say "hi"$
exec      = alacritty
EOF
  local out
  out=$("$CLI" apply quoted --dry-run 2>&1) || return 1
  assert_contains "$out" '\"hi\"'
}

test_dry_run_writes_nothing() {
  valid_workplace | write_workplace desk
  "$CLI" apply desk --dry-run >/dev/null 2>&1 || return 1
  [[ ! -e $HW_STATE_HOME/workplace.lua ]] || {
    printf 'dry-run created %s\n' "$HW_STATE_HOME/workplace.lua" >&2
    return 1
  }
  [[ ! -e $HW_HYPR_CONFIG/monitors.lua ]] || {
    printf 'dry-run touched monitors.lua\n' >&2
    return 1
  }
}

# --------------------------------------------------------------------------
# apply and loader
# --------------------------------------------------------------------------

test_apply_writes_lua_and_records_current() {
  valid_workplace | write_workplace desk
  "$CLI" apply desk >/dev/null 2>&1 || return 1
  [[ -s $HW_STATE_HOME/workplace.lua ]] || {
    printf 'no generated lua\n' >&2
    return 1
  }
  assert_eq "$("$CLI" current)" "desk"
}

test_apply_installs_the_loader_once() {
  valid_workplace | write_workplace desk
  printf -- '-- user monitors\n' >"$HW_HYPR_CONFIG/monitors.lua"

  "$CLI" apply desk >/dev/null 2>&1 || return 1
  "$CLI" apply desk >/dev/null 2>&1 || return 1

  local count
  count=$(grep -c -- '>>> hyprworkplace >>>' "$HW_HYPR_CONFIG/monitors.lua")
  assert_eq "$count" "1" || return 1
  assert_contains "$(cat "$HW_HYPR_CONFIG/monitors.lua")" "-- user monitors"
}

test_loader_is_appended_after_the_user_config() {
  valid_workplace | write_workplace desk
  printf -- '-- user monitors\n' >"$HW_HYPR_CONFIG/monitors.lua"
  "$CLI" apply desk >/dev/null 2>&1 || return 1

  local user_line loader_line
  user_line=$(grep -n -- '-- user monitors' "$HW_HYPR_CONFIG/monitors.lua" | cut -d: -f1)
  loader_line=$(grep -n -- '>>> hyprworkplace >>>' "$HW_HYPR_CONFIG/monitors.lua" | cut -d: -f1)
  ((user_line < loader_line))
}

lua_available() {
  command -v luac >/dev/null 2>&1 || command -v lua >/dev/null 2>&1
}

# Compile a Lua file without executing it.
lua_syntax_check() {
  if command -v luac >/dev/null 2>&1; then
    luac -p "$1"
  else
    LUA_CHECK_FILE="$1" lua -e 'assert(loadfile(os.getenv("LUA_CHECK_FILE")))'
  fi
}

test_generated_lua_is_valid_lua() {
  lua_available || {
    printf 'skipped: no lua interpreter\n'
    return 0
  }
  valid_workplace | write_workplace desk
  "$CLI" apply desk >/dev/null 2>&1 || return 1
  lua_syntax_check "$HW_STATE_HOME/workplace.lua"
}

test_loader_snippet_is_valid_lua() {
  lua_available || {
    printf 'skipped: no lua interpreter\n'
    return 0
  }
  valid_workplace | write_workplace desk
  "$CLI" apply desk >/dev/null 2>&1 || return 1
  lua_syntax_check "$HW_HYPR_CONFIG/monitors.lua"
}

test_uninstall_removes_the_loader_but_keeps_workplaces() {
  valid_workplace | write_workplace desk
  printf -- '-- user monitors\n' >"$HW_HYPR_CONFIG/monitors.lua"
  "$CLI" apply desk >/dev/null 2>&1 || return 1
  "$CLI" uninstall >/dev/null 2>&1 || return 1

  assert_not_contains "$(cat "$HW_HYPR_CONFIG/monitors.lua")" ">>> hyprworkplace >>>" || return 1
  assert_contains "$(cat "$HW_HYPR_CONFIG/monitors.lua")" "-- user monitors" || return 1
  [[ -f $HW_CONFIG_HOME/workplaces/desk.conf ]]
}

# --------------------------------------------------------------------------
# cli surface
# --------------------------------------------------------------------------

test_list_marks_the_active_workplace() {
  valid_workplace | write_workplace desk
  valid_workplace | write_workplace travel
  "$CLI" apply desk >/dev/null 2>&1 || return 1

  local out
  out=$("$CLI" list 2>&1)
  assert_contains "$out" "* desk" || return 1
  assert_contains "$out" "  travel"
}

test_list_is_friendly_when_empty() {
  local out
  out=$("$CLI" list 2>&1) || return 1
  assert_contains "$out" "No workplaces yet"
}

test_show_renders_sections() {
  valid_workplace | write_workplace desk
  local out
  out=$("$CLI" show desk 2>&1) || return 1
  assert_contains "$out" "Monitors" || return 1
  assert_contains "$out" "Workspaces" || return 1
  assert_contains "$out" "Apps" || return 1
  assert_contains "$out" "disabled"
}

test_unknown_workplace_fails_clearly() {
  local out
  out=$("$CLI" show nope 2>&1) && return 1
  assert_contains "$out" "unknown workplace 'nope'"
}

test_invalid_name_is_rejected() {
  local out
  out=$("$CLI" validate '../etc/passwd' 2>&1) && return 1
  assert_contains "$out" "invalid workplace name"
}

test_new_creates_from_template() {
  local out
  out=$("$CLI" new desk </dev/null 2>&1) || {
    printf '%s\n' "$out" >&2
    return 1
  }
  [[ -f $HW_CONFIG_HOME/workplaces/desk.conf ]] || return 1
  assert_contains "$(cat "$HW_CONFIG_HOME/workplaces/desk.conf")" "name        = desk" || return 1
  "$CLI" validate desk >/dev/null 2>&1
}

test_new_refuses_to_overwrite() {
  "$CLI" new desk </dev/null >/dev/null 2>&1 || return 1
  local out
  out=$("$CLI" new desk </dev/null 2>&1) && return 1
  assert_contains "$out" "already exists"
}

test_remove_deletes_and_clears_current() {
  valid_workplace | write_workplace desk
  "$CLI" apply desk >/dev/null 2>&1 || return 1
  "$CLI" remove desk --force >/dev/null 2>&1 || return 1

  [[ ! -f $HW_CONFIG_HOME/workplaces/desk.conf ]] || return 1
  "$CLI" current >/dev/null 2>&1 && return 1
  return 0
}

test_unknown_command_exits_nonzero() {
  local out
  out=$("$CLI" frobnicate 2>&1) && return 1
  assert_contains "$out" "unknown command"
}

test_help_lists_the_commands() {
  local out
  out=$("$CLI" help 2>&1) || return 1
  assert_contains "$out" "hyprworkplace <command>" || return 1
  assert_contains "$out" "detect"
}

test_version_is_printed() {
  local out
  out=$("$CLI" version 2>&1) || return 1
  assert_contains "$out" "hyprworkplace "
}

test_detect_needs_hyprland() {
  valid_workplace | write_workplace desk
  local out
  out=$("$CLI" detect 2>&1) && return 1
  assert_contains "$out" "Hyprland does not seem to be running"
}

# Fake a running Hyprland: `hyprctl` logs every invocation and answers just
# enough (monitors, empty clients, successful eval/reload) for apply/detect/
# menu to run end to end without a real compositor. $1 is a JSON array of
# connected monitor names, e.g. '["eDP-1","HDMI-A-1"]'.
fake_hyprland() (
  local monitors_json=$1
  local bindir="$SANDBOX/fakebin"
  mkdir -p "$bindir"
  printf '%s' "$monitors_json" >"$SANDBOX/monitors.json"
  : >"$SANDBOX/hyprctl.log"

  cat >"$bindir/hyprctl" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$SANDBOX/hyprctl.log"
case "\$1 \$2" in
  "monitors all") cat "$SANDBOX/monitors.json" ;;
  "clients -j") echo '[]' ;;
  *) ;;
esac
exit 0
EOF
  chmod +x "$bindir/hyprctl"
  printf '%s\n' "$bindir"
)

test_apply_warns_about_missing_monitor() {
  valid_workplace | write_workplace desk # needs eDP-1 and HDMI-A-1

  local bindir out
  bindir=$(fake_hyprland '[{"name":"eDP-1"}]') # HDMI-A-1 is not connected

  out=$(HYPRLAND_INSTANCE_SIGNATURE=test PATH="$bindir:$PATH" \
    "$CLI" apply desk 2>&1) || return 1
  assert_contains "$out" "HDMI-A-1" || return 1
  assert_contains "$out" "not connected"
}

test_menu_preselects_and_labels_the_detected_workplace() {
  valid_workplace | write_workplace desk # needs eDP-1 + HDMI-A-1 (best match)
  sed 's/^name        = Desk/name        = Alt/; s/HDMI-A-1/DP-9/g' \
    < <(valid_workplace) | write_workplace alt # needs eDP-1 + DP-9 (DP-9 missing)

  local bindir
  bindir=$(fake_hyprland '[{"name":"eDP-1"},{"name":"HDMI-A-1"}]')

  cat >"$bindir/omarchy" <<EOF
#!/usr/bin/env bash
# \$1=menu \$2=select \$3=prompt, the rest are the offered options. Echo the
# first option back verbatim, same as the raw-echo terminal fallbacks do;
# cmd_menu's parsing is written to handle that convention too.
shift 3
printf '%s\n' "\$1" >"$SANDBOX/first-option"
printf '%s\n' "\$@" >"$SANDBOX/all-options"
printf '%s\n' "\$1"
EOF
  chmod +x "$bindir/omarchy"

  HYPRLAND_INSTANCE_SIGNATURE=test PATH="$bindir:$PATH" \
    "$CLI" menu >/dev/null 2>&1 || return 1

  assert_contains "$(<"$SANDBOX/first-option")" "desk" || return 1
  assert_contains "$(<"$SANDBOX/first-option")" "detected" || return 1
  assert_eq "$("$CLI" current)" "desk"
}

# --------------------------------------------------------------------------
# shipped examples
# --------------------------------------------------------------------------

test_examples_are_valid() {
  local example name
  for example in "$ROOT"/examples/*.conf; do
    [[ -e $example ]] || continue
    name=${example##*/}
    name=${name%.conf}
    cp "$example" "$HW_CONFIG_HOME/workplaces/$name.conf"
    "$CLI" validate "$name" >/dev/null 2>&1 || {
      printf 'example %s is invalid:\n' "$example" >&2
      "$CLI" validate "$name" >&2
      return 1
    }
  done
}

test_template_is_valid() {
  sed 's/@NAME@/tmpl/g' "$ROOT/templates/workplace.conf" \
    >"$HW_CONFIG_HOME/workplaces/tmpl.conf"
  "$CLI" validate tmpl >/dev/null 2>&1
}

# --------------------------------------------------------------------------

# Run _lua_literal in a subshell; lib/hypr.sh only defines functions on load.
lua_literal() (
  # shellcheck source=../lib/hypr.sh
  source "$ROOT/lib/hypr.sh"
  _lua_literal "$1"
)

test_lua_literal_wraps_plain_text() {
  assert_eq "$(lua_literal 'uwsm-app -- foot')" '[[uwsm-app -- foot]]'
}

test_lua_literal_needs_no_escaping() {
  assert_eq "$(lua_literal 'a "quote" and a \ backslash')" \
    '[[a "quote" and a \ backslash]]'
}

test_lua_literal_escalates_bracket_level() {
  assert_eq "$(lua_literal 'ends with ]] inside')" '[=[ends with ]] inside]=]' &&
    assert_eq "$(lua_literal 'both ]] and ]=] inside')" \
      '[==[both ]] and ]=] inside]==]'
}

test_lua_literal_output_is_valid_lua() {
  lua_available || return 0
  local f="$SANDBOX/lit.lua"
  printf 'return %s\n' "$(lua_literal '[workspace 9 silent] foo ]] ]=] bar')" >"$f"
  lua_syntax_check "$f" ||
    {
      printf 'generated Lua literal does not parse\n' >&2
      return 1
    }
}

# Run hypr_force_workspace_monitors against a fake hyprctl that logs every
# invocation, so the two Hyprland API variants can be tested without one.
force_workspace_monitors_log() (
  local api=$1 # lua | legacy
  local bindir="$SANDBOX/fakebin"
  mkdir -p "$bindir"
  : >"$SANDBOX/hyprctl.log"

  cat >"$bindir/hyprctl" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$SANDBOX/hyprctl.log"
if [[ "\$1 \$2" == "eval return 1" ]]; then
  [[ $api == lua ]] && exit 0 || exit 1
fi
exit 0
EOF
  chmod +x "$bindir/hyprctl"

  PATH="$bindir:$PATH" bash -c '
    die() { exit 1; }; warn() { :; }
    source "'"$ROOT"'/lib/hypr.sh"
    HW_WS_IDS=(1 2)
    declare -A HW_WS=([1]=eDP-1 [2]=DP-2)
    hypr_force_workspace_monitors
  '
  cat "$SANDBOX/hyprctl.log"
)

test_force_workspace_monitors_uses_lua_eval() {
  local log
  log=$(force_workspace_monitors_log lua)
  assert_contains "$log" 'eval return hl.dispatch(hl.dsp.workspace.move({ workspace = [[1]], monitor = [[eDP-1]] }))' ||
    return 1
  assert_contains "$log" 'eval return hl.dispatch(hl.dsp.workspace.move({ workspace = [[2]], monitor = [[DP-2]] }))'
}

test_force_workspace_monitors_falls_back_to_legacy() {
  local log
  log=$(force_workspace_monitors_log legacy)
  assert_contains "$log" 'dispatch moveworkspacetomonitor 1 eDP-1' || return 1
  assert_contains "$log" 'dispatch moveworkspacetomonitor 2 DP-2'
}

test_edit_splits_editor_arguments() {
  valid_workplace | write_workplace desk

  cat >"$SANDBOX/fake-editor" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$@" >"$SANDBOX/editor-args"
EOF
  chmod +x "$SANDBOX/fake-editor"

  local out
  out=$(EDITOR="$SANDBOX/fake-editor --inline" "$CLI" edit desk </dev/null 2>&1) ||
    return 1
  assert_contains "$out" "is valid" || return 1

  local args
  args=$(<"$SANDBOX/editor-args")
  assert_contains "$args" "--inline" || return 1
  assert_contains "$args" "desk.conf"
}

test_edit_prefers_visual_over_editor() {
  valid_workplace | write_workplace desk

  cat >"$SANDBOX/fake-editor" <<EOF
#!/usr/bin/env bash
printf 'visual\n' >"$SANDBOX/editor-args"
EOF
  chmod +x "$SANDBOX/fake-editor"

  VISUAL="$SANDBOX/fake-editor" EDITOR=definitely-not-installed \
    "$CLI" edit desk </dev/null >/dev/null 2>&1 || return 1
  assert_eq "$(<"$SANDBOX/editor-args")" visual
}

test_edit_reports_a_missing_editor() {
  valid_workplace | write_workplace desk
  local out
  out=$(VISUAL="" EDITOR="definitely-not-installed --inline" \
    "$CLI" edit desk </dev/null 2>&1) && return 1
  assert_contains "$out" "editor 'definitely-not-installed' not found"
}

main() {
  it "valid workplace passes" test_valid_workplace_passes
  it "unknown section is rejected" test_unknown_section_is_rejected
  it "unknown key is rejected" test_unknown_key_is_rejected
  it "duplicate key is rejected" test_duplicate_key_is_rejected
  it "duplicate section is rejected" test_duplicate_section_is_rejected
  it "missing mode is rejected" test_missing_mode_is_rejected
  it "invalid mode is rejected" test_invalid_mode_is_rejected
  it "workspace on unknown monitor is rejected" test_workspace_on_unknown_monitor_is_rejected
  it "workspace on disabled monitor is rejected" test_workspace_on_disabled_monitor_is_rejected
  it "all monitors disabled is rejected" test_all_monitors_disabled_is_rejected
  it "app without match is rejected" test_app_without_match_is_rejected
  it "app with bad match field is rejected" test_app_with_bad_match_field_is_rejected
  it "autostart without exec is rejected" test_autostart_without_exec_is_rejected
  it "comments and blank lines are ignored" test_comments_and_blank_lines_are_ignored
  it "hash inside a value is kept" test_hash_inside_a_value_is_kept

  it "lua contains monitors, workspaces and apps" test_lua_contains_monitors_workspaces_and_apps
  it "lua disables unlisted monitors when asked" test_lua_disables_unlisted_monitors_when_asked
  it "lua keeps unlisted monitors on auto" test_lua_keeps_unlisted_monitors_on_auto
  it "lua escapes quotes in values" test_lua_escapes_quotes_in_values
  it "lua dry run writes nothing" test_dry_run_writes_nothing
  it "generated lua parses as lua" test_generated_lua_is_valid_lua
  it "loader snippet parses as lua" test_loader_snippet_is_valid_lua

  it "apply writes lua and records current" test_apply_writes_lua_and_records_current
  it "apply installs the loader once" test_apply_installs_the_loader_once
  it "loader is appended after the user config" test_loader_is_appended_after_the_user_config
  it "uninstall removes the loader but keeps workplaces" test_uninstall_removes_the_loader_but_keeps_workplaces

  it "list marks the active workplace" test_list_marks_the_active_workplace
  it "list is friendly when empty" test_list_is_friendly_when_empty
  it "show renders sections" test_show_renders_sections
  it "unknown workplace fails clearly" test_unknown_workplace_fails_clearly
  it "invalid name is rejected" test_invalid_name_is_rejected
  it "new creates from template" test_new_creates_from_template
  it "new refuses to overwrite" test_new_refuses_to_overwrite
  it "remove deletes and clears current" test_remove_deletes_and_clears_current
  it "unknown command exits nonzero" test_unknown_command_exits_nonzero
  it "help lists the commands" test_help_lists_the_commands
  it "version is printed" test_version_is_printed
  it "detect needs hyprland" test_detect_needs_hyprland
  it "apply warns about a missing monitor" test_apply_warns_about_missing_monitor
  it "menu preselects and labels the detected workplace" test_menu_preselects_and_labels_the_detected_workplace

  it "lua literal wraps plain text" test_lua_literal_wraps_plain_text
  it "lua literal needs no escaping" test_lua_literal_needs_no_escaping
  it "lua literal escalates bracket level" test_lua_literal_escalates_bracket_level
  it "lua literal output is valid lua" test_lua_literal_output_is_valid_lua

  it "force workspace monitors uses lua eval" test_force_workspace_monitors_uses_lua_eval
  it "force workspace monitors falls back to legacy" test_force_workspace_monitors_falls_back_to_legacy
  it "edit splits editor arguments" test_edit_splits_editor_arguments
  it "edit prefers VISUAL over EDITOR" test_edit_prefers_visual_over_editor
  it "edit reports a missing editor" test_edit_reports_a_missing_editor

  it "shipped examples are valid" test_examples_are_valid
  it "shipped template is valid" test_template_is_valid

  printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
  if ((FAIL > 0)); then
    printf 'failed: %s\n' "${FAILED_NAMES[*]}"
    exit 1
  fi
}

main
