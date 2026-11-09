#!/bin/sh
# Opens the app on a few scenes and writes each window to a PNG (KELP_SNAPSHOT: no screen-recording permission needed):
# the start page, Settings, a file, a terminal that ran a command. Fails when the app doesn't come up, crashes or draws
# nothing, or when the launch or a workspace switch takes longer than its budget. Run after `swift build` (KELP_APP: a
# build elsewhere); the pictures and logs go to $1 (default /tmp/kelp-ui) for a look by eye.
#
# Budgets: the slowest of five local runs (an M-series Mac under a load of 30, debug build) times 3, rounded up. The
# first launch (daemon start, window, the snapshot's 1.5 s wait, quit) took 6.0-8.1 s, a switch 46-79 ms.
set -eu
out=${1:-/tmp/kelp-ui}
mkdir -p "$out"
home=$(mktemp -d /tmp/kui.XXXX)   # short: the daemon's socket path must fit in 104 bytes
app=${KELP_APP:-.build/debug/KelpApp}
launch_budget_ms=${KELP_LAUNCH_BUDGET_MS:-25000}
switch_budget_ms=${KELP_SWITCH_BUDGET_MS:-250}
now_ms() { perl -MTime::HiRes=time -e 'printf "%d\n", time * 1000'; }
# A project to show: a repository with a commit and a README.
repo="$home/demo"
mkdir -p "$repo"
git -C "$repo" init -q -b main
printf '# Demo\n\nKelp smoke test.\n' > "$repo/README.md"
git -C "$repo" add README.md
git -C "$repo" -c user.name=kelp -c user.email=kelp@example.com commit -qm init
# A second, to switch to: its workspace is named after its branch.
other="$home/other"
mkdir -p "$other"
git -C "$other" init -q -b other
git -C "$other" -c user.name=kelp -c user.email=kelp@example.com commit -qm init --allow-empty
scene() {
    name=$1
    shift
    started=$(now_ms)
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
    took=$(($(now_ms) - started))
    echo "$name: ok ($took ms)"
}
# Added by the app, as Add Project does: CI runs this as a launchd job, which the daemon holds to an agent's rules.
scene start KELP_SNAPSHOT_SHEET="project=$repo"
if [ "$took" -gt "$launch_budget_ms" ]; then
    echo "start: the launch took $took ms, over its $launch_budget_ms ms budget"
    exit 1
fi
scene settings KELP_SNAPSHOT_WINDOW=settings
scene file KELP_SNAPSHOT_OPEN="file://$repo/README.md"
# Workspace switches, timed by the app (KELP_SWITCH prints "SWITCH <name> <ms> ms" for each).
scene project2 KELP_SNAPSHOT_SHEET="project=$other"
scene switch KELP_SWITCH=other,main,other,main KELP_SNAPSHOT_DELAY=3
switches=$(grep -c '^SWITCH .* ms$' "$out/switch.log" || true)
slowest=$(awk '/^SWITCH .* ms$/ { if ($(NF-1) > max) max = $(NF-1) } END { print max + 0 }' "$out/switch.log")
if [ "$switches" -ne 4 ]; then
    grep '^SWITCH' "$out/switch.log" || true
    echo "switch: $switches of 4 switches happened"
    exit 1
fi
if [ "$slowest" -gt "$switch_budget_ms" ]; then
    grep '^SWITCH' "$out/switch.log"
    echo "switch: the slowest took $slowest ms, over its $switch_budget_ms ms budget"
    exit 1
fi
echo "switch: slowest of 4 $slowest ms"
# A terminal running a command: its answer (42) isn't in the command's text, so finding it means the shell ran it.
scene terminal KELP_SNAPSHOT_OPEN='terminal:?cmd=expr%2040%20%2B%202' KELP_TYPE='{wait}{wait}'
if ! grep -rqs '42' "$home/history"; then
    echo "terminal: the command didn't run"
    exit 1
fi
# The daemon the app started goes with the scenes.
printf '{"jsonrpc":"2.0","id":1,"method":"daemon.shutdown"}\n' | nc -U -w 2 "$home/kelp.sock" > /dev/null 2>&1 || true
