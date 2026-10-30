# Public statistics

Slashlight can send anonymous usage statistics to a self-hosted server. Everything the server collects is aggregated and published on a public dashboard, so users, contributors and maintainers all see the same numbers. No third-party analytics service is involved.

## Principles

1. **Ask first.** Nothing is sent until the user says yes, either in onboarding or in Settings → General. Both choices are presented equally, and the answer can be changed at any time.
2. **Collect counts, not content.** The app never sends search text, item titles, file names, clipboard contents, terminal commands, window titles or the names of external extensions.
3. **Publish everything we keep.** The public dashboard and its JSON file contain every aggregate the server computes. Raw reports are deleted after 90 days.
4. **Small groups stay hidden.** Any bucket with fewer than 5 installs (a rare macOS version or region, for example) is folded into "Other".
5. **Verifiable.** Settings → General → "Show what's sent" displays the exact JSON of the next report, and the server and dashboard code live in this repository.

## Identity

Each install has a **random install ID**, a UUID v4 created locally the first time a report is sent. It is not derived from the hardware, Apple ID, user name or network. It lets us count active installs and retention without knowing who anyone is.

- Settings → General → "Reset ID" creates a new one, after which the install looks like a new user.
- Turning sharing off deletes the ID and the record of which days were already sent.
- The server stores a keyed hash of the ID, `HMAC-SHA256(server secret, install ID)`, never the ID itself. A database leak alone therefore cannot link rows to a device.
- The server does not log or store IP addresses. The bundled Caddy config turns access logs off, and the collector only keeps a short in-memory rate-limit counter per IP.

## What a report contains

The app sends one report per finished local day, the day after, with up to 7 missed days caught up. Days with no activity are not sent.

```json
{
  "schema": 1,
  "install": "1F0C6A0E-…",
  "day": "2026-10-29",
  "app": { "version": "0.4.0", "build": 57, "channel": "stable" },
  "system": { "macos": "26.1", "arch": "arm64", "region": "DE", "language": "en" },
  "settings": {
    "hotkey": "opt+space",
    "appearance": "system",
    "disabled": ["files"],
    "externalExtensions": 2
  },
  "usage": {
    "opens": 34,
    "actions": 41,
    "byExtension": { "apps": 22, "window-switcher": 9, "terminal": 4, "external": 3 },
    "inputs": { "key": 37, "click": 2, "number": 1, "shortcut": 1, "hold": 0 },
    "firstResult": 33,
    "ranked": 40,
    "latencyP50": 1350,
    "queryLengthP50": 3
  }
}
```

| Field | Why we want it |
|---|---|
| `install` + `day` | Daily, weekly and monthly active installs, new installs, retention |
| `app.version`, `channel` | Adoption of releases; whether beta users are on the newest build |
| `system.macos`, `arch` | Which macOS versions and Intel Macs we still need to support |
| `region`, `language` | Which translations to prioritise (from system settings, not IP) |
| `settings.*` | Whether defaults are good: hotkeys people change, extensions people turn off |
| `usage.byExtension` | Which extensions matter. Built-in ids only; external ones are all counted as `external` |
| `inputs`, `firstResult` / `ranked`, `latencyP50` | Search quality: is the right result first, and how quickly people reach it |
| `queryLengthP50` | How much people type before they find what they want |

## Public metrics

The dashboard shows:

- **Reach:** daily, weekly and monthly active installs; new installs per day; total installs ever seen.
- **Retention:** the share of each weekly cohort still active 1, 2 and 4 weeks later.
- **Engagement:** median actions per active install per day, and the share of active installs using each extension.
- **Search quality:** first-result rate, keyboard share and median time to action.
- **Platform:** app versions, update channel, macOS versions, Apple silicon vs Intel, regions and languages.
- **Defaults:** hotkey choices, appearance, and the most-disabled extensions.

Every chart is computed from the same `stats.json`, which is published next to the dashboard so anyone can analyse it.

## Architecture

```
Slashlight.app ── HTTPS POST /v1/report (once a day) ──▶ collector (Python, stdlib only)
                                                            │ SQLite: reports (90 days), install hashes
                                                            ▼
                                                     aggregator (hourly) ──▶ public/stats.json
                                                                                  │
                                                     static dashboard (HTML + JS) ◀┘  served by Caddy
```

- **`server/collector.py`** validates the schema, caps reports at 16 KB, rate-limits per IP in memory, and upserts one row per (install, day).
- **`server/aggregate.py`** computes the metrics above, applies the 5-install threshold, writes `stats.json`, and deletes raw reports older than 90 days.
- **`server/dashboard/`** is a static page that renders `stats.json` with no external requests.
- **`server/docker-compose.yml`** runs the collector, an hourly aggregator and Caddy, which provides automatic HTTPS for your domain.

Reports are computed from the same local event log as Usage Insights, so turning that extension off also stops statistics.

The app sends to the URL baked in at build time (`TELEMETRY_URL` in `scripts/build-app.sh`). Builds without it, including every local development build, never send anything.

## Self-hosting

[server/README.md](../server/README.md) has the full setup, including AWS. In short:

```bash
cd server
cp .env.example .env        # set DOMAIN and SECRET
docker compose up -d
```

Point the domain's DNS at the server. The dashboard is then live at `https://<domain>/` and the collector at `https://<domain>/v1/report`. Build the app with:

```bash
TELEMETRY_URL=https://<domain>/v1/report scripts/build-app.sh
```

For releases, set `TELEMETRY_URL` as a repository variable; `release.yml` passes it to the build.
