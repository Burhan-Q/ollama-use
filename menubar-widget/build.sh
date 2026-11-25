#!/usr/bin/env bash
# Builds OllamaUsage.app into the menubar-widget directory.
set -euo pipefail
cd "$(dirname "$0")"

APP=OllamaUsage.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"

swiftc -O Core.swift main.swift -o "$APP/Contents/MacOS/OllamaUsage"

cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>menubar.ollama-usage</string>
  <key>CFBundleExecutable</key><string>OllamaUsage</string>
  <key>CFBundleName</key><string>OllamaUsage</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSUIElement</key><true/>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
</dict>
</plist>
EOF

codesign --force --sign - "$APP" 2>/dev/null || true
echo "Built $APP"
