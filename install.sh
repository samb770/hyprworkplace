#!/usr/bin/env bash
#
# Install hyprworkplace for the current user.
#
#   ./install.sh                  symlink the CLI and set up the integration
#   ./install.sh --with-examples  also copy the example workplaces
#   ./install.sh --uninstall      remove the symlink and the integration

set -euo pipefail

ROOT=$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)
BIN_DIR="${BIN_DIR:-$HOME/.local/bin}"
TARGET="$BIN_DIR/hyprworkplace"
WORKPLACES_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/hyprworkplace/workplaces"

with_examples=false
uninstall=false

for arg in "$@"; do
  case $arg in
    --with-examples) with_examples=true ;;
    --uninstall) uninstall=true ;;
    -h | --help)
      sed -n '2,8p' "$ROOT/install.sh" | sed 's/^# \?//'
      exit 0
      ;;
    *)
      printf 'install.sh: unknown option %s\n' "$arg" >&2
      exit 1
      ;;
  esac
done

if [[ $uninstall == true ]]; then
  if [[ -x $TARGET ]]; then
    "$TARGET" uninstall || true
  fi
  rm -f "$TARGET"
  printf 'Removed %s. Your workplaces in %s were kept.\n' "$TARGET" "$WORKPLACES_DIR"
  exit 0
fi

for cmd in bash awk sed jq; do
  command -v "$cmd" >/dev/null 2>&1 || {
    printf 'install.sh: missing dependency: %s\n' "$cmd" >&2
    exit 1
  }
done

mkdir -p "$BIN_DIR" "$WORKPLACES_DIR"
ln -sfn "$ROOT/bin/hyprworkplace" "$TARGET"
printf 'Linked %s -> %s\n' "$TARGET" "$ROOT/bin/hyprworkplace"

if [[ $with_examples == true ]]; then
  for example in "$ROOT"/examples/*.conf; do
    [[ -e $example ]] || continue
    name=${example##*/}
    if [[ -e $WORKPLACES_DIR/$name ]]; then
      printf 'Kept existing %s\n' "$WORKPLACES_DIR/$name"
      continue
    fi
    cp "$example" "$WORKPLACES_DIR/$name"
    printf 'Copied %s\n' "$WORKPLACES_DIR/$name"
  done
fi

"$TARGET" install

case ":$PATH:" in
  *":$BIN_DIR:"*) ;;
  *) printf '\nNote: %s is not on your PATH.\n' "$BIN_DIR" ;;
esac
