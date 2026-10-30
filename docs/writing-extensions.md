# Writing extensions

An extension is a program that answers searches with results and runs actions on them. There are two ways to write one:

| | Swift + `SlashlightSDK` | Any language |
|---|---|---|
| Effort | Subclass `Extension`; the SDK handles the protocol | Read and write JSON lines yourself |
| Sub-screens and live output | `return .push(ListView(…))` | `push` outcome + `detail` messages |
| Example | [Examples/HelloExtension](../Examples/HelloExtension) | [Examples/PythonExtension](../Examples/PythonExtension) |

Both run as separate processes. If your extension crashes, Slashlight keeps working and relaunches it on the next query.

## Swift: from zero to `/hello`

1. Create a package that depends on Slashlight:

   ```swift
   // swift-tools-version:5.9
   import PackageDescription

   let package = Package(
       name: "Hello",
       platforms: [.macOS(.v14)],
       dependencies: [.package(url: "https://github.com/burinworks/slashlight.git", branch: "main")],
       targets: [.executableTarget(name: "hello", dependencies: [.product(name: "SlashlightSDK", package: "slashlight")])]
   )
   ```

2. Write `Sources/hello/main.swift`:

   ```swift
   import SlashlightSDK

   final class Hello: Extension {
       override var manifest: Manifest { Manifest(id: "hello", title: "Hello", icon: .symbol("hand.wave")) }
       override var triggers: [Trigger] { [.commands, .command("hello")] }

       override func search(_ query: Query) async throws -> [Section] {
           let greeting = "Hello, \(query.text.isEmpty ? "world" : query.text)!"
           return [Section("Hello", [
               Item(id: "greet", title: greeting, icon: .symbol("hand.wave"),
                    primary: Action("Say Hello") { .hud(greeting) },
                    secondary: Action("Paste") { .paste(greeting) }),
           ])]
       }
   }

   ExtensionRunner.run { Hello() }
   ```

3. Build and install:

   ```bash
   swift build -c release
   DEST=~/Library/Application\ Support/Slashlight/Extensions/hello
   mkdir -p "$DEST" && cp .build/release/hello "$DEST/"
   ```

4. Add `manifest.json` next to the binary:

   ```json
   { "id": "hello", "title": "Hello", "icon": "sf:hand.wave",
     "triggers": ["commands", "command:hello"], "exec": ["./hello"] }
   ```

5. In Slashlight: Settings → Extensions → Reload, then type `/hello Alex`.

## Concepts

### Triggers: where your results appear

| Swift | manifest | Your `search` is called |
|---|---|---|
| `.defaultSearch` | `default` | On plain typing (keep it fast, under 50 ms) |
| `.commands` | `commands` | In `/` mode |
| `.command("x")` | `command:x` | When the user opens `/x`. This shows your root screen |
| `.prefix("!")` | `prefix:!` | When the text starts with `!`; you own the bar |

`query.mode` tells you which one fired: `.default`, `.command`, `.prefix(p)` or `.scoped`. In scoped mode the user is on your own screen.

### Items and actions

- `primary` runs on ↵.
- `secondary` runs on ⌘↵.
- `more:` lists extra actions under ⌘K; give them a `shortcut:` such as `Shortcut("c", [.command, .shift])`.
- `accessories:` decorate the right side of the row: `.pill("New", .green)`, `.text("3 KB")` or `.keycap(Shortcut("n", .command))`.

### Outcomes

An action returns what happens next:

| Outcome | Use it for |
|---|---|
| `.close` | You did the thing; get out of the way |
| `.stay` | You changed data; show the updated results |
| `.hud("Saved")` | Close the panel and confirm with a toast |
| `.paste(text)` | Close the panel and paste into the app the user came from |
| `.push(ListView(…))` | Drill into a sub-screen |
| `.pop` | Back one screen |

### Sub-screens

A `ListView` is a screen with its own search closure:

```swift
ListView(title: "Pick a Wave", icon: .symbol("square.grid.3x3"), placeholder: "Filter…",
         layout: .grid(columns: 3), filters: ["All", "Hands", "Water"]) { query in
    // query.filter is the Tab filter the user picked
    [Section("Waves", items(matching: query.text, filter: query.filter))]
}
```

For live output, pass a `DetailModel` and update `detail.text` and `detail.isRunning` from a `Task`. The SDK streams every change to the panel.

### Storage

`context.storage(.persistent)` keeps values across restarts; `.ephemeral` keeps them in memory only:

```swift
context.storage(.persistent).set(favorites, forKey: "favorites")
let favorites = context.storage(.persistent).value([String].self, forKey: "favorites") ?? []
```

`context.supportDirectory` is a private folder for anything bigger.

## Any other language

Read one JSON object per line on stdin and write one per line on stdout. Logs go to stderr. A minimal loop:

```python
for line in sys.stdin:
    req = json.loads(line)
    if req["type"] == "hello":
        reply({"type": "hello", "id": req["id"], "version": 2})
    elif req["type"] == "search":
        reply({"type": "results", "id": req["id"], "sections": [...]})
    elif req["type"] == "run":
        reply({"type": "outcome", "id": req["id"], "outcome": {"type": "hud", "value": "Done"}})
```

[Examples/PythonExtension](../Examples/PythonExtension) is a complete UUID generator in about 50 lines with no dependencies. Every message is specified in [extension-protocol.md](extension-protocol.md).

## Tips

- **Be fast in default search.** It runs on every keystroke. Cache, and do slow work in `activate(context:)`.
- **Make ids stable.** `run` requests name the item by `id`, so an id must still mean the same item after a refresh.
- **Test without the app.** Pipe requests in:
  ```bash
  printf '%s\n' '{"type":"hello","id":1}' '{"type":"search","id":2,"query":"x","mode":"scoped"}' | ./your-extension
  ```
- **Share it.** Open a PR that adds a link to your extension to the README, or ask about it in [Discussions](https://github.com/burinworks/slashlight/discussions).
