#!/bin/bash
# Build Spoolup.app and register two LaunchAgents:
#   com.spoolup.server  — log collector + web dashboard (http://127.0.0.1:8787), always on
#   com.spoolup.app     — menu bar app, started at login
# Claude Code / Codex configuration is never touched.
set -euo pipefail
# LaunchAgents live in the user's GUI session (gui/<uid>); under sudo that's gui/0,
# which doesn't exist, and every file would end up owned by root.
if [ "$(id -u)" -eq 0 ]; then
  echo "✗ 不要用 sudo 运行：Spoolup 装在当前用户下，直接运行 $0 即可。" >&2
  exit 1
fi
ROOT="$(cd "$(dirname "$0")" && pwd)"
PORT="${SPOOLUP_PORT:-8787}"
APP="$HOME/Applications/Spoolup.app"
AGENTS="$HOME/Library/LaunchAgents"
# fnm/nvm expose per-shell shims; launchd needs the real binary.
NODE="$(python3 -c 'import os,sys;print(os.path.realpath(sys.argv[1]))' "$(command -v node)")"
mkdir -p "$HOME/.spoolup" "$AGENTS" "$HOME/Applications"

if [ -e "$APP" ] && [ -n "$(find "$APP" ! -user "$(id -un)" -print -quit)" ]; then
  echo "✗ $APP 里有不属于你的文件（多半是之前用 sudo 装过）。先运行一次：" >&2
  echo "    sudo rm -rf \"$APP\"" >&2
  echo "  然后不带 sudo 重新运行 $0" >&2
  exit 1
fi

echo "→ building Spoolup.app"
rm -rf "$APP" && mkdir -p "$APP/Contents/MacOS"
swiftc -O -parse-as-library -target "$(uname -m)-apple-macos14" "$ROOT/menubar/Spoolup.swift" -o "$APP/Contents/MacOS/Spoolup"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>com.spoolup.app</string>
  <key>CFBundleName</key><string>Spoolup</string>
  <key>CFBundleExecutable</key><string>Spoolup</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>NSAppTransportSecurity</key><dict><key>NSAllowsLocalNetworking</key><true/></dict>
</dict></plist>
PLIST
if [ -f "$ROOT/assets/AppIcon.png" ]; then
  ICONSET="$(mktemp -d)/AppIcon.iconset"; mkdir -p "$ICONSET" "$APP/Contents/Resources"
  for s in 16 32 128 256 512; do
    sips -z $s $s "$ROOT/assets/AppIcon.png" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
    sips -z $((s * 2)) $((s * 2)) "$ROOT/assets/AppIcon.png" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
  done
  iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
fi
codesign --force --sign - "$APP" >/dev/null 2>&1 || true
# Same path + bundle id as a previous (icon-less) build: make LaunchServices re-read it.
touch "$APP"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP" >/dev/null 2>&1 || true

echo "→ registering LaunchAgents (node: $NODE)"
cat > "$AGENTS/com.spoolup.server.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>com.spoolup.server</string>
  <key>ProgramArguments</key><array><string>$NODE</string><string>$ROOT/server/spoolup.mjs</string></array>
  <key>EnvironmentVariables</key><dict><key>SPOOLUP_PORT</key><string>$PORT</string></dict>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ProcessType</key><string>Background</string>
  <key>StandardOutPath</key><string>$HOME/.spoolup/server.log</string>
  <key>StandardErrorPath</key><string>$HOME/.spoolup/server.log</string>
</dict></plist>
PLIST
cat > "$AGENTS/com.spoolup.app.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>com.spoolup.app</string>
  <key>ProgramArguments</key><array><string>$APP/Contents/MacOS/Spoolup</string></array>
  <key>EnvironmentVariables</key><dict><key>SPOOLUP_PORT</key><string>$PORT</string></dict>
  <key>RunAtLoad</key><true/>
  <key>ProcessType</key><string>Interactive</string>
</dict></plist>
PLIST

for l in com.spoolup.server com.spoolup.app; do
  launchctl bootout "gui/$(id -u)/$l" 2>/dev/null || true
  # bootout returns before the old job is gone; bootstrapping too early fails with "5: Input/output error".
  for _ in $(seq 1 50); do launchctl print "gui/$(id -u)/$l" >/dev/null 2>&1 || break; sleep 0.1; done
  launchctl bootstrap "gui/$(id -u)" "$AGENTS/$l.plist"
done
echo "✓ Spoolup installed — click the Spoolup icon in the menu bar; ⤢ opens the full dashboard"
