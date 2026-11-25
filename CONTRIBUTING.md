# Contributing

Single Swift project lives in `menubar-widget/` (`Core.swift`: model,
normalization, settings, self-tests; `main.swift`: menubar UI + entry).
Build, verification, and lint/format tooling below.

## Testing with mock data

The endpoint serves two response shapes; both are supported — legacy plans
(`included.session` / `included.weekly` percent limits) and current plans
(`included.balance_usd` / `allowance_usd` + `period.until`, shown as one "S"
limit — purchased credits are not counted).

Point `OLLAMA_BALANCE_MOCK` at a JSON payload matching either shape to run the
widget or `--once` against canned data (bypasses the network and the
API-key requirement). An unreadable path fails loudly (`mock file unreadable`)
rather than falling back to the network:

```sh
OLLAMA_BALANCE_MOCK=<path-to-mock.json> \
    menubar-widget/OllamaUsage.app/Contents/MacOS/OllamaUsage --once
# or launch the GUI with the same env var
```

## Build & verify

```sh
cd menubar-widget
./build.sh                                          # -> OllamaUsage.app
OllamaUsage.app/Contents/MacOS/OllamaUsage --self-test   # logic assertions
OLLAMA_API_KEY='<key>' OllamaUsage.app/Contents/MacOS/OllamaUsage --once  # live API check
```

## Tooling (check on every commit)

- **SwiftFormat** — auto-fixes style.
  Runs in the pre-commit hook.
- **SwiftLint** — rule gate.
  Runs in the pre-commit hook in `--strict` (warnings fail the commit).
  Tune `.swiftlint.yml` instead of committing warnings.

Configs are at the repo root: `.swiftformat`, `.swiftlint.yml`.

### Install tools

```sh
brew install swiftformat
# swiftlint: brew formula requires full Xcode.app. On a Command-Line-Tools-only
# machine use the release binary:
curl -fsSL -o /tmp/swiftlint.zip \
  https://github.com/realm/SwiftLint/releases/download/0.65.1/portable_swiftlint.zip
ditto -x -k /tmp/swiftlint.zip /tmp/swiftlint
mkdir -p ~/.local/bin && cp /tmp/swiftlint/SwiftLint/swiftlint ~/.local/bin/
xattr -dr com.apple.quarantine ~/.local/bin/swiftlint 2>/dev/null || true
# The portable binary needs the CLT sourcekit framework on dyld's search path:
export DYLD_FRAMEWORK_PATH=/Library/Developer/CommandLineTools/usr/lib
```

If you have full Xcode installed, plain `brew install swiftlint` instead — then the `DYLD_FRAMEWORK_PATH` export is
unnecessary.

### Install the hook

The canonical hook is tracked at `.githooks/pre-commit`; install it into your own `.git/hooks/` (re-run after a fresh
clone or on another machine):

```sh
cp .githooks/pre-commit .git/hooks/pre-commit
chmod +x .git/hooks/pre-commit
```

Why not `git config core.hooksPath .githooks` globally?
Both work; the copy keeps this repo's hook project-local so it doesn't affect other repos on the same clone worktree.
Use `core.hooksPath` if you prefer.

Committing: hook runs SwiftFormat (restages files it rewrites) and SwiftLint `--strict` on **staged `.swift` files
only**. Anything failing blocks the commit — fix or tune config.
Non-Swift commits are untouched.

### Hook script

```bash
#!/usr/bin/env bash
# Pre-commit: SwiftFormat (auto-fix) + SwiftLint (gate) on staged Swift files.
set -uo pipefail
cd "$(git rev-parse --show-toplevel)"

export DYLD_FRAMEWORK_PATH=/Library/Developer/CommandLineTools/usr/lib
export PATH="$HOME/.local/bin:$PATH"

files=$(git diff --cached --name-only --diff-filter=ACM -- '*.swift')
[ -z "$files" ] && exit 0

# Format in place; restage files that SwiftFormat rewrote.
swiftformat --quiet --swiftversion 6 $files || exit 1
git add -- $files

# Lint; fail on anything (warnings included so they don't accumulate).
swiftlint lint --strict --quiet -- $files
```

Put the above at `.git/hooks/pre-commit` and `chmod +x` it.

## Manual check (same as the hook)

```sh
export DYLD_FRAMEWORK_PATH=/Library/Developer/CommandLineTools/usr/lib
swiftformat --lint .
swiftlint lint --strict menubar-widget
```

### Publish plan (future)

- GitHub repo `ollama-use` (public) → `install.sh` one-liner becomes live (path placeholder in
  `menubar-widget/install.sh`).
- GitHub Actions PR check: lint + format gate on PRs touching `menubar-widget/**` — macOS runner,
  `brew install swiftformat`, SwiftLint from release zip (or plain brew if full Xcode image), run both tools in
  `--strict`/`--lint` mode.
