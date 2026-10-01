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
# Remove before copying: overwriting a binary in place invalidates its cached signature (SIGKILL).
rm -f "$BIN/jarvis"
cp "$ROOT/.build/release/jarvis" "$BIN/"
ln -sf "$BIN/jarvis" "$HOME/.local/bin/jarvis"

# The daemon is a signed background app bundle so macOS can grant it Calendar access
# (TCC needs a bundle with usage descriptions; Claude and the MCP bridge inherit it).
DAEMON_APP="$SUPPORT/JarvisDaemon.app"
rm -rf "$DAEMON_APP" "$BIN/jarvisd"
mkdir -p "$DAEMON_APP/Contents/MacOS"
cp "$ROOT/.build/release/jarvisd" "$DAEMON_APP/Contents/MacOS/jarvisd"
cat > "$DAEMON_APP/Contents/Info.plist" <<INFO
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>it.dnafactory.jarvis.daemon</string>
    <key>CFBundleName</key><string>Jarvis Daemon</string>
    <key>CFBundleDisplayName</key><string>Elio</string>
    <key>CFBundleExecutable</key><string>jarvisd</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.3.0</string>
    <key>CFBundleVersion</key><string>$(date +%Y%m%d%H%M)</string>
    <key>LSUIElement</key><true/>
    <key>NSCalendarsFullAccessUsageDescription</key><string>Jarvis legge la tua agenda per dirti gli impegni e prepararti i meeting.</string>
    <key>NSRemindersFullAccessUsageDescription</key><string>Jarvis gestisce i tuoi promemoria.</string>
    <key>NSAppleEventsUsageDescription</key><string>Jarvis controlla le app del Mac quando glielo chiedi.</string>
</dict>
</plist>
INFO
codesign --force --sign "${JARVIS_SIGN_IDENTITY:-Apple Development}" "$DAEMON_APP"

cat > "$PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>$LABEL</string>
    <key>ProgramArguments</key><array><string>$DAEMON_APP/Contents/MacOS/jarvisd</string></array>
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

# Phone PWA files, served by the daemon on 127.0.0.1:8766.
rm -rf "$SUPPORT/web"
cp -R "$ROOT/web" "$SUPPORT/web"

launchctl bootstrap "gui/$UID" "$PLIST"
echo "Jarvis installato. Log: $LOGS/jarvisd.log — prova: jarvis \"ciao\""
