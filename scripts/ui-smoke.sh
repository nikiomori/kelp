#!/bin/sh
# Opens the app on a few scenes and writes each window to a PNG (KELP_SNAPSHOT: no screen-recording permission needed):
# the start page, Settings, a file, a terminal that ran a command. Fails when the app doesn't come up, crashes or draws
# nothing. Run after `swift build`; the pictures and logs go to $1 (default /tmp/kelp-ui) for a look by eye.
set -eu
out=${1:-/tmp/kelp-ui}
mkdir -p "$out"
home=$(mktemp -d /tmp/kui.XXXX)   # short: the daemon's socket path must fit in 104 bytes
app=.build/debug/KelpApp
# A project to show: a repository with a commit and a README.
repo="$home/demo"
mkdir -p "$repo"
git -C "$repo" init -q -b main
printf '# Demo\n\nKelp smoke test.\n' > "$repo/README.md"
git -C "$repo" add README.md
git -C "$repo" -c user.name=kelp -c user.email=kelp@example.com commit -qm init
scene() {
    name=$1
    shift
    if ! env KELP_HOME="$home" KELP_SNAPSHOT="$out/$name.png" "$@" "$app" > "$out/$name.log" 2>&1; then
        cat "$out/$name.log"
        echo "$name: the app failed"
        exit 1
    fi
    size=$(stat -f%z "$out/$name.png" 2>/dev/null || echo 0)
    if [ "$size" -lt 20000 ]; then
        echo "$name: nothing drawn ($size bytes)"
        exit 1
    fi
    echo "$name: ok"
}
# Added by the app, as Add Project does: CI runs this as a launchd job, which the daemon holds to an agent's rules.
scene start KELP_SNAPSHOT_SHEET="project=$repo"
scene settings KELP_SNAPSHOT_WINDOW=settings
scene file KELP_SNAPSHOT_OPEN="file://$repo/README.md"
# A terminal running a command: its answer (42) isn't in the command's text, so finding it means the shell ran it.
scene terminal KELP_SNAPSHOT_OPEN='terminal:?cmd=expr%2040%20%2B%202' KELP_TYPE='{wait}{wait}'
if ! grep -rqs '42' "$home/history"; then
    echo "terminal: the command didn't run"
    exit 1
fi
# The daemon the app started goes with the scenes.
printf '{"jsonrpc":"2.0","id":1,"method":"daemon.shutdown"}\n' | nc -U -w 2 "$home/kelp.sock" > /dev/null 2>&1 || true
