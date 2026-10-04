# hyprworkplace

Switch between **workplaces** on [Hyprland](https://hypr.land) and
[Omarchy](https://omarchy.org) with a single command.

A workplace bundles the three things that change when you move between a desk
and the road:

- **Monitors** — which outputs are on, their mode, position, scale and rotation
- **Workspaces** — which virtual desktop lives on which monitor
- **Apps** — which app belongs on which workspace, moved there or launched

Example output, with workplaces named after the author's own setups:

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
| `startup` | Detect and apply the best workplace, run at every login |
| `install` / `uninstall` | Add or remove the loader and the menu entry |

Useful flags: `apply --dry-run` prints the generated Lua instead of applying
it, `apply --no-apps` leaves your windows alone, and `detect --apply` applies
the detected workplace right away.

`apply` warns (but doesn't fail) if the workplace expects monitors that
aren't currently connected. `menu` detects the workplace that best matches
your connected monitors and puts it first in the list, labelled
`(detected)` (and `(active)` if it's also the one currently applied), so the
right choice is pre-selected when you hit `SUPER+SHIFT+W`.

## At login

`install` registers `hyprworkplace startup` with Hyprland, so **every start
picks the workplace that fits the hardware in front of you** instead of
replaying the one you happened to apply last:

1. It waits until `hyprctl` answers — at login the compositor needs a moment
   before it reports its monitors.
2. It detects the best match: every monitor a workplace needs must be
   connected, and the one matching the most monitors wins.
3. If nothing matches, it warns and applies the workplace marked
   `fallback = true` (typically the laptop-only one). Without such a marker
   it keeps the last active workplace and warns.
4. The winner is applied like `apply` does, including launching the apps that
   belong on each workspace.

```ini
[workplace]
name     = Notebook
fallback = true
```

Because the apps of a workplace are launched by `startup`, any app
autostart you had in `~/.config/hypr/autostart.lua` and any window rule in
`~/.config/hypr/windows.lua` that pins the same apps to a workspace should be
removed — otherwise both configurations fight over your windows after a
reboot.

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
| `fallback` | `false` | `true` marks this workplace as the one `startup` applies when no workplace matches the attached monitors |

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
| `split` | — | Tiling share in percent, see below |
| `pin` | `true` | `false` skips the persistent window rule, see below |

Find the values to match on with `hyprctl clients`. On Omarchy, prefix launch
commands with `uwsm-app --` so apps end up in the right systemd scope.

#### Splitting a workspace between two apps

Give exactly two apps on the same workspace a `split` percentage and they add
up to 100:

```ini
[app.browser]
workspace = 1
match     = class:^chromium$
exec      = omarchy launch browser
split     = 67

[app.terminal]
workspace = 1
match     = class:^foot$
exec      = uwsm-app -- foot
split     = 33
```

`apply` focuses the workspace, adjusts the dwindle split ratio between the
two windows to match, and restores whatever was focused before. This only
works for exactly two apps per workspace — `validate` rejects a lone `split`
without a sibling, percentages that don't add up to 100, or more than two.

#### Unpinning a shared window class

By default every `[app.*]` becomes a permanent Hyprland window rule: any
window matching `match` is pulled onto `workspace`, forever, even ones you
open later by hand. That is unwanted when `match` can't tell your app's main
window apart from other windows that happen to share the same class.

Chromium is the typical case. A plain browser window (`omarchy launch
browser`) runs with the generic class `chromium`, and that class is also
shared by private/incognito windows, file-picker dialogs, picture-in-picture
popups, and any other Chromium window that was not given its own class.
Pinning `^chromium$` to a workspace would therefore drag *all* of those
along too, including ones you deliberately opened or moved elsewhere.

Dedicated webapps (`omarchy launch webapp <url>`) don't have this problem:
each one gets its own distinct class (e.g.
`chrome-outlook.cloud.microsoft__mail_-Default`), so `match` only ever hits
that one window and pinning it is safe. The same goes for apps with a stable,
unique class such as VS Code.

Set `pin = false` to skip both the persistent rule and the forced move on
`apply`: an existing matching window is left wherever it currently is, and
`apply` only launches `exec` when no window matches at all.

```ini
[app.browser]
workspace = 1
match     = class:^chromium$
exec      = omarchy launch browser
pin       = false
```

## How it works

`apply` does not fight with your Hyprland config, it generates one:

1. The workplace is validated — unknown keys, impossible modes and workspaces
   pointing at missing monitors are caught before anything changes.
2. `~/.local/state/hyprworkplace/workplace.lua` is written using Omarchy's own
   helpers: `hl.monitor`, `hl.workspace_rule` and `o.window`.
3. A loader block at the end of `~/.config/hypr/monitors.lua` `dofile`s that
   generated file, so it overrides whatever you configured above it — and the
   workplace survives reloads, logouts and reboots. The same block registers
   `hyprworkplace startup` on `hyprland.start`, which re-detects the matching
   workplace on every login. `install` refreshes the block in place when it
   is out of date.
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
7. Apps with a `split` are handled last: hyprworkplace waits for both windows
   to exist, focuses the workspace and the first app's window, and sets the
   dwindle split ratio with `hl.dsp.layout('splitratio ... exact')`. Since
   that ratio describes the tiling tree's first child regardless of which
   window is focused, it measures the resulting sizes and flips the ratio
   once if the tree happened to place the apps the other way around.

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
- [x] Auto-detect and apply the matching workplace at login
- [ ] `watch` — apply automatically when a monitor is plugged in or removed
- [ ] Status bar widget showing the active workplace
- [ ] AUR package

## License

[MIT](LICENSE)
