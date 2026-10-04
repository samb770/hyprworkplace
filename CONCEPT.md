# hyprworkplace — Konzept

## Idee

`hyprworkplace` ist ein Open-Source-CLI-Tool für **Omarchy**, mit dem sich
komplette **Arbeitsplätze (Workplaces)** definieren, bearbeiten und per
Befehl wechseln lassen. Ein Workplace beschreibt:

1. **Monitor-Konfiguration** — welche Displays aktiv sind, Auflösung,
   Position, Skalierung, Rotation
2. **Workspace-Zuordnung** — welcher virtuelle Desktop (Workspace) auf
   welchem Monitor liegt
3. **App-Zuordnung** — welche Anwendungen auf welchem Workspace geöffnet
   werden bzw. dorthin verschoben werden

Typische Workplaces: „Home S“ (Laptop + 2× Dell), „Home M“ (Laptop +
Samsung Ultrawide), „Unterwegs“ (nur Laptop), „Büro“ (Dock mit 2× 4K).
Der Wechsel passiert mit einem Befehl oder über das Omarchy-Menü, ohne
Hyprland neu zu starten oder Config-Dateien von Hand zu editieren.

## Ausgangslage

Heute lässt sich das in Omarchy nur manuell lösen: in
`~/.config/hypr/monitors.lua` eine `active_profile`-Variable umstellen,
die per `dofile()` eine von mehreren `monitors-<name>.lua` lädt. Das ist
umständlich, fehleranfällig, und die App-Zuordnung fehlt komplett.
`hyprworkplace` ersetzt diesen Handgriff durch ein sauberes Tool.

## Zielgruppe & Plattform

- **Primär:** Omarchy-Nutzer (Omarchy ≥ 4, Hyprland mit Lua-Config)
- Integration in Omarchy-Konventionen: `omarchy`-CLI-Stil, Menü-Eintrag,
  Hooks, `omarchy menu select` als Picker
- Grundfunktionen (apply/list/edit) funktionieren auch auf reinem
  Hyprland, Omarchy-Integration ist optional und wird zur Laufzeit
  erkannt.

## Lizenz

**MIT**. Das Projekt ist von Anfang an öffentlich (GitHub), Beiträge
sind willkommen. `LICENSE`, `README.md` und `CONTRIBUTING.md` gehören zum
ersten Release.

## Workplace-Format

Ein Workplace ist eine Datei `~/.config/hyprworkplace/workplaces/<name>.conf`
im einfachen INI-Stil — gut lesbar, mit jedem Editor bearbeitbar, ohne
Lua-Kenntnisse:

```ini
[workplace]
name        = Home S
description = Laptop + 2x Dell am Schreibtisch

[monitor.eDP-1]
mode     = 1920x1200
position = 800x1200
scale    = 1

[monitor.DP-2]
mode     = 1920x1200
position = 0x0
scale    = 1

[monitor.HDMI-A-1]
mode     = 1920x1200
position = 1920x0
scale    = 1

[workspaces]
1 = eDP-1
2 = DP-2
3 = HDMI-A-1
4 = HDMI-A-1
5 = HDMI-A-1
6 = HDMI-A-1

[app.terminal]
workspace = 1
exec      = alacritty
match     = class:^Alacritty$

[app.browser]
workspace = 2
exec      = omarchy launch browser
match     = class:^(chromium|Chromium|brave-browser)$

[app.editor]
workspace = 3
exec      = code
match     = class:^Code$
autostart = false        # nur verschieben, falls offen; nicht starten
```

Semantik:
- `[monitor.*]` → `hl.monitor({...})`; nicht gelistete Monitore werden
  per `disable` abgeschaltet.
- `[workspaces]` → `hl.workspace_rule({workspace, monitor})`.
- `[app.*]` → `o.window(match, { workspace = N })` als persistente
  Fensterregel **und** Laufzeit-Aktion beim Anwenden (siehe unten).

## Funktionsweise

### `apply <name>`

1. **Validieren** des Workplace (Syntax, Monitor-Namen gegen
   `hyprctl monitors all -j`).
2. **Lua generieren:** Das Tool schreibt
   `~/.config/hypr/workplace.lua` (Monitore, Workspace-Regeln,
   Fensterregeln) und sorgt einmalig dafür, dass `monitors.lua` diese
   Datei per `dofile()` lädt. Dadurch ist der Workplace **persistent**
   — er überlebt Hyprland-Neustarts und Logins.
3. **Reload:** `hyprctl reload` + `hyprctl configerrors` prüfen.
4. **Apps anwenden** (über `hyprctl --batch`, um Flackern zu vermeiden):
   - App läuft bereits (`match` gegen `hyprctl clients -j`) →
     `movetoworkspacesilent`.
   - App läuft nicht und `autostart` ≠ false →
     `exec "[workspace N silent] <exec>"`.
5. Aktiven Workplace in `~/.local/state/hyprworkplace/current` merken.
6. `notify-send` / `o.notify`-Stil: „Workplace ‚Home S' aktiv“.

### `edit <name>` / `new <name>`

- Öffnet die `.conf` im `$EDITOR`; nach dem Speichern automatisch
  `validate` und Rückfrage „Jetzt anwenden?“.
