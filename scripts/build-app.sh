#!/bin/zsh
# Builds Elio.app (menu bar app: voice + HUD) and installs it in ~/Applications.
# Signed with the Apple Development identity so macOS keeps mic permission across rebuilds.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$HOME/Applications/Elio.app"
IDENTITY="${ELIO_SIGN_IDENTITY:-Apple Development}"

"$ROOT/scripts/fetch-onnxruntime.sh"
swift build -c release --package-path "$ROOT" --product ElioApp

pkill -x ElioApp 2>/dev/null || true
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$ROOT/.build/release/ElioApp" "$APP/Contents/MacOS/ElioApp"
swift "$ROOT/scripts/make-app-icon.swift" "$APP/Contents/Resources/AppIcon.icns"

# Speaker verification: ship the official, self-contained ONNX Runtime inside the app
# (Homebrew's build depends on other Homebrew libraries macOS refuses to load in a signed app).
ORT="$ROOT/vendor/onnxruntime/lib/libonnxruntime.1.dylib"
if [ -f "$ORT" ]; then
    mkdir -p "$APP/Contents/Frameworks"
    cp -L "$ORT" "$APP/Contents/Frameworks/libonnxruntime.1.dylib"
    install_name_tool -id @rpath/libonnxruntime.1.dylib "$APP/Contents/Frameworks/libonnxruntime.1.dylib"
    OLD=$(otool -L "$APP/Contents/MacOS/ElioApp" | awk '/libonnxruntime/ {print $1; exit}')
    [ -n "$OLD" ] && install_name_tool -change "$OLD" @rpath/libonnxruntime.1.dylib "$APP/Contents/MacOS/ElioApp"
    codesign --force --sign "$IDENTITY" "$APP/Contents/Frameworks/libonnxruntime.1.dylib"
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>it.dnafactory.elio.app</string>
    <key>CFBundleName</key><string>Elio</string>
    <key>CFBundleDisplayName</key><string>Elio</string>
    <key>CFBundleExecutable</key><string>ElioApp</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.2.0</string>
    <key>CFBundleVersion</key><string>$(date +%Y%m%d%H%M)</string>
    <key>LSMinimumSystemVersion</key><string>26.0</string>
    <key>LSUIElement</key><true/>
    <key>NSMicrophoneUsageDescription</key><string>Elio ascolta la tua voce per rispondere ai comandi. L'audio è trascritto sul Mac e non viene inviato.</string>
    <key>NSSpeechRecognitionUsageDescription</key><string>Elio trascrive la tua voce sul dispositivo.</string>
</dict>
</plist>
PLIST

codesign --force --sign "$IDENTITY" --options runtime \
    --entitlements "$ROOT/scripts/Elio.entitlements" "$APP"
echo "Installato: $APP"
