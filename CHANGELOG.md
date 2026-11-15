# Changelog

All notable changes to this project are documented here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project uses [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Changed
- The main search ranks across extensions instead of always listing apps first. The best result is the **Top Hit**, and lists follow in order of their best result. A word that starts with what you typed beats letters inside a word ("his" finds Clipboard *His*tory before About T*his* Mac), extensions edge out apps when the match is as good, files come later and the web search last.
- It learns: what you open for what you typed ranks first next time, also for shorter and longer versions of the query ("hi", "hist"). The memory fades over about a month and stays in `search-memory.json` on this Mac.

### Added
- Settings → Hotkeys lists every key Slashlight uses: ⌃P/⌃N, ⌘↵, the terminal tab keys (⌘⌫ ⌘T ⌘W ⌃⇥ ⌃⇧⇥), Insights' Clear, and every item action's shortcut (Copy Path, Quit App, Delete, Paste as Plain Text…), each changeable. Arrows, ↵, Tab, Esc and ⌘1…⌘9 stay fixed.
- A clash warning has **Use it here**: it takes the key from the others, so ⌃⇥ can open Switch Window anywhere.

### Changed
- Versions are CORE.STABLE.MINOR and CI picks them: each promotion to beta adds one to MINOR (v0.4.1, v0.4.2…), each promotion to main adds one to STABLE and resets MINOR (v0.5.0). `VERSION` sets CORE.

## [0.4.0] - 2026-11-15

### Added
- Settings → Hotkeys: every key grouped by what it does (Slashlight, Open Extensions, Commands & Scripts, Windows), with an icon for where it works: globe for anywhere on the Mac, Slashlight's mark for anywhere in the panel, a puzzle piece for one extension. Record a new key (esc cancels, ⌫ removes) or reset it; keys that clash or that another app took are flagged. Open Slashlight stays in General, now as the welcome tour's choice of ⌘Space, ⌥Space, ⌃Space or a recorded key, with a warning while Spotlight still holds ⌘Space; Esc is always Back.
- Every extension with a screen gets an "Open <extension>" global slot, and every command and script a global slot, without a key until you set one. `hotkey` in commands.json and `# @slashlight.hotkey` in a script set one, Set Hotkey… on a command opens Settings on it, and a command's key shows on its row.
- Extensions offer hotkey actions: `hotkeys` in Swift, a `hotkeys` block in `manifest.json` and a `hotkey` request for external ones. The Python example pastes a new UUID on ⌃⌥U.
- Hotkeys can't take what macOS or every app already uses: the recorder refuses the shortcuts macOS has turned on (read from macOS) and keys like ⌘C, ⌘V, ⌘Q, ⌘Tab as global keys, and says why.
- Hotkeys can use F1–F12 and the ; ' [ ] and backslash keys.
- Each build says what it is: local builds are **Slashlight Dev** and CI builds of `test` and pull requests are **Slashlight Test**, each with its own app ID, settings folder and permissions. Both stay in the Dock with a DEV / TEST badge, and the panel's footer shows a tag (Local build, Test · build n, Beta · build n).
- Build numbers: every pull request merged into `test` adds one; beta and stable keep the number of the test build they came from. Shown in Settings → About and Updates.
- Uninstall from Settings → About or the menu bar icon: moves the app to the Trash, resets its permissions and login item, and optionally deletes its data. Reset Welcome Tour in Settings → About.
- Installing the app again shows the welcome tour again (updates don't).
- Clipboard History keeps images and files, with an Images view of large previews, and survives quitting and updates (encrypted; key in your Keychain). Settings → General → Clipboard History: keep after quitting, forget after 1/7/30 days or never, clear.
- Recent on the home screen follows each extension's choice (`Manifest.recents` / manifest key `recents`): the commands, window layouts, apps and system actions you ran, or the extension itself.
- `/` on its own lists every command, the one you ran last first.
- Calculator answers before you finish: `12*(3+` shows 36, `5 km` shows miles, `100 usd` your own currency.
- `Extension.recentItem(id:title:)` rebuilds a recent item when the panel opens.
- Settings → General → Appearance: background opacity (see-through to solid) and blur behind the panel, with a live preview.
- `Extension.panelWillOpen()`: called each time the panel opens, so extensions can reload cached data.
- Security workflow: zizmor (workflow audit), TruffleHog (committed secrets), OSV-Scanner (known vulnerabilities in dependencies) and dependency review on pull requests. Every action is pinned to a commit SHA.
- [Extension permissions](docs/extension-permissions.md) proposal: what extensions declare in `manifest.json`, what the user is shown, and how each permission is enforced.

### Changed
- The window switcher's key moved from `windowSwitcherHotkey` to Settings → Hotkeys; a changed key carries over.
- The main search shows each result's icon and name only, with no subtitle or status pill such as "Running". Lists inside an extension still show them.
- Esc goes back one screen and closes the panel only from the main search. Backspace on an empty bar no longer goes back. In the terminal, Esc at an idle prompt goes back to search; ⌘⌫ still works there too.
- Local builds are named **Slashlight Dev** with their own app ID, so they no longer take over the installed app's permissions or Keychain item.
- Welcome tour shows the new search: `/` lists commands, extensions open by name, and `5 km` converts without a target.
- Extensions open by typing their name; `/` lists commands only. `command:<name>` triggers are now extra names to find the extension by.
- Raycast script commands are part of Commands and read `/hello-world` like your other commands.
- Calculator is inline only: no Calculator entry in the extension list.
- The panel is translucent with a blurred background. Rows are shorter, and extension rows no longer show a description.
- Opening the panel under a still mouse no longer selects the row under the pointer: ↑↓ start from the top until the mouse moves.
- App and window lists refresh every time the panel opens, so newly installed apps show up straight away.

### Removed
- The extension dropdown in the search bar. Type an extension's name, or pick it on the home list (⌘E).

### Fixed
- Copying or pasting from Clipboard History keeps the original formatting (Google Docs, Pages, Slack…) instead of plain text.
- Permissions you granted no longer show as missing:
  - Releases are signed with one certificate, so macOS keeps your Accessibility and Screen Recording grants across updates.
  - Screen Recording shows as granted without restarting Slashlight.
  - Settings → Permissions and the welcome tour have a **Reset** button for a switch left over from an earlier copy.
- Hotkey recording stops when you click anything else, such as a suggested hotkey in the welcome tour.

### Security
- External extensions and script commands run in a macOS sandbox (Seatbelt). They get their own folder, a data folder and their own temp folder. Anything else needs a permission in `manifest.json` (`permissions`) or a `# @slashlight.*` header line:
  - the network
  - other folders in your home folder
  - running other programs
  - opening apps and websites
  The clipboard, the Keychain, Apple Events, launchd jobs, Slashlight's data, `~/.ssh` and other secrets, the window server and Accessibility are always blocked. Writing outside the granted folders is blocked too, so an extension can't replace programs in `/opt/homebrew`.
- Extensions granted ~/Documents, ~/Desktop or ~/Downloads run under Slashlight's folder access, since macOS gives a program that is its own responsible process no access to those folders. The sandbox still blocks Accessibility and Screen Recording for them.
- External extensions keep their data in `ExtensionData/<id>`, and an extension can no longer use a built-in's id (such as `clipboard`) to reach its data. Manifests using the `default` trigger need `"defaultSearch": true`.
- External extensions and Raycast script commands no longer inherit Slashlight's Accessibility, Screen Recording and Automation access: each runs as its own responsible process.
- They start with a short, clean environment (no tokens from your shell), none of Slashlight's open files, default signal handlers, and in their own process group, so stopping one also stops what it started.
- `context.copy` in the SDK asks the host to write the clipboard (new `copy` message).

## [0.3.0] - 2026-11-01

### Added
- Usage Insights (`/insights`): a dashboard of your own usage, with actions per day, busiest hours, top extensions and items, streak, median time to action and tips. Recorded locally only.
- Welcome tour on first launch: pick a hotkey (with a shortcut to free ⌘Space from Spotlight), see what you can type, where extensions live and which optional permissions help. Replay it from the menu bar icon or Settings → About. Existing installs skip it.
- `--onboarding --step N --snapshot-onboarding out.png` renders a tour step for checking UI changes.
- Home screen shows your 5 most recently used extensions above the full A–Z list.
- Test suites for fuzzy ranking, the wire protocol and the calculator parser.
- CI (build, test, universal app artifact), CodeQL and tag-driven GitHub releases.
- Python example extension and a guide to writing extensions.
- App icon, and releases ship as a drag-to-Applications `.dmg`.
- In-app updates with Sparkle: **Check for Updates…** in the menu bar menu and Settings → General, plus **Automatically install updates** and **Join the beta program** switches.
- Release channels: work lands on `test`, is promoted to `beta` (pre-releases `vX.Y.Z-beta.N`) and then `main` (stable releases), each with an EdDSA-signed appcast entry.

## [0.2.0] - 2026-10-29

### Added
- Terminal tabs inside the panel (`> command`): real terminal, busy/idle/exit tracking, a tab strip and finish toasts.
- Calculator with units and live currency rates; System commands; Emoji & Symbols; Raycast script commands; web search fallback; `{query}` quicklinks.
- Extension protocol v2: external extensions can push sub-screens (lists, grids with filters, streaming detail).
- Multi-line snippet editor.
- Settings window: hotkey recorder, theme, launch at login, extension toggles and permission status.

### Fixed
- Window switcher lists windows on every Space, including minimized windows and hidden apps.
- Extensions and commands are found by name in plain search ("switch window").
- A stable local signing identity keeps permissions across rebuilds.

## [0.1.0] - 2026-10-29

### Added
- First version: the `Extension` API, the stdio SDK, the panel, and built-ins for apps, files, commands, clipboard, snippets, window layouts and the window switcher.

[Unreleased]: https://github.com/burinworks/slashlight/compare/v0.2.0...HEAD
[0.2.0]: https://github.com/burinworks/slashlight/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/burinworks/slashlight/releases/tag/v0.1.0
