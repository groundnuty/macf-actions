#!/usr/bin/env bash
# Canonical-vector test for the "Assert one complete routing-secrets form
# before any work" step embedded in the `pick-runner` job of
# .github/workflows/agent-router.yml (groundnuty/macf-actions#82).
#
# Prior to #82, "required: false" on all seven routing secrets removed the
# composition-time failure a misconfigured caller used to get, without
# replacing it with anything at RUN time in the workflow's FIRST job — a
# caller supplying neither form (bundle nor six) only found out once one of
# the four route-by-* jobs actually happened to trigger (each of which has
# its OWN "Resolve routing secrets" step — see test/routing-bundle-unpack.sh
# for that one). This step closes the gap: it runs as the LAST step of
# `pick-runner`, the very first job, so a `run:` failure here fails/skips
# every downstream job (config + all four route-by-*) via the EXISTING
# `needs:` chain, no new `needs:` edges required.
#
# Unlike test/routing-bundle-unpack.sh's function (which WRITES the
# resolved values to $GITHUB_ENV for the job's later steps to consume),
# this step is validate-only — pick-runner has no route to send, so
# nothing downstream needs the values here. Assertions below check the
# exit code AND (for the failure cases) that the printed diagnostic names
# both valid forms and — for the "neither supplied" case specifically —
# the cross-org `secrets: inherit` likely-cause hint (groundnuty/macf#1338).
#
# Replicated verbatim from the workflow's own step (see this repo's
# established lockstep-duplication convention — test/routing-bundle-
# unpack.sh's own header explains why: composite-action extraction broke
# external callers twice, CHANGELOG [3.1.0]/[3.0.3]/[3.0.2]). Keep this
# copy in lockstep with agent-router.yml's "Assert one complete
# routing-secrets form before any work (#82)" step by hand.

set -euo pipefail

# ── Replicated verbatim from the workflow's preflight step. ──
validate_routing_secrets_preflight() {
  set -euo pipefail

  mask_lines() {
    local value="$1" line
    while IFS= read -r line || [ -n "$line" ]; do
      [ -n "$line" ] && echo "::add-mask::${line}"
    done <<< "$value"
  }

  NAMES="MACF_ROUTING_APP_ID MACF_ROUTING_APP_KEY ROUTING_CLIENT_CERT ROUTING_CLIENT_KEY TS_OAUTH_CLIENT_ID TS_OAUTH_SECRET"
  CROSS_ORG_HINT="Likely cause if you're a cross-org/enterprise caller: 'secrets: inherit' only propagates within the SAME organization/enterprise (GitHub docs) — see groundnuty/macf#1338, where a cross-org caller had all six secrets on its OWN repo but none reached this call. Pass the routing secrets explicitly in your caller workflow's 'secrets:' block, or supply MACF_ROUTING_BUNDLE."

  if [ -n "${BUNDLE:-}" ]; then
    mask_lines "$BUNDLE"
    echo "routing secrets preflight: MACF_ROUTING_BUNDLE supplied — validating form B (bundle)"
    if ! DECODED=$(printf '%s' "$BUNDLE" | base64 -d 2>/dev/null); then
      echo "::error::MACF_ROUTING_BUNDLE is not valid base64 — refusing to route on an unreadable bundle."
      return 1
    fi
    mask_lines "$DECODED"
    if ! printf '%s' "$DECODED" | jq -e 'type == "object"' >/dev/null 2>&1; then
      echo "::error::MACF_ROUTING_BUNDLE decoded but is not a JSON object — refusing to route on a malformed bundle."
      return 1
    fi
    MISSING=""
    for NAME in $NAMES; do
      VALUE=$(printf '%s' "$DECODED" | jq -r --arg k "$NAME" '.[$k] // empty')
      [ -z "$VALUE" ] && MISSING="${MISSING:+$MISSING, }$NAME"
    done
    unset DECODED
    if [ -n "$MISSING" ]; then
      echo "::error::MACF_ROUTING_BUNDLE is missing required key(s): $MISSING — refusing to route on a partial bundle."
      return 1
    fi
    echo "routing secrets preflight: form B (MACF_ROUTING_BUNDLE) is complete — proceeding"
    return 0
  fi

  echo "routing secrets preflight: MACF_ROUTING_BUNDLE not supplied — validating form A (six individual secrets)"
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
    if [ -n "$VALUE" ]; then
      mask_lines "$VALUE"
      continue
    fi
    if { [ "$NAME" = "TS_OAUTH_CLIENT_ID" ] || [ "$NAME" = "TS_OAUTH_SECRET" ]; } \
      && [ "${TAILNET_NEEDED:-true}" != "true" ]; then
      echo "routing secrets preflight: $NAME not supplied and not needed this run (self-hosted runner skips Tailscale connect) — leaving unset"
      continue
    fi
    MISSING="${MISSING:+$MISSING, }$NAME"
  done

  if [ -n "$MISSING" ]; then
    echo "::error::This caller supplied neither a complete MACF_ROUTING_BUNDLE (form B) nor a complete set of the six individual routing secrets (form A). Missing from form A: $MISSING."
    echo "::error::Exactly ONE complete form is required: (A) all six — MACF_ROUTING_APP_ID, MACF_ROUTING_APP_KEY, ROUTING_CLIENT_CERT, ROUTING_CLIENT_KEY, TS_OAUTH_CLIENT_ID, TS_OAUTH_SECRET — or (B) MACF_ROUTING_BUNDLE (preferred, groundnuty/macf#1112)."
    echo "::error::${CROSS_ORG_HINT}"
    return 1
  fi
  echo "routing secrets preflight: form A (six individual secrets) is complete — proceeding"
}

