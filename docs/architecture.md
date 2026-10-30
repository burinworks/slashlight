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
| `ci.yml` | PRs; pushes to `test`, `beta`, `main` | Builds, runs tests, builds a universal `.app` and packs it into a `.dmg` artifact (`test` builds are kept 30 days) |
| `codeql.yml` | Pushes, PRs, weekly | Static analysis for Swift |
| `release.yml` | Pushes to `beta` and `main`, tags `v*` | Tests, builds a universal `.app`, publishes a GitHub release with `Slashlight-<tag>.dmg` and `SHA256SUMS.txt`, and adds the EdDSA-signed update to the appcast |
| `promote.yml` | Manual | Opens the PR that promotes `test → beta` or `beta → main` (or back-merges) |

| Branch | Channel | Release |
|---|---|---|
| `test` | Newest work | None; CI artifacts only |
| `beta` | Beta testers | Pre-release `vX.Y.Z-beta.N`, appcast channel `beta` |
| `main` | Stable | `vX.Y.Z` once per `VERSION`, after a maintainer approves the `stable` environment |

`X.Y.Z` comes from the `VERSION` file; `N` counts up per beta. `CFBundleVersion` is the release workflow's run number, so it grows across both channels and Sparkle can compare any two builds.

### Updates

`Host/Updater.swift` wraps Sparkle's `SPUStandardUpdaterController`. `scripts/build-app.sh` embeds `Sparkle.framework` in `Contents/Frameworks` and writes `SUFeedURL` and `SUPublicEDKey` into Info.plist; a build without `SPARKLE_PUBLIC_KEY` (every local build) never checks for updates.

There is one appcast, `appcast.xml` on the `gh-pages` branch, served at `https://burinworks.github.io/slashlight/appcast.xml`. Stable items have no channel; beta items carry `<sparkle:channel>beta</sparkle:channel>`, and the updater allows that channel when **Join the beta program** is on. `scripts/appcast.swift` adds each release's item, with the `sparkle:edSignature` from Sparkle's `sign_update`.

The app is ad-hoc signed and not notarized. What that means for updates:

- **Trust comes from EdDSA.** Sparkle rejects an update whose archive signature doesn't match `SUPublicEDKey`. For apps without a Developer ID it checks only that the new app's code signature is valid, not that it matches the old one, so ad-hoc builds update fine.
- **No Gatekeeper prompt on updates.** Sparkle downloads the update itself and removes the quarantine attribute before installing, so only the first manual install needs `xattr -dr com.apple.quarantine`.
- **Permissions may need granting again.** An ad-hoc signature's designated requirement is the binary's hash, which changes with every build, so macOS treats the updated app as a new one for Accessibility and Screen Recording.
- **Losing the private key strands users.** Installed copies trust only the key they shipped with. Back it up.
