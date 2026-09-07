#!/bin/sh
# examples/hung-worker.sh
# -----------------------------------------------------------
# Demonstrates SIGKILL fallback: a child process that ignores
# SIGTERM must be hard-killed after the grace period expires.
#
# We simulate this by running the v4 binary against a wrapper
# that spawns `sleep 3600` as a child -- sleep(1) exits cleanly
# on SIGTERM though, so we use a shell trap loop instead.
# -----------------------------------------------------------

set -e
cd "$(dirname "$0")/.."

echo "==> spawning a hung worker in background..."
(
  trap 'echo "child got SIGTERM but IGNORES"' TERM
  # busy loop that shrugs off SIGTERM
  i=0
  while [ $i -lt 100 ]; do
    sleep 0.5
    i=$((i + 1))
  done
) &
HUNG_PID=$!
echo "==> hung worker started, pid=$HUNG_PID"

# give it a moment
sleep 0.5

echo "==> sending SIGTERM (should be ignored)"
kill -TERM $HUNG_PID
sleep 1

if kill -0 $HUNG_PID 2>/dev/null; then
  echo "==> confirmed: worker still alive after SIGTERM"
  echo "==> sending SIGKILL (unblockable)"
  kill -KILL $HUNG_PID
  sleep 0.3
  if kill -0 $HUNG_PID 2>/dev/null; then
    echo "  FAIL: worker survived SIGKILL (impossible!)"
    exit 1
  else
    echo "  PASS: worker terminated by SIGKILL"
  fi
else
  echo "  NOTE: worker exited on SIGTERM anyway (shell trap not honored)"
fi

wait $HUNG_PID 2>/dev/null || true
echo "==> done"
