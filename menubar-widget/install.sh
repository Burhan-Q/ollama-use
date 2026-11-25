#!/usr/bin/env bash
# Installs the OllamaUsage menu bar widget without cloning the repo:
#   curl -fsSL https://raw.githubusercontent.com/burhan/ollama-use/HEAD/menubar-widget/install.sh | bash
# (Update REPO if the repo moves.)
set -euo pipefail

REPO="Burhan-Q/ollama-use"
TARBALL="https://codeload.github.com/${REPO}/tar.gz/HEAD"
APP_DEST="/Applications/OllamaUsage.app"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

if ! command -v swiftc >/dev/null 2>&1; then
  echo "error: swiftc not found — install Xcode Command Line Tools first:" >&2
  echo "  xcode-select --install" >&2
  exit 1
fi

if [[ "$(sw_vers -productVersion | cut -d. -f1)" -lt 13 ]]; then
  echo "error: macOS 13 or newer required" >&2
  exit 1
fi

# Local rebuild: works when run next to the sources (menubar-widget/).
if [[ -f "OllamaUsage.swift" && -f "build.sh" ]]; then
  DIR="$(pwd)"
else
  # Remote install: fetch the parent-repo tarball and locate menubar-widget/.
  echo "Downloading ${REPO} (menubar-widget/) …"
  curl -fsSL "$TARBALL" -o "$TMP/repo.tar.gz"
  tar -xzf "$TMP/repo.tar.gz" -C "$TMP"
  DIR="$(find "$TMP" -maxdepth 1 -type d -name '*ollama-use*' | head -1)/menubar-widget"
fi

echo "Building …"
bash "$DIR/build.sh"

echo "Installing to $APP_DEST …"
rm -rf "$APP_DEST"
cp -R "$DIR/OllamaUsage.app" "$APP_DEST"

echo "Launching …"
open "$APP_DEST"

cat <<'NOTE'
Done. The app needs OLLAMA_API_KEY in its environment, e.g.:
  launchctl setenv OLLAMA_API_KEY <your-key>
Then quit & relaunch the app. Use its menu to set "Launch at Login".
NOTE
