# Extension protocol v1

An external extension is a process the host starts on first use. Messages are single-line JSON objects, one per line:
host → extension on **stdin**, extension → host on **stdout**. Write logs to **stderr** only.
The Swift types are in `Sources/SlashlightKit/WireProtocol.swift`; `SlashlightSDK` implements the extension side.

## Install

`~/Library/Application Support/Slashlight/Extensions/<folder>/manifest.json`:

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
{"type":"search","id":2,"query":"alex","mode":"command","filter":null,"supportDirectory":"/Users/…/Slashlight/hello"}
{"type":"run","id":3,"itemId":"greet","actionId":"say-hello"}
{"type":"shutdown","id":4}
```

`mode` is `default` | `command` | `prefix` | `scoped`. `filter` is the active Tab filter in a scoped screen.
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
- `outcome.type`: `close`, `stay` (re-run search), `pop`, `hud` (value = message), `paste` (value = text to paste into the frontmost app).

Unsolicited messages (no `id`):

```json
{"type":"refresh"}                         // data changed: re-run the current search
{"type":"hud","message":"Synced"}
{"type":"outcome","outcome":{"type":"close"}}
```

## Not in v1

Sub-screens (`push`), detail panes, global hotkeys and permission declarations for external extensions.
