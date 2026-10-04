# hyprworkplace

Switch between **workplaces** on [Hyprland](https://hypr.land) and
[Omarchy](https://omarchy.org) with a single command.

A workplace bundles the three things that change when you move between a desk
and the road:

- **Monitors** — which outputs are on, their mode, position, scale and rotation
- **Workspaces** — which virtual desktop lives on which monitor
- **Apps** — which app belongs on which workspace, moved there or launched

```console
$ hyprworkplace list
* home-s           Laptop with two external 1920x1200 monitors
  home-m           Laptop with the Samsung ultrawide above it
  laptop           Built-in panel only, external outputs disabled

$ hyprworkplace apply laptop
✓ Workplace 'Laptop' applied
```

No more editing `monitors.lua` by hand and no Hyprland restart.

## Install

Requires `bash`, `awk`, `sed`, `jq` and Hyprland.

```bash
git clone https://github.com/samb770/hyprworkplace.git
cd hyprworkplace
./install.sh --with-examples
```

`install.sh` links `bin/hyprworkplace` into `~/.local/bin`, appends a small
loader to `~/.config/hypr/monitors.lua` and — on Omarchy — adds a **Workplace**
entry to the menu. Everything it touches is backed up first, and
`./install.sh --uninstall` reverses it.

## Getting started

Capture your current setup, then edit it:

```bash
hyprworkplace new desk --from-current
```

This reads the running session and writes a ready-to-use workplace: every
attached monitor with its current mode and position, the current
workspace-to-monitor mapping, and one `[app.*]` section per open window with
its class already matched and escaped. Fill in the `exec` lines for the apps
you want started automatically and you are done.

```bash
hyprworkplace apply desk
```

## Commands

| Command | What it does |
|---|---|
| `list` | List all workplaces, marking the active one |
| `show <name>` | Show monitors, workspaces and apps in detail |
| `apply <name>` | Apply a workplace |
| `current` | Print the active workplace |
| `menu` | Pick a workplace interactively and apply it |
| `new <name>` | Create a workplace, optionally `--from-current` |
| `edit <name>` | Open it in `$EDITOR`, validate, offer to apply |
| `validate <name>` | Check it for errors |
| `remove <name>` | Delete it |
| `detect` | Suggest the workplace matching the attached monitors |
| `install` / `uninstall` | Add or remove the loader and the menu entry |

Useful flags: `apply --dry-run` prints the generated Lua instead of applying
it, `apply --no-apps` leaves your windows alone, and `detect --apply` applies
the detected workplace right away.

`apply` warns (but doesn't fail) if the workplace expects monitors that
aren't currently connected. `menu` detects the workplace that best matches
your connected monitors and puts it first in the list, labelled
`(detected)` (and `(active)` if it's also the one currently applied), so the
right choice is pre-selected when you hit `SUPER+SHIFT+W`.

## Workplace format

Workplaces live in `~/.config/hyprworkplace/workplaces/<name>.conf` and use a
plain INI syntax. Only whole-line comments (`#` or `;`) are recognised, so
regexes and commands may contain `#` safely.

```ini
[workplace]
name        = Home S
description = Laptop with two external 1920x1200 monitors
unlisted    = disable
gdk_scale   = 2

[monitor.DP-2]
mode     = 1920x1200
position = 0x0
scale    = 1

[monitor.eDP-1]
mode     = 1920x1200
position = 800x1200
scale    = 1

[monitor.DP-5]
enabled = false

[workspaces]
1 = eDP-1
2 = DP-2

[app.browser]
workspace = 2
match     = class:^chromium$
exec      = omarchy launch browser

[app.editor]
workspace = 1
match     = class:^com\.microsoft\.VSCode$
autostart = false
```

### `[workplace]`

| Key | Default | Meaning |
|---|---|---|
| `name` | the file name | Display name |
| `description` | — | One-line summary shown by `list` |
| `unlisted` | `auto` | What to do with monitors not listed here: `auto` keeps them at their preferred mode, `disable` switches them off |
| `gdk_scale` | — | Sets `GDK_SCALE`, matching Omarchy's own default of `2` |

### `[monitor.<output>]`

One section per connector; run `hyprctl monitors all` to see yours.
`mode` is required unless the monitor is disabled.

| Key | Default | Meaning |
|---|---|---|
| `mode` | — | `1920x1200@60`, `preferred`, `highres`, `highrr` |
| `position` | `auto` | `1920x0`, `auto`, `auto-right` |
| `scale` | `1` | `1`, `1.5`, `auto` |
| `transform` | `0` | `1` = 90°, `3` = 270° |
| `vrr` | `0` | Variable refresh rate, `0`–`3` |
| `mirror` | — | Mirror another output |
| `bitdepth` | — | For example `10` |
| `enabled` | `true` | `false` switches this output off |

### `[workspaces]`

`<workspace> = <monitor>`. The monitor must be defined and enabled above.

### `[app.<name>]`

| Key | Default | Meaning |
|---|---|---|
| `workspace` | — | Target workspace, required |
| `match` | — | `class:`, `title:`, `initialClass:` or `initialTitle:` followed by a regex, required |
| `exec` | — | Command used to start the app when no window matches |
| `autostart` | `true` | `false` only moves a running window, it never launches |

Find the values to match on with `hyprctl clients`. On Omarchy, prefix launch
commands with `uwsm-app --` so apps end up in the right systemd scope.

## How it works

`apply` does not fight with your Hyprland config, it generates one:

1. The workplace is validated — unknown keys, impossible modes and workspaces
   pointing at missing monitors are caught before anything changes.
2. `~/.local/state/hyprworkplace/workplace.lua` is written using Omarchy's own
   helpers: `hl.monitor`, `hl.workspace_rule` and `o.window`.
3. A loader block at the end of `~/.config/hypr/monitors.lua` `dofile`s that
   generated file, so it overrides whatever you configured above it — and the
   workplace survives reloads, logouts and reboots.
4. `hyprctl reload` applies it, and `hyprctl configerrors` is checked.
5. A `workspace_rule`'s `monitor` only takes effect for a workspace that is
   (re)created; one already showing on another monitor stays there, so every
   configured workspace is also explicitly moved to its monitor. This makes
   `apply` idempotent no matter what was active before.
6. Running windows are moved to their workspace without stealing focus, and
   missing apps are launched straight onto their workspace with
   `[workspace N silent]`. Hyprland 0.52 and newer parse `hyprctl dispatch`
   as Lua, so hyprworkplace detects that at runtime and uses `hyprctl eval`
   with `hl.dsp.window.move` / `hl.dsp.exec_cmd` there, falling back to the
   classic dispatcher strings on older versions.

Your own `monitors.lua` is never rewritten, only appended to — and backed up
before the one time that happens.

## Omarchy integration

Optional and auto-detected; on plain Hyprland everything still works.

- A **Workplace** entry in `~/.config/omarchy/extensions/omarchy-menu.jsonc`
- `omarchy menu select` as the picker behind `hyprworkplace menu`, falling back
  to `fzf` and then to a plain prompt
- Notifications through `omarchy-notification-send`

Suggested keybinding for `~/.config/hypr/bindings.lua`:

```lua
o.bind("SUPER + SHIFT + W", "Workplace", "hyprworkplace menu")
```

## Development

```bash
tests/run.sh            # run the suite
tests/run.sh lua        # only tests whose name contains "lua"
```

The tests run in a throwaway sandbox via `HW_CONFIG_HOME`, `HW_STATE_HOME` and
`HW_HYPR_CONFIG`, so they never touch your real configuration. See
[CONTRIBUTING.md](CONTRIBUTING.md), and [CONCEPT.md](CONCEPT.md) for the design
notes (in German).

## Roadmap

- [x] Workplaces for monitors, workspaces and apps
- [x] `new --from-current`, validation, `detect`
- [x] Omarchy menu entry and picker
- [ ] `watch` — apply automatically when a monitor is plugged in or removed
- [ ] Status bar widget showing the active workplace
- [ ] AUR package

## License

[MIT](LICENSE)
