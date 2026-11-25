# OllamaUsage — macOS menu bar widget

Shows your Ollama Cloud legacy-plan usage in the macOS menu bar: session % remaining, weekly % remaining, and reset
countdowns.

Menu bar text (default): `S 89% | S 1h 54m` — session % remaining + session reset countdown, `|`-separated.
Usage values are colored (green ≥50, orange 20–50, pink 10–20, red <10 remaining) with "Show Colors" toggled on; off =
plain system font. Tooltip shows "ollama-use" on hover.

## Install (no clone)

```sh
curl -fsSL https://raw.githubusercontent.com/Burhan-Q/ollama-use/HEAD/menubar-widget/install.sh \
    | bash
```

Downloads the source tarball, builds, installs to `/Applications`, and launches.
Requires Xcode Command Line Tools (`xcode-select --install`) and macOS 13+.

## Build from clone

The source lives in `menubar-widget/`:

```sh
cd menubar-widget && ./build.sh
```

## Run

The app reads `OLLAMA_API_KEY` from its environment (from the repo root):

```sh
OLLAMA_API_KEY=$(security find-generic-password -s ollama-api-key -w 2>/dev/null) \
    menubar-widget/OllamaUsage.app/Contents/MacOS/OllamaUsage
```

If launched from Finder, `LSUIElement` keeps it off the Dock; use `launchctl setenv OLLAMA_API_KEY <key>` so the
environment is visible to GUI apps.

CLI check (prints the values the widget would show, no GUI):

```sh
menubar-widget/OllamaUsage.app/Contents/MacOS/OllamaUsage --once
```

## Configuration (settings menu)

Defaults persist in `~/Library/Preferences/menubar.ollama-usage.plist` (your domain defaults:
`defaults read menubar.ollama-usage`).

- **Show Colors** — color usage % by remaining (≥50 green, 20–50 orange, 10–20 pink, <10 red).
  Off = system font color.
- **Display items** — toggle up to any two of: Session Usage, Session Reset Time, Weekly Usage, Weekly Reset Time (at
  least one). Default: Session Usage | Session Reset Time.
- **Update Interval** — 30s / 1m / 5m / 15m / 30m / 60m min (default 5m; API allows 10 req/min).
  Changes apply immediately.
  Also settable via `defaults write menubar.ollama-usage intervalSeconds <n>` (clamped 30–3600s), or
  `OLLAMA_USAGE_INTERVAL=<seconds>` env var (takes precedence).
- **Launch at Login** — registers the app with the macOS login items (app must be in `/Applications`).

## Troubleshooting

- `⚠︎ no API key` — `OLLAMA_API_KEY` missing.
- `⚠︎ auth` — API key invalid (401/403).
- `⚠︎ rate-limited` — hit the 10 req/min limit; the app auto-retries after the `Retry-After` delay.
- `⚠︎ network …` — connectivity issue; last data is kept, title clears once a poll succeeds.
- `--self-test` flag runs the formatter assertions and exits.

## Docs

API: https://docs.ollama.com/api/balance.md (legacy plans return `included.session` / `included.weekly` with
`remaining_percent` and `resets_at`).
