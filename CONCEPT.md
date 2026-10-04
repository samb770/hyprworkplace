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
unlisted    = disable
gdk_scale   = 2

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

# autostart = false verschiebt nur ein offenes Fenster, startet nie
[app.editor]
workspace = 3
match     = class:^Code$
autostart = false

# split: zwei Apps am selben Workspace teilen sich die Fläche prozentual
[app.browser2]
workspace = 1
match     = class:^chromium$
exec      = omarchy launch browser
split     = 67

[app.terminal2]
workspace = 1
match     = class:^foot$
exec      = uwsm-app -- foot
split     = 33
```

Semantik:
- `[workplace] unlisted` steuert nicht gelistete Monitore: `auto`
  (preferred/auto, Standard) oder `disable` (abschalten).
- `[monitor.*]` → `hl.monitor({...})`. `mode` ist Pflicht, optional sind
  `position`, `scale`, `transform`, `vrr`, `mirror`, `bitdepth` und
  `enabled = false`.
- `[workspaces]` → `hl.workspace_rule({workspace, monitor})`. Der Monitor
  muss oben definiert und aktiv sein.
- `[app.*]` → `o.window(match, { workspace = N })` als persistente
  Fensterregel **und** Laufzeit-Aktion beim Anwenden (siehe unten).
  `match` ist Pflicht und trägt das Feld im Präfix (`class:`, `title:`,
  `initialClass:`, `initialTitle:`), damit nichts geraten wird.
- `split = <1-99>` (Prozent) teilt einen Workspace zwischen genau zwei
  Apps auf, deren Werte sich zu 100 addieren müssen — `validate` prüft
  das (fehlender Partner, falsche Summe, mehr als zwei Apps sind Fehler).
- Kommentare sind nur zeilenweise erlaubt (`#`/`;`), damit Regexe und
  Befehle ein `#` enthalten dürfen.

## Funktionsweise

### `apply <name>`

1. **Validieren** des Workplace (Syntax, Monitor-Namen gegen
   `hyprctl monitors all -j`).
2. **Lua generieren:** Das Tool schreibt
   `~/.local/state/hyprworkplace/workplace.lua` (Monitore,
   Workspace-Regeln, Fensterregeln) und hängt einmalig einen markierten
   Loader-Block ans Ende von `~/.config/hypr/monitors.lua`, der die
   Datei per `dofile()` lädt. Weil er zuletzt läuft, überschreibt er die
   eigene Config — und der Workplace ist **persistent**, er überlebt
   Reload, Logout und Neustart. Vorher wird `monitors.lua` gesichert.
3. **Reload:** `hyprctl reload` + `hyprctl configerrors` prüfen.
4. **Apps anwenden** (ohne den Fokus zu verschieben):
   - App läuft bereits (`match` gegen `hyprctl clients -j`) → Fenster auf
     seinen Workspace verschieben.
   - App läuft nicht und `autostart` ≠ false →
     `exec "[workspace N silent] <exec>"`.

   Ab Hyprland 0.52 ist `hyprctl dispatch` ein Lua-Ausdruck, die alte
   `dispatcher args`-Form ist dort ein Syntaxfehler. hyprworkplace erkennt
   das zur Laufzeit und nutzt dann `hyprctl eval` mit `hl.dsp.window.move`
   bzw. `hl.dsp.exec_cmd`; auf älteren Versionen bleibt es bei den
   klassischen Dispatcher-Strings.
5. **Splits anwenden:** Für jedes Workspace-Paar mit `split` wird gewartet,
   bis beide Fenster existieren, der Workspace und das erste Fenster
   fokussiert, und per `hl.dsp.layout('splitratio <wert> exact')` das
   Dwindle-Verhältnis gesetzt. Das Verhältnis gilt immer für das erste
   Kind im Tiling-Baum — unabhängig vom Fokus — daher wird die
   resultierende Fenstergröße gemessen und bei Bedarf einmal invertiert.
   Danach wird der ursprüngliche Fokus (Workspace + Fenster)
   wiederhergestellt.
6. Aktiven Workplace in `~/.local/state/hyprworkplace/current` merken.
7. `notify-send` / `o.notify`-Stil: „Workplace ‚Home S' aktiv“.

### `edit <name>` / `new <name>`

- Öffnet die `.conf` im `$EDITOR`; nach dem Speichern automatisch
  `validate` und Rückfrage „Jetzt anwenden?“.
- `new` erzeugt eine Vorlage, optional **aus dem Ist-Zustand**:
  `hyprworkplace new buero --from-current` liest aktuelle Monitore und
  offene Fenster aus `hyprctl` und schreibt sie als Startpunkt in die
  Datei. Das ist der schnellste Weg, einen neuen Workplace anzulegen.

### `detect` / `startup` / `watch`

- `detect` vergleicht angeschlossene Monitore mit allen Workplaces und
  schlägt den passenden vor (`--apply` wendet ihn direkt an). Gewählt
  wird der Workplace, dessen Monitore alle vorhanden sind und der davon
  die meisten nutzt.
- Passt keiner, greift der Workplace mit `fallback = true` — typischerweise
  die Nur-Laptop-Konfiguration. `detect` gibt ihn mit einer Warnung aus.
