# Slashlight

Open-source, keyboard-first Spotlight replacement (and Raycast alternative) for macOS. Native Swift (AppKit + SwiftUI), macOS 14+.
Every capability is an **extension** built on one public `Extension` class, the built-ins included.

## Run it

```bash
scripts/dev-signing-identity.sh   # once: a local signing identity so permissions survive rebuilds
scripts/build-app.sh --install-example
open "build/Slashlight.app"
```

Press **⌥Space** to open. The app lives in the menu bar (no Dock icon).
Grant **Accessibility** (window layout, auto-paste) and **Screen Recording** (window thumbnails) when asked, or from Settings (⌘,).
Without `scripts/dev-signing-identity.sh` the app is ad-hoc signed and macOS forgets these grants on every rebuild
(symptoms: no window thumbnails, the window switcher only sees the current Space).

## What you can type

| Input | What happens |
|---|---|
| `claude` | Apps, files, and any extension or command whose name matches (`switch window`, `left half`) |
| `/` | Command mode: your `/commands`, every extension (`/clipboard`, `/snippets`…), window layouts (`/left-half`) |
| `> npm run dev` | Opens a terminal tab inside Slashlight and runs it there |
| empty bar | List of all extensions (also in the dropdown at the top right) |

## Keys

| Key | Action |
|---|---|
| ⌥Space | Open / close (change in `settings.json`) |
| ↑ ↓, ⌃N ⌃P | Move selection |
| ↵ / click | Primary action |
| ⌘↵ / ⌘-click | Secondary action |
| ⌘K | All actions of the selected item |
| ⌫ on an empty bar | Back one screen |
| Esc | Close everything |
| Tab / ⇧Tab | Cycle filters (by section type, or the screen's own filters) |
| ⌘1…⌘9 | Run the Nth result |
| ⌘E | Back to the extension list |
| ⌘, | Settings window (also in the menu bar icon) |
| ⌥Tab | Window switcher. Hold ⌥, tap Tab to move, release to switch |
| ⌃⌥ ← → ↑ ↓ ↵ C ⌫, D F G E T, U I J K | Window layouts (halves, maximize, center, restore, thirds, quarters) |

## Built-in extensions

| Extension | ↵ | ⌘↵ |
|---|---|---|
| All Apps (`/apps`) — Tab: recently opened / recently added / A–Z | Open | Show in Finder |
| Files (`/files`) — Spotlight index, home folder | Open | Show in Finder |
| Commands (`/commands`) — `commands.json`: shell, url, shortcut, http, applescript | Run | Copy definition |
| Clipboard History (`/clipboard`) — in memory, gone after quit | Copy and move to top | Paste (⌘V) |
| Snippets (`/snippets`) — on disk, multi-line editor (⌘↵ saves); `{clipboard}` `{date}` `{time}` | Copy | Paste |
| Window Layout (`/windows`) | Apply to the focused window | — |
| Switch Window (`/switch`, ⌥Tab) — thumbnail grid, every Space and display | Switch | Show all app windows |
| Terminal (`>` or `/terminal`) — real terminal tabs that keep running in the background | Run in a new tab | Open in Terminal.app |

Settings (⌘,): hotkeys (click and press a new combination), theme, launch at login, turning extensions on and off, permissions.
Config lives in `~/Library/Application Support/Slashlight/`: `settings.json`, `commands/commands.json`, `snippets/`, `Extensions/`.

## Terminal tabs

`> command` + ↵ opens a real terminal (your login shell, colors, vim, top all work) inside the panel and runs the command.
Tabs keep running when you go back to search or close the panel. Open tabs show as a strip at the bottom of the panel:
green dot = a task is running (with its run time), grey = idle at the prompt, red = exited with an error.
A task that runs longer than 3 s shows a toast when it finishes while you are elsewhere.

| Key (in a terminal tab) | Action |
|---|---|
| ⌘⌫ or ⌘[ | Back to search, tab keeps running |
| Esc | Closes the panel at an idle prompt; goes to the program while one runs (vim, less) |
| ⌘T / ⌘W | New tab / close tab |
| ⌃⇥, ⌃⇧⇥, ⌘1…⌘9 | Switch tabs (⌃⇥ from search jumps back to the last tab) |
| ⌘C ⌘V ⌘K ⌘+ ⌘− | Copy, paste, clear, font size |

## Writing an extension

Subclass `Extension` from `SlashlightKit`. Return sections of items; each item's first action is ↵, the second ⌘↵, the rest live under ⌘K.

```swift
import SlashlightSDK

final class Hello: Extension {
    override var manifest: Manifest { Manifest(id: "hello", title: "Hello", icon: .symbol("hand.wave")) }
    override var triggers: [Trigger] { [.commands, .command("hello")] }

    override func search(_ query: Query) async throws -> [Section] {
        [Section("Hello", [
            Item(id: "greet", title: "Hello, \(query.text)!", icon: .symbol("hand.wave"),
                 primary: Action("Say Hello") { .hud("Hello!") },
                 secondary: Action("Paste") { .paste("Hello!") }),
        ])]
    }
}

ExtensionRunner.run { Hello() }
```

Third-party extensions run as **separate processes** speaking JSON lines over stdin/stdout, and can open their own sub-screens (lists, grids, live text) like built-ins, so a crash cannot take the launcher down. `SlashlightSDK` wraps that protocol for Swift; any language can implement it directly — see [docs/extension-protocol.md](docs/extension-protocol.md).
Install: put the binary and a `manifest.json` in `~/Library/Application Support/Slashlight/Extensions/<name>/` and choose Settings → Reload extensions. [Examples/HelloExtension](Examples/HelloExtension) is a complete one.

Built-ins subclass the same `Extension` class but run in-process for speed.

## Layout

```
Sources/SlashlightKit     Public API: Extension, Item, Action, Outcome, ListView, Wire protocol types
Sources/SlashlightSDK     ExtensionRunner — runs an Extension as a JSON-over-stdio process
Sources/Slashlight      The app: panel, keyboard handling, hotkeys, built-in extensions
Examples/HelloExtension  Out-of-process example
```

Debug aids: `.build/debug/Slashlight --snapshot out.png --query "saf" [--open apps] [--enter] [--dark]` renders the panel to a PNG and quits;
`--settings --tab General --snapshot-settings out.png` does the same for the Settings window; `--list-windows` prints what the switcher finds on every Space.

## Known gaps

- Terminal tabs do not survive quitting Slashlight.
- External extensions cannot declare global hotkeys or permissions yet (see docs/extension-protocol.md).
