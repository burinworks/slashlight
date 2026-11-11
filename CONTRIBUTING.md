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

Every channel is its own app, so you can always tell which one is running:

| Channel | Built by | App name | App ID | Dock | Panel tag |
| --- | --- | --- | --- | --- | --- |
| local | `scripts/build-app.sh` | Slashlight Dev | `dev.slashlight.app.dev` | yes, badge DEV | Local build · commit |
| pr / test | CI on pull requests and on `test` | Slashlight Test | `dev.slashlight.app.test` | yes, badge TEST + build | PR #n / Test · build n |
| beta | Release workflow on `beta` | Slashlight | `dev.slashlight.app` | no | Beta · build n |
| stable | Release workflow on `main` | Slashlight | `dev.slashlight.app` | no | none |

The executable, the Settings window, the menu items and the disk image carry the same name. Each channel has its own entries in System Settings → Privacy, its own Keychain key and its own folder in `~/Library/Application Support/` (`Slashlight`, `Slashlight Test`, `Slashlight Dev`), so they can run side by side. Set `CHANNEL=test` to build a test app locally.

**Build numbers.** `CFBundleVersion` is the build number from `scripts/build-number.sh`: the length of `test`'s first-parent history, so every pull request merged into `test` adds one. Beta and stable releases keep the number of the test build they were promoted from, and pull request builds show the number of the `test` they are based on. CI fetches the full history for it.

**Reinstalling.** A newly installed copy (a different folder on disk than the one that last ran, other than through an in-app update) shows the welcome tour again. Settings → About → Uninstall, or the menu bar icon's Uninstall item, moves the app to the Trash, resets its permissions and login item, and can delete its data.

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

## Branches and release channels

```
feature branch ──PR──▶ test ──promote──▶ beta ──promote──▶ main
                    newest work      beta testers      stable
```

| Branch | Who gets it | Merging into it |
|---|---|---|
| `test` | CI artifacts only | PRs from feature branches, squash or rebase |
| `beta` | Beta testers: a pre-release `vX.Y.Z-beta.N` on every push | Promotion PR from `test`, merge commit |
| `main` | Everyone: stable `vX.Y.Z` | Promotion PR from `beta`, merge commit |

All three need a PR, signed commits and a passing **Build & test** check, and can't be force-pushed or deleted. Promotions use merge commits so the branches keep sharing history and never conflict.

To promote, run **Actions → Promote → Run workflow** and pick `test → beta` or `beta → main`. It opens the PR; merge it with **Create a merge commit**. Or from a terminal:

```bash
gh workflow run promote.yml -f promotion="test → beta"
```

An urgent fix can go to `main` directly through a `hotfix/…` branch. Afterwards run the `main → beta (back-merge)` and `beta → test (back-merge)` promotions so the fix reaches the other channels.

## Pull requests

1. Branch from `test` and open the PR against `test`.
2. Keep each PR to one change.
3. Make sure `scripts/test.sh` passes; CI runs the same command.
4. Describe what changed and how you checked it. The PR template has a checklist.

Commits use the imperative mood: "Add emoji recents", not "Added…".

## Releasing (maintainers)

Releases come from branches; you don't push tags.

1. On `test`, set `VERSION` to the next version and move the `CHANGELOG.md` entries from Unreleased to it.
2. Promote `test → beta`. Each push to `beta` publishes the pre-release `vX.Y.Z-beta.N` for beta testers.
3. Promote `beta → main`. The release workflow waits for your approval in the `stable` environment (Actions → the run → **Review deployments**), then publishes `vX.Y.Z`.

Each release builds a universal app with `scripts/build-app.sh`, packs `Slashlight-<tag>.dmg` with `scripts/make-dmg.sh`, publishes it with `SHA256SUMS.txt` and adds the signed update to the appcast on `gh-pages`. Pushing a `v*` tag by hand still works; a tag with a hyphen is a pre-release.

### One-time setup

`scripts/setup-release-channels.sh` creates the rulesets, the `beta` and `stable` environments, the `gh-pages` branch with GitHub Pages, and lets Actions open promotion PRs. Run it once as a repository admin.

### Code-signing certificate

macOS remembers Accessibility and Screen Recording grants per signing identity. An ad-hoc signature is different for every build, so each update looked like a new app and the old switch in System Settings stopped working. Releases are therefore signed with one self-signed certificate, `Slashlight`:

1. Run `scripts/release-signing-identity.sh` once. It creates the certificate, sets the `SIGNING_P12` and `SIGNING_P12_PASSWORD` secrets, and saves a backup `.p12` on your Desktop.
2. Move the backup and its password into a password manager, then delete the file.

CI and releases import it with `scripts/import-signing-identity.sh`. Without the secret they fall back to ad-hoc signing and print a warning. It is not an Apple Developer ID: Gatekeeper still asks on first open.

### Update signing keys

Sparkle accepts only updates signed with the project's EdDSA key. Generate the pair once, on a Mac, with Sparkle's `generate_keys` (after `swift build`, it is in `.build/artifacts/sparkle/Sparkle/bin/`):

```bash
.build/artifacts/sparkle/Sparkle/bin/generate_keys --account slashlight   # creates the key in your login keychain, prints the public key
.build/artifacts/sparkle/Sparkle/bin/generate_keys --account slashlight -x sparkle_private.key   # exports the private key to a file
gh secret set SPARKLE_PRIVATE_KEY < sparkle_private.key
gh variable set SPARKLE_PUBLIC_KEY --body "<public key printed above>"
rm sparkle_private.key
```

- `SPARKLE_PRIVATE_KEY` (Actions secret) signs each `.dmg`. Never commit it. The keychain item is your backup; if the key is lost, installed copies can't verify new updates.
- `SPARKLE_PUBLIC_KEY` (Actions variable) goes into the app's Info.plist as `SUPublicEDKey`.

The release workflow fails early when either is missing, so no release ships without working updates.
