#!/bin/bash
# Runs a test command; on a shared runner load fails a few tests at random, so the ones that failed run once more, alone,
# and the run says so. A data race, or a crash that names no test, fails at once.
log=$(mktemp)
"$@" 2>&1 | tee "$log"
[ "${PIPESTATUS[0]}" = 0 ] && exit 0
grep -q 'WARNING: ThreadSanitizer' "$log" && exit 1
failed=$(sed -nE 's/.*✘[^T]*Test ([^ (]+)\(.*failed after.*/\1/p' "$log" | sort -u | paste -sd'|' -)
[ -n "$failed" ] || exit 1
echo "::warning::Failed, running these once more: $failed"
"$@" --filter "$failed"
