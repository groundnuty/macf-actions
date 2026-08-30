#!/usr/bin/env bash
# Canonical-vector test for the `pick-runner` job's `pick` step in
# .github/workflows/agent-router.yml (groundnuty/macf-actions#81 — a fleet
# that DECLARES `runner-runs-on: self-hosted` must FAIL the job rather than
# silently relocate to a metered github-hosted runner).
#
# Replicated verbatim (per this repo's established convention — see
# test/routing-bundle-unpack.sh's own header) from the `pick` step's `run:`
# block. Keep this copy in lockstep with the workflow's one copy by hand —
# a change to one without the other is a drift the CI unit-tests job won't
# catch by itself, only a code reviewer diffing the PR will.
#
# Decisive pair (per the issue's own Tests section):
#   1. self-hosted declared + untrusted actor, non-fork -> job FAILS,
#      message names actor + MACF_TRUSTED_ACTORS + repo
#   2. self-hosted declared + trusted actor            -> runs self-hosted,
#      unchanged
# Plus: fork event keeps its downgrade (no failure, regardless of the
# declaration) · hosted-declared (or empty/undeclared) + any actor -> keeps
# today's behaviour exactly, unchanged · declaration unreadable
# (MACF_TRUSTED_ACTORS empty/unset) + self-hosted caller -> fails closed,
# never inferred as "hosted is fine" · IS_FORK="" (the value on every
# non-pull_request event — issues/issue_comment/check_suite, the majority
# of what this router handles, since `github.event.pull_request` doesn't
# exist there) is exercised explicitly, not just IS_FORK="true"/"false".
#
# Mutation check at the bottom: the pre-#81 shape (unconditional
# ubuntu-latest fallback, no enforcement) run against case 1's EXACT vector
# must NOT fail — proving case 1 is a real regression guard against the
# defect this issue forbids, not an assertion that would pass regardless
# (assert-the-wrong-path.md's own gate).
#
# Honest limit NOT covered here (unobservable from pick-runner, by design):
# a trusted actor whose declared self-hosted runner isn't actually
# registered still gets self-hosted labels and queues indefinitely rather
# than failing — pick-runner only ever sees MACF_TRUSTED_ACTORS membership,
# never live runner-registration state.

set -euo pipefail

