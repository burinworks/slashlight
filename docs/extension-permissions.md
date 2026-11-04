# Extension permissions

> Status: **proposal.** Nothing here is enforced yet. This page is the spec the sandbox work builds on.

An extension says in its `manifest.json` what it needs. Slashlight shows that list to the user in plain words before the extension runs for the first time, and enforces it: anything not declared is blocked by the operating system, not by asking the extension to behave.

## Goals

1. **No silent access.** The user sees every capability before it is used, and again whenever an update asks for more.
2. **Deny by default.** An extension with no `permissions` block can answer searches and return results, and nothing else.
3. **Enforced, not trusted.** Each permission maps to a sandbox rule, a filtering proxy or a host-side broker. A permission the host cannot enforce is not offered.
4. **Readable.** Every permission has one sentence the user can understand without knowing what a mach service is.

## The manifest

```json
{
  "id": "vault",
  "title": "Vault",
  "exec": ["./vault"],
  "triggers": ["command:vault"],
  "permissions": {
    "network": ["api.vault.example", "*.vault-cdn.example"],
    "files": { "read": ["~/Downloads"], "write": [] },
    "defaultSearch": false,
    "background": false,
    "subprocesses": false
  },
  "why": {
    "network": "Syncs your vault with your account."
  }
}
```

| Key | Values | Default |
|---|---|---|
| `network` | list of hosts (`api.example.com`, `*.example.com`), or `"any"` | `[]`: no network |
| `files.read`, `files.write` | folders from the allowed list below | `[]`: only the extension's own folders |
| `defaultSearch` | `true` when the `default` trigger is used | `false` |
| `background` | `true` to keep running while the panel is closed | `false` |
| `subprocesses` | `true` to start other programs (`curl`, `git`, `python3`) | `false` |
| `why` | one sentence per permission, written by the author | none; shown as "No reason given" |

`triggers` and `permissions` must agree: an extension that uses the `default` trigger without `"defaultSearch": true` fails to load, and the error says why.

### Always allowed

These cannot leak data on their own, so they need no permission:

- Reading and writing its own folder (`Extensions/<id>/`) and its storage folder (`Application Support/Slashlight/ExtensionData/<id>/`).
- Returning results, opening its own screens, showing a HUD.
- Outcomes the user triggers by pressing a key: `.paste(text)` and `.close`. The host performs the paste, so the extension never gets Accessibility.
- Putting text on the clipboard with `context.copy(text)`. The SDK sends it to the host, which writes the pasteboard; the extension process itself cannot open the pasteboard.
- Opening a URL in the default browser after the user presses ↵. The host opens it, and the URL is shown in the action row first.

### Never allowed

No manifest key can grant these:

- Slashlight's Accessibility and Screen Recording permissions. Extensions are launched as their own "responsible process", so macOS does not hand them the grants the user gave Slashlight.
- The Keychain, `~/.ssh`, `~/.gnupg`, `~/.aws`, `~/.config/gh`, browser profiles, Mail, Messages, and every other app's `~/Library` data.
- **Reading the clipboard.** Only Slashlight's built-in Clipboard History sees what you copy. No manifest key, prompt or setting unlocks it for a third-party extension, so an extension that wants to inspect the clipboard has to be its own app with its own macOS permissions, outside Slashlight.
- Slashlight's own data: settings, clipboard history, usage events, other extensions' folders.
- Sending keystrokes, reading the screen, reading other apps' windows.

### Allowed folders for `files`

`~/Downloads`, `~/Documents`, `~/Desktop`, `~/Pictures`, `~/Movies`, `~/Music`, and `~/Developer` or any folder under `~` that is not on the never-allowed list, written as an exact path. Wildcards and `~` alone are rejected.

## What the user sees

### First run

The first time an extension would run, the panel shows this screen instead of its results. Nothing has started yet.

```
┌──────────────────────────────────────────────────────┐
│  🔐 Vault                     from ~/…/Extensions/vault │
│  wants to:                                            │
│                                                       │
│  🌐 Connect to api.vault.example and *.vault-cdn.example │
│     “Syncs your vault with your account.”             │
│  📂 Read files in Downloads                           │
│                                                       │
│  It can’t see your screen, type for you, read your    │
│  clipboard, or read your other files.                 │
│                                                       │
│              [ Don’t Allow ]   [ Allow ↵ ]            │
└──────────────────────────────────────────────────────┘
```

