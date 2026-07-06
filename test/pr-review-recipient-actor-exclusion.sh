#!/usr/bin/env bash
# Canonical-vector test for the recipient-set actor-exclusion in
# .github/workflows/agent-router.yml's `route-by-pr-review-state` job
# (groundnuty/macf-actions#68).
#
# The macf#62 Instance-13 closure builds the recipient set as
#   {author} ∪ {body-@mentioned} ∪ {formal reviewers} ∪ {requested reviewers}
# — folding in FORMAL reviewers, which NECESSARILY includes the login that
# just submitted THIS review. Without excluding the actor, the submitting
# reviewer self-notifies (an echo of its own review — verified on
# groundnuty/icsoc-2026-code-agent PR #15, router run 28758802015).
#
# The fix (must match the inline implementation): resolve REVIEWER_LOGIN
# (= github.event.review.user.login) → its registry key (REVIEWER_AGENT)
# and skip it at add_recipient (the single choke-point covering all four
# sources). A human/unregistered submitter resolves to "" → guard inert.

set -euo pipefail

# ── Replicated verbatim from the workflow's route-by-pr-review-state step. ──
# AGENTS + REVIEWER_LOGIN are the inputs; RECIPIENTS is the output under test.
build_recipients() {
  AGENTS="$1"
  REVIEWER_LOGIN="$2"
  # $3.. = "source_kind:login-or-key" adds, in order, e.g. "login:foo[bot]" / "key:code-agent"
  shift 2

  RECIPIENTS=""

  REVIEWER_AGENT=""
  for CANDIDATE in $(echo "$AGENTS" | jq -r 'keys[]'); do
    APP_NAME=$(echo "$AGENTS" | jq -r --arg a "$CANDIDATE" '.[$a].app_name // empty')
    if [ -n "$APP_NAME" ] && [ "$REVIEWER_LOGIN" = "${APP_NAME}[bot]" ]; then
      REVIEWER_AGENT="$CANDIDATE"
      break
    fi
  done

  add_recipient() {
    [ -n "$REVIEWER_AGENT" ] && [ "$1" = "$REVIEWER_AGENT" ] && return 0  # #68
    case " $RECIPIENTS " in
      *" $1 "*) ;;
      *) RECIPIENTS="${RECIPIENTS:+$RECIPIENTS }$1" ;;
    esac
  }

  add_recipient_by_login() {
    login="$1"
    for CANDIDATE in $(echo "$AGENTS" | jq -r 'keys[]'); do
      APP_NAME=$(echo "$AGENTS" | jq -r --arg a "$CANDIDATE" '.[$a].app_name // empty')
      if [ -n "$APP_NAME" ] && [ "$login" = "${APP_NAME}[bot]" ]; then
        add_recipient "$CANDIDATE"
        return 0
      fi
    done
  }

  for add in "$@"; do
    kind="${add%%:*}"; val="${add#*:}"
    case "$kind" in
      login) add_recipient_by_login "$val" ;;
      key)   add_recipient "$val" ;;
    esac
  done

  echo "$RECIPIENTS"
}

# A 3-agent fleet with the DR-032 double-prefixed App handles (icsoc shape),
# so the login→key resolution (handle+[bot] → bare routing label) is exercised.
AGENTS='{
  "code-agent":    {"app_name":"icsoc-2026-code-agent"},
  "science-agent": {"app_name":"icsoc-2026-science-agent"},
  "paper-agent":   {"app_name":"icsoc-2026-paper-agent"}
}'

fail=0
check() {
  local description=$1 expected=$2 actual=$3
  # Order-insensitive compare (RECIPIENTS is a set).
  local e a
  e=$(printf '%s\n' $expected | sort | tr '\n' ' ')
  a=$(printf '%s\n' $actual  | sort | tr '\n' ' ')
  if [ "$e" = "$a" ]; then
    echo "ok: $description — [$actual]"
  else
    echo "FAIL: $description — expected [{$expected}] got [{$actual}]" >&2
    fail=1
  fi
}

# 1. The PR #15 shape: author=code, submitter=science (a formal reviewer).
#    science must be EXCLUDED (the self-echo bug); code must be included.
check 'submitting reviewer excluded, author included' \
  'code-agent' \
  "$(build_recipients "$AGENTS" 'icsoc-2026-science-agent[bot]' \
      'login:icsoc-2026-code-agent[bot]' 'login:icsoc-2026-science-agent[bot]')"

# 2. Submitter also @mentioned in its own review body (add via key) — still excluded.
check 'submitter self-mention in body also excluded' \
  'code-agent' \
  "$(build_recipients "$AGENTS" 'icsoc-2026-science-agent[bot]' \
      'login:icsoc-2026-code-agent[bot]' 'key:science-agent' 'login:icsoc-2026-science-agent[bot]')"

# 3. Instance-13 preserved: a THIRD-agent formal reviewer (paper), NOT the
#    submitter, is still included (the gate-owner case #62 exists for).
check 'non-submitter formal reviewer still included (Instance-13 preserved)' \
  'code-agent paper-agent' \
  "$(build_recipients "$AGENTS" 'icsoc-2026-science-agent[bot]' \
      'login:icsoc-2026-code-agent[bot]' 'login:icsoc-2026-paper-agent[bot]' 'login:icsoc-2026-science-agent[bot]')"

# 4. Human/unregistered submitter → REVIEWER_AGENT="" → guard inert, author added.
check 'unregistered submitter → guard inert, normal recipients' \
  'code-agent' \
  "$(build_recipients "$AGENTS" 'some-human' 'login:icsoc-2026-code-agent[bot]')"

# 5. Self-review (author IS the submitter): author excluded → empty set.
check 'self-review → submitter-author excluded → empty' \
  '' \
  "$(build_recipients "$AGENTS" 'icsoc-2026-code-agent[bot]' 'login:icsoc-2026-code-agent[bot]')"

if [ "$fail" -ne 0 ]; then
  echo "" >&2
  echo "FAILED: at least one recipient-set check did not match expected" >&2
  exit 1
fi

echo ""
echo "all checks passed"
