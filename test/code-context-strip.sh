#!/usr/bin/env bash
# Canonical-vector test for the Markdown code-context strip applied to
# $BODY before @mention substring matching in .github/workflows/agent-
# router.yml's `route-by-mention` job. Per groundnuty/macf-actions#33:
# bodies that mention @bot[bot] inside ```...``` fences or `inline` code
# (e.g. PR descriptions quoting future trigger heredoc content, or
# scenario test-case documentation) should NOT fire routing —
# `mention-routing-hygiene.md` (canonical) prescribes backticking
# describing-context handles, but the pre-#33 matcher ignored GitHub's
# autolink semantics.
#
# Pipeline tested (must match the inline implementation in
# agent-router.yml's `Route to mentioned agents` step):
#
#   awk '/^```/ { inside_fence = !inside_fence; next }
#        inside_fence { next }
#        { print }' | sed -E 's/`[^`]*`//g'
#
# ReDoS-safe: awk patterns line-anchored, sed bounded by [^`]*. No
# backtracking on either.

set -euo pipefail

strip_code_context() {
  printf '%s' "$1" | awk '
    /^```/ { inside_fence = !inside_fence; next }
    inside_fence { next }
    { print }
  ' | sed -E 's/`[^`]*`//g'
}

fail=0
check_match() {
  local description=$1
  local body=$2
  local needle=$3
  local expected=$4  # 'should-match' or 'should-not-match'
  local cleaned
  cleaned=$(strip_code_context "$body")
  local actual='no-match'
  if printf '%s' "$cleaned" | grep -qF -e "$needle"; then
    actual='match'
  fi

  case "$expected" in
    should-match)
      if [ "$actual" = 'match' ]; then
        echo "ok: $description — '$needle' matched (expected)"
      else
        echo "FAIL: $description — '$needle' did NOT match (expected to match)" >&2
        fail=1
      fi
      ;;
    should-not-match)
      if [ "$actual" = 'no-match' ]; then
        echo "ok: $description — '$needle' did NOT match (correctly stripped)"
      else
        echo "FAIL: $description — '$needle' matched (expected to be stripped from code-context)" >&2
        fail=1
      fi
      ;;
  esac
}

# ─── Positive cases (should match — body has handle in non-code-context) ───

check_match \
  'raw mention in plain prose' \
  'Hello @macf-tester-1-agent[bot] please review.' \
  '@macf-tester-1-agent[bot]' \
  should-match

check_match \
  'raw mention at end of paragraph' \
  'Standing by, @macf-code-agent[bot]' \
  '@macf-code-agent[bot]' \
  should-match

check_match \
  'raw mention with surrounding inline code (handle itself NOT in code)' \
  'After running `gh issue view`, @macf-science-agent[bot] should review.' \
  '@macf-science-agent[bot]' \
  should-match

check_match \
  'raw mention with adjacent inline code on a separate phrase' \
  'See `coordination.md` for context. @macf-tester-2-agent[bot] please ack.' \
  '@macf-tester-2-agent[bot]' \
  should-match

# ─── Negative cases (should NOT match — handle inside code-context) ───

check_match \
  'handle inside inline code spans' \
  'The describing convention is `@macf-tester-2-agent[bot]` per the rule.' \
  '@macf-tester-2-agent[bot]' \
  should-not-match

check_match \
  'handle inside fenced block (no language hint)' \
  'PR body example:

```
@macf-tester-2-agent[bot] please pick up this scenario.
```

End of example.' \
  '@macf-tester-2-agent[bot]' \
  should-not-match

check_match \
  'handle inside fenced block with language hint' \
  'Heredoc:

```bash
ISSUE_BODY="@macf-tester-1-agent[bot] please verify"
```

That is the trigger content.' \
  '@macf-tester-1-agent[bot]' \
  should-not-match

check_match \
  'handle inside fenced block + outside both occurrences' \
  'Trigger: `@macf-code-agent[bot]` reviews via:

```
@macf-tester-2-agent[bot] (this is documentation only)
```

But @macf-code-agent[bot] addressing here is the actual ping.' \
  '@macf-code-agent[bot]' \
  should-match

check_match \
  'tester-2 handle in fenced + tester-1 handle outside — only tester-1 should match' \
  'Doc:

```
The pattern is `@macf-tester-2-agent[bot]` — describes only.
```

Real call: @macf-tester-1-agent[bot] please pick up.' \
  '@macf-tester-1-agent[bot]' \
  should-match

check_match \
  'same body — tester-2 should NOT match (only inside fence + inline code)' \
  'Doc:

```
The pattern is `@macf-tester-2-agent[bot]` — describes only.
```

Real call: @macf-tester-1-agent[bot] please pick up.' \
  '@macf-tester-2-agent[bot]' \
  should-not-match

# ─── Edge cases ───

check_match \
  'multiple fences in one body — all stripped' \
  'First example:

```
@macf-tester-2-agent[bot]
```

Some prose.

Second example:

```bash
@macf-tester-1-agent[bot]
```

End.' \
  '@macf-tester-1-agent[bot]' \
  should-not-match

check_match \
  'inline code with backslash backticks does NOT span (still bounded)' \
  'Both `@macf-tester-2-agent[bot]` and `@macf-code-agent[bot]` are described.' \
  '@macf-tester-2-agent[bot]' \
  should-not-match

check_match \
  'inline code with backslash backticks does NOT span (other handle also stripped)' \
  'Both `@macf-tester-2-agent[bot]` and `@macf-code-agent[bot]` are described.' \
  '@macf-code-agent[bot]' \
  should-not-match

check_match \
  'fence containing backticks inside (closing fence not at line start)' \
  'Example with inline backticks inside a fence:

```
The example: @macf-tester-1-agent[bot] is `inline-backticked` here.
```

End.' \
  '@macf-tester-1-agent[bot]' \
  should-not-match

# ─── Final result ───

if [ "$fail" -ne 0 ]; then
  echo "" >&2
  echo "FAILED: at least one check did not match expected behavior" >&2
  exit 1
fi

echo ""
echo "all checks passed"
