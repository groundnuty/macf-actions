#!/usr/bin/env bash
# Test for the CA-cert resolution step in .github/workflows/agent-router.yml,
# "Resolve project CA cert (registry primary, repo-var fallback)" (macf-actions#66,
# and the groundnuty/macf#1498 follow-up: tell a 404 from any other failure).
#
# The test EXTRACTS the step's real `run:` block from the workflow (every copy,
# and requires them to be identical), then runs it with a fake `gh` on PATH.
# Cases:
#   - 200 with a value            -> registry wins
#   - 404 (HTTP 404 on stderr)    -> repo-var fallback, with the warning
#   - 401 / any other failure     -> exit 1 with the "refusing to guess" error,
#                                    even when a fallback variable is set
#   - 200 with an empty value     -> treated like a miss (fallback / loud fail)
#   - 404 and no fallback         -> loud fail
# Mutation (at the bottom): treat every failure as a miss again -> the 401
# case must then NOT fail, proving it is a real guard.

set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
wf="$here/../.github/workflows/agent-router.yml"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# Extract each copy of the step's run block (dedented) into $work/step-N.sh.
awk -v dir="$work" '
  /- name: Resolve project CA cert \(registry primary, repo-var fallback\)/ { n++; infound=1; inrun=0; next }
  infound && /^        run: \|/ { inrun=1; next }
  inrun && /^      - name:/ { infound=0; inrun=0 }
  inrun { sub(/^          /, ""); print > (dir "/step-" n ".sh") }
' "$wf"

copies=$(ls "$work"/step-*.sh 2>/dev/null | wc -l | tr -d ' ')
if [ "$copies" -lt 1 ]; then
  echo "FAIL: no CA-resolution step extracted from $wf" >&2
  exit 1
fi
for f in "$work"/step-*.sh; do
  if ! cmp -s "$work/step-1.sh" "$f"; then
    echo "FAIL: CA-resolution step copies differ ($f vs step-1.sh)" >&2
    exit 1
  fi
done
echo "ok: $copies copies of the step are identical"

# Fake gh: behaviour chosen by FAKE_GH_MODE.
mkdir -p "$work/bin"
cat > "$work/bin/gh" <<'EOF'
#!/usr/bin/env bash
case "$FAKE_GH_MODE" in
  200)   printf '%s' "REGISTRY-PEM"; exit 0 ;;
  empty) exit 0 ;;
  404)   echo "gh: Not Found (HTTP 404)" >&2; exit 1 ;;
  401)   echo "gh: Bad credentials (HTTP 401)" >&2; echo "second line" >&2; exit 1 ;;
  net)   echo "error connecting to api.github.com" >&2; exit 1 ;;
esac
EOF
chmod +x "$work/bin/gh"

fail=0
LAST_CODE=0; LAST_OUT=""; LAST_PEM=""

# $1=script $2=gh mode $3=fallback value
run_step() {
  local script=$1 mode=$2 fallback=$3
  local go="$work/gh-output" tmp="$work/tmp"
  mkdir -p "$tmp"; : > "$go"
  set +e
  LAST_OUT=$(
    PATH="$work/bin:$PATH" FAKE_GH_MODE="$mode" RUNNER_TEMP="$tmp" GITHUB_OUTPUT="$go" \
    PROJECT_SEG="MACF" REG_PATH="repos/o/r" PROJECT_CA_CERT_REPO_VAR_FALLBACK="$fallback" \
    bash "$script" 2>&1
  )
  LAST_CODE=$?
  set -e
  local p; p=$(sed -n 's/^path=//p' "$go")
  LAST_PEM=""
  if [ -n "$p" ] && [ -f "$p" ]; then LAST_PEM=$(cat "$p"); fi
}

expect() {
  local desc=$1 code=$2 pem=$3 needle=$4
  if [ "$LAST_CODE" -ne "$code" ] || [ "$LAST_PEM" != "$pem" ]; then
    echo "FAIL: $desc — rc=$LAST_CODE pem='$LAST_PEM' (want rc=$code pem='$pem')" >&2
    echo "$LAST_OUT" | sed 's/^/  | /' >&2
    fail=1; return
  fi
  case "$LAST_OUT" in
    *"$needle"*) echo "ok: $desc" ;;
    *) echo "FAIL: $desc — output lacks '$needle'" >&2
       echo "$LAST_OUT" | sed 's/^/  | /' >&2; fail=1 ;;
  esac
}

S="$work/step-1.sh"

run_step "$S" 200 "REPO-VAR-PEM"
expect "200 -> registry wins even with a fallback set" 0 "REGISTRY-PEM" "resolved from registry"

run_step "$S" 404 "REPO-VAR-PEM"
expect "404 -> repo-var fallback with the warning" 0 "REPO-VAR-PEM" "transitional per-repo"

run_step "$S" 401 "REPO-VAR-PEM"
expect "401 -> exit 1, no fallback" 1 "" "Could not read MACF_CA_CERT from the registry (gh: Bad credentials (HTTP 401)); refusing to guess."

run_step "$S" net "REPO-VAR-PEM"
expect "network failure -> exit 1, no fallback" 1 "" "refusing to guess"

run_step "$S" empty "REPO-VAR-PEM"
expect "200 with empty value -> fallback, as a miss" 0 "REPO-VAR-PEM" "transitional per-repo"

run_step "$S" empty ""
expect "empty value, no fallback -> loud failure" 1 "" "CA cert not found in the registry"

run_step "$S" 404 ""
expect "404, no fallback -> loud failure" 1 "" "CA cert not found in the registry"

# Mutation: every failure is a miss again (the pre-fix behaviour). The 401 case
# must then take the fallback instead of failing.
sed 's/if \[ "\$REG_RC" -ne 0 \] && ! grep -q .HTTP 404. "\$REG_ERR"; then/if false; then/' "$S" > "$work/mutant.sh"
if cmp -s "$S" "$work/mutant.sh"; then
  echo "FAIL: mutation did not change the step (sed pattern stale)" >&2
  fail=1
else
  run_step "$work/mutant.sh" 401 "REPO-VAR-PEM"
  if [ "$LAST_CODE" -eq 0 ] && [ "$LAST_PEM" = "REPO-VAR-PEM" ]; then
    echo "ok: mutant (all failures are misses) silently falls back on a 401 — the 401 case is a real guard"
  else
    echo "FAIL: mutant did not reproduce the silent fallback (rc=$LAST_CODE pem='$LAST_PEM')" >&2
    fail=1
  fi
fi

if [ "$fail" -ne 0 ]; then
  echo "FAIL: ca-cert-resolution test failed" >&2
  exit 1
fi
echo "all ok"
