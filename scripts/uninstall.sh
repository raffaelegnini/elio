#!/bin/zsh
# Stops and removes the LaunchAgent. Keeps config, memory and logs.
set -euo pipefail
LABEL="it.dnafactory.jarvis"
launchctl bootout "gui/$UID/$LABEL" 2>/dev/null || true
rm -f "$HOME/Library/LaunchAgents/$LABEL.plist" "$HOME/.local/bin/jarvis"
rm -rf "$HOME/Library/Application Support/Jarvis/bin"
echo "Jarvis disinstallato (config e memoria in ~/Library/Application Support/Jarvis restano)."
