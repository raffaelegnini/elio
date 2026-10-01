#!/bin/zsh
# Stops and removes the LaunchAgent. Keeps config, memory and logs.
set -euo pipefail
LABEL="it.dnafactory.elio"
launchctl bootout "gui/$UID/$LABEL" 2>/dev/null || true
rm -f "$HOME/Library/LaunchAgents/$LABEL.plist" "$HOME/.local/bin/elio"
rm -rf "$HOME/Library/Application Support/Elio/bin"
echo "Elio disinstallato (config e memoria in ~/Library/Application Support/Elio restano)."
