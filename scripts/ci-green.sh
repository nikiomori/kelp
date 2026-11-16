#!/bin/zsh
# Refuses to go on unless CI passed on main for the commit about to be published (HEAD, or the one given): a release
# cut on a red main ships what the tests caught. Run by `make publish` and `make publish-beta`.
set -euo pipefail
SHA=$(git rev-parse "${1:-HEAD}")
read -r STATUS CONCLUSION URL <<< "$(gh run list --workflow CI --branch main --commit "$SHA" -L 1 \
  --json status,conclusion,url --jq '.[0] | "\(.status) \(.conclusion) \(.url)"')" || true
if [[ -z "${STATUS:-}" || $STATUS == null ]]; then
  echo "CI hasn't run on main for ${SHA:0:7}: push it and wait for the run, then publish."
  exit 1
elif [[ $STATUS != completed ]]; then
  echo "CI is still running on main for ${SHA:0:7}: publish once it passes ($URL)."
  exit 1
elif [[ $CONCLUSION != success ]]; then
  echo "CI failed on main for ${SHA:0:7}: fix it first ($URL)."
  exit 1
fi
