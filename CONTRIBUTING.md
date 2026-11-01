# Contributing to Slashlight

Thanks for helping. Bug fixes, new built-in extensions, docs and external extensions are all welcome.

## Setup

```bash
git clone https://github.com/burinworks/slashlight.git && cd slashlight
scripts/dev-signing-identity.sh   # once, so macOS keeps permissions across rebuilds
swift build                       # debug build
scripts/test.sh                   # tests (works with Xcode or just the Command Line Tools)
scripts/build-app.sh              # build/Slashlight.app
```

Open the folder in Xcode (`xed .`) or any editor with SourceKit-LSP.

## Where things live

[docs/architecture.md](docs/architecture.md) has the full map. In short:

| You want to change… | Look in |
|---|---|
| A built-in extension | `Sources/Slashlight/Extensions/` |
| Keyboard handling, search routing | `Sources/Slashlight/Panel/PaletteModel.swift` |
| How the panel looks | `Sources/Slashlight/Panel/PaletteView.swift`, `Components.swift`, `Theme.swift` |
| The public extension API | `Sources/SlashlightKit/` (keep it source-compatible) |
| The wire protocol | `Sources/SlashlightKit/WireProtocol.swift` **and** `docs/extension-protocol.md` |

## Adding a built-in extension

1. Add `Sources/Slashlight/Extensions/YourExtension.swift` that subclasses `Extension`.
2. Register it in `Sources/Slashlight/Extensions/BuiltIns.swift`.
3. Add a row to the built-ins table in `docs/user-guide.md`.

If it doesn't need the app's internals, consider making it an external extension instead. That keeps the core small.

## Checking UI changes without clicking

The debug build can render the panel to a PNG:

```bash
.build/debug/Slashlight --snapshot out.png --query "5 km in mi"
.build/debug/Slashlight --snapshot out.png --open emoji --dark
.build/debug/Slashlight --settings --tab General --snapshot-settings out.png
.build/debug/Slashlight --onboarding --step 3 --dark --snapshot-onboarding out.png
```

Attach before/after snapshots to PRs that change the UI.

## Code style

- Match the surrounding code. Small types, early returns, and a doc comment on anything non-obvious.
- UI code is `@MainActor`. Don't block the main thread; extensions' `search` is `async` for a reason.
- No new dependencies without discussing them in an issue first.
- Add tests for pure logic (parsers, ranking, protocol encoding) in `Tests/`. We use [swift-testing](https://github.com/swiftlang/swift-testing).

## Pull requests

1. Branch from `main`.
2. Keep each PR to one change.
3. Make sure `scripts/test.sh` passes; CI runs the same command.
4. Describe what changed and how you checked it. The PR template has a checklist.

Commits use the imperative mood: "Add emoji recents", not "Added…".

## Releasing (maintainers)

Update `CHANGELOG.md`, then push a tag:

```bash
git tag v0.3.0
git push origin v0.3.0
```

The release workflow builds a universal app, packs it into a `.dmg` with `scripts/make-dmg.sh` and publishes the GitHub release.
