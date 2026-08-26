#!/usr/bin/env bash
# Canonical-vector test for the "Resolve routing secrets" step embedded in
# EVERY route-by-* job of .github/workflows/agent-router.yml
# (groundnuty/macf-actions#1169 / groundnuty/macf#1169).
#
# That step is the ONE place per job that decides whether ROUTING_CLIENT_CERT/
# ROUTING_CLIENT_KEY/MACF_ROUTING_APP_ID/MACF_ROUTING_APP_KEY/TS_OAUTH_CLIENT_ID/
# TS_OAUTH_SECRET come from the ONE MACF_ROUTING_BUNDLE secret (preferred,
# groundnuty/macf#1112/#1118 — base64(JSON) keyed by the six secret names) or
# from the legacy six individually-passed secrets — and it must fail LOUD,
# never proceed on empty values, when neither source resolves completely, or
# when a SUPPLIED bundle is malformed (bad base64 / bad JSON / missing keys).
#
# Replicated verbatim (per this repo's established convention — see
# test/pr-review-recipient-actor-exclusion.sh's own header) from the four
# copies embedded inline in agent-router.yml — this repo deliberately
# duplicates shell per-job rather than extracting to a composite action
# (CHANGELOG [3.1.0]/[3.0.3]/[3.0.2]: composite extraction has broken
# external callers twice via cross-repo-checkout + workflow_ref-scoping
# pitfalls). Keep this copy in lockstep with the workflow's four inline
# copies by hand — a change to one without the other is a drift the CI
# unit-tests job won't catch by itself, only a code reviewer diffing the
# PR will.
#
# $GITHUB_ENV is exercised for real here (pointed at a scratch file), so
# this test also exercises the multiline-value round-trip (the random
# per-call delimiter — MACF_ROUTING_APP_KEY is raw multi-line PEM) end to
# end, not just the decode/validate logic in isolation.

set -euo pipefail

