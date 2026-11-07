#!/bin/bash
# Runs a test command; on a shared runner load fails a few tests at random, so the ones that failed run once more, alone,
# and the run says so, only when each is listed in Tests/flaky.txt (with why). Any other failure fails the run, as do a
# data race and a crash that names no test.
log=$(mktemp)
"$@" 2>&1 | tee "$log"
[ "${PIPESTATUS[0]}" = 0 ] && exit 0
grep -q 'WARNING: ThreadSanitizer' "$log" && exit 1
# A test process that crashed (a trap, a guarded fd) prints no summary for its run: whatever else failed, that fails.
[ "$(grep -c 'Test run started' "$log")" = "$(grep -cE 'Test run with [0-9]+ tests? ' "$log")" ] || { echo "::error::A test run ended with no summary (a crash)"; exit 1; }
failed=$(sed -nE 's/.*✘[^T]*Test ([^ (]+)\(.*failed after.*/\1/p' "$log" | sort -u)
[ -n "$failed" ] || exit 1
known=$(sed -E 's/#.*//; s/[[:space:]]+//g; /^$/d' "$(dirname "$0")/../Tests/flaky.txt")
unknown=$(comm -23 <(echo "$failed") <(echo "$known" | sort -u) | paste -sd' ' -)
if [ -n "$unknown" ]; then echo "::error::Failed, and not known to be load-bound (Tests/flaky.txt): $unknown"; exit 1; fi
list=$(echo "$failed" | paste -sd'|' -)
echo "::warning::Failed, running these once more: $list"
"$@" --filter "$list" 2>&1 | tee "$log"
[ "${PIPESTATUS[0]}" = 0 ] && ! grep -q 'WARNING: ThreadSanitizer' "$log"
