#!/bin/zsh
# Fetches the IDE's editor and terminal (Monaco, xterm.js) into ide/vendor (not committed).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$ROOT/ide/vendor"
MONACO=0.52.2
XTERM=5.5.0
FIT=0.10.0
SEARCH=0.15.0
WEBLINKS=0.11.0
[ -f "$DEST/.versions" ] && [ "$(cat "$DEST/.versions")" = "$MONACO $XTERM $FIT $SEARCH $WEBLINKS" ] && exit 0
rm -rf "$DEST"; mkdir -p "$DEST"
TMP=$(mktemp -d)
fetch() { curl -fsSL "https://registry.npmjs.org/$1/-/$2-$3.tgz" | tar -xz -C "$TMP" && mv "$TMP/package" "$TMP/$2"; }
fetch monaco-editor monaco-editor $MONACO
fetch @xterm/xterm xterm $XTERM
fetch @xterm/addon-fit addon-fit $FIT
fetch @xterm/addon-search addon-search $SEARCH
fetch @xterm/addon-web-links addon-web-links $WEBLINKS
mkdir -p "$DEST/monaco" "$DEST/xterm"
cp -R "$TMP/monaco-editor/min/vs" "$DEST/monaco/vs"
cp "$TMP/xterm/lib/xterm.js" "$TMP/xterm/css/xterm.css" "$DEST/xterm/"
cp "$TMP/addon-fit/lib/addon-fit.js" "$TMP/addon-search/lib/addon-search.js" "$TMP/addon-web-links/lib/addon-web-links.js" "$DEST/xterm/"
rm -rf "$TMP"
echo "$MONACO $XTERM $FIT $SEARCH $WEBLINKS" > "$DEST/.versions"
echo "IDE libraries in $DEST ($(du -sh "$DEST" | cut -f1))"
