#!/usr/bin/env bash
# INI-style workplace parsing and validation.

# Parse an INI file into TAB-separated "section<TAB>key<TAB>value" records.
# Only full-line comments (# or ;) are supported so that values may contain
# those characters verbatim (regexes, shell commands).
config_parse() {
  local file=$1
  [[ -f $file ]] || die "no such file: $file"
  awk -v file="$file" '
    function trim(s) { sub(/^[ \t\r]+/, "", s); sub(/[ \t\r]+$/, "", s); return s }
    function fail(msg) { printf("%s:%d: %s\n", file, NR, msg) > "/dev/stderr"; errors++ }

    { line = trim($0) }
    line == "" { next }
    line ~ /^[#;]/ { next }

    line ~ /^\[/ {
      if (line !~ /^\[[^][]+\]$/) { fail("malformed section header: " line); next }
      section = trim(substr(line, 2, length(line) - 2))
      if (section == "") { fail("empty section name"); next }
      if (section in seen_section) { fail("duplicate section [" section "]"); next }
      seen_section[section] = 1
      next
    }

    {
      pos = index(line, "=")
      if (pos == 0) { fail("expected \"key = value\" or a [section] header: " line); next }
      if (section == "") { fail("key outside of any section: " line); next }
      key = trim(substr(line, 1, pos - 1))
      value = trim(substr(line, pos + 1))
      if (key == "") { fail("empty key: " line); next }
      if ((section SUBSEP key) in seen_key) {
        fail("duplicate key \"" key "\" in [" section "]"); next
      }
      seen_key[section SUBSEP key] = 1
      printf("%s\t%s\t%s\n", section, key, value)
    }

    END { if (errors) exit 1 }
  ' "$file"
}

# Load a workplace file into global arrays:
#   HW_META[key]              from [workplace]
#   HW_MONITORS[]             monitor outputs, in file order
#   HW_MON[output|key]        monitor settings
#   HW_WS_IDS[] / HW_WS[id]   workspace -> monitor
#   HW_APPS[] / HW_APP[name|key]
config_load() {
  local file=$1 parsed

  parsed=$(config_parse "$file") || die "$file: invalid workplace file"

  unset HW_META HW_MON HW_WS HW_APP HW_MONITORS HW_WS_IDS HW_APPS
  declare -gA HW_META=() HW_MON=() HW_WS=() HW_APP=()
  declare -ga HW_MONITORS=() HW_WS_IDS=() HW_APPS=()

  local section key value name
  while IFS=$'\t' read -r section key value; do
    [[ -n $section ]] || continue
    case $section in
      workplace)
        HW_META[$key]=$value
        ;;
      monitor.*)
        name=${section#monitor.}
        [[ -n $name ]] || die "$file: [monitor.] needs an output name"
        if [[ -z ${HW_MON[$name|__seen]:-} ]]; then
          HW_MONITORS+=("$name")
          HW_MON[$name|__seen]=1
        fi
        HW_MON[$name|$key]=$value
        ;;
      workspaces)
        HW_WS_IDS+=("$key")
        HW_WS[$key]=$value
        ;;
      app.*)
        name=${section#app.}
        [[ -n $name ]] || die "$file: [app.] needs a name"
        if [[ -z ${HW_APP[$name|__seen]:-} ]]; then
          HW_APPS+=("$name")
          HW_APP[$name|__seen]=1
        fi
        HW_APP[$name|$key]=$value
        ;;
      *)
        die "$file: unknown section [$section]"
        ;;
    esac
  done <<<"$parsed"
}

_config_check_keys() {
  local label=$1 allowed=$2
  shift 2
  local key
  for key in "$@"; do
    [[ $key == __seen ]] && continue
    [[ " $allowed " == *" $key "* ]] ||
      die "$label: unknown key '$key' (allowed: $allowed)"
  done
}

# Echo the keys of a "name|key" namespaced associative array for one name.
_config_keys_of() {
  local -n _arr=$1
  local name=$2 k
  for k in "${!_arr[@]}"; do
    [[ $k == "$name|"* ]] && printf '%s\n' "${k#"$name"|}"
  done
}

_config_monitor_known() {
  local m
  for m in "${HW_MONITORS[@]}"; do
    [[ $m == "$1" ]] && return 0
  done
  return 1
}

_config_monitor_enabled() {
  [[ ${HW_MON[$1|enabled]:-true} == true ]]
}

