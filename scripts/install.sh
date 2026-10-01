#!/bin/zsh
# Builds release binaries, installs them under Application Support and
# registers eliod as a LaunchAgent (starts at login, restarted if it dies).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SUPPORT="$HOME/Library/Application Support/Elio"
BIN="$SUPPORT/bin"
LOGS="$HOME/Library/Logs/Elio"
LABEL="it.dnafactory.elio"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

swift build -c release --package-path "$ROOT"
mkdir -p "$BIN" "$LOGS" "$HOME/.local/bin"

launchctl bootout "gui/$UID/$LABEL" 2>/dev/null || true
# Remove before copying: overwriting a binary in place invalidates its cached signature (SIGKILL).
rm -f "$BIN/elio"
cp "$ROOT/.build/release/elio" "$BIN/"
ln -sf "$BIN/elio" "$HOME/.local/bin/elio"

# The daemon is a signed background app bundle so macOS can grant it Calendar access
# (TCC needs a bundle with usage descriptions; Claude and the MCP bridge inherit it).
DAEMON_APP="$SUPPORT/ElioDaemon.app"
rm -rf "$DAEMON_APP" "$BIN/eliod"
mkdir -p "$DAEMON_APP/Contents/MacOS"
cp "$ROOT/.build/release/eliod" "$DAEMON_APP/Contents/MacOS/eliod"
cat > "$DAEMON_APP/Contents/Info.plist" <<INFO
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>it.dnafactory.elio.daemon</string>
    <key>CFBundleName</key><string>Elio Daemon</string>
    <key>CFBundleDisplayName</key><string>Elio</string>
    <key>CFBundleExecutable</key><string>eliod</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.3.0</string>
    <key>CFBundleVersion</key><string>$(date +%Y%m%d%H%M)</string>
    <key>LSUIElement</key><true/>
    <key>NSCalendarsFullAccessUsageDescription</key><string>Elio legge la tua agenda per dirti gli impegni e prepararti i meeting.</string>
    <key>NSRemindersFullAccessUsageDescription</key><string>Elio gestisce i tuoi promemoria.</string>
    <key>NSAppleEventsUsageDescription</key><string>Elio controlla le app del Mac quando glielo chiedi.</string>
</dict>
</plist>
INFO
codesign --force --sign "${ELIO_SIGN_IDENTITY:-Apple Development}" "$DAEMON_APP"

cat > "$PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>$LABEL</string>
    <key>ProgramArguments</key><array><string>$DAEMON_APP/Contents/MacOS/eliod</string></array>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><true/>
    <key>ThrottleInterval</key><integer>10</integer>
    <key>ProcessType</key><string>Interactive</string>
    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key><string>$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin</string>
    </dict>
    <key>StandardOutPath</key><string>$LOGS/eliod.log</string>
    <key>StandardErrorPath</key><string>$LOGS/eliod.log</string>
</dict>
</plist>
PLIST

# Speaker verification model (WeSpeaker ResNet34, VoxCeleb, Apache-2.0), downloaded once.
MODEL="$SUPPORT/models/speaker.onnx"
if [ ! -f "$MODEL" ]; then
    mkdir -p "$SUPPORT/models"
    curl -sL -o "$MODEL" "https://github.com/k2-fsa/sherpa-onnx/releases/download/speaker-recongition-models/wespeaker_en_voxceleb_resnet34.onnx" \
        || echo "Attenzione: modello vocale non scaricato (riconoscimento della voce disattivato)"
fi

# Phone PWA files, served by the daemon on 127.0.0.1:8766.
rm -rf "$SUPPORT/web"
cp -R "$ROOT/web" "$SUPPORT/web"

launchctl bootstrap "gui/$UID" "$PLIST"
echo "Elio installato. Log: $LOGS/eliod.log — prova: elio \"ciao\""
