#!/usr/bin/env bash
# Canonical-vector test for the CA-cert resolution PRECEDENCE logic
# inlined in .github/workflows/agent-router.yml's "Resolve project CA
# cert (registry primary, repo-var fallback)" step — identical in all
# four route-by-* jobs (route-by-label, route-by-mention,
# route-by-ci-completion, route-by-pr-review-state) per macf-actions#66.
#
# The real step's `gh api .../actions/variables/<SEG>_CA_CERT` registry
# call can't be exercised outside a live registry — same "transform-
# contract, not full step" scope as test/resolve-agent-endpoint-
# transform.sh (see that file's header). This test isolates the
# PRECEDENCE + FAILURE-MODE decision only: given an already-resolved
# registry lookup result and an already-resolved repo-var-fallback
# value, which one wins, and does both-empty fail loud. Full end-to-end
# coverage (the actual `gh api` call, `mktemp`, $GITHUB_OUTPUT write) is
# exercised via the live external-caller path, not this vector test.
#
# Keep resolve_ca() here in lockstep with the workflow step's shell body
# if either changes — no shared source, same manual-sync convention as
# test/pr-review-recipient-actor-exclusion.sh's build_recipients().

set -euo pipefail

# Mirrors the workflow step's if/elif/else precedence + failure mode
# exactly (registry primary, repo-var-fallback transitional, both-empty
# loud-fail — macf-actions#66 / groundnuty/macf#799/#806). $1 = simulated
# registry lookup result (empty string = registry miss, same as the real
# step's `gh api ... --jq '.value'` returning empty or the command
# failing under `2>/dev/null`). $2 = simulated
# PROJECT_CA_CERT_REPO_VAR_FALLBACK env value (empty = no repo var set).
# On success, prints the resolved PEM to stdout and returns 0 — the
# real step instead writes to a mktemp'd file and returns the path via
# $GITHUB_OUTPUT, but the CONTENT + WHICH-BRANCH-FIRED decision is
# identical. On both-empty, prints nothing and returns 1 (mirrors the
# real step's `exit 1`).
resolve_ca() {
  local registry_ca=$1 repo_var_fallback=$2
  if [ -n "$registry_ca" ]; then
    printf '%s' "$registry_ca"
    return 0
  elif [ -n "$repo_var_fallback" ]; then
    printf '%s' "$repo_var_fallback"
    return 0
  else
    return 1
  fi
}

fail=0
check() {
  local description=$1 expected_rc=$2 expected_out=$3 registry_ca=$4 repo_var_fallback=$5
  local actual_out actual_rc
  if actual_out=$(resolve_ca "$registry_ca" "$repo_var_fallback"); then
    actual_rc=0
  else
    actual_rc=$?
  fi
  if [ "$actual_rc" = "$expected_rc" ] && [ "$actual_out" = "$expected_out" ]; then
    echo "ok: $description — rc=$actual_rc out='$actual_out'"
  else
    echo "FAIL: $description — expected rc=$expected_rc out='$expected_out', got rc=$actual_rc out='$actual_out'" >&2
    fail=1
  fi
}

# 1. Registry hit, repo-var ALSO set — registry wins (primary source).
check 'registry-hit → registry value wins even with repo-var fallback set' \
  0 'REGISTRY-PEM' \
  'REGISTRY-PEM' 'REPO-VAR-PEM'

# 2. Registry hit, no repo-var set — registry wins (the common
#    post-migration case: nothing to fall back to, doesn't matter).
check 'registry-hit → registry value wins with no repo-var set' \
  0 'REGISTRY-PEM' \
  'REGISTRY-PEM' ''

# 3. Registry miss, repo-var set — falls back (transitional case).
check 'registry-miss + repo-var-set → falls back to repo var' \
  0 'REPO-VAR-PEM' \
  '' 'REPO-VAR-PEM'

# 4. Both empty — loud failure (non-zero exit, no CA written).
check 'both-empty → loud failure, no CA resolved' \
  1 '' \
  '' ''

if [ "$fail" -ne 0 ]; then
  echo "" >&2
  echo "FAIL: ca-cert-resolution canonical-vector test failed" >&2
  exit 1
fi
echo "all ok"
