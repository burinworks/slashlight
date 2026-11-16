# Privacy

Slashlight has no account, no analytics and no telemetry, and there is no Slashlight server. This page lists every time the app goes on the network, so you can check that claim.

## When Slashlight uses the network

| When | Where to | What it sends |
|---|---|---|
| Checking for updates, at most once a day (and when you choose **Check for Updates…**) | The appcast on GitHub Pages: `burinworks.github.io/slashlight/appcast.xml`. Updates download from GitHub Releases. | Your IP address, the app version and the macOS version, as part of the request. Sparkle's system profiling is off. Turn automatic checks off in Settings → General. |
| Converting currencies in the calculator (`100 usd`) | ExchangeRate-API: `open.er-api.com`. Rates are cached on your Mac. | Your IP address only. |
| Running a web search, a quicklink or a URL command | The site you chose (Google, DuckDuckGo, GitHub…) opens in your browser. | Whatever that link contains, from your browser. |
| Running a command that uses the network, such as the example `/my-ip` (`api.ipify.org`) or an HTTP command | The address in that command. | What the command sends. |
| Extensions and script commands you install | Only hosts their permissions allow (see [extension permissions](docs/extension-permissions.md)). | Up to the extension. |

## What stays on your Mac

Settings, commands, snippets, clipboard history, Usage Insights and the search memory never leave your Mac. They live in `~/Library/Application Support/Slashlight/`.

- **Clipboard history** is encrypted with a key kept in your Keychain. Copies that password managers mark as concealed or transient are never saved. You can clear it, or turn off keeping it, in Settings → General.
- **Usage Insights** (`/insights`) and the **search memory** (`search-memory.json`) record which results you open, so the dashboard and ranking can use them. **Clear** in Insights deletes the usage data.

Uninstall (Settings → About) can delete all of it.

## Contact

Questions about privacy: [alex@burinworks.com](mailto:alex@burinworks.com). Security issues: please use a [private security advisory](https://github.com/burinworks/slashlight/security/advisories/new).
