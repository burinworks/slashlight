# Security policy

Slashlight runs with Accessibility and Screen Recording permissions and executes commands you configure, so security reports matter.

## Reporting a vulnerability

Please **do not open a public issue**. Use [GitHub private vulnerability reporting](https://github.com/burinworks/slashlight/security/advisories/new) instead. Include:

- what an attacker can do, and what they need first (local access, a malicious extension, a crafted file…);
- steps to reproduce;
- the Slashlight and macOS versions.

You'll get a reply within 7 days. Fixes for confirmed issues ship in a patch release, and you get credit in the advisory if you want it.

## Scope

In scope:

- the app;
- `SlashlightKit` and `SlashlightSDK`;
- the release workflow.

External extensions and Raycast script commands run as your user. They do **not** get the Accessibility, Screen Recording or Automation access you gave Slashlight (macOS asks you separately if they want it), they don't see your shell's environment variables, and they can't read files Slashlight has open. They can still read and write your files and use the network, so only install extensions you trust. [Extension permissions](docs/extension-permissions.md) describes the planned sandbox and permission prompts.

## How the project checks itself

| Check | Workflow | Looks for |
|---|---|---|
| CodeQL | `codeql.yml` | Bugs and unsafe patterns in the Swift code |
| zizmor | `security.yml` | Unsafe GitHub Actions workflows: unpinned actions, leaked tokens, template injection |
| TruffleHog | `security.yml` | Secrets committed to the repository |
| OSV-Scanner | `security.yml` | Known vulnerabilities in `Package.resolved`, weekly and on every push |
| Dependency review | `security.yml` | Pull requests that add a vulnerable dependency |

All third-party actions are pinned to a commit SHA, and Dependabot waits 7 days before proposing a new version.

## Supported versions

Only the latest release gets security fixes.
