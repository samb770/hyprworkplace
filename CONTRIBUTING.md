# Contributing

Thanks for taking a look. Issues and pull requests are welcome.

## Getting set up

```bash
git clone https://github.com/<you>/hyprworkplace.git
cd hyprworkplace
./tests/run.sh
```

There is nothing to build. To try your changes without installing, run
`./bin/hyprworkplace` directly, or point the tool at a sandbox:

```bash
export HW_CONFIG_HOME=/tmp/hw/config
export HW_STATE_HOME=/tmp/hw/state
export HW_HYPR_CONFIG=/tmp/hw/hypr
mkdir -p "$HW_CONFIG_HOME/workplaces" "$HW_STATE_HOME" "$HW_HYPR_CONFIG"
./bin/hyprworkplace new demo
```

## Tests

`tests/run.sh` is a plain bash suite with no dependencies beyond `bash`, `awk`,
`sed` and `jq`. Each test runs in its own temporary sandbox, so the suite never
touches a real configuration or a running Hyprland session.

```bash
./tests/run.sh          # everything
./tests/run.sh lua      # only tests whose name contains "lua"
```

If `luac` or `lua` is installed, the suite also checks that the generated Lua
actually compiles. Please keep it installed while working on the generator.

Add a test for every bug you fix and every option you add. Register it in the
`main` function at the bottom of the file.

## Style

- Bash with `set -euo pipefail`, two-space indentation, `shellcheck`-clean.
- Prefer `if` over `cmd && other`, and `x=$((x + 1))` over `((x++))`; under
  `set -e` both of the short forms abort the script when the result is zero or
  false.
- Keep user-facing strings lowercase except for proper nouns, and make error
  messages say what to do next.
- Comments explain *why*, not *what*.

Run `shellcheck bin/hyprworkplace lib/*.sh install.sh tests/run.sh` before
opening a pull request; CI runs it too.

## Touching the generator

The generated Lua is the contract with Hyprland. It must only use the public
helpers:

- `hl.monitor({ output, mode, position, scale, transform, vrr, mirror, bitdepth, disabled })`
- `hl.workspace_rule({ workspace, monitor })`
- `o.window(match, rules)` — Omarchy's wrapper around `hl.window_rule`

Never emit raw `hyprctl keyword` strings, and never rewrite a user's config
file in place. Appending a clearly marked, removable block is the only
exception, and it always makes a timestamped backup first.

## Commit messages

One logical change per commit, imperative mood, for example
`Add vrr support to the monitor section`.
