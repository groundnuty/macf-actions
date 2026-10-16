#!/usr/bin/env bash
# Vector test for PR resolution in agent-router.yml's `route-by-ci-completion`
# job (groundnuty/macf#1479). The block under test is EXTRACTED from the
# workflow, not copied, so it cannot drift from what runs.
#
# Decisive cases:
#   1. workflow_run with pull_requests -> those PR numbers, and the head-SHA
#      API lookup is NEVER called (the fake gh fails the case if invoked).
#   2. workflow_run with empty pull_requests ([]) -> head-SHA fallback.
#   3. check_suite (WORKFLOW_RUN_PRS="null") -> head-SHA lookup, as before.
# Mutation check at the bottom: dropping the workflow_run branch makes
# case 1 fail (it calls the fake gh, which refuses).
set -euo pipefail
WF=.github/workflows/agent-router.yml

BLOCK=$(awk '
  /PR_NUMBERS=\$\(printf/ {on=1}
  /^ *\[ -z "\$PR_NUMBERS" \] &&/ {on=0}
  on {print}
' "$WF")
[ -n "$BLOCK" ] || { echo "FAIL: could not extract PR-resolution block from $WF"; exit 1; }
printf '%s\n' "$BLOCK" | grep -q 'gh api' || { echo "FAIL: extracted block has no API fallback"; exit 1; }

fail=0
run_case() { # name, WORKFLOW_RUN_PRS, expected, api-allowed(yes|no), block
  local name="$1" prs="$2" expected="$3" allowed="$4" block="$5" out
  out=$(
    export REPO=o/r CHECK_SUITE_HEAD_SHA=abc WORKFLOW_RUN_PRS="$prs" API_ALLOWED="$allowed"
    gh() {
      [ "$API_ALLOWED" = yes ] || { echo "API CALLED" >&2; return 99; }
      printf '7\n8\n'
    }
    set +e
    eval "$block"
    printf '%s' "$PR_NUMBERS" | tr '\n' ' '
  ) || true
  if [ "$out" = "$expected" ]; then echo "ok   $name"; else echo "FAIL $name: got '$out' want '$expected'"; fail=1; fi
}

run_case "workflow_run uses its own PRs, no API call" '[{"number":42},{"number":43}]' '42 43' no "$BLOCK"
run_case "workflow_run empty PRs falls back to SHA lookup" '[]' '7 8' yes "$BLOCK"
run_case "check_suite (null) uses SHA lookup" 'null' '7 8' yes "$BLOCK"

# Mutation: neutralise the workflow_run branch; case 1 must now FAIL.
MUT=$(printf '%s\n' "$BLOCK" | sed 's/^ *PR_NUMBERS=\$(printf.*$/PR_NUMBERS=""/')
echo "-- mutation (expect FAIL below) --"
mut_out=$(fail=0; run_case "workflow_run uses its own PRs, no API call" '[{"number":42},{"number":43}]' '42 43' no "$MUT")
echo "$mut_out"
echo "$mut_out" | grep -q '^FAIL' || { echo "FAIL: mutation was not detected"; fail=1; }

exit $fail
