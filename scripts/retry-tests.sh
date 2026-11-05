#!/bin/bash
# Runs a test command; on a shared runner load fails a few tests at random, so the ones that failed run once more, alone,
# and the run says so. A data race fails at once, and so does a run that stopped short: its other tests never ran.
log=$(mktemp)
"$@" 2>&1 | tee "$log"
status=${PIPESTATUS[0]}
[ "$status" = 0 ] && exit 0
grep -q 'WARNING: ThreadSanitizer' "$log" && exit 1
if [ "$(grep -c 'Test run started' "$log")" != "$(grep -cE 'Test run with .* after' "$log")" ]; then
  echo "::error::The test run stopped short (status $status): a crash or a kill"
  exit 1
fi
failed=$(sed -nE 's/.*✘[^T]*Test ([^ (]+)\(.*failed after.*/\1/p' "$log" | sort -u | paste -sd'|' -)
[ -n "$failed" ] || { echo "::error::The tests ended with status $status and named no failure"; exit 1; }
echo "::warning::Failed, running these once more: $failed"
"$@" --filter "$failed"
