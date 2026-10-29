#!/usr/bin/env bash
# Vector test for the sender-facing registry-miss and near-miss notices in
# agent-router.yml (groundnuty/macf#1525). The functions under test are
# EXTRACTED from the workflow, not copied, so they cannot drift from what runs.
#
# Cases:
#   1. A registry miss warns and builds exactly one comment, addressed to the
#      sender, with the agent handle in backticks (never a raw bot mention).
#   2. A second miss with the marker already on the thread builds none.
#   3. All three routes carry an identical copy of the function and call it
#      from their miss branch (no bare "skip and continue" left behind).
#   4. A near-miss "@name" without [bot] is detected outside code, ignored in
#      backticks and fences, and ignored when [bot] follows.
# Mutation at the bottom: restoring the old echo+continue in the mention
# route's miss branch makes case 3 fail.
# Set WF to run against another copy of the workflow.
set -euo pipefail
WF=${WF:-.github/workflows/agent-router.yml}
fail=0
ok() { echo "ok   $1"; }
bad() { echo "FAIL $1"; fail=1; }

# Extract every copy of a marked block, dedented to column 0.
extract_all() { # name -> blocks separated by a NUL-free marker line
  awk -v n="$1" '
    $0 ~ "^ *# >>> " n " " { on=1; sub(/^ */, ""); print; next }
    on && $0 ~ "^ *# <<< " n { sub(/^ */, ""); print; on=0; print "=====BLOCK-END====="; next }
    on { sub(/^          /, ""); print }
  ' "$WF"
}
# Read every line (no early exit): under pipefail an early-exiting reader can SIGPIPE the writer.
first_block() { extract_all "$1" | awk 'done {next} /=====BLOCK-END=====/ {done=1; next} {print}'; }

REG=$(first_block registry_miss_notify)
NEAR=$(first_block near_miss_notify)
[ -n "$REG" ] || { echo "FAIL: could not extract registry_miss_notify from $WF"; exit 1; }
[ -n "$NEAR" ] || { echo "FAIL: could not extract near_miss_notify from $WF"; exit 1; }

# 3a. three identical copies
copies=$(extract_all registry_miss_notify | grep -c '=====BLOCK-END=====' || true)
[ "$copies" = 3 ] && ok "registry_miss_notify present in 3 routes" || bad "registry_miss_notify copies: $copies (want 3)"
uniq_copies=$(extract_all registry_miss_notify | awk '/=====BLOCK-END=====/ {print h; h=""; next} {h=h $0 "\001"}' | sort -u | wc -l | tr -d ' ')
[ "$uniq_copies" = 1 ] && ok "the three copies are identical" || bad "the three copies differ ($uniq_copies variants)"

# 3b. every route's miss branch calls it, and none still skips silently
miss_calls=$(grep -c 'registry_miss_notify "\$AGENT_NAME" "\$VAR_NAME"' "$WF" || true)
[ "$miss_calls" = 3 ] && ok "3 miss branches call registry_miss_notify" || bad "miss branches calling it: $miss_calls (want 3)"
if grep -q 'Registry miss for \${AGENT_NAME} (\${VAR_NAME}); skipping' "$WF"; then
  bad "an old silent 'Registry miss ... skipping' branch is still present"
else
  ok "no silent skip branch remains"
fi

# Fake gh: `gh api` returns $EXISTING; `gh issue comment` records its body.
CALLS=$(mktemp); trap 'rm -f "$CALLS"' EXIT
run_fn() { # fn args... ; env EXISTING
  : > "$CALLS"
  (
    export GITHUB_REPOSITORY=o/r
    gh() {
      case "$1 $2" in
        "api repos/o/r/issues/"*) printf '%s' "${EXISTING:-}" ;;
        "api -X") # POST repos/o/r/issues/<n>/comments -f body=<text>
                  local path="$4" num
                  num=${path#repos/o/r/issues/}; num=${num%/comments}
                  shift 4
                  while [ $# -gt 0 ]; do
                    [ "$1" = "-f" ] && case "$2" in body=*) printf 'COMMENT#%s\n%s\n--END--\n' "$num" "${2#body=}" >> "$CALLS" ;; esac
                    shift
                  done ;;
        *) echo "unexpected gh $*" >&2; return 99 ;;
      esac
    }
    eval "$REG"; eval "$NEAR"
    "$@"
  )
}

