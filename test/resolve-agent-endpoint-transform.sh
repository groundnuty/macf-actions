#!/usr/bin/env bash
# Canonical-vector test for the toVariableSegment-equivalent shell transform
# used by .github/actions/resolve-agent-endpoint/action.yml. Drift-catcher
# paired with test/registry/variable-name.test.ts in groundnuty/macf —
# if either side's logic diverges from the other, the matching test fails.
#
# Keep the cases here in lockstep with:
#   groundnuty/macf:test/registry/variable-name.test.ts
#
# Rule: uppercase + hyphen→underscore. No other transforms (digits,
# existing underscores, uppercase input all pass through unchanged).

set -euo pipefail

transform() {
  printf '%s' "$1" | tr '[:lower:]-' '[:upper:]_'
}

fail=0
check() {
  local input=$1 expected=$2
  local actual
  actual=$(transform "$input")
  if [ "$actual" = "$expected" ]; then
    echo "ok: '${input}' → '${actual}'"
  else
    echo "FAIL: '${input}' → '${actual}' (expected '${expected}')" >&2
    fail=1
  fi
}

check 'macf'                    'MACF'
check 'academic-resume'         'ACADEMIC_RESUME'
check 'cv-architect'            'CV_ARCHITECT'
check 'cv-project-archaeologist' 'CV_PROJECT_ARCHAEOLOGIST'
check 'macf-experiments-q1-2026' 'MACF_EXPERIMENTS_Q1_2026'
check 'with_underscore'         'WITH_UNDERSCORE'
check 'mix-of_both'             'MIX_OF_BOTH'
check 'worker-a8f3c2'           'WORKER_A8F3C2'

# Edge cases per science-agent's sign-off:
# - Empty input: the transform itself produces empty output; the composite
#   action fails loudly via ${VAR:?msg} BEFORE reaching this transform, so
#   that path is exercised by the composite's inline guards (not this test).
#   Covered here as a transform-contract check only.
check ''                        ''

# Already-uppercase input: idempotent.
check 'MACF'                    'MACF'
check 'CODE_AGENT'              'CODE_AGENT'

# Mixed case: uppercase wins.
check 'MiXeD-CaSe'              'MIXED_CASE'

# Equivalence: hyphens and underscores collapse identically.
if [ "$(transform code-agent)" != "$(transform CODE_AGENT)" ]; then
  echo "FAIL: 'code-agent' and 'CODE_AGENT' should transform identically" >&2
  fail=1
fi

if [ "$fail" -ne 0 ]; then
  echo "FAIL: canonical-vector test failed" >&2
  exit 1
fi
echo "all ok"