Rules for the screen:

1. One line per permission, in the order of the table below (riskiest first).
2. Below each line, the author's `why` in quotes, or "No reason given" in grey.
3. Lines marked **high** are drawn in red.
4. The last line always says what the extension **can't** do, so a short list reads as reassuring rather than empty.
5. ↵ is Allow, ⎋ is Don't Allow. Don't Allow disables the extension; Settings → Extensions turns it back on and shows this screen again.

### Wording

| Permission | Line shown | Risk |
|---|---|---|
| `network: "any"` | Connect to any website or server | high |
| `defaultSearch: true` | See everything you type in the search bar | high |
| `subprocesses: true` | Run other programs on your Mac | high |
| `files.write` | Change files in *Downloads* | medium |
| `network: [hosts]` | Connect to *api.vault.example* | medium |
| `files.read` | Read files in *Downloads* | medium |
| `background: true` | Keep running when Slashlight is closed | low |

### Updates

Slashlight stores a SHA-256 hash of every file in the extension's folder together with the permissions the user approved.

- **Same files:** nothing is shown.
- **Files changed, same permissions:** a HUD says "Vault was updated", and the extension runs.
- **Files changed, more permissions:** the first-run screen comes back and lists only the new lines, under "Vault now also wants to:". Until the user answers, the old version's permissions stay in force.
- **Fewer permissions:** applied silently.

### Settings → Extensions

Each extension row shows a short summary ("Network · Downloads") and opens a detail page with the full list, the approval date and a **Revoke** button.

## Raycast script commands

Script commands have no manifest, so they read optional header lines:

```bash
# @raycast.title Create Gist
# @slashlight.network api.github.com
# @slashlight.files.read ~/Documents
```

A script without these lines gets the deny-by-default set plus `subprocesses` (a shell script calls other programs), and the first-run screen says "This script didn't say what it needs. It can't use the internet or read your files." When a script fails because the network was blocked, its error row offers "Allow network for this script", which shows the screen again.

## How each permission is enforced

| Permission | Enforced by |
|---|---|
| no network / `"any"` | The sandbox profile denies or allows outbound connections |
| `network: [hosts]` | The sandbox only allows connections to a local filtering proxy started by Slashlight; the extension gets `HTTPS_PROXY`, and the proxy allows only the listed hosts. Programs that ignore the proxy are blocked by the sandbox, so the check fails closed |
| `files` | Sandbox read and write rules for the listed folders, with the never-allowed list denied on top |
| clipboard (never readable) | The sandbox always denies the pasteboard service. `copy` goes through the host |
| `defaultSearch` | The host only sends plain typing to extensions that have it |
| `background` | The host stops the process when the panel closes, unless granted |
| `subprocesses` | Sandbox `process-exec` rule. Children inherit the same sandbox |
| Accessibility, Screen Recording | The extension is spawned as its own responsible process, so the TCC grants stay with Slashlight |
| environment | Extensions start with a clean environment (`PATH`, `HOME`, `LANG`, `TMPDIR` and `SLASHLIGHT_*` only), so tokens in your shell environment are not passed on |

## Limits

- An extension allowed to reach `api.example.com` can send that host anything it is allowed to read. Permissions limit **where** data can go; the extension store's review covers **what** is sent.
- The sandbox uses macOS's built-in Seatbelt (`sandbox-exec`). Apple marks the command-line tool as deprecated, but it ships in every macOS release and is used by Chrome, Bazel and other developer tools. If Apple removes it, the fallback is an XPC helper with the App Sandbox entitlement.

## Rollout

1. Spawn extensions as their own responsible process, with a clean environment.
2. Sandbox with deny-by-default plus the always-allowed set; read `permissions` but grant everything declared without prompting.
3. First-run and update screens; hash tracking.
4. Filtering proxy for host lists.
5. Extension store: a GitHub index listing each extension's source, version, file hashes and permissions, checked in CI. Slashlight refuses a store install whose hashes don't match.

Each step ships with a test extension that tries to break the rule (connect to an undeclared host, read `~/.ssh`, read the clipboard, take a screenshot, read `GITHUB_TOKEN`) and a test asserting it fails. These run in CI on GitHub's macOS runners.
