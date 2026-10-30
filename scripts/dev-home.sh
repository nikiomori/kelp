#!/bin/zsh
# Kelp Dev's home (~/.kelp-dev) copied from the installed Kelp's ~/.kelp again, over Kelp Dev's own: it's emptied of what
# the copy brings, and the next start's kelpd fills it (HomeSeed, which a build with its own home does by itself the
# first time; it says what's copied). `scripts/dev-home.sh beta` does the same for Kelp Beta (~/.kelp-beta).
set -euo pipefail
CH=${1:-dev}; NAME="Kelp ${(C)CH}"; DST=$HOME/.kelp-$CH
if pgrep -qf "/$NAME.app/Contents/MacOS/KelpApp"; then echo "Quit $NAME first: ⌘Q"; exit 1; fi
# Its kelpd outlives the app (Login Items): asked to stop through its own socket, then waited for until it lets go of its
# home (it holds kelpd.lock until its agents are gone).
if [ -S "$DST/kelp.sock" ]; then
  print '{"jsonrpc":"2.0","id":1,"method":"daemon.shutdown"}' | nc -U -w 5 "$DST/kelp.sock" >/dev/null 2>&1 || true
  for _ in {1..50}; do lsof -t "$DST/kelpd.lock" >/dev/null 2>&1 || break; sleep 0.2; done
  if lsof -t "$DST/kelpd.lock" >/dev/null 2>&1; then echo "$NAME's background service is still running"; exit 1; fi
fi
rm -rf "$DST"/(kelp.sqlite(|-wal|-shm)|settings.json|hooks-claude.json|extensions|agents|remote|templates|history)(N)
echo "$NAME copies $HOME/.kelp the next time it starts"