# 1. first miss: warning + exactly one comment
out=$(EXISTING="" run_fn registry_miss_notify code-agent ACME_AGENT_CODE_AGENT 12 alice 2>&1)
grep -qF '::warning::Registry miss for code-agent (ACME_AGENT_CODE_AGENT); not delivered' <<<"$out" \
  && ok "miss prints the warning" || bad "miss warning missing: $out"
n=$(grep -c '^COMMENT#' "$CALLS" || true)
[ "$n" = 1 ] && ok "exactly one comment built" || bad "comments built: $n (want 1)"
grep -q '^@alice `code-agent` is not registered, so it did not receive this\. Its channel server is probably not running; tell the operator\.$' "$CALLS" \
  && ok "comment text and sender address match the spec" || { bad "comment text differs"; cat "$CALLS"; }
grep -qF '<!-- macf-registry-miss:code-agent -->' "$CALLS" && ok "comment carries the dedupe marker" || bad "marker missing"
if grep -qE '@[A-Za-z0-9_-]+\[bot\]' "$CALLS"; then bad "comment has a raw bot mention"; else ok "no raw bot mention in the comment"; fi

# 2. marker already on the thread: no comment, still warns
out=$(EXISTING="earlier text <!-- macf-registry-miss:code-agent --> more" run_fn registry_miss_notify code-agent ACME_AGENT_CODE_AGENT 12 alice 2>&1)
n=$(grep -c '^COMMENT#' "$CALLS" || true)
[ "$n" = 0 ] && ok "second miss builds no comment" || bad "second miss built $n comments"
grep -qF '::warning::Registry miss' <<<"$out" && ok "second miss still warns" || bad "second miss lost the warning"

# a different agent's marker does not suppress this agent's comment
EXISTING="<!-- macf-registry-miss:science-agent -->" run_fn registry_miss_notify code-agent V 12 alice >/dev/null 2>&1
n=$(grep -c '^COMMENT#' "$CALLS" || true)
[ "$n" = 1 ] && ok "another agent's marker does not suppress" || bad "other-agent marker suppressed ($n)"

