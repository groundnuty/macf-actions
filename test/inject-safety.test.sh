#!/usr/bin/env bash
# macf-actions#47 — injection-safety test for the router's prompt-send path.
#
# Proves the base64 data-passing pattern used by agent-router.yml's four send
# sites (route-by-label / -mention / -ci-completion / -pr-review-state) carries
# attacker-controllable event text (PR_TITLE, comment/label text) to the remote
# WITHOUT it ever being interpreted as command/prompt context — and that it
# arrives byte-for-byte intact (no `tr -d`-style mangling).
#
# Two properties per hostile input:
#   (1) SAFETY  — nothing in the payload executes on the local runner OR the
#                 simulated remote shell (no side-effect file appears).
#   (2) FIDELITY — the value the remote helper receives as argv equals the
#                  original payload exactly (passed as opaque data, not stripped).
#
# `fake_ssh` simulates the REMOTE shell: it runs the command string the router
# builds, exactly as a real sshd would. The fake `helper` records its $2 (the
# prompt argv) so we can assert fidelity. If any payload broke out of data
# context, it would `touch $PWNED_DIR/<name>` and the safety assertion fails.
#
# Run: bash test/inject-safety.test.sh   (no CI harness in this repo yet)
set -uo pipefail

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
PWNED_DIR="$WORK/pwned"; mkdir -p "$PWNED_DIR"
RECV="$WORK/received_prompt"

# Fake remote helper: records the prompt argv it was handed.
HELPER="$WORK/helper.sh"
cat > "$HELPER" <<HELPER_EOF
#!/usr/bin/env bash
printf '%s' "\$2" > "$RECV"
HELPER_EOF
chmod +x "$HELPER"

# Simulate the remote shell executing the router's built command string.
fake_ssh() { bash -c "$1"; }

TARGET="proj@agent"
fails=0

# This MUST mirror the send pattern in .github/workflows/agent-router.yml
# (helper path). If you change the workflow's send, change this in lockstep.
route_send() {
  local prompt="$1" prompt_b64
  prompt_b64=$(printf '%s' "$prompt" | base64 | tr -d '\n')
  # Local build of the remote command (HELPER/TARGET are trusted config; the
  # prompt rides as base64 and is decoded into a remote-quoted var).
  fake_ssh "PROMPT=\$(printf %s '${prompt_b64}' | base64 -d) && '${HELPER}' '${TARGET}' \"\$PROMPT\""
}

check() {
  local name="$1" payload="$2"
  : > "$RECV"
  route_send "$payload"
  # (1) safety: no execution side-effect anywhere
  if [ -n "$(ls -A "$PWNED_DIR" 2>/dev/null)" ]; then
    echo "FAIL [$name]: payload EXECUTED — $(ls -A "$PWNED_DIR")"; rm -f "$PWNED_DIR"/*; fails=$((fails+1)); return
  fi
  # (2) fidelity: the helper received the payload byte-for-byte
  local got; got="$(cat "$RECV")"
  if [ "$got" != "$payload" ]; then
    echo "FAIL [$name]: prompt mangled in transit"; printf '  want: %q\n  got:  %q\n' "$payload" "$got"; fails=$((fails+1)); return
  fi
  echo "PASS [$name]"
}

# Hostile PR titles / event text. Each tries a different breakout.
check "command-substitution"  'PR title $(touch '"$PWNED_DIR"'/cmdsub)'
check "backticks"             'PR title `touch '"$PWNED_DIR"'/backtick`'
check "single-quote-break"    "'; touch $PWNED_DIR/quotebreak; echo '"
check "double-quote-break"    'x"; touch '"$PWNED_DIR"'/dquote; echo "y'
check "semicolon-and-amp"     'a; touch '"$PWNED_DIR"'/semi && touch '"$PWNED_DIR"'/amp'
check "newline-injection"     "$(printf 'line1\ntouch %s/newline\nline2' "$PWNED_DIR")"
check "benign-with-marker"    'PR #5 ("Fix the thing"): CI SUCCESS. [macf-route:123:code-agent]'

# Negative control: the OLD interpolated+single-quoted pattern (no base64) MUST
# execute the quote-break payload — proving these assertions actually have teeth.
old_pattern_executes() {
  local payload="$1"
  fake_ssh "'${HELPER}' '${TARGET}' '${payload}'"   # the pre-#47 vulnerable form
}
: > "$RECV"; rm -f "$PWNED_DIR"/*
old_pattern_executes "'; touch $PWNED_DIR/CONTROL; echo '"
if [ -f "$PWNED_DIR/CONTROL" ]; then
  echo "PASS [negative-control]: pre-#47 pattern is injectable (test has teeth)"; rm -f "$PWNED_DIR"/*
else
  echo "FAIL [negative-control]: control payload did NOT execute — test cannot detect injection"; fails=$((fails+1))
fi

echo "---"
if [ "$fails" -eq 0 ]; then echo "ALL INJECTION-SAFETY CHECKS PASSED"; exit 0; else echo "$fails CHECK(S) FAILED"; exit 1; fi
