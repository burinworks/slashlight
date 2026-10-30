# Changelog

All notable changes to this project are documented here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project uses [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added
- Anonymous, opt-in usage statistics with a self-hosted collector and a public dashboard (`server/`, `docs/telemetry.md`). Settings → General → Privacy has the toggle, a preview of the exact report, and an ID reset.
- Usage Insights (`/insights`): a dashboard of your own usage, with actions per day, busiest hours, top extensions and items, streak, time saved and tips. Recorded locally only.

### Added
- Home screen shows your 5 most recently used extensions above the full A–Z list.
- Test suites for fuzzy ranking, the wire protocol and the calculator parser.
- CI (build, test, universal app artifact), CodeQL and tag-driven GitHub releases.
- Python example extension and a guide to writing extensions.
- App icon, and releases ship as a drag-to-Applications `.dmg`.

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
