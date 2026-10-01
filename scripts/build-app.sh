#!/bin/zsh
# Builds Jarvis.app (menu bar app: voice + HUD) and installs it in ~/Applications.
# Signed with the Apple Development identity so macOS keeps mic permission across rebuilds.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$HOME/Applications/Jarvis.app"
IDENTITY="${JARVIS_SIGN_IDENTITY:-Apple Development}"

swift build -c release --package-path "$ROOT" --product JarvisApp

pkill -x JarvisApp 2>/dev/null || true
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$ROOT/.build/release/JarvisApp" "$APP/Contents/MacOS/JarvisApp"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>it.dnafactory.jarvis.app</string>
    <key>CFBundleName</key><string>Elio</string>
    <key>CFBundleDisplayName</key><string>Elio</string>
    <key>CFBundleExecutable</key><string>JarvisApp</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.2.0</string>
    <key>CFBundleVersion</key><string>$(date +%Y%m%d%H%M)</string>
    <key>LSMinimumSystemVersion</key><string>26.0</string>
    <key>LSUIElement</key><true/>
    <key>NSMicrophoneUsageDescription</key><string>Jarvis ascolta la tua voce per rispondere ai comandi. L'audio è trascritto sul Mac e non viene inviato.</string>
    <key>NSSpeechRecognitionUsageDescription</key><string>Jarvis trascrive la tua voce sul dispositivo.</string>
</dict>
</plist>
PLIST

codesign --force --sign "$IDENTITY" --options runtime \
    --entitlements "$ROOT/scripts/Jarvis.entitlements" "$APP"
echo "Installato: $APP"
