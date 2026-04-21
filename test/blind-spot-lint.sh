#!/usr/bin/env bash
# Static-analysis guard against the 3 known "self-test blind spot"
# patterns that bit v3.0.x in quick succession (#20, #22, #25). Full
# dynamic validation — running the reusable from a real external
# caller pre-tag — is still TBD (#24 remaining scope). This script
# is the cheap-but-accurate partial: greps agent-router.yml for the
# specific YAML patterns that those 3 bugs shipped, fails CI if any
# reappear.
#
# Each pattern below references the issue that introduced it, so a
# future contributor re-adding a blocked pattern sees not just
# "forbidden" but *why*.

set -euo pipefail

WORKFLOW=".github/workflows/agent-router.yml"
if [ ! -f "$WORKFLOW" ]; then
  echo "error: $WORKFLOW not found; run from repo root" >&2
  exit 1
fi

fail=0
forbid() {
  local pattern=$1 reason=$2 issue=$3
  # Match only in NON-comment lines. Our comments reference these
  # patterns legitimately (explaining past bugs); we don't want to
  # flag them. Strip leading-whitespace + # comment lines before
  # matching. Also filter inline comments (anything after a #).
  # Grep matching lines with line numbers, then filter out comment-only
  # lines (lines whose first non-whitespace char is #). Comments
  # legitimately reference these patterns to explain history, so we
  # don't want to flag them.
  local hits
  hits=$(grep -n -E "$pattern" "$WORKFLOW" \
    | awk -F: '{
        # reconstruct the line content after the NN: prefix in case
        # content contains additional colons
        content=""
        for (i=2;i<=NF;i++) content=(i==2?$i:content":"$i)
        # skip comment-only lines
        trimmed=content
        sub(/^[[:space:]]+/, "", trimmed)
        if (substr(trimmed, 1, 1) != "#") print $0
      }' || true)
  if [ -n "$hits" ]; then
    echo "FAIL: forbidden pattern in $WORKFLOW (#$issue — $reason)" >&2
    echo "  pattern: $pattern" >&2
    echo "$hits" | sed 's/^/  /' >&2
    fail=1
  fi
}

# Pattern 1 (#20): `permission-variables:` is not a valid input on
# actions/create-github-app-token@v3. The action silently drops
# unknown inputs → token request passes it to GitHub's API → 422
# "permissions not granted to this installation". Any permission-*
# subsetting belongs in the App's grants, not in the step input.
forbid 'permission-variables:' \
  "not a valid create-github-app-token@v3 input; use narrow-App-scope instead" \
  20

# Pattern 2 (#22): `uses: ./.github/actions/...` in a reusable
# workflow resolves against the CALLER's filesystem, not the
# reusable's. Breaks every external caller that doesn't happen to
# have the same path on disk.
forbid 'uses:[[:space:]]*\./\.github/actions/' \
  "local \`uses: ./...\` resolves against caller filesystem in reusables; inline the logic or use cross-repo ref" \
  22

# Pattern 3 (#25): `github.workflow_sha` in a reusable workflow is
# the CALLER's commit SHA, not the reusable's. Any context-based
# pinning to "this workflow's commit" is silently caller-scoped.
# Community#31054 documents this; parse `github.workflow_ref`
# instead, OR avoid cross-repo dependencies entirely.
forbid 'github\.workflow_sha' \
  "is caller-scoped in reusable workflows (community#31054); use workflow_ref parse or inline the logic" \
  25

if [ "$fail" -ne 0 ]; then
  echo "" >&2
  echo "Blind-spot lint failed. These patterns have shipped bugs to every v3 external caller," >&2
  echo "invisible to self-routing tests. Fix before merge. Background in macf-actions#24." >&2
  exit 1
fi

echo "blind-spot lint: 3 patterns checked, all clear"
