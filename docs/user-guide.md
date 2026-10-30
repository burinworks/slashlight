# User guide

## What you can type

| Input | What happens |
|---|---|
| `claude` | Apps, files, a calculator answer, and any extension or command whose name matches (`switch window`, `left half`) |
| `/` | Command mode: your `/commands`, every extension (`/clipboard`, `/snippets`…), window layouts (`/left-half`) |
| `> npm run dev` | Opens a terminal tab inside Slashlight and runs the command there |
| empty bar | Your 5 most recently used extensions, then every extension A–Z |

## Keys

| Key | Action |
|---|---|
| ⌥Space | Open / close (change it in Settings → General) |
| ↑ ↓, ⌃N ⌃P | Move the selection |
| ↵ / click | Primary action |
| ⌘↵ / ⌘-click | Secondary action |
| ⌘K | All actions of the selected item |
| ⌫ on an empty bar | Back one screen |
| Esc | Close the panel |
| Tab / ⇧Tab | Cycle filters (by section type, or the screen's own filters) |
| ⌘1…⌘9 | Run the Nth result |
| ⌘E | Back to the extension list |
| ⌘, | Settings window (also in the menu bar icon) |
| ⌥Tab | Window switcher: hold ⌥, tap Tab to move, release to switch |
| ⌃⌥ ← → ↑ ↓ ↵ C ⌫ | Window layout: halves, maximize, center, restore |
| ⌃⌥ D F G / E T | Thirds / two-thirds |
| ⌃⌥ U I J K | Quarters |

## Built-in extensions

| Extension | ↵ | ⌘↵ |
|---|---|---|
| **All Apps** (`/apps`): Tab switches between recently opened, recently added and A–Z | Open | Show in Finder |
| **Files** (`/files`): Spotlight index of your home folder | Open | Show in Finder |
| **Commands** (`/commands`): your `commands.json` | Run | Copy definition |
| **Clipboard History** (`/clipboard`): kept in memory, gone after quit | Copy and move to top | Paste |
| **Snippets** (`/snippets`): stored on disk; multi-line editor where ⌘↵ saves | Copy | Paste |
| **Window Layout** (`/windows`) | Apply to the focused window | — |
| **Switch Window** (`/switch`, ⌥Tab): every Space and display | Switch | Show all of the app's windows |
| **Terminal** (`>` or `/terminal`) | Run in a new tab | Open in Terminal.app |
| **Calculator**: answers as you type | Copy result | Paste result |
| **System** (`/system`, `/lock`, `/sleep`…) | Run | — |
| **Emoji & Symbols** (`/emoji`) | Copy | Paste |
| **Script Commands** (`/scripts`): Raycast script commands from `script-commands/` | Run | — |
| **Usage Insights** (`/insights`, `/stats`): a dashboard of your own usage | Open | — |
| **Search the Web**: always the last result | Google | DuckDuckGo |

Turn any extension except All Apps on or off in Settings → Extensions.

## Calculator

- **Math:** `+ - * / ^ %`, parentheses, `sqrt cbrt abs round floor ceil exp sin cos tan asin acos atan log ln log2`, plus `pi`, `e` and `tau`.
- **Percentages:** `15% of 80`, `200 + 10%`.
- **Units:** length, mass, temperature, volume, speed, time and data (`5 km in mi`, `100 f to c`, `2 gb to mb`).
- **Currencies:** ISO codes and `$ € £ ¥` (`$100 to eur`). Rates come from open.er-api.com and are cached for 12 hours.

## Terminal tabs

`> command` then ↵ opens a real terminal inside the panel and runs the command in your login shell. Colors, `vim`, `top` and `less` all work.
Tabs keep running when you go back to search or close the panel. Open tabs show as a strip at the bottom of the panel:

- **green dot:** a task is running, with its run time;
- **grey:** idle at the prompt;
- **red:** the last command exited with an error.

When a task that ran longer than 3 s finishes while you are elsewhere, you get a toast.

| Key (in a terminal tab) | Action |
|---|---|
| ⌘⌫ or ⌘[ | Back to search; the tab keeps running |
| Esc | At an idle prompt, closes the panel; while a program runs (vim, less), goes to that program |
| ⌘T / ⌘W | New tab / close tab |
| ⌃⇥, ⌃⇧⇥, ⌘1…⌘9 | Switch tabs. From search, ⌃⇥ jumps back to the last tab |
| ⌘C ⌘V ⌘K ⌘+ ⌘− | Copy, paste, clear, font size |

## Usage Insights

`/insights` opens a dashboard of how you use Slashlight:

- totals, plus the time saved (estimated at 3 s per action);
- your streak, actions per day and the busiest hours;
- top extensions and the items you open most;
- how often the first result was the right one, and keyboard versus mouse;
- short tips, for example extensions you haven't tried.

| Key | Action |
|---|---|
| Tab / ⇧Tab | 7 days, 30 days, all time |
| ↑ ↓ | Scroll |
| ⌘⇧⌫ twice | Delete all recorded usage |
| ⌘⌫ | Back |

What is recorded:

- when the panel opens;
- for each action: the extension, the item's title, the action, the row's position, how many characters you had typed, the time since the panel opened, and whether you used the keyboard or the mouse.

Titles are not recorded for Clipboard History, Calculator, Files and web searches, because those titles are your own content. What you type in the search bar is stored only as its length, and as part of a terminal tab's title (`Run  npm run dev`) when you run a command. Events live in `usage/events.jsonl` and are deleted after a year. Turning Usage Insights off in Settings → Extensions stops recording.

## Your own commands

`~/Library/Application Support/Slashlight/commands/commands.json` is an array of commands:

```json
[
  { "name": "gh", "title": "Search GitHub", "type": "url", "run": "https://github.com/search?q={query}" },
  { "name": "deploy", "type": "shell", "run": "cd ~/code/site && ./deploy.sh {query}" },
  { "name": "focus", "type": "shortcut", "run": "Focus Mode" },
  { "name": "ping", "type": "http", "method": "POST", "run": "https://example.com/hook",
    "headers": { "Content-Type": "application/json" }, "body": "{\"text\":\"{query}\"}" },
  { "name": "mute", "type": "applescript", "run": "set volume output muted true" }
]
```

| `type` | `run` is |
|---|---|
| `shell` | A command for your login shell. `{query}` is shell-quoted |
| `url` | A URL. `{query}` is percent-encoded, so this makes a quicklink |
| `shortcut` | The name of a Shortcuts.app shortcut |
| `http` | A request URL; `method`, `headers` and `body` are optional |
| `applescript` | AppleScript source |

`{query}` is whatever you type after the command's name: `/gh slashlight`.

## Script commands

Put Raycast-style scripts in `~/Library/Application Support/Slashlight/script-commands/`. Slashlight reads the `@raycast.title`, `icon`, `mode` (`fullOutput`, `compact`, `silent`, `inline`), `argument1…3`, `packageName`, `currentDirectoryPath`, `needsConfirmation` and `refreshTime` headers. The scripts from [raycast/script-commands](https://github.com/raycast/script-commands) work unchanged.

## Configuration files

Everything lives in `~/Library/Application Support/Slashlight/`:

| Path | Contents |
|---|---|
| `settings.json` | Hotkeys, theme, window-layout keys on/off, disabled extensions |
| `commands/commands.json` | Your `/commands` |
| `snippets/` | Snippets |
| `script-commands/` | Raycast-style scripts |
| `Extensions/<name>/` | External extensions (`manifest.json` + executable) |
| `recent-extensions.json` | Order of the Recent section |
| `usage/events.jsonl` | Usage Insights events (stays on this Mac) |

`settings.json` defaults:

```json
{
  "hotkey": "opt+space",
  "windowSwitcherHotkey": "opt+tab",
  "windowManagementHotkeys": true,
  "appearance": "system",
  "disabledExtensions": []
}
```

## Permissions

| Permission | Used for | Without it |
|---|---|---|
| Accessibility | Window layouts, auto-paste, raising windows on other Spaces, Lock Screen | Switcher sees only the current Space; paste falls back to copy |
| Screen Recording | Window thumbnails in the switcher | App icons instead of thumbnails |
| Automation (asked on first use) | Commands that open Terminal.app or run AppleScript | That command fails with a message |

If you build from source, run `scripts/dev-signing-identity.sh` once. Otherwise every rebuild is signed differently and macOS forgets these grants.

## Troubleshooting

- **No window thumbnails, or the switcher only shows the current Space:** grant Screen Recording and Accessibility in Settings → Permissions, then quit and reopen Slashlight.
- **⌥Space does nothing:** another app may own the shortcut. Record a new one in Settings → General.
- **An external extension doesn't show up:** check that `manifest.json` is valid and `exec` is executable (`chmod +x`), then use Settings → Extensions → Reload. Extensions log to stderr, which Slashlight passes through: run `build/Slashlight.app/Contents/MacOS/Slashlight` from a terminal to see it.

## Known gaps

- Terminal tabs do not survive quitting Slashlight.
- External extensions cannot declare global hotkeys or permissions yet.
- Releases are not notarized by Apple, so the first launch needs `xattr -dr com.apple.quarantine /Applications/Slashlight.app`.