- `new` erzeugt eine Vorlage, optional **aus dem Ist-Zustand**:
  `hyprworkplace new buero --from-current` liest aktuelle Monitore und
  offene Fenster aus `hyprctl` und schreibt sie als Startpunkt in die
  Datei. Das ist der schnellste Weg, einen neuen Workplace anzulegen.

### `detect` / `watch` (Phase 2)

- `detect` vergleicht angeschlossene Monitore mit allen Workplaces und
  schlägt den passenden vor (`--apply` wendet ihn direkt an).
- `watch` lauscht auf Hyprland-IPC-Events (`monitoradded`/
  `monitorremoved`) und ruft `detect --apply` auf. Läuft als
  systemd-user-Service oder wird über `post-boot.d`-Hook gestartet.

## CLI

```
hyprworkplace list                   # Workplaces anzeigen (aktiver markiert)
hyprworkplace show <name>            # Details anzeigen
hyprworkplace apply <name>           # Workplace anwenden
hyprworkplace current                # aktiver Workplace
hyprworkplace new <name> [--from-current]
hyprworkplace edit <name>            # im $EDITOR öffnen, danach validieren
hyprworkplace validate <name>
hyprworkplace remove <name>
hyprworkplace detect [--apply]       # Phase 2
hyprworkplace watch                  # Phase 2
hyprworkplace menu                   # Picker via `omarchy menu select`
```

## Omarchy-Integration

- **Menü:** Eintrag in `~/.config/omarchy/extensions/omarchy-menu.jsonc`
  mit einem Untermenü pro Workplace (`checked` zeigt den aktiven an).
  Wird bei `hyprworkplace install` angelegt.
- **Keybinding:** Vorschlag `SUPER + SHIFT + W` → `hyprworkplace menu`
  (Picker über `omarchy menu select`).
- **Hooks:** `post-boot.d`-Hook wendet beim Login den zuletzt aktiven
  oder per `detect` erkannten Workplace an.
- **Bar (optional, Phase 3):** Widget mit dem aktiven Workplace-Namen,
  basierend auf einem geklonten Omarchy-Shell-Plugin.
- **Stil:** Hilfe-Ausgabe und Fehlermeldungen folgen dem Format der
  `omarchy-*`-Binaries.

## Architektur

```
hyprworkplace/
├── bin/hyprworkplace          # Haupt-CLI (Bash)
├── lib/
│   ├── config.sh              # INI-Parser, Validierung
│   ├── lua.sh                 # Lua-Generator (monitors/workspaces/windows)
│   ├── hypr.sh                # hyprctl-Wrapper, Client-Matching
│   └── omarchy.sh             # Menü/Hook/Picker-Integration (optional)
├── templates/
│   ├── workplace.conf         # Vorlage für `new`
│   └── omarchy-menu.jsonc     # Menü-Snippet
├── examples/
│   ├── home-s.conf
│   └── laptop-only.conf
├── install.sh                 # Symlink nach ~/.local/bin, Menü/Hook einrichten
├── tests/                     # bats-Tests für Parser & Lua-Generator
├── README.md
├── CONTRIBUTING.md
├── LICENSE                    # MIT
└── CONCEPT.md
```

## Technologie

- **Bash** + `jq` (für `hyprctl -j`), keine Compile-Schritte.
- Generiertes Lua nutzt ausschließlich Omarchys öffentliche Helfer
  (`hl.monitor`, `hl.workspace_rule`, `o.window`), keine Hyprland-
  Keyword-Strings von Hand.
- Installation: `git clone` + `./install.sh`; später AUR-Paket
  (`hyprworkplace-git`).
- Tests mit `bats`, Linting mit `shellcheck` (CI via GitHub Actions).

## Nicht-Ziele

- Kein Ersatz für die restliche Hyprland-/Omarchy-Config (Keybindings,
  Theming, Look & Feel) — `hyprworkplace` verwaltet nur Monitore,
  Workspaces und App-Platzierung.
- Keine GUI in Phase 1; Menü-/Picker-Integration ist die Oberfläche.
- Keine Fenster-Layouts innerhalb eines Workspaces (Tiling-Positionen) —
  das bleibt Hyprland bzw. Omarchys Workspace-Layouts überlassen.

## Roadmap

| Phase | Inhalt |
|-------|--------|
| 1 | `list/show/apply/current/new/edit/validate/remove`, Lua-Generator, Beispiele, README, MIT, Tests |
| 2 | `detect`, `watch`, post-boot-Hook, Menü-Integration, `--from-current` |
| 3 | Bar-Widget, AUR-Paket, pro-Workplace Overrides (Wallpaper, Idle-Zeit) |

## Offene Entscheidungen

1. Soll `apply` zusätzlich zur Lua-Generierung auch sofort
   `hyprctl keyword monitor` setzen (schnellerer Effekt), oder reicht
   `hyprctl reload`?
2. Matching-Default für Apps: nur `class`, oder `class` + `title` wie im
   Beispiel? Vorschlag: `class` als Default, `title` optional.
3. `watch`: systemd-user-Service (robust) vs. Start über
   `post-boot.d`-Hook (einfacher)? Vorschlag: beides anbieten,
   Hook als Default.