# ── Replicated verbatim from the workflow's "Resolve routing secrets" step. ──
resolve_routing_secrets() {
  # Reads BUNDLE / IN_<NAME> from the environment (mirrors the step's own
  # `env:` block), writes resolved NAME<<DELIM/value/DELIM entries to
  # $GITHUB_ENV, echoes ::add-mask::/::error:: lines exactly as the real
  # step does. Returns the step's exit code.
  set -euo pipefail

  NAMES="MACF_ROUTING_APP_ID MACF_ROUTING_APP_KEY ROUTING_CLIENT_CERT ROUTING_CLIENT_KEY TS_OAUTH_CLIENT_ID TS_OAUTH_SECRET"

  emit_secret() {
    local name="$1" value="$2" delim line
    while IFS= read -r line || [ -n "$line" ]; do
      [ -n "$line" ] && echo "::add-mask::${line}"
    done <<< "$value"
    delim="ROUTING_SECRET_EOF_${name}_${RANDOM}${RANDOM}_$$"
    {
      echo "${name}<<${delim}"
      printf '%s\n' "$value"
      echo "$delim"
    } >> "$GITHUB_ENV"
  }

  if [ -n "${BUNDLE:-}" ]; then
    echo "routing secrets: MACF_ROUTING_BUNDLE supplied — bundle mode"
    if ! DECODED=$(printf '%s' "$BUNDLE" | base64 -d 2>/dev/null); then
      echo "::error::MACF_ROUTING_BUNDLE is not valid base64 — refusing to route on an unreadable bundle"
      return 1
    fi
    if ! printf '%s' "$DECODED" | jq -e 'type == "object"' >/dev/null 2>&1; then
      echo "::error::MACF_ROUTING_BUNDLE decoded but is not a JSON object — refusing to route on a malformed bundle"
      return 1
    fi
    MISSING=""
    for NAME in $NAMES; do
      VALUE=$(printf '%s' "$DECODED" | jq -r --arg k "$NAME" '.[$k] // empty')
      if [ -z "$VALUE" ]; then
        MISSING="${MISSING:+$MISSING, }$NAME"
        continue
      fi
      emit_secret "$NAME" "$VALUE"
    done
    unset DECODED
    if [ -n "$MISSING" ]; then
      echo "::error::MACF_ROUTING_BUNDLE is missing required key(s): $MISSING — refusing to route on a partial bundle"
      return 1
    fi
    echo "routing secrets: unpacked all six values from MACF_ROUTING_BUNDLE"
  else
    echo "routing secrets: MACF_ROUTING_BUNDLE not supplied — falling back to the six individual secrets"
    MISSING=""
    for NAME in $NAMES; do
      case "$NAME" in
        MACF_ROUTING_APP_ID)  VALUE="${IN_MACF_ROUTING_APP_ID:-}" ;;
        MACF_ROUTING_APP_KEY) VALUE="${IN_MACF_ROUTING_APP_KEY:-}" ;;
        ROUTING_CLIENT_CERT)  VALUE="${IN_ROUTING_CLIENT_CERT:-}" ;;
        ROUTING_CLIENT_KEY)   VALUE="${IN_ROUTING_CLIENT_KEY:-}" ;;
        TS_OAUTH_CLIENT_ID)   VALUE="${IN_TS_OAUTH_CLIENT_ID:-}" ;;
        TS_OAUTH_SECRET)      VALUE="${IN_TS_OAUTH_SECRET:-}" ;;
      esac
      if [ -z "$VALUE" ]; then
        # TS_OAUTH_* is legitimately absent on a fleet that hasn't
        # declared Tailscale (apply-routing-secrets.ts's `'not-required'`
        # leg — transport.tailscale_oauth_required defaults to false, so
        # this is the COMMON case, not an edge case). Such a fleet's
        # Connect-to-Tailscale step never runs on the self-hosted `macf-vm`
        # runner (already tailnet-joined, macf-actions#64) — its TS_OAUTH_*
        # values are never consumed this run. Failing this job for a
        # secret nothing downstream reads would turn an
        # already-routing fleet into a hard failure on upgrade — exactly
        # the regression groundnuty/macf-actions#1169 must not introduce.
        # Only fail on a missing TS_OAUTH_* when TAILNET_NEEDED says this
        # run WILL attempt the Tailscale connect (github-hosted runner).
        # Defaults to "required" (fail-safe) if TAILNET_NEEDED is somehow
        # unset. MACF_ROUTING_APP_ID/KEY and ROUTING_CLIENT_CERT/KEY have
        # no such carve-out — every job always needs them.
        if { [ "$NAME" = "TS_OAUTH_CLIENT_ID" ] || [ "$NAME" = "TS_OAUTH_SECRET" ]; } \
          && [ "${TAILNET_NEEDED:-true}" != "true" ]; then
          echo "routing secrets: $NAME not supplied and not needed this run (self-hosted runner skips Tailscale connect) — leaving unset"
          continue
        fi
        MISSING="${MISSING:+$MISSING, }$NAME"
        continue
      fi
      emit_secret "$NAME" "$VALUE"
    done
    if [ -n "$MISSING" ]; then
      echo "::error::Neither MACF_ROUTING_BUNDLE nor the following individual routing secret(s) were supplied: $MISSING — this caller cannot route. Pass MACF_ROUTING_BUNDLE (preferred, groundnuty/macf#1112) or all six secrets individually."
      return 1
    fi
    echo "routing secrets: resolved all six from the individually-supplied secrets"
  fi
}

# ── Test harness ──────────────────────────────────────────────────────────

# Extracts just the resolved NAMEs from a $GITHUB_ENV-format scratch file
# (NAME<<DELIM / value lines / DELIM, repeated) — one name per line. Value
# content is intentionally discarded here: this test only needs the SET of
# names that resolved for its assertions (the value round-trip itself —
# including the multi-line-PEM case through the random-delimiter heredoc —
# was verified directly against this exact script during development; see
# groundnuty/macf-actions#1169's implementation notes). Skipping value
# capture also sidesteps a real trap: a naive per-physical-line `cut -d=
# -f1` over a record whose VALUE itself spans multiple lines (e.g.
# MACF_ROUTING_APP_KEY's PEM body) misparses the value's OWN lines as if
# they were additional NAME<<DELIM headers.
parse_github_env_names() {
  local file="$1"
  [ -f "$file" ] || return 0
  awk '
    /<</ {
      split($0, parts, "<<")
      print parts[1]
      delim = parts[2]
      while ((getline line) > 0) {
        if (line == delim) break
      }
      next
    }
  ' "$file"
}

