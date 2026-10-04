#!/bin/zsh
# Elio updates itself: tests, then build + reinstall (app and daemon), with the previous app kept as a backup
# and put back if anything fails. Runs as its own launchd job (the daemon it replaces is restarted midway).
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LOG="$HOME/Library/Logs/Elio/self-update.log"
APP="$HOME/Applications/Elio.app"
BACKUP="$HOME/Applications/.Elio-previous.app"
notify() { /usr/bin/osascript -e "display notification \"$2\" with title \"$1\"" >/dev/null 2>&1 || true; }
finish() { /bin/launchctl remove it.dnafactory.elio.selfupdate >/dev/null 2>&1; exit "$1"; }
exec >>"$LOG" 2>&1
echo "=== $(date) self-update in $ROOT ==="
cd "$ROOT" || finish 1
notify "Elio" "Mi aggiorno: test in corso…"
if ! swift test; then
    notify "Elio" "Aggiornamento annullato: i test non passano. Dettagli in self-update.log"
    finish 1
fi
rm -rf "$BACKUP"; [ -d "$APP" ] && cp -R "$APP" "$BACKUP"
if ./scripts/build-app.sh && ./scripts/install.sh; then
    /usr/bin/open "$APP"
    notify "Elio" "Aggiornato e ripartito."
    echo "ok"
    finish 0
fi
echo "build/install failed: restoring the previous app"
if [ -d "$BACKUP" ]; then rm -rf "$APP"; cp -R "$BACKUP" "$APP"; /usr/bin/open "$APP"; fi
notify "Elio" "Aggiornamento non riuscito: ho rimesso la versione di prima."
finish 1
