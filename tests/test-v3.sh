#!/bin/sh
# tests/test-v3.sh -- assertion suite for v3 (single-process supervisor tree)
#
# Reads the demo output log and asserts key invariants hold.

set -e
LOG="${1:-/tmp/cordis-v3.log}"

if [ ! -f "$LOG" ]; then
  echo "  FAIL: log $LOG not found"; exit 1
fi

pass=0
fail=0

assert_grep() {
  # $1 = pattern, $2 = description
  if grep -qE "$1" "$LOG"; then
    echo "  PASS  $2"
    pass=$((pass + 1))
  else
    echo "  FAIL  $2"
    echo "        pattern: $1"
    fail=$((fail + 1))
  fi
}

assert_not_grep() {
  if grep -qE "$1" "$LOG"; then
    echo "  FAIL  $2"
    echo "        forbidden pattern found: $1"
    fail=$((fail + 1))
  else
    echo "  PASS  $2"
    pass=$((pass + 1))
  fi
}

assert_count() {
  # $1 = pattern, $2 = expected count, $3 = description
  n=$(grep -cE "$1" "$LOG" || true)
  if [ "$n" = "$2" ]; then
    echo "  PASS  $3 (count=$n)"
    pass=$((pass + 1))
  else
    echo "  FAIL  $3 (expected $2, got $n)"
    fail=$((fail + 1))
  fi
}

echo ""
echo "  --- Cordis v3 invariants ---"

# ---- structural invariants ----
assert_grep 'PHASE 1' 'phase 1 reached'
assert_grep 'PHASE 7' 'phase 7 reached (cascade dispose)'
assert_grep 'DONE'    'demo completed'

# ---- fork correctness ----
assert_grep '\[FORK\] child <math>'     'math child forked'
assert_grep '\[FORK\] child <research>' 'research child forked'
assert_grep '\[FORK\] child <slow>'     'slow child forked'
assert_grep '\[FORK\] child <late>'     'late child forked post-hoc'

# ---- tool provider correctness ----
assert_grep "provide 'tool/calc@v1'"   'calc tool provided'
assert_grep "provide 'tool/search@v1'" 'search tool provided'
assert_grep "provide 'tool/write@v1'"  'write tool provided'

# ---- ReAct step correctness ----
assert_grep '\[math\] .*\[OBS\] result=56'  'math computed 7*8=56'
assert_grep 'Cordis: reactive IoC'           'research got cordis kb entry'
assert_grep 'wrote:math_answer'              'math wrote artifact'

# ---- partial dispose (Phase 5) ----
assert_grep 'PARTIAL DISPOSE'                   'phase 5 partial dispose'
assert_grep 'DISPOSE.*<slow>'                   'slow scope disposed'
assert_grep 'slow alive=false'                  'slow marked dead'
assert_grep 'research alive=true'               'research still alive after partial'
assert_grep 'math alive=true'                   'math still alive after partial'

# ---- cascade dispose (Phase 7) ----
assert_grep 'FULL DISPOSE'                      'phase 7 cascade dispose'
assert_grep 'DISPOSE.*<agent:supervisor>'       'supervisor scope disposed'
assert_grep 'late alive=false'                  'late child cascaded to dead'
assert_grep 'research alive=false'              'research cascaded to dead'
assert_grep 'math alive=false'                  'math cascaded to dead'

# ---- post-cascade: tools gone, root logger still live ----
assert_grep '\[-\] tool/calc@v1 gone'          'calc tool retracted'
assert_grep '\[-\] tool/search@v1 gone'        'search tool retracted'
assert_grep '\[-\] tool/write@v1 gone'         'write tool retracted'
assert_grep '\[\+\] logger still live'         'root logger unaffected'

# ---- no leaked panics ----
assert_not_grep 'Uncaught exception'            'no uncaught exceptions'
assert_not_grep 'FATAL'                         'no fatal errors'

echo ""
echo "  --- v3: $pass passed, $fail failed ---"

if [ "$fail" -gt 0 ]; then
  exit 1
fi
