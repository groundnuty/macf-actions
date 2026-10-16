#!/usr/bin/env bash
# The router's jobs that call gh may land on a self-hosted runner whose image
# has no gh (groundnuty/macf#1498: the ARC runner image ships jq and curl but
# not gh). Every such job must run the "Ensure gh CLI" step before its first
# gh call, and that step must install a pinned, checksum-verified gh only when
# gh is absent, failing loudly otherwise.
#
# Structural: each job with a gh call has the step, and it comes first.
# Behavioural: the step's run block is EXTRACTED from the workflow and run in a
# PATH with no gh, against a local fixture tarball:
#   1. gh already present -> exits 0 and never downloads.
#   2. gh absent, checksum matches -> installs and appends to GITHUB_PATH.
#   3. checksum mismatch -> fails, says sha256, GITHUB_PATH untouched.
#   4. non-Linux runner -> fails with an install-gh message.
set -euo pipefail
WF=.github/workflows/agent-router.yml
fail=0

# --- structural -------------------------------------------------------------
python3 - "$WF" <<'PY' || fail=1
import re, sys
lines = open(sys.argv[1]).read().split('\n')
gh = re.compile(r'(^|[\s(=$"])gh (api|pr|run|issue|label)\b')
starts = [i for i, l in enumerate(lines) if re.match(r'^  [a-z0-9-]+:$', l)] + [len(lines)]
bad = 0
for a, b in zip(starts, starts[1:]):
    name = lines[a].strip().rstrip(':')
    calls = [i for i in range(a, b) if gh.search(lines[i]) and not lines[i].lstrip().startswith('#')]
    if not calls:
        continue
    ensure = [i for i in range(a, b) if 'name: Ensure gh CLI' in lines[i]]
    if not ensure or ensure[0] > calls[0]:
        print(f'FAIL: job {name} calls gh at line {calls[0] + 1} with no Ensure gh CLI step before it')
        bad = 1
    else:
        print(f'ok: {name} ensures gh before its first gh call')
sys.exit(bad)
PY

# --- behavioural ------------------------------------------------------------
BLOCK=$(awk '
  /name: Ensure gh CLI/ {found=1}
  found && /^        run: \|$/ {on=1; next}
  on && /^      - / {exit}
  on {sub(/^          /, ""); print}
' "$WF")
[ -n "$BLOCK" ] || { echo "FAIL: could not extract the Ensure gh CLI run block"; exit 1; }

# Every copy of the step must be identical (apart from its if:), so testing one tests them all.
python3 - "$WF" <<'PYEOF' || fail=1
import sys
lines = open(sys.argv[1]).read().split('\n')
blocks = []
for i, l in enumerate(lines):
    if 'name: Ensure gh CLI' in l:
        j = i + 1
        while j < len(lines) and not lines[j].startswith('      - '):
            j += 1
        blocks.append('\n'.join(x for x in lines[i:j] if not x.startswith('        if: ')))
if len(set(blocks)) != 1:
    print(f'FAIL: the {len(blocks)} Ensure gh CLI steps are not identical ({len(set(blocks))} variants)')
    sys.exit(1)
print(f'ok: all {len(blocks)} Ensure gh CLI steps are identical')
PYEOF

work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
ver=9.9.9
mkdir -p "$work/pkg/gh_${ver}_linux_amd64/bin"
printf '#!/bin/sh\necho "gh version %s (fixture)"\n' "$ver" > "$work/pkg/gh_${ver}_linux_amd64/bin/gh"
chmod +x "$work/pkg/gh_${ver}_linux_amd64/bin/gh"
tar -czf "$work/gh_${ver}_linux_amd64.tar.gz" -C "$work/pkg" "gh_${ver}_linux_amd64"
good_sum=$(sha256sum "$work/gh_${ver}_linux_amd64.tar.gz" | cut -d' ' -f1)

# A PATH with the tools the step needs, but no gh. curl and uname are fakes.
mkbin() { # dir, os
  local d="$1" os="$2" t
  mkdir -p "$d"
  for t in bash sh sha256sum tar gzip mkdir head cat printf cut cp; do
    ln -sf "$(command -v "$t")" "$d/$t"
  done
  printf '#!/bin/sh\ncase "$1" in -s) echo %s ;; -m) echo x86_64 ;; esac\n' "$os" > "$d/uname"
  # Fake curl: copy the fixture to the -o path; record that it was called.
  cat > "$d/curl" <<EOF
#!/bin/sh
echo called >> "$work/curl.calls"
while [ \$# -gt 0 ]; do [ "\$1" = -o ] && out="\$2"; shift; done
cp "$work/gh_${ver}_linux_amd64.tar.gz" "\$out"
EOF
  chmod +x "$d/uname" "$d/curl"
}

run_case() { # name, bin, sum, want_rc, want_text
  local name="$1" bin="$2" sum="$3" want_rc="$4" want="$5" rc=0 out
  rm -f "$work/curl.calls"; : > "$work/github_path"; rm -rf "$work/runner"; mkdir -p "$work/runner"
  out=$(PATH="$bin" GH_CLI_VERSION="$ver" GH_CLI_SHA256_AMD64="$sum" GH_CLI_SHA256_ARM64=x \
        RUNNER_TEMP="$work/runner" GITHUB_PATH="$work/github_path" bash -c "$BLOCK" 2>&1) || rc=$?
  if [ "$rc" != "$want_rc" ] || ! printf '%s' "$out" | grep -q "$want"; then
    echo "FAIL: $name (rc=$rc, want $want_rc / '$want'): $out"; fail=1
  else
    echo "ok: $name"
  fi
}

mkbin "$work/linux" Linux
mkbin "$work/darwin" Darwin
mkbin "$work/withgh" Linux
printf '#!/bin/sh\necho "gh version 2.0.0 (preinstalled)"\n' > "$work/withgh/gh"; chmod +x "$work/withgh/gh"

run_case "gh already present: no download" "$work/withgh" "$good_sum" 0 "gh present"
[ ! -f "$work/curl.calls" ] || { echo "FAIL: downloaded although gh was present"; fail=1; }

run_case "gh absent: pinned build installed" "$work/linux" "$good_sum" 0 "gh installed: gh version $ver"
grep -q "gh-cli/gh_${ver}_linux_amd64/bin" "$work/github_path" || { echo "FAIL: GITHUB_PATH not updated"; fail=1; }

run_case "checksum mismatch: refused" "$work/linux" "0000000000000000000000000000000000000000000000000000000000000000" 1 "sha256"
[ ! -s "$work/github_path" ] || { echo "FAIL: GITHUB_PATH written after a checksum mismatch"; fail=1; }

run_case "non-Linux runner: refused" "$work/darwin" "$good_sum" 1 "only on Linux"

[ "$fail" = 0 ] && echo "PASS: ensure-gh-cli" || { echo "FAILED: ensure-gh-cli"; exit 1; }
