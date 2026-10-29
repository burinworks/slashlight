# Extension protocol v2

An external extension is a process the host starts on first use. Messages are single-line JSON objects, one per line:
host → extension on **stdin**, extension → host on **stdout**. Write logs to **stderr** only.
The Swift types are in `Sources/SpotlightKit/WireProtocol.swift`; `SpotlightSDK` implements the extension side.

## Install

`~/Library/Application Support/MySpotlight/Extensions/<folder>/manifest.json`:

```json
{
  "id": "hello",
  "title": "Hello",
  "subtitle": "Example out-of-process extension",
  "icon": "sf:hand.wave",
  "triggers": ["commands", "command:hello"],
  "exec": ["./hello-extension"]
}
```

`exec` paths are relative to the folder. Triggers:

| Trigger | Meaning |
|---|---|
| `default` | Contributes to plain-text search |
| `commands` | Contributes to `/` mode |
| `command:<name>` | Reachable as `/<name>`; opening it shows a scoped search |
| `prefix:<p>` | Owns the bar when the text starts with `p` |

## Host → extension

```json
{"type":"search","id":2,"query":"alex","mode":"command","filter":null,"supportDirectory":"/Users/…/MySpotlight/hello"}
{"type":"run","id":3,"itemId":"greet","actionId":"say-hello"}
{"type":"search","id":5,"view":"v1","query":"","mode":"scoped","filter":"Water"}
{"type":"run","id":6,"view":"v1","itemId":"wave-6","actionId":"choose"}
{"type":"dispose","id":0,"view":"v1"}
{"type":"shutdown","id":4}
```

`mode` is `default` | `command` | `prefix` | `scoped`. `filter` is the active Tab filter in a scoped screen.
`view` is set when the request belongs to a screen the extension pushed (see below); root requests omit it, as in v1.
`dispose` (no reply) tells the extension the panel dropped that screen, so it can free it.
Every request carries `supportDirectory`, a folder the extension may use for storage.
A request that gets no reply within 5 s fails; a newer search makes older results irrelevant (the host drops them).

## Extension → host

Replies echo the request `id`:

```json
{"type":"results","id":2,"sections":[{"title":"Hello","items":[{
  "id":"greet","title":"Hello, Alex!","subtitle":"…","icon":"sf:hand.wave",
  "accessories":[{"type":"pill","value":"Example","tint":"blue"}],
  "actions":[{"id":"say-hello","title":"Say Hello"},{"id":"paste","title":"Paste"},
             {"id":"copy","title":"Copy","shortcut":"cmd+shift+c"}]}]}]}
{"type":"outcome","id":3,"outcome":{"type":"hud","value":"Hello, Alex!"}}
{"type":"error","id":3,"message":"something broke"}
```

- `icon`: `sf:<SF Symbol>`, `file:<path>` (Finder icon), `text:<emoji>`.
- `accessories[].type`: `pill` (with `tint`: blue, green, orange, red, gray), `text`, `keycap` (value like `cmd+n`).
- `actions[0]` runs on ↵, `actions[1]` on ⌘↵, all appear under ⌘K. Extra `shortcut`s must include cmd, ctrl or opt.
- `outcome.type`: `close`, `stay` (re-run search), `push` (open a sub-screen, below), `pop` (back one screen),
  `hud` (value = message), `paste` (value = text to paste into the frontmost app).

## Sub-screens (v2)

An action can open its own screen. The extension picks the `view` id; every later `search` and `run` on that screen carries it:

```json
{"type":"outcome","id":3,"outcome":{"type":"push","view":{
  "id":"v1","title":"Pick a Wave","icon":"sf:square.grid.3x3","placeholder":"Filter waves…",
  "layout":"grid:3","filters":["All","Hands","Water"],"initialText":"","initialSelection":0,
  "detail":"","running":true}}}
```

- Only `id` and `title` are required. `layout` is `list` (default) or `grid:<columns>`; `filters` cycle with Tab and arrive as `filter`.
- `detail` present (even `""`) gives the screen a live text area above the list, with that initial text; `running` shows its spinner.
- Item ids are resolved per screen: a `run` with `view` refers to items that screen's searches returned.
- An action on the screen returning `pop` goes back. When the screen is gone (popped, panel closed) the host sends `dispose`;
  requests for a disposed view should get an `error`.

Unsolicited updates for a screen:

```json
{"type":"detail","view":"v1","text":"3\n","append":true}   // append to the detail area (omit append to replace)
{"type":"detail","view":"v1","running":false}             // stop the spinner
{"type":"refresh","view":"v1"}                            // re-run the current search
```

`SpotlightSDK` does all of this for you: return `.push(ListView(…))` from an action and it assigns the id, routes the
screen's searches and runs to the `ListView`, streams changes of its `DetailModel` as `detail` messages and forgets the
screen on `dispose` (it also keeps at most 32).

Unsolicited messages (no `id`):

```json
{"type":"refresh"}                         // data changed: re-run the current search
{"type":"hud","message":"Synced"}
{"type":"outcome","outcome":{"type":"close"}}
```

## Versions

The SDK answers `hello` with `"version":2`. v1 extensions keep working: they never send `push`, and never see `view` or `dispose`
unless they push. Ignore unknown fields and message types.

## Not yet supported

Global hotkeys and permission declarations for external extensions.