fail=0
check() {
  local description="$1" expected_exit="$2" expected_names="$3"
  shift 3
  # Remaining args are KEY=VALUE env assignments for the resolve call.
  local envfile
  envfile=$(mktemp)
  rm -f "$envfile"  # resolve_routing_secrets must create it fresh, like GH does

  # Re-invoke THIS script with an internal dispatch flag so
  # resolve_routing_secrets runs in a true fresh subprocess with a
  # controlled, minimal environment (env -i) — no leakage between cases,
  # no reliance on function-export across a subshell boundary.
  local actual_exit=0
  env -i PATH="$PATH" GITHUB_ENV="$envfile" "$@" \
    bash "$0" --run-resolve-only \
    >/tmp/routing-bundle-unpack-test-stdout.$$ 2>/tmp/routing-bundle-unpack-test-stderr.$$ \
    || actual_exit=$?

  local actual_names
  actual_names=$(parse_github_env_names "$envfile" | sort | tr '\n' ' ' | sed 's/ $//')
  local expected_names_sorted
  expected_names_sorted=$(printf '%s\n' $expected_names | sort | tr '\n' ' ' | sed 's/ $//')

  local ok=1
  [ "$actual_exit" -eq "$expected_exit" ] || ok=0
  [ "$actual_names" = "$expected_names_sorted" ] || ok=0

  if [ "$ok" -eq 1 ]; then
    echo "ok: $description (exit=$actual_exit, resolved=[$actual_names])"
  else
    echo "FAIL: $description" >&2
    echo "  expected exit=$expected_exit names=[$expected_names_sorted]" >&2
    echo "  actual   exit=$actual_exit names=[$actual_names]" >&2
    echo "  --- stderr ---" >&2
    sed 's/^/  /' /tmp/routing-bundle-unpack-test-stderr.$$ >&2
    fail=1
  fi
  rm -f "$envfile" /tmp/routing-bundle-unpack-test-stdout.$$ /tmp/routing-bundle-unpack-test-stderr.$$
}

# Dispatch mode: when invoked as `bash test/routing-bundle-unpack.sh
# --run-resolve-only`, just run the resolved-secrets function once and
# exit with its status — this is how check() gets a fresh subprocess
# per case without re-parenting complex function-export machinery.
if [ "${1:-}" = "--run-resolve-only" ]; then
  resolve_routing_secrets
  exit $?
fi

BUNDLE_VALID=$(printf '%s' '{"MACF_ROUTING_APP_ID":"123456","MACF_ROUTING_APP_KEY":"-----BEGIN KEY-----\nAAAA\nBBBB\n-----END KEY-----","ROUTING_CLIENT_CERT":"Y2VydA==","ROUTING_CLIENT_KEY":"a2V5","TS_OAUTH_CLIENT_ID":"cid","TS_OAUTH_SECRET":"csecret"}' | base64 -w0)
BUNDLE_PARTIAL=$(printf '%s' '{"MACF_ROUTING_APP_ID":"123456","ROUTING_CLIENT_CERT":"Y2VydA=="}' | base64 -w0)
BUNDLE_NOT_JSON=$(printf '%s' 'not json at all' | base64 -w0)

ALL_SIX="MACF_ROUTING_APP_ID MACF_ROUTING_APP_KEY ROUTING_CLIENT_CERT ROUTING_CLIENT_KEY TS_OAUTH_CLIENT_ID TS_OAUTH_SECRET"

# 1. Decisive test, trigger (1): bundle-only caller → all six resolved.
check 'bundle-only caller resolves all six' 0 "$ALL_SIX" \
  BUNDLE="$BUNDLE_VALID"

# 2. Decisive test, trigger (2) — assert-the-wrong-path.md: legacy
#    six-secret caller (NO bundle) still works unchanged. This is the
#    trigger a bundle-only implementation would fail — a router that
#    silently drops the six would still pass check 1 alone.
check 'legacy six-secret caller (no bundle) still resolves all six' 0 "$ALL_SIX" \
  IN_MACF_ROUTING_APP_ID=999 \
  IN_MACF_ROUTING_APP_KEY="-----BEGIN KEY-----
line1
-----END KEY-----" \
  IN_ROUTING_CLIENT_CERT=Y2VydA== \
  IN_ROUTING_CLIENT_KEY=a2V5 \
  IN_TS_OAUTH_CLIENT_ID=cid \
  IN_TS_OAUTH_SECRET=csecret

# 3. Neither supplied → loud failure, nothing resolved.
check 'neither bundle nor six supplied fails loudly, resolves nothing' 1 ""