_config_valid_match() {
  local spec=$1
  [[ $spec == *:* ]] || return 1
  [[ -n ${spec#*:} ]] || return 1
  case ${spec%%:*} in
    class | title | initialClass | initialTitle) return 0 ;;
    *) return 1 ;;
  esac
}

# Validate the currently loaded workplace. Pass the file name for messages.
config_validate() {
  local file=$1
  local mon ws app value enabled_monitors=0
  local -a keys

  _config_check_keys "[workplace]" "name description unlisted gdk_scale" "${!HW_META[@]}"

  case ${HW_META[unlisted]:-auto} in
    auto | disable) ;;
    *) die "[workplace] unlisted must be 'auto' or 'disable'" ;;
  esac

  if [[ -n ${HW_META[gdk_scale]:-} && ! ${HW_META[gdk_scale]} =~ ^[1-9][0-9]*$ ]]; then
    die "[workplace] gdk_scale must be a positive integer"
  fi

  [[ ${#HW_MONITORS[@]} -gt 0 ]] ||
    die "$file: no [monitor.*] section defined"

  for mon in "${HW_MONITORS[@]}"; do
    mapfile -t keys < <(_config_keys_of HW_MON "$mon")
    _config_check_keys "[monitor.$mon]" \
      "mode position scale transform vrr mirror bitdepth enabled" "${keys[@]}"

    case ${HW_MON[$mon|enabled]:-true} in
      true) ;;
      false) continue ;;
      *) die "[monitor.$mon] enabled must be true or false" ;;
    esac
    enabled_monitors=$((enabled_monitors + 1))

    value=${HW_MON[$mon|mode]:-}
    [[ -n $value ]] || die "[monitor.$mon] missing required key 'mode'"
    [[ $value == preferred || $value == highres || $value == highrr ||
      $value =~ ^[0-9]+x[0-9]+(@[0-9]+(\.[0-9]+)?)?$ ]] ||
      die "[monitor.$mon] invalid mode '$value' (e.g. 1920x1200@60, preferred)"

    value=${HW_MON[$mon|position]:-auto}
    [[ $value == auto || $value =~ ^-?[0-9]+x-?[0-9]+$ ||
      $value =~ ^auto-(up|down|left|right)$ ]] ||
      die "[monitor.$mon] invalid position '$value' (e.g. 1920x0, auto, auto-right)"

    value=${HW_MON[$mon|scale]:-1}
    [[ $value == auto || $value =~ ^[0-9]+(\.[0-9]+)?$ ]] ||
      die "[monitor.$mon] invalid scale '$value' (e.g. 1, 1.5, auto)"

    value=${HW_MON[$mon|transform]:-0}
    [[ $value =~ ^[0-7]$ ]] ||
      die "[monitor.$mon] invalid transform '$value' (0-7, 1 = 90°, 3 = 270°)"

    value=${HW_MON[$mon|vrr]:-0}
    [[ $value =~ ^[0-3]$ ]] ||
      die "[monitor.$mon] invalid vrr '$value' (0-3)"
  done

  ((enabled_monitors > 0)) ||
    die "$file: every monitor is disabled, at least one must stay enabled"

  for ws in "${HW_WS_IDS[@]}"; do
    value=${HW_WS[$ws]}
    [[ -n $value ]] || die "[workspaces] workspace '$ws' has no monitor"
    _config_monitor_known "$value" ||
      die "[workspaces] workspace '$ws' references unknown monitor '$value'"
    _config_monitor_enabled "$value" ||
      die "[workspaces] workspace '$ws' is assigned to disabled monitor '$value'"
  done

  for app in "${HW_APPS[@]}"; do
    mapfile -t keys < <(_config_keys_of HW_APP "$app")
    _config_check_keys "[app.$app]" "workspace exec match autostart" "${keys[@]}"

    value=${HW_APP[$app|workspace]:-}
    [[ -n $value ]] || die "[app.$app] missing required key 'workspace'"

    value=${HW_APP[$app|match]:-}
    [[ -n $value ]] || die "[app.$app] missing required key 'match'"
    _config_valid_match "$value" ||
      die "[app.$app] invalid match '$value' (use class:<regex>, title:<regex>, initialClass:<regex> or initialTitle:<regex>)"

    value=${HW_APP[$app|autostart]:-true}
    case $value in
      true) ;;
      false) continue ;;
      *) die "[app.$app] autostart must be true or false" ;;
    esac

    [[ -n ${HW_APP[$app|exec]:-} ]] ||
      die "[app.$app] autostart requires 'exec' (or set autostart = false)"
  done
}

app_match_field() { printf '%s' "${HW_APP[$1|match]%%:*}"; }
app_match_regex() { printf '%s' "${HW_APP[$1|match]#*:}"; }