# ── Replicated verbatim from pick-runner's "pick" step (post-#81). `::error::`
# is emitted on STDOUT (no `>&2`) — matches this workflow's dominant
# convention (30-of-34 pre-existing `::error::` lines in agent-router.yml
# have no stderr redirect); the runner turns the annotation into a visible
# error regardless of which stream it reads, and staying on-convention is
# what a code reviewer diffing this file will expect. ──
pick_runner() {
  set -euo pipefail
  set -f  # disable globbing — actor logins contain [bot]
  labels='"ubuntu-latest"'   # default: github-hosted (safe fallback)
  trusted=false
  if [ "${IS_FORK:-}" != "true" ] && [ -n "${TRUSTED_ACTORS:-}" ]; then
    for a in ${TRUSTED_ACTORS//,/ }; do
      if [ "$a" = "$ACTOR" ]; then
        labels='["self-hosted","macf-vm"]'
        trusted=true
        break
      fi
    done
  fi
  if [ "${RUNNER_RUNS_ON:-}" = "self-hosted" ] && [ "$trusted" != "true" ] && [ "${IS_FORK:-}" != "true" ]; then
    echo "::error::runner-runs-on=self-hosted was declared for ${REPO:-this repo}, but actor '${ACTOR:-<unknown>}' is not listed in the MACF_TRUSTED_ACTORS variable (repo or org scope) that pick-runner reads to decide self-hosted eligibility — refusing to fall back to a metered ubuntu-latest runner. Fix: add '${ACTOR:-<actor>}' to MACF_TRUSTED_ACTORS on ${REPO:-the caller repo} (or its org), then re-run."
    return 1
  fi
  echo "labels=$labels" >> "$GITHUB_OUTPUT"
  echo "runner: actor='$ACTOR' fork='${IS_FORK:-false}' runner-runs-on='${RUNNER_RUNS_ON:-<none>}' -> $labels"
}

# Pre-#81 shape — the unconditional silent-relocate fallback this issue
# forbids. Used ONLY by the mutation check at the bottom.
pick_runner_pre81() {
  set -euo pipefail
  set -f
  labels='"ubuntu-latest"'
  if [ "${IS_FORK:-}" != "true" ] && [ -n "${TRUSTED_ACTORS:-}" ]; then
    for a in ${TRUSTED_ACTORS//,/ }; do
      if [ "$a" = "$ACTOR" ]; then
        labels='["self-hosted","macf-vm"]'
        break
      fi
    done
  fi
  echo "labels=$labels" >> "$GITHUB_OUTPUT"
}

fail=0
LAST_CODE=""
LAST_LABELS=""
LAST_STDOUT=""

# $1=name $2=TRUSTED_ACTORS $3=ACTOR $4=IS_FORK $5=RUNNER_RUNS_ON $6=REPO
run_case() {
  local name="$1" trusted_actors="$2" actor="$3" is_fork="$4" runner_runs_on="$5" repo="$6"
  local gh_output out_file err_file code

  gh_output=$(mktemp)
  out_file=$(mktemp)
  err_file=$(mktemp)
  : > "$gh_output"

  set +e
  (
    export TRUSTED_ACTORS="$trusted_actors" ACTOR="$actor" IS_FORK="$is_fork" \
           RUNNER_RUNS_ON="$runner_runs_on" REPO="$repo" GITHUB_OUTPUT="$gh_output"
    pick_runner
  ) >"$out_file" 2>"$err_file"
  code=$?
  set -e

  LAST_CODE=$code
  LAST_LABELS=$(grep '^labels=' "$gh_output" 2>/dev/null | cut -d= -f2- || true)
  LAST_STDOUT=$(cat "$out_file")

  echo "── $name ──"
  echo "  exit=$LAST_CODE labels='${LAST_LABELS:-<none>}'"
  [ -s "$out_file" ] && sed 's/^/  stdout: /' "$out_file"
  [ -s "$err_file" ] && sed 's/^/  stderr: /' "$err_file"

  rm -f "$gh_output" "$out_file" "$err_file"
}

assert_exit() {
  local name="$1" expected="$2"
  if [ "$LAST_CODE" -eq "$expected" ]; then
    echo "  ok: exit == $expected"
  else
    echo "  FAIL ($name): exit == $LAST_CODE, expected $expected" >&2
    fail=1
  fi
}

assert_labels() {
  local name="$1" expected="$2"
  if [ "$LAST_LABELS" = "$expected" ]; then
    echo "  ok: labels == '$expected'"
  else
    echo "  FAIL ($name): labels == '${LAST_LABELS:-<none>}', expected '$expected'" >&2
    fail=1
  fi
}

# The `::error::` annotation is written to STDOUT (see pick_runner's own
# comment above) — this asserts against stdout, not stderr.
assert_stdout_contains() {
  local name="$1" needle="$2"
  case "$LAST_STDOUT" in
    *"$needle"*) echo "  ok: stdout contains '$needle'" ;;
    *)
      echo "  FAIL ($name): stdout does not contain '$needle' (stdout: ${LAST_STDOUT:-<empty>})" >&2
      fail=1
      ;;
  esac
}

# ── Decisive pair ──

run_case "1: self-hosted required, untrusted actor (non-fork) -> FAILS" \
  "macf-trial-writing-agent[bot]" "attacker-bot" "false" "self-hosted" "groundnuty/macf-trial-code-agent"
assert_exit "case1" 1
assert_stdout_contains "case1-actor" "attacker-bot"
assert_stdout_contains "case1-var" "MACF_TRUSTED_ACTORS"
assert_stdout_contains "case1-repo" "groundnuty/macf-trial-code-agent"

run_case "2: self-hosted required, trusted actor -> self-hosted, unchanged" \
  "macf-code-agent[bot],macf-science-agent[bot]" "macf-code-agent[bot]" "false" "self-hosted" "groundnuty/macf-trial-code-agent"
assert_exit "case2" 0
assert_labels "case2" '["self-hosted","macf-vm"]'

# ── Preserve the fork downgrade — even with self-hosted required and an
#    untrusted actor, a fork PR downgrades to hosted, no failure. ──

run_case "3: fork event (IS_FORK=true), self-hosted required, untrusted actor -> downgrades, no failure" \
  "macf-trial-writing-agent[bot]" "outside-contributor" "true" "self-hosted" "groundnuty/macf-trial-code-agent"
assert_exit "case3" 0
assert_labels "case3" '"ubuntu-latest"'

# ── IS_FORK="" — the value on every non-pull_request event (issues,
#    issue_comment, check_suite: `github.event.pull_request` doesn't exist,
#    so the expression resolves empty, not "false"). This is NOT the fork
#    carve-out (that's IS_FORK="true" only) — an untrusted actor on one of
#    these events with self-hosted required DOES fail, same as case 1. A
#    trusted actor is unaffected. Pinning this so the behavior change on
#    the majority of this router's event types is explicit, not assumed. ──