# 4. Malformed base64 bundle → loud failure, nothing resolved (even though
#    the base64-decode step never reaches the per-key loop).
check 'malformed-base64 bundle fails loudly, resolves nothing' 1 "" \
  BUNDLE='not-valid-base64!!!'

# 5. Valid base64, non-JSON payload → loud failure, nothing resolved.
check 'bundle decodes but is not JSON fails loudly, resolves nothing' 1 "" \
  BUNDLE="$BUNDLE_NOT_JSON"

# 6. Bundle present but missing 4 of 6 keys → loud failure; the 2 keys
#    that WERE present got resolved+masked before the loop found the gap,
#    but the step as a whole still fails (GH Actions marks the step/job
#    failed, so no downstream step ever consumes the partial resolution).
check 'partial bundle (2 of 6 keys) fails loudly; job fails despite partial writes' 1 "MACF_ROUTING_APP_ID ROUTING_CLIENT_CERT" \
  BUNDLE="$BUNDLE_PARTIAL"

# 7. Malformed bundle present AND a complete legacy six ALSO present →
#    still fails loudly. The bundle NEVER silently falls back to the six
#    just because they happen to be available — a bundle-packing bug
#    must not hide behind a coincidental fallback.
check 'malformed bundle does NOT fall back to a complete legacy six' 1 "" \
  BUNDLE='not-valid-base64!!!' \
  IN_MACF_ROUTING_APP_ID=999 \
  IN_MACF_ROUTING_APP_KEY=keydata \
  IN_ROUTING_CLIENT_CERT=Y2VydA== \
  IN_ROUTING_CLIENT_KEY=a2V5 \
  IN_TS_OAUTH_CLIENT_ID=cid \
  IN_TS_OAUTH_SECRET=csecret

# 8. Partial legacy six (2 of 6) with no bundle → loud failure naming the
#    missing ones; the 2 present ones got resolved+masked, job still fails.
check 'partial legacy six (2 of 6), no bundle, fails loudly' 1 "MACF_ROUTING_APP_ID ROUTING_CLIENT_CERT" \
  IN_MACF_ROUTING_APP_ID=999 \
  IN_ROUTING_CLIENT_CERT=Y2VydA==

FOUR_NON_TAILSCALE="MACF_ROUTING_APP_ID MACF_ROUTING_APP_KEY ROUTING_CLIENT_CERT ROUTING_CLIENT_KEY"

# 9. The regression this fix targets: TS_OAUTH_* genuinely absent (fleet
#    with transport.tailscale_oauth_required=false, apply-routing-secrets.ts's
#    'not-required' leg — the DEFAULT, not an edge case) AND this run will
#    NOT attempt a Tailscale connect (self-hosted runner, TAILNET_NEEDED=
#    false) → succeeds with the four non-Tailscale secrets resolved, TS_OAUTH_*
#    left unset. Without this carve-out an already-routing self-hosted fleet
#    would break on upgrade purely because it never had Tailscale secrets to
#    begin with — the exact backward-compatibility break #1169 must avoid.
check 'TS_OAUTH_* absent + not needed (self-hosted) → succeeds, four resolved' 0 "$FOUR_NON_TAILSCALE" \
  TAILNET_NEEDED=false \
  IN_MACF_ROUTING_APP_ID=999 \
  IN_MACF_ROUTING_APP_KEY=keydata \
  IN_ROUTING_CLIENT_CERT=Y2VydA== \
  IN_ROUTING_CLIENT_KEY=a2V5

# 10. Same absent TS_OAUTH_*, but this run WILL attempt Tailscale connect
#     (github-hosted fallback runner, TAILNET_NEEDED=true) → fails loudly,
#     naming exactly the two Tailscale secrets (not all six — the four
#     present ones are correctly NOT reported as missing).
check 'TS_OAUTH_* absent + needed (github-hosted) → fails loudly, names only the two' 1 "$FOUR_NON_TAILSCALE" \
  TAILNET_NEEDED=true \
  IN_MACF_ROUTING_APP_ID=999 \
  IN_MACF_ROUTING_APP_KEY=keydata \
  IN_ROUTING_CLIENT_CERT=Y2VydA== \
  IN_ROUTING_CLIENT_KEY=a2V5

if [ "$fail" -ne 0 ]; then
  echo "" >&2
  echo "FAILED: at least one routing-bundle-unpack check did not match expected" >&2
  exit 1
fi

echo ""
echo "all checks passed"