- `startup` ist der Login-Pfad: wartet auf `hyprctl`, erkennt den passenden
  Workplace (inkl. Fallback, sonst der zuletzt aktive) und wendet ihn an.
  Registriert wird er vom Loader-Block in `monitors.lua` über
  `o.exec_on_start` bzw. `hl.on("hyprland.start", ...)`. Damit lädt ein
  Reboot nie mehr eine zur Hardware unpassende Konfiguration, und die Apps
  landen ohne `autostart.lua`-Duplikate auf ihren Workspaces.
- `watch` (geplant) lauscht auf Hyprland-IPC-Events (`monitoradded`/
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
hyprworkplace detect [--apply]       # passenden Workplace erkennen
hyprworkplace startup                # beim Login: erkennen + anwenden
hyprworkplace menu                   # Picker via `omarchy menu select`
hyprworkplace install | uninstall    # Loader + Menü ein-/ausrichten
hyprworkplace watch                  # geplant (Phase 2)
```

Flags: `apply --dry-run` zeigt nur das generierte Lua, `apply --no-apps`
lässt Fenster unangetastet, `new --from-current` liest den Ist-Zustand.

## Omarchy-Integration

- **Menü:** Ein „Workplace"-Eintrag in
  `~/.config/omarchy/extensions/omarchy-menu.jsonc`, der den Picker
  öffnet. Wird bei `hyprworkplace install` angelegt und ist über
  Marker-Kommentare wieder entfernbar.
- **Keybinding:** Vorschlag `SUPER + SHIFT + W` → `hyprworkplace menu`
  (Picker über `omarchy menu select`).
- **Hooks (geplant):** `post-boot.d`-Hook wendet beim Login den zuletzt
  aktiven oder per `detect` erkannten Workplace an. Bis dahin genügt der
  Loader-Block, da er den aktiven Workplace ohnehin bei jedem Start lädt.
- **Bar (optional, Phase 3):** Widget mit dem aktiven Workplace-Namen,
  basierend auf einem geklonten Omarchy-Shell-Plugin.
- **Stil:** Hilfe-Ausgabe und Fehlermeldungen folgen dem Format der
  `omarchy-*`-Binaries.

## Architektur

```
hyprworkplace/
├── bin/hyprworkplace          # Haupt-CLI (Bash)
├── lib/
│   ├── common.sh              # Pfade, Logging, Lua-Quoting
│   ├── config.sh              # INI-Parser, Validierung
│   ├── lua.sh                 # Lua-Generator + Loader-Verwaltung
│   ├── hypr.sh                # hyprctl-Wrapper, Fenster-Matching
│   └── omarchy.sh             # Menü, Picker, Notifications (optional)
├── templates/workplace.conf   # Vorlage für `new`
├── examples/                  # home-s, home-m, laptop
├── tests/run.sh               # Testsuite (ohne Fremdabhängigkeiten)
├── install.sh                 # Symlink + Loader + Menü
├── .github/workflows/ci.yml   # shellcheck + Tests
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
- Tests: `tests/run.sh`, eine reine Bash-Suite ohne Fremdabhängigkeiten,
  die in einer Sandbox (`HW_CONFIG_HOME`/`HW_STATE_HOME`/`HW_HYPR_CONFIG`)
  läuft und das generierte Lua mit `luac -p` gegenprüft. Linting mit
  `shellcheck -x`, beides in der GitHub-Actions-CI.

## Nicht-Ziele

- Kein Ersatz für die restliche Hyprland-/Omarchy-Config (Keybindings,
  Theming, Look & Feel) — `hyprworkplace` verwaltet nur Monitore,
  Workspaces und App-Platzierung.
- Keine GUI in Phase 1; Menü-/Picker-Integration ist die Oberfläche.
- Keine Fenster-Layouts innerhalb eines Workspaces (Tiling-Positionen) —
  das bleibt Hyprland bzw. Omarchys Workspace-Layouts überlassen.

## Getroffene Entscheidungen

1. **Lua statt `hyprctl keyword`.** `apply` erzeugt
   `~/.local/state/hyprworkplace/workplace.lua` und lässt Hyprland per
   `hyprctl reload` neu laden. Damit ist der Workplace persistent und es
   gibt nur eine Quelle der Wahrheit. Ausnahme: die App-Platzierung
   (verschieben/starten) passiert zur Laufzeit über `hyprctl`.
2. **Matching:** `match` ist für jede App Pflicht und trägt das Feld im
   Präfix — `class:`, `title:`, `initialClass:` oder `initialTitle:`.
   Geraten wird nichts; `new --from-current` füllt es automatisch und
   escaped die Regex korrekt.
3. **`watch`** ist auf Phase 2 verschoben. `detect` ist bereits da und
   deckt den manuellen Fall ab.
4. **Lizenz MIT**, Projektname `hyprworkplace` bestätigt.

## Stand der Umsetzung

| Phase | Inhalt | Status |
|-------|--------|--------|
| 1 | `list/show/apply/current/menu/new/edit/validate/remove`, Lua-Generator, Loader, Beispiele, README, MIT, 40 Tests, CI | **fertig** |
| 2 | `detect`, `startup` (Login-Autodetect + `fallback`) | **fertig** |
| 2 | `watch` (Hyprland-IPC), post-boot-Hook | offen |
| 3 | Bar-Widget, AUR-Paket, Wallpaper/Idle pro Workplace | offen |

Menü-Integration (`omarchy-menu.jsonc`), Picker über
`omarchy menu select` und Notifications sind in Phase 1 mitgeliefert.