# ── Test harness ──────────────────────────────────────────────────────────

fail=0

# check DESCRIPTION EXPECTED_EXIT MUST_CONTAIN_REGEX MUST_NOT_CONTAIN_REGEX -- KEY=VALUE...
# MUST_CONTAIN_REGEX / MUST_NOT_CONTAIN_REGEX may be "" to skip that assertion.
check() {
  local description="$1" expected_exit="$2" must_contain="$3" must_not_contain="$4"
  shift 4
  # Remaining args are KEY=VALUE env assignments for the preflight call.

  local out actual_exit=0
  # Fresh subprocess, controlled minimal environment (env -i) — no leakage
  # between cases, same discipline as test/routing-bundle-unpack.sh.
  out=$(env -i PATH="$PATH" "$@" bash "$0" --run-preflight-only 2>&1) || actual_exit=$?

  local ok=1
  [ "$actual_exit" -eq "$expected_exit" ] || ok=0
  if [ -n "$must_contain" ] && ! printf '%s' "$out" | grep -qE "$must_contain"; then
    ok=0
  fi
  if [ -n "$must_not_contain" ] && printf '%s' "$out" | grep -qE "$must_not_contain"; then
    ok=0
  fi

  if [ "$ok" -eq 1 ]; then
    echo "ok: $description (exit=$actual_exit)"
  else
    echo "FAIL: $description" >&2
    echo "  expected exit=$expected_exit must_contain=[$must_contain] must_not_contain=[$must_not_contain]" >&2
    echo "  actual   exit=$actual_exit" >&2
    echo "  --- output ---" >&2
    printf '%s\n' "$out" | sed 's/^/  /' >&2
    fail=1
  fi
}

# Dispatch mode: fresh-subprocess entrypoint, mirrors routing-bundle-unpack.sh.
if [ "${1:-}" = "--run-preflight-only" ]; then
  validate_routing_secrets_preflight
  exit $?
fi

BUNDLE_VALID=$(printf '%s' '{"MACF_ROUTING_APP_ID":"123456","MACF_ROUTING_APP_KEY":"-----BEGIN KEY-----\nAAAA\n-----END KEY-----","ROUTING_CLIENT_CERT":"Y2VydA==","ROUTING_CLIENT_KEY":"a2V5","TS_OAUTH_CLIENT_ID":"cid","TS_OAUTH_SECRET":"csecret"}' | base64 -w0)
BUNDLE_PARTIAL=$(printf '%s' '{"MACF_ROUTING_APP_ID":"123456","ROUTING_CLIENT_CERT":"Y2VydA=="}' | base64 -w0)

# ── Decisive pair from the issue (a check that always passes is the failure
#    mode here — assert-the-wrong-path.md): ──

# 1. Neither form complete → fails at THIS job, naming BOTH valid forms
#    (form A and form B by name) and the cross-org likely-cause hint.
check 'neither form complete fails, names both forms + cross-org hint' 1 \
  'form A.*form B|form B.*form A' '' \
  TAILNET_NEEDED=true
check 'neither form complete: cross-org hint present' 1 \
  "secrets: inherit' only propagates within the SAME organization" '' \
  TAILNET_NEEDED=true

