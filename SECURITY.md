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

External extensions run with your user's privileges, just like any program you install. Only install extensions you trust.

## Supported versions

Only the latest release gets security fixes.
