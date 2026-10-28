#!/bin/zsh
# dist/Kelp.app replaces the installed Kelp (`make install`, the end of `make release`). A running one quits and opens
# again; it finds its kelpd older and has it run the new one in place (daemon.upgrade), so agents keep running.
set -euo pipefail
cd "$(dirname "$0")/.."
APP=dist/Kelp.app; INSTALL=${INSTALL:-/Applications/Kelp.app}
[ -d "$INSTALL" ] || { echo "no $INSTALL: install from dist/Kelp.dmg first"; exit 0; }
# Another signer's copy loses the Login Items switch and keychain items the installed one has.
team() { codesign -dv "$1" 2>&1 | sed -n 's/^TeamIdentifier=//p'; }
[ "$(team $APP)" = "$(team $INSTALL)" ] || { echo "$APP isn't signed as $INSTALL is: not installed"; exit 0; }
PID=$(pgrep -f "^$INSTALL/Contents/MacOS/KelpApp" | head -1 || true)
if [ -n "$PID" ]; then
  # A quit as from the Dock (the layout saved; unsaved files ask), to this process only, not another Kelp copy.
  osascript -l JavaScript -e "ObjC.import('AppKit'); \$.NSRunningApplication.runningApplicationWithProcessIdentifier($PID).terminate" >/dev/null
  echo "waiting for Kelp to quit…"
  for _ in {1..300}; do kill -0 "$PID" 2>/dev/null || break; sleep 0.2; done
  if kill -0 "$PID" 2>/dev/null; then echo "Kelp is still open: quit it, then make install"; exit 1; fi
fi
# Beside it, then renamed: files changed in place under a running kelpd break its code signature (killed on load).
rm -rf "$INSTALL.new" "$INSTALL.old"; cp -Rp "$APP" "$INSTALL.new"
mv "$INSTALL" "$INSTALL.old"
mv "$INSTALL.new" "$INSTALL" || { mv "$INSTALL.old" "$INSTALL"; exit 1; }
rm -rf "$INSTALL.old"
echo "installed $INSTALL"
[ -z "$PID" ] || open "$INSTALL"
