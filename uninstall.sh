#!/bin/bash
# Remove Spoolup's LaunchAgents and app. Claude Code / Codex config is never touched.
if [ "$(id -u)" -eq 0 ]; then
  echo "✗ 不要用 sudo 运行：直接运行 $0 即可。" >&2
  exit 1
fi
for l in com.spoolup.app com.spoolup.server; do
  launchctl bootout "gui/$(id -u)/$l" 2>/dev/null || true
  rm -f "$HOME/Library/LaunchAgents/$l.plist"
done
rm -rf "$HOME/Applications/Spoolup.app"
echo "✓ Spoolup removed"
