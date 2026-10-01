#!/bin/zsh
# Builds release binaries, installs them under Application Support and
# registers jarvisd as a LaunchAgent (starts at login, restarted if it dies).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SUPPORT="$HOME/Library/Application Support/Jarvis"
BIN="$SUPPORT/bin"
LOGS="$HOME/Library/Logs/Jarvis"
LABEL="it.dnafactory.jarvis"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

swift build -c release --package-path "$ROOT"
mkdir -p "$BIN" "$LOGS" "$HOME/.local/bin"

launchctl bootout "gui/$UID/$LABEL" 2>/dev/null || true
cp "$ROOT/.build/release/jarvisd" "$ROOT/.build/release/jarvis" "$BIN/"
ln -sf "$BIN/jarvis" "$HOME/.local/bin/jarvis"

cat > "$PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>$LABEL</string>
    <key>ProgramArguments</key><array><string>$BIN/jarvisd</string></array>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><true/>
    <key>ThrottleInterval</key><integer>10</integer>
    <key>ProcessType</key><string>Interactive</string>
    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key><string>$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin</string>
    </dict>
    <key>StandardOutPath</key><string>$LOGS/jarvisd.log</string>
    <key>StandardErrorPath</key><string>$LOGS/jarvisd.log</string>
</dict>
</plist>
PLIST

launchctl bootstrap "gui/$UID" "$PLIST"
echo "Jarvis installato. Log: $LOGS/jarvisd.log — prova: jarvis \"ciao\""
