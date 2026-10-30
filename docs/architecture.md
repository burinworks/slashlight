# Architecture

Slashlight is a Swift package with four products:

```
Sources/SlashlightKit     Public API: Extension, Query, Section, Item, Action, Outcome, ListView, Fuzzy, Wire types
Sources/SlashlightSDK     ExtensionRunner: runs an Extension as a JSON-over-stdio process
Sources/Slashlight        The app: panel, keyboard handling, hotkeys, settings, built-in extensions
Examples/HelloExtension   An out-of-process extension
Tests/                    swift-testing suites for the Kit (fuzzy ranking, wire format) and the app (calculator)
```

`SlashlightKit` has no dependency on the app. Built-ins and third-party extensions compile against the same types.

## The pieces

```
              ⌥Space (Carbon hotkey)
                       │
                       ▼
┌─────────────── PanelController ───────────────┐   NSPanel, non-activating, floats over full-screen apps
│  PaletteView (SwiftUI)                        │   search bar, result list or grid, footer hints, terminal tabs
│        ▲  rows / sections                     │
│        │                                      │
│  PaletteModel  ── screen stack ──▶ ListView   │   one screen per push; ⌫ on an empty bar pops
│        │ query                                │
└────────┼──────────────────────────────────────┘
         ▼
       Host ── extensions ──┬─ built-ins (in-process subclasses of Extension)
                            └─ ExternalExtension ── Process ── stdin/stdout JSON lines ── your extension
```

| Type | File | Job |
|---|---|---|
| `Host` | `Host/Host.swift` | Loads built-ins and external extensions, applies settings, registers hotkeys, owns the panel |
| `PanelController` | `Panel/PanelController.swift` | The floating `NSPanel`: show/hide, focus, key event monitor |
| `PaletteModel` | `Panel/PaletteModel.swift` | Screen stack, search routing, result merging, selection and key handling |
| `PaletteView` | `Panel/PaletteView.swift` | SwiftUI rendering of the current screen |
| `EmbeddedScreen` | `Panel/EmbeddedScreen.swift` | Shows a live AppKit view (terminal, text editor) in place of the result list |
| `ExternalExtension` | `Host/ExternalExtension.swift` | Wraps a child process so it looks like any other `Extension` |
| `ExtensionRunner` | `SlashlightSDK/ExtensionRunner.swift` | The extension-side half of the wire protocol |

## Extension model

An extension declares:

- a `manifest` (id, title, icon);
- `triggers`, which say where it takes part:

  | Trigger | Takes part in |
  |---|---|
  | `.defaultSearch` | Plain typing |
  | `.commands` | `/` mode |
  | `.command("x")` | `/x` |
  | `.prefix(">")` | Text that starts with `>` |

- optionally, `permissions` and `globalHotkeys`.

`search(_:)` returns `[Section]`. Each `Item` carries up to N `Action`s, and each action returns an `Outcome`:

| `Outcome` | Effect |
|---|---|
| `.close` | Hide the panel |
| `.stay` | Re-run the search, keeping the selection |
| `.push(ListView)` | Open a sub-screen with its own search closure, layout, filters and optional live detail text |
| `.pop` | Go back one screen |
| `.hud(text)` | Hide the panel and show a toast |
| `.paste(text)` | Hide the panel and paste into the previous app |

`ExtensionContext` gives each extension:

- `storage(.ephemeral | .persistent)`
- `supportDirectory`
- `frontmostApplication`
- `copy`, `showHUD`, `refresh`, `present` and `close`

## Search pipeline

`PaletteModel.search()` routes on what is in the bar:

1. **Inside a pushed screen:** that screen's `search` closure, scoped to its filter.
2. **Empty bar:** the home screen. It shows up to 5 recently used extensions (`RecentExtensions`), then all extensions A–Z.
3. **`/text`:** user commands first, then extension entry points ranked by `Fuzzy`, then other `.commands` providers.
4. **A registered prefix (`>`):** only that extension.
5. **Plain text:** runs in three groups.
   1. Default providers, except files and the web: calculator, apps, clipboard.
   2. Extensions whose name contains the text, then up to 3 name-matching commands from `.commands` providers.
   3. Files, then the web-search fallback.

