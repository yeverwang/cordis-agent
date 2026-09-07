#!/bin/sh
# tests/test-v4.sh -- assertion suite for v4 (cross-process supervisor)
#
# Verifies fork+exec, pgid inheritance, SIGTERM broadcast, and reap.

set -e
LOG="${1:-/tmp/cordis-v4.log}"

if [ ! -f "$LOG" ]; then
  echo "  FAIL: log $LOG not found"; exit 1
fi

pass=0
fail=0

assert_grep() {
  if grep -qE "$1" "$LOG"; then
    echo "  PASS  $2"; pass=$((pass + 1))
  else
    echo "  FAIL  $2 (pattern: $1)"; fail=$((fail + 1))
  fi
}

assert_not_grep() {
  if grep -qE "$1" "$LOG"; then
    echo "  FAIL  $2 (forbidden: $1)"; fail=$((fail + 1))
  else
    echo "  PASS  $2"; pass=$((pass + 1))
  fi
}

assert_count() {
  n=$(grep -cE "$1" "$LOG" || true)
  if [ "$n" = "$2" ]; then
    echo "  PASS  $3 (count=$n)"; pass=$((pass + 1))
  else
    echo "  FAIL  $3 (expected $2, got $n)"; fail=$((fail + 1))
  fi
}

echo ""
echo "  --- Cordis v4 invariants ---"

# ---- phases reached ----
assert_grep 'PHASE 1' 'phase 1 (bootstrap)'
assert_grep 'PHASE 2' 'phase 2 (fork+exec)'
assert_grep 'PHASE 4' 'phase 4 (graceful shutdown)'
assert_grep 'DONE'    'reached DONE'

# ---- forking correctness: 3 workers spawned ----
assert_count "\\[FORK\\] 'math'"     "1" 'math forked exactly once'
assert_count "\\[FORK\\] 'research'" "1" 'research forked exactly once'
assert_count "\\[FORK\\] 'slow'"     "1" 'slow forked exactly once'

# ---- pgid inheritance: workers should log distinct pids ----
assert_grep 'WORKER START.*name=math'     'math worker booted via exec'
assert_grep 'WORKER START.*name=research' 'research worker booted via exec'
assert_grep 'WORKER START.*name=slow'     'slow worker booted via exec'

# ---- worker ran expected ticks ----
assert_grep 'worker math.*tick 3/3'     'math completed 3 ticks'
assert_grep 'worker research.*tick 3/3' 'research completed 3 ticks'

# ---- broadcast + reap ----
assert_grep '\[BROADCAST\] signal to 3 child' 'broadcast sent to 3 children'
assert_count '\[REAP\] pid=' "3" 'all 3 children reaped'

# ---- successful shutdown ----
assert_grep 'all children reaped gracefully' 'graceful shutdown succeeded'

# ---- no orphans / zombies remain ----
assert_not_grep 'FATAL' 'no fatal errors'
assert_not_grep 'exec failed' 'no exec failures'

echo ""
echo "  --- v4: $pass passed, $fail failed ---"

if [ "$fail" -gt 0 ]; then
  exit 1
fi