# 4. near-miss detection, on the body after the router's code-context strip
strip_code_context() {
  printf '%s' "$1" | awk '
    /^```/ { inside_fence = !inside_fence; next }
    inside_fence { next }
    { print }
  ' | sed -E 's/`[^`]*`//g'
}
nm() { # body name expected(hit|none) description
  local clean got
  clean=$(strip_code_context "$1")
  got=$(run_fn near_miss_handle "$clean" "$2")
  if [ -n "$got" ] && [ "$3" = hit ]; then ok "$4"
  elif [ -z "$got" ] && [ "$3" = none ]; then ok "$4"
  else bad "$4 (got '$got')"; fi
}
nm 'please look, @code-agent' code-agent hit "bare @name at end is a near-miss"
nm '@code-agent please look' code-agent hit "bare @name at line start is a near-miss"
nm 'cc @macf-code-agent, thanks' macf-code-agent hit "bare @app-name is a near-miss"
nm 'cc `@code-agent` for context' code-agent none "inside inline code is ignored"
nm $'text\n```\n@code-agent\n```\nmore' code-agent none "inside a fence is ignored"
nm 'cc @code-agent[bot] please' code-agent none "with [bot] it is a routed mention, not a near-miss"
nm 'mail a@code-agent.com' code-agent none "an address is not a mention"
nm 'cc @code-agent-2 please' code-agent none "a longer name does not match"
nm 'cc @code-agent[bot] and also @code-agent' code-agent hit "a bare form beside a routed one is still flagged"
nm 'nothing here' code-agent none "no mention at all"

: > "$CALLS"
out=$(EXISTING="" run_fn near_miss_notify code-agent code-agent 7 bob 2>&1)
grep -qF '::notice::near-miss mention @code-agent without [bot]; not routed' <<<"$out" && ok "near-miss prints the notice" || bad "near-miss notice missing"
n=$(grep -c '^COMMENT#' "$CALLS" || true); [ "$n" = 1 ] && ok "near-miss builds one comment" || bad "near-miss comments: $n"
grep -q '^@bob ' "$CALLS" && grep -qF '<!-- macf-near-miss:code-agent -->' "$CALLS" && ok "near-miss comment addressed to sender, with marker" || bad "near-miss comment shape"
grep -E '@code-agent\[bot\]' "$CALLS" | grep -vq '`@code-agent\[bot\]`' && bad "near-miss comment has an unbackticked bot mention" || ok "near-miss suggestion is backticked"
EXISTING="<!-- macf-near-miss:code-agent -->" run_fn near_miss_notify code-agent code-agent 7 bob >/dev/null 2>&1
n=$(grep -c '^COMMENT#' "$CALLS" || true); [ "$n" = 0 ] && ok "near-miss deduped by marker" || bad "near-miss not deduped ($n)"

# A lookup error that is not a 404 must not claim the agent is unregistered.
LOOK=$(first_block registry_miss_notify)
[ -n "$LOOK" ] && grep -q 'registry_lookup_failed()' <<<"$LOOK" && ok "registry_lookup_failed is in the shared block" || bad "registry_lookup_failed missing from the shared block"
n404=$(grep -cF "grep -q 'HTTP 404' \"\${RUNNER_TEMP:-/tmp}/macf-reg-err\"" "$WF" || true)
[ "$n404" = 3 ] && ok "3 lookups tell a 404 apart from other errors" || bad "404 checks: $n404 (want 3)"
nfail=$(grep -c 'registry_lookup_failed "\$AGENT_NAME" "\$VAR_NAME"' "$WF" || true)
[ "$nfail" = 3 ] && ok "3 routes call registry_lookup_failed" || bad "registry_lookup_failed calls: $nfail (want 3)"
out=$(EXISTING="" run_fn registry_lookup_failed code-agent ACME_AGENT_CODE_AGENT 12 alice "HTTP 502: Bad Gateway" 2>&1)
grep -qF '::warning::Registry lookup for code-agent (ACME_AGENT_CODE_AGENT) failed: HTTP 502: Bad Gateway; not delivered' <<<"$out" \
  && ok "lookup failure warns with the error" || bad "lookup failure warning missing"
n=$(grep -c '^COMMENT#' "$CALLS" || true); [ "$n" = 1 ] && ok "lookup failure builds one comment" || bad "lookup-failure comments: $n"
grep -qF 'could not read the registry' "$CALLS" && ! grep -qF 'is not registered' "$CALLS" \
  && ok "lookup-failure comment does not claim the agent is unregistered" || bad "lookup-failure comment wording"
EXISTING="<!-- macf-registry-lookup-failed:code-agent -->" run_fn registry_lookup_failed code-agent V 12 alice "x" >/dev/null 2>&1
n=$(grep -c '^COMMENT#' "$CALLS" || true); [ "$n" = 0 ] && ok "lookup-failure comment deduped by marker" || bad "lookup-failure not deduped ($n)"

# Mutation (only when not already running against a mutated copy): restore the
# old silent skip in the mention route; this test must now FAIL.
if [ -z "${MUTATED:-}" ]; then
  MUT_WF=$(mktemp)
  sed '0,/registry_miss_notify "\$AGENT_NAME" "\$VAR_NAME" "\$VIEW_NUM" "\$ACTOR"/s//echo "Registry miss for ${AGENT_NAME} (${VAR_NAME}); skipping mention route"/' "$WF" > "$MUT_WF"
  cmp -s "$WF" "$MUT_WF" && { bad "mutation did not change the workflow"; }
  echo "-- mutation (expect FAIL below) --"
  mut_out=$(MUTATED=1 WF="$MUT_WF" bash "$0" 2>&1 || true)
  printf '%s\n' "$mut_out" | grep 'FAIL' | sed 's/^/   | /'
  if grep -q '^FAIL' <<<"$mut_out"; then
    ok "mutation detected"
  else
    bad "mutation was not detected"
  fi
  rm -f "$MUT_WF"
fi

exit $fail