Every provider runs concurrently in its own `Task`. Results stream in as each provider finishes, but they are always assembled in the fixed order above, so rows do not jump around. A generation counter drops results from stale queries.

## Usage events

`UsageStore` (`Host/Usage.swift`) receives events from two places:

- `Host.show()` records each time the panel opens;
- `PaletteModel.run()` records each action that runs.

Each event is appended to a JSON-lines file. `UsageReport` turns a list of events into everything the Usage Insights dashboard shows. It is a pure function of the events, the period and a clock, so it is unit-tested directly. `--sample-usage` replaces the log with generated data and turns off writing, for screenshots.

## Threading

- Everything UI-facing is `@MainActor`, including `Extension`, `ListView` and `ExtensionContext`.
- Extension `search` methods are `async` and may hop off the main actor for I/O.
- Window discovery uses `DispatchQueue.concurrentPerform` across apps, with a 150 ms budget per app.
- The window list is cached and rescanned in the background when it is older than 1 s.

## External extensions

`ExternalExtension` launches the executable from `manifest.json` on first use and talks newline-delimited JSON (see [extension-protocol.md](extension-protocol.md)).

- **Requests:** `hello`, `search`, `run`, `dispose`, `shutdown`.
- **Messages back:** `results`, `outcome`, `refresh`, `hud`, `detail` and `error`. Each request is matched to its reply by `id`.
- **Sub-screens:** a pushed view gets a view id (`v1`, `v2`…). The host includes that id when it searches or runs inside the screen, and sends `dispose` when the screen is popped.
- **Crashes:** a crash only affects that extension. Its pending requests fail, and the host relaunches the process on the next query.

## Window switcher internals

Listing windows on other Spaces has no public API. Slashlight uses three sources:

1. `CGWindowListCopyWindowInfo(.optionAll)` gives the order and on-screen state.
2. For each app, AX elements are created from remote tokens: pid, a constant, and an element id brute-forced from 0 to 999. This finds windows on other Spaces and minimized ones; `_AXUIElementGetWindow` maps them back to `CGWindowID`s.
3. `ScreenCaptureKit` (`SCShareableContent`, `onScreenWindowsOnly: false`) supplies the thumbnails.

Without Accessibility it falls back to windows on the current Space only.

## Terminal tabs

The terminal is [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm)'s `LocalProcessTerminalView`, running your login shell (`-zsh`).

- `TerminalManager` polls each session once a second:
  - `proc_listchildpids` tells busy from idle and gives the running command's name;
  - `proc_pidinfo(PROC_PIDVNODEPATHINFO)` gives the current folder.
- The view is created once and re-parented into the panel through `EmbeddedHost`, so scrollback and running programs survive navigation.

## Debug flags

The app binary accepts flags that render without user interaction. They are used for README screenshots and for checking UI changes:

```bash
.build/debug/Slashlight --snapshot out.png --query "5 km in mi" [--open emoji] [--enter] [--dark]
.build/debug/Slashlight --settings --tab Extensions --snapshot-settings out.png
.build/debug/Slashlight --list-windows
```

## CI and releases

| Workflow | Runs on | Does |
|---|---|---|
| `ci.yml` | Every push and PR | Builds, runs tests, builds a universal `.app` and packs it into a `.dmg` artifact |
| `codeql.yml` | Pushes, PRs, weekly | Static analysis for Swift |
| `release.yml` | Tag `v*` | Tests, builds a universal `.app`, publishes a GitHub release with a drag-to-Applications `.dmg` and its SHA-256 sum |

To cut a release:

```bash
git tag v0.3.0
git push origin v0.3.0
```

A tag with a hyphen (`v0.3.0-beta.1`) is published as a pre-release.
