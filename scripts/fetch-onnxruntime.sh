#!/bin/zsh
# Downloads the official, self-contained ONNX Runtime build (system frameworks only) into vendor/.
# Used for speaker verification; bundled inside Elio.app by build-app.sh.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="${ORT_VERSION:-1.30.0}"
DEST="$ROOT/vendor/onnxruntime"
[ -f "$DEST/lib/libonnxruntime.$VERSION.dylib" ] && exit 0
mkdir -p "$ROOT/vendor"
curl -sL "https://github.com/microsoft/onnxruntime/releases/download/v$VERSION/onnxruntime-osx-arm64-$VERSION.tgz" | tar xz -C "$ROOT/vendor"
rm -rf "$DEST"
mv "$ROOT/vendor/onnxruntime-osx-arm64-$VERSION" "$DEST"
echo "ONNX Runtime $VERSION in $DEST"
