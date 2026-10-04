# hyprworkplace — Konzept

## Idee

`hyprworkplace` ist ein CLI-Tool für Hyprland (inkl. Omarchy), mit dem
Nutzer komplette **Arbeitsplatz-Profile** definieren und per Befehl oder
automatisch wechseln können. Ein Profil bündelt:

- **Monitor-Konfiguration** (welche Displays aktiv sind, Auflösung,
  Position, Skalierung)
- **Workspace-Zuordnung** (welcher Workspace auf welchem Monitor liegt)
- **App-Zuordnung** (welche Anwendungen in welchem Workspace starten
  bzw. dorthin verschoben werden)

Damit lässt sich z. B. zwischen "Laptop + 2 externe Monitore am
Schreibtisch" und "nur Laptop unterwegs" wechseln, ohne Config-Dateien
manuell zu editieren oder Hyprland neu zu starten.

## Zielgruppe

Primär Hyprland-Nutzer allgemein, mit besonderer Unterstützung für
Omarchy-spezifische Konventionen (Menü-Integration, `omarchy`-CLI-Stil),
aber ohne harte Abhängigkeit von Omarchy — funktioniert auf jedem
Hyprland-System.

## Architektur

```
hyprworkplace/
├── bin/
│   └── hyprworkplace          # Haupt-CLI (Bash)
├── profiles/                  # Beispiel-/Vorlagen-Profile
│   └── example.conf
├── lib/                       # Hilfsfunktionen (hyprctl-Wrapper etc.)
├── examples/
│   └── home-s.conf            # Reales Beispielprofil
├── docs/
├── README.md
├── LICENSE
└── CONCEPT.md
```

### Profil-Format

Jedes Profil ist eine einfache, gut lesbare Konfigurationsdatei
(`~/.config/hyprworkplace/profiles/<name>.conf`), die deklarativ
beschreibt:

```ini
[monitor.eDP-1]
mode = 1920x1200@60
position = 0x0
scale = 1
enabled = true

[monitor.HDMI-A-1]
mode = 2560x1440@144
position = 1920x0
scale = 1
enabled = true

[workspace.1]
monitor = eDP-1

[workspace.2]
monitor = HDMI-A-1

[app.term-main]
workspace = 1
exec = "foot --title term-main"
match = "title:^term-main$"

[app.vscode]
workspace = 3
exec = "code"
match = "class:^com\\.microsoft\\.VSCode$"
```

### Funktionsweise (Ausführung)

1. **Monitore setzen** – `hyprctl keyword monitor "..."` pro
   `[monitor.*]`-Block.
2. **Workspace-Regeln setzen** – `hyprctl keyword workspace "N,
   monitor:X"` pro `[workspace.*]`-Block.
3. **Apps anwenden**:
   - Läuft die App bereits (per `match` in `hyprctl clients -j`
     gefunden) → `hyprctl dispatch movetoworkspacesilent`.
   - Läuft sie nicht → `hyprctl dispatch exec "[workspace N silent]
     <exec>"`.
4. Alle `hyprctl`-Aufrufe werden wo möglich über `hyprctl --batch`
   gebündelt, um Flackern zu vermeiden.

### Automatischer Profil-Wechsel (optional, Phase 2)

- `hyprworkplace detect` vergleicht aktuell angeschlossene Monitore
  (`hyprctl monitors -j`) gegen die in den Profilen hinterlegten
  Monitor-Namen und schlägt ein passendes Profil vor.
- `hyprworkplace watch` lauscht auf Hyprland-IPC-Events
  (`monitoradded` / `monitorremoved` über den Unix-Socket) und wendet
  automatisch das passende Profil an.
- Optionaler Omarchy-Hook (`post-boot.d/`) für automatisches Anwenden
  beim Login.

### CLI-Oberfläche

```
hyprworkplace list                  # verfügbare Profile anzeigen
hyprworkplace show <name>           # Profil-Details anzeigen
hyprworkplace apply <name>          # Profil aktiv anwenden
hyprworkplace current               # aktuell aktives Profil anzeigen
hyprworkplace edit <name>           # Profil im $EDITOR öffnen
hyprworkplace detect                # passendes Profil anhand Monitore vorschlagen
hyprworkplace watch                 # Hintergrunddienst für Auto-Wechsel
hyprworkplace validate <name>       # Profil-Syntax prüfen
```

### Integration (optional, Phase 3)

- Eintrag im Omarchy-Menü (`omarchy-menu.jsonc`) zur manuellen Auswahl.
- Keybinding + `omarchy menu select prompt` als schneller Picker.
- Status-Anzeige in der Omarchy-Bar (aktives Profil), auf Basis eines
  geklonten Bar-Widgets.

## Nicht-Ziele

- Kein Ersatz für Hyprlands eigentliche Config (`hyprland.conf`/`.lua`)
  — Profile ergänzen, nicht ersetzen grundlegende Keybindings,
  Theming etc.
- Kein Fenstermanager-Ersatz; `hyprworkplace` orchestriert nur über
  `hyprctl`.
- Keine GUI in Phase 1 — reines CLI-Tool, GUI/Bar-Integration ist
  optional und später.

## Technologie

- Reines **Bash** (+ `jq` für JSON-Parsing von `hyprctl -j`-Ausgaben),
  keine Compile-Schritte, leicht auf jedem Arch/Hyprland-System
  installierbar.
- Installation via `git clone` + Symlink nach `~/.local/bin`, später
  optional als AUR-Paket.

## Offene Entscheidungen (vor Implementierungsstart klären)

1. Profil-Format: INI-ähnlich (wie oben) vs. einfaches Shell-sourcebares
   Format vs. JSON/YAML (zusätzliche Abhängigkeit)?
2. Matching-Strategie für laufende Fenster: `class` vs. `title` vs.
   beides, wie in Beispiel oben?
3. Soll `watch` ein systemd-user-Service sein oder ein einfacher
   Hintergrundprozess?
4. Lizenz (MIT vorgeschlagen) und Projektname final bestätigen.
