#!/bin/sh
# tests/test-v3m.sh -- invariants for v3-modular (functor-typed services)
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LOG=/tmp/cordis-v3m.log
"$ROOT/bin/cordis-v3m" > "$LOG" 2>&1
rc=$?

pass=0
fail=0
echo ""
echo "  --- Cordis v3-modular invariants ---"

check() {
  msg="$1"; pat="$2"
  if grep -qF "$pat" "$LOG"; then
    echo "  PASS  $msg"; pass=$((pass+1))
  else
    echo "  FAIL  $msg  (missing: $pat)"; fail=$((fail+1))
  fi
}

# --- Refactor-specific invariants ---
check "type ledger printed"             "TYPE LEDGER"
check "logger via typed module"         "Logger.get () returned SOME"
check "logger slot provided"            "[SVC] provide 'logger'"
check "calc slot provided"              "[SVC] provide 'tool/calc@v1'"
check "search slot provided"            "[SVC] provide 'tool/search@v1'"
check "write slot provided"             "[SVC] provide 'tool/write@v1'"

# --- Behavioural invariants (same as v3) ---
check "phase 1 reached"                 "PHASE 1"
check "phase 7 reached (cascade)"       "PHASE 7"
check "demo completed"                  "DONE"
check "math child forked"               "[FORK] child <math>"
check "research child forked"           "[FORK] child <research>"
check "slow child forked"               "[FORK] child <slow>"
check "late child forked"               "[FORK] child <late>"
check "math computed 7*8=56"            "result=56"
check "research got cordis kb"          "reactive IoC"
check "math wrote artifact"             "wrote:math_answer"
check "phase 5 partial dispose"         "PHASE 5"
check "slow scope disposed"             "[DISPOSE] scope <slow>"
check "supervisor scope disposed"       "[DISPOSE] scope <agent:supervisor>"
check "calc slot retracted"             "[SVC] retract 'tool/calc@v1'"
check "search slot retracted"           "[SVC] retract 'tool/search@v1'"
check "write slot retracted"            "[SVC] retract 'tool/write@v1'"
check "calc gone after cascade"         "[-] Calc gone"
check "search gone after cascade"       "[-] Search gone"
check "write gone after cascade"        "[-] Write gone"
check "logger untouched"                "[+] Logger still live"

# --- Negative check: no uncaught exceptions ---
if grep -qEi "Uncaught exception|Unhandled exception" "$LOG"; then
  echo "  FAIL  no uncaught exceptions"; fail=$((fail+1))
else
  echo "  PASS  no uncaught exceptions"; pass=$((pass+1))
fi

# --- Exit code ---
if [ $rc -eq 0 ]; then
  echo "  PASS  binary exited 0"; pass=$((pass+1))
else
  echo "  FAIL  binary exited $rc"; fail=$((fail+1))
fi

echo ""
echo "  --- v3m: $pass passed, $fail failed ---"
[ $fail -eq 0 ]
