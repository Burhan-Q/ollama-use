# OllamaUsage - A macOS menu bar widget

A simple widget to display your [Ollama Cloud](https://ollama.com) subscription usage in the macOS menu bar.

## Menubar Widget

| Credit Subscription | Legacy Subscription |
| :-----------------: | :-----------------: |
| <img height="30" alt="image" src="https://github.com/user-attachments/assets/6be18957-a3b5-469d-8e1f-53e9524de3b9" /> | <img height="30" alt="image" src="https://github.com/user-attachments/assets/9c5d41a1-eaa5-4661-a20d-9672c158646b" /> |

## Installation

### Prerequisites

Requires Xcode Command Line Tools (`xcode-select --install`) and macOS 13+. Set environment variable `OLLAMA_API_KEY`.

### Direct from GitHub (recommended)

Downloads the source tarball, builds, installs to `/Applications`, and launches.

```sh
curl -fsSL https://github.com/Burhan-Q/ollama-use/raw/HEAD/menubar-widget/install.sh \
    | bash
```

## Clone Repo & Build

The source lives in `menubar-widget/`:

```sh
cd menubar-widget && ./build.sh
```

### Run

From the repo root:

```sh
# OLLAMA_API_KEY already set in environment

# Run in foreground
menubar-widget/OllamaUsage.app/Contents/MacOS/OllamaUsage

# Run in background
menubar-widget/OllamaUsage.app/Contents/MacOS/OllamaUsage &
```

```sh
# Fetch API Key using Apple Keychain
OLLAMA_API_KEY=$(security find-generic-password -s ollama-api-key -w 2>/dev/null) \
    menubar-widget/OllamaUsage.app/Contents/MacOS/OllamaUsage
```

**NOTE**: If launched from Finder, `LSUIElement` keeps it off the Dock; use `launchctl setenv OLLAMA_API_KEY <key>` 
so the environment is visible to GUI apps.

If needed, kill process using:

```sh
pkill -f OllamaUsage
```

### CLI check

Prints the values the widget would show, no menubar widget launched.

```sh
menubar-widget/OllamaUsage.app/Contents/MacOS/OllamaUsage --once
```

## Configuration Options

<img width="400" alt="image" src="https://github.com/user-attachments/assets/00ed2b0d-a636-4093-b831-a18708d86ef1" />

Defaults persist in `~/Library/Preferences/menubar.ollama-usage.plist` (your domain defaults:
`defaults read menubar.ollama-usage`).

| Setting | Options | Default | Description |
| ------- | ------- | ------- | ----------- |
| **Show Colors** | ON/OFF | ON | Color usage by %-remaining<br>  ≥50 GREEN<br>  20–50% ORANGE<br>  10–20% PINK<br>  <10% RED; when `OFF` uses system font color. |
| **Display items** | Session Usage<br>Session Reset Time<br>Weekly Usage<br>Weekly Reset Time | Session Usage \| Session Reset Time | Select up to any two. |
| **Update Interval** | 30s<br>1m<br>5m<br>15m<br>30m<br>60m | 5m | Note: API allows 10 req/min, override with `OLLAMA_USAGE_INTERVAL=<seconds>` | 
| **Launch at Login** | ON/OFF | OFF | registers the app with the macOS login items (app must be in `/Applications`). |

## Troubleshooting

- `⚠︎ no API key` — `OLLAMA_API_KEY` missing.
- `⚠︎ auth` — API key invalid (401/403).
- `⚠︎ rate-limited` — hit the 10 req/min limit; the app auto-retries after the `Retry-After` delay.
- `⚠︎ network …` — connectivity issue; last data is kept, title clears once a poll succeeds.
- `--self-test` flag runs the formatter assertions and exits.

## Docs

API: https://docs.ollama.com/api/balance.md (legacy plans return `included.session` / `included.weekly` with
`remaining_percent` and `resets_at`).