# 2. Either form complete → proceeds unchanged.
check 'form A (six) complete, no bundle → proceeds' 0 'form A .* is complete' '' \
  TAILNET_NEEDED=true \
  IN_MACF_ROUTING_APP_ID=999 \
  IN_MACF_ROUTING_APP_KEY=keydata \
  IN_ROUTING_CLIENT_CERT=Y2VydA== \
  IN_ROUTING_CLIENT_KEY=a2V5 \
  IN_TS_OAUTH_CLIENT_ID=cid \
  IN_TS_OAUTH_SECRET=csecret

check 'form B (bundle) complete, six absent → proceeds' 0 'form B .* is complete' '' \
  BUNDLE="$BUNDLE_VALID"

# 3. Partially-complete form A (some of six present, others empty) fails,
#    naming which are empty (macf#1336's live case).
check 'partial form A fails, names the empty ones' 1 \
  'Missing from form A: .*ROUTING_CLIENT_CERT' '' \
  TAILNET_NEEDED=true \
  IN_MACF_ROUTING_APP_ID=999 \
  IN_MACF_ROUTING_APP_KEY=keydata \
  IN_ROUTING_CLIENT_KEY=a2V5 \
  IN_TS_OAUTH_CLIENT_ID=cid \
  IN_TS_OAUTH_SECRET=csecret

# 4. Form B present, form A entirely absent → proceeds (the bundle case
#    #82 exists to keep working — required:true would have blocked it).
check 'bundle present, six entirely absent → proceeds (bundle-only caller)' 0 \
  'form B .* is complete' '' \
  BUNDLE="$BUNDLE_VALID"

# 5. Both forms present → proceeds, no ambiguity error (bundle wins, six
#    being present too is not an error).
check 'both forms present → proceeds, no ambiguity error' 0 \
  'form B .* is complete' 'error' \
  BUNDLE="$BUNDLE_VALID" \
  IN_MACF_ROUTING_APP_ID=999 \
  IN_MACF_ROUTING_APP_KEY=keydata \
  IN_ROUTING_CLIENT_CERT=Y2VydA== \
  IN_ROUTING_CLIENT_KEY=a2V5 \
  IN_TS_OAUTH_CLIENT_ID=cid \
  IN_TS_OAUTH_SECRET=csecret

# ── TS_OAUTH self-hosted carve-out preserved (same invariant as
#    test/routing-bundle-unpack.sh cases 9/10 — must not regress). ──

check 'TS_OAUTH_* absent + not needed (self-hosted) → proceeds' 0 \
  'form A .* is complete' '' \
  TAILNET_NEEDED=false \
  IN_MACF_ROUTING_APP_ID=999 \
  IN_MACF_ROUTING_APP_KEY=keydata \
  IN_ROUTING_CLIENT_CERT=Y2VydA== \
  IN_ROUTING_CLIENT_KEY=a2V5

check 'TS_OAUTH_* absent + needed (github-hosted) → fails, names only the two' 1 \
  'Missing from form A: TS_OAUTH_CLIENT_ID, TS_OAUTH_SECRET' '' \
  TAILNET_NEEDED=true \
  IN_MACF_ROUTING_APP_ID=999 \
  IN_MACF_ROUTING_APP_KEY=keydata \
  IN_ROUTING_CLIENT_CERT=Y2VydA== \
  IN_ROUTING_CLIENT_KEY=a2V5

# ── Malformed bundle: fails loudly, does NOT fall back to a complete six
#    (same invariant as routing-bundle-unpack.sh case 7). ──

check 'malformed-base64 bundle fails, does not fall back to a complete six' 1 \
  'not valid base64' '' \
  BUNDLE='not-valid-base64!!!' \
  IN_MACF_ROUTING_APP_ID=999 \
  IN_MACF_ROUTING_APP_KEY=keydata \
  IN_ROUTING_CLIENT_CERT=Y2VydA== \
  IN_ROUTING_CLIENT_KEY=a2V5 \
  IN_TS_OAUTH_CLIENT_ID=cid \
  IN_TS_OAUTH_SECRET=csecret

check 'bundle missing keys fails, names them (no cross-org hint — packing bug, not cross-org)' 1 \
  'missing required key' 'secrets: inherit' \
  BUNDLE="$BUNDLE_PARTIAL"

if [ "$fail" -ne 0 ]; then
  echo "" >&2
  echo "FAILED: at least one pick-runner-secrets-preflight check did not match expected" >&2
  exit 1
fi

echo ""
echo "all checks passed"