run_case "3b: IS_FORK=\"\" (non-PR event), self-hosted required, untrusted actor -> FAILS" \
  "macf-trial-writing-agent[bot]" "attacker-bot" "" "self-hosted" "groundnuty/macf-trial-code-agent"
assert_exit "case3b" 1
assert_stdout_contains "case3b" "MACF_TRUSTED_ACTORS"

run_case "3c: IS_FORK=\"\" (non-PR event), self-hosted required, trusted actor -> self-hosted, unchanged" \
  "macf-code-agent[bot]" "macf-code-agent[bot]" "" "self-hosted" "groundnuty/macf-trial-code-agent"
assert_exit "case3c" 0
assert_labels "case3c" '["self-hosted","macf-vm"]'

# ── hosted-declared (or empty/undeclared) + any actor -> today's behaviour
#    exactly, unchanged (the new enforcement is a no-op for anything other
#    than the literal string "self-hosted"). ──

run_case "4a: hosted declared, untrusted actor -> hosted, unchanged" \
  "macf-trial-writing-agent[bot]" "attacker-bot" "false" "hosted" "groundnuty/macf-trial-code-agent"
assert_exit "case4a" 0
assert_labels "case4a" '"ubuntu-latest"'

run_case "4b: hosted declared, trusted actor -> self-hosted, unchanged" \
  "macf-code-agent[bot]" "macf-code-agent[bot]" "false" "hosted" "groundnuty/macf-trial-code-agent"
assert_exit "case4b" 0
assert_labels "case4b" '["self-hosted","macf-vm"]'

run_case "6: undeclared caller, untrusted actor -> hosted, unchanged (regression guard)" \
  "macf-trial-writing-agent[bot]" "attacker-bot" "false" "" "groundnuty/macf-trial-code-agent"
assert_exit "case6" 0
assert_labels "case6" '"ubuntu-latest"'

run_case "7: undeclared caller, trusted actor -> self-hosted, unchanged (regression guard)" \
  "macf-code-agent[bot]" "macf-code-agent[bot]" "false" "" "groundnuty/macf-trial-code-agent"
assert_exit "case7" 0
assert_labels "case7" '["self-hosted","macf-vm"]'

# ── honest-unknown: declaration effectively unreadable (MACF_TRUSTED_ACTORS
#    unset/empty) + self-hosted required -> fails closed, never inferred as
#    "hosted is fine". ──

run_case "5: self-hosted required, MACF_TRUSTED_ACTORS unset (unreadable) -> fails closed" \
  "" "macf-code-agent[bot]" "false" "self-hosted" "groundnuty/macf-trial-code-agent"
assert_exit "case5" 1
assert_stdout_contains "case5" "MACF_TRUSTED_ACTORS"

# ── Mutation check: the pre-#81 shape, run against case 1's EXACT vector,
#    must silently relocate (exit 0, ubuntu-latest) rather than fail. This
#    is the issue's own "restore the unconditional ubuntu-latest fallback
#    and confirm test 1 fails" mutation, proving case 1 actually depends on
#    the new enforcement rather than being a check that always fails. ──

echo "── mutation: pre-#81 pick_runner on case-1's vector must NOT fail ──"
mut_gh_output=$(mktemp)
: > "$mut_gh_output"
set +e
(
  export TRUSTED_ACTORS="macf-trial-writing-agent[bot]" ACTOR="attacker-bot" IS_FORK="false" \
         GITHUB_OUTPUT="$mut_gh_output"
  pick_runner_pre81
) >/dev/null 2>&1
mut_code=$?
set -e
mut_labels=$(grep '^labels=' "$mut_gh_output" 2>/dev/null | cut -d= -f2- || true)
rm -f "$mut_gh_output"

if [ "$mut_code" -eq 0 ] && [ "$mut_labels" = '"ubuntu-latest"' ]; then
  echo "  ok: pre-#81 shape silently relocates to ubuntu-latest (exit 0) on case 1's vector — confirms case 1 is a real regression guard, not a check that always fails"
else
  echo "  FAIL: pre-#81 shape did not reproduce the silent-relocate baseline (exit=$mut_code labels='${mut_labels:-<none>}') — the mutation check itself is broken" >&2
  fail=1
fi

if [ "$fail" -ne 0 ]; then
  echo "FAIL: canonical-vector test failed" >&2
  exit 1
fi
echo "all ok"
