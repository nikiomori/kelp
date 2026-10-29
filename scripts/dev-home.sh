#!/bin/zsh
# Kelp Dev's home (~/.kelp-dev, `make dev`) as a copy of the installed Kelp's ~/.kelp: its projects, workspaces, layouts,
# sidebar, settings, extensions, agents, remote projects, and sessions with what they printed. A Claude Code session
# that's live there comes back paused, and waking it (showing its tab does) continues a fork of its conversation
# (--fork-session): never the one the installed Kelp's agent writes. Any other session that could come back is ended
# (a second agent in the same conversation, or the same tmux); routines are copied switched off (they'd run twice).
# `make dev` runs it once, while there's no ~/.kelp-dev/kelp.sqlite; `make dev-home` copies again over Kelp Dev's own.
# The workspaces are the same folders: what Kelp Dev changes in them (or a git worktree it removes) the installed one sees.
set -euo pipefail
SRC=$HOME/.kelp; DST=$HOME/.kelp-dev
[ -f "$SRC/kelp.sqlite" ] || { echo "no $SRC/kelp.sqlite: nothing to copy"; exit 0; }
if pgrep -qf "/Kelp Dev.app/Contents/MacOS/KelpApp"; then echo "Quit Kelp Dev first: ⌘Q"; exit 1; fi
# Its kelpd outlives the app (Login Items): asked to stop through its own socket, then waited for until it lets go of its
# home (it holds kelpd.lock until its agents are gone).
if [ -S "$DST/kelp.sock" ]; then
  print '{"jsonrpc":"2.0","id":1,"method":"daemon.shutdown"}' | nc -U -w 5 "$DST/kelp.sock" >/dev/null 2>&1 || true
  for _ in {1..50}; do lsof -t "$DST/kelpd.lock" >/dev/null 2>&1 || break; sleep 0.2; done
  if lsof -t "$DST/kelpd.lock" >/dev/null 2>&1; then echo "Kelp Dev's background service is still running"; exit 1; fi
fi
mkdir -p "$DST"; rm -rf "$DST"/kelp.sqlite(|-wal|-shm)(N) "$DST/history"
sqlite3 -readonly "$SRC/kelp.sqlite" ".backup '$DST/kelp.sqlite'"   # consistent while the installed kelpd writes it
# Folders inside the installed Kelp's home (remote projects' stand-ins) are Kelp Dev's own copies.
IN="substr(path, 1, length('$SRC/')) = '$SRC/'"; TO="'$DST/' || substr(path, length('$SRC/') + 1)"
sqlite3 "$DST/kelp.sqlite" "
  UPDATE session SET argv = json_insert(replace(argv, '\"--session-id\"', '\"--resume\"'), '\$[#]', '--fork-session')
    WHERE agent = 'claude' AND tmux IS NULL AND substr(cwd, 1, length('$SRC/')) != '$SRC/';
  UPDATE session SET status = 'exited' WHERE status != 'exited' AND argv NOT LIKE '%\"--fork-session\"%';
  UPDATE routine SET enabled = 0;
  UPDATE repo SET path = $TO WHERE $IN; UPDATE worktree SET path = $TO WHERE $IN;
  UPDATE session SET cwd = ${TO//path/cwd} WHERE ${IN//path/cwd};"
# Clones (-c, APFS): the sessions' history takes no room until one of the two writes.
for f in settings.json extensions agents remote templates history; do [ ! -e "$SRC/$f" ] || cp -cR "$SRC/$f" "$DST/"; done
echo "copied $SRC's projects, workspaces and sessions to $DST"
