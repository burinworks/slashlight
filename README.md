# My Spotlight

Open-source, keyboard-first Spotlight replacement for macOS. Native Swift (AppKit + SwiftUI), macOS 14+.
Every capability is an **extension** built on one public `Extension` class, the built-ins included.

## Run it

```bash
scripts/build-app.sh --install-example
open "build/My Spotlight.app"
```

Press **⌥Space** to open. The app lives in the menu bar (no Dock icon).
Grant **Accessibility** (window layout, auto-paste) and **Screen Recording** (window thumbnails) when asked, or from Settings (⌘,).
The app is ad-hoc signed, so macOS may ask again for these after each rebuild.

## What you can type

| Input | What happens |
|---|---|
| `claude` | Apps and files (default search) |
| `/` | Command mode: your `/commands`, every extension (`/clipboard`, `/snippets`…), window layouts (`/left-half`) |
| `> git status` | Runs the shell command, output streams inline |
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
| ⌘, | Settings |
| ⌥Tab | Window switcher. Hold ⌥, tap Tab to move, release to switch |
| ⌃⌥ ← → ↑ ↓ ↵ C ⌫, D F G E T, U I J K | Window layouts (halves, maximize, center, restore, thirds, quarters) |

## Built-in extensions

| Extension | ↵ | ⌘↵ |
|---|---|---|
| All Apps (`/apps`) — Tab: recently opened / recently added / A–Z | Open | Show in Finder |
| Files (`/files`) — Spotlight index, home folder | Open | Show in Finder |
| Commands (`/commands`) — `commands.json`: shell, url, shortcut, http, applescript | Run | Copy definition |
| Clipboard History (`/clipboard`) — in memory, gone after quit | Copy and move to top | Paste (⌘V) |
| Snippets (`/snippets`) — on disk; `{clipboard}` `{date}` `{time}` | Copy | Paste |
| Window Layout (`/windows`) | Apply to the focused window | — |
| Switch Window (`/switch`, ⌥Tab) — thumbnail grid | Switch | Show all app windows |
| Terminal (`>` or `/terminal`) | Run inline | Open in Terminal.app |

Config lives in `~/Library/Application Support/MySpotlight/`: `settings.json`, `commands/commands.json`, `snippets/`, `Extensions/`.

## Writing an extension

Subclass `Extension` from `SpotlightKit`. Return sections of items; each item's first action is ↵, the second ⌘↵, the rest live under ⌘K.

```swift
import SpotlightSDK

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

Third-party extensions run as **separate processes** speaking JSON lines over stdin/stdout, so a crash cannot take the launcher down. `SpotlightSDK` wraps that protocol for Swift; any language can implement it directly — see [docs/extension-protocol.md](docs/extension-protocol.md).
Install: put the binary and a `manifest.json` in `~/Library/Application Support/MySpotlight/Extensions/<name>/` and choose Settings → Reload extensions. [Examples/HelloExtension](Examples/HelloExtension) is a complete one.

Built-ins subclass the same `Extension` class but run in-process for speed.

## Layout

```
Sources/SpotlightKit     Public API: Extension, Item, Action, Outcome, ListView, Wire protocol types
Sources/SpotlightSDK     ExtensionRunner — runs an Extension as a JSON-over-stdio process
Sources/MySpotlight      The app: panel, keyboard handling, hotkeys, built-in extensions
Examples/HelloExtension  Out-of-process example
```

Debug aid: `.build/debug/MySpotlight --snapshot out.png --query "saf" [--open apps] [--enter] [--dark]` renders the panel to a PNG and quits.

## Known gaps

- Terminal: stdin is `/dev/null`, so interactive commands get EOF. Long-running ones stream and can be stopped.
- Snippet text is single-line when typed in the bar; for multi-line, copy it first and choose "Save clipboard contents".
- Protocol v1 has no `push` (sub-screens) for external extensions.
