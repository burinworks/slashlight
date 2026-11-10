# Changelog

All notable changes to this project are documented here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project uses [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Security
- External extensions and Raycast script commands no longer inherit Slashlight's Accessibility, Screen Recording and Automation access: each runs as its own responsible process.
- They start with a short, clean environment (no tokens from your shell), none of Slashlight's open files, default signal handlers, and in their own process group, so stopping one also stops what it started.
- `context.copy` in the SDK asks the host to write the clipboard (new `copy` message).

### Added
- Recent on the home screen follows each extension's choice (`Manifest.recents` / manifest key `recents`): the commands, window layouts, apps and system actions you ran, or the extension itself.
- `/` on its own lists every command, the one you ran last first.
- Calculator answers before you finish: `12*(3+` shows 36, `5 km` shows miles, `100 usd` your own currency.
- `Extension.recentItem(id:title:)` rebuilds a recent item when the panel opens.
- Settings → General → Appearance: background opacity (see-through to solid) and blur behind the panel, with a live preview.
- `Extension.panelWillOpen()`: called each time the panel opens, so extensions can reload cached data.
- Usage Insights (`/stats`): a dashboard of your own usage, with actions per day, busiest hours, top extensions and items, streak, median time to action and tips. Recorded locally only.
- Welcome tour on first launch: pick a hotkey (with a shortcut to free ⌘Space from Spotlight), see what you can type, where extensions live and which optional permissions help. Replay it from the menu bar icon or Settings → About. Existing installs skip it.
- `--onboarding --step N --snapshot-onboarding out.png` renders a tour step for checking UI changes.
- Test suites for fuzzy ranking, the wire protocol and the calculator parser.
- CI (build, test, universal app artifact), CodeQL and tag-driven GitHub releases.
- Python example extension and a guide to writing extensions.
- App icon, and releases ship as a drag-to-Applications `.dmg`.
- In-app updates with Sparkle: **Check for Updates…** in the menu bar menu and Settings → General, plus **Automatically install updates** and **Join the beta program** switches.
- Release channels: work lands on `test`, is promoted to `beta` (pre-releases `vX.Y.Z-beta.N`) and then `main` (stable releases), each with an EdDSA-signed appcast entry.
- Security workflow: zizmor (workflow audit), TruffleHog (committed secrets), OSV-Scanner (known vulnerabilities in dependencies) and dependency review on pull requests. Every action is pinned to a commit SHA.
- [Extension permissions](docs/extension-permissions.md) proposal: what extensions declare in `manifest.json`, what the user is shown, and how each permission is enforced.

### Changed
- Extensions open by typing their name; `/` lists commands only. `command:<name>` triggers are now extra names to find the extension by.
- Raycast script commands are part of Commands and read `/hello-world` like your other commands.
- Calculator is inline only: no Calculator entry in the extension list.
- The panel is translucent with a blurred background. Rows are shorter, and extension rows no longer show a description.
- Opening the panel under a still mouse no longer selects the row under the pointer: ↑↓ start from the top until the mouse moves.
- App and window lists refresh every time the panel opens, so newly installed apps show up straight away.

### Removed
- The extension dropdown in the search bar. Type an extension's name, or pick it on the home list (⌘E).

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
