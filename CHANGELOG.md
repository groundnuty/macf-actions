# Changelog

All notable changes to this project will be documented in this file. The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Security

- **Harden the router's prompt-send path against command injection (#47).** All four send jobs (`route-by-label`, `route-by-mention`, `route-by-ci-completion`, `route-by-pr-review-state`) now pass the routed prompt to the remote as opaque **base64 data**, decoded into a quoted variable on the remote before being handed to the canonical helper / `tmux send-keys` as argv — it is never interpolated into the remote shell command string. This replaces the prior `tr -d "'"` single-quote strip (line 12 below): that strip *did* contain the single-quote breakout on the `PR_TITLE` paths, but it relied on fragile char-stripping and left every send path **without** the strip (label/mention) injectable via a single-quote breakout. Event-derived text (PR titles, comment/label text — attacker-controllable on public repos) can no longer become command/prompt context on the routing path. This is a **hard prerequisite** for the self-hosted-runner work (#49), where a routing runner's blast radius rises from a throwaway hosted runner to the whole substrate VM. Adds `test/inject-safety.test.sh` demonstrating hostile titles neither execute nor get mangled in transit.

### Performance

- **Replace the Tailscale-readiness `sleep 10` with a result-invariant poll + bump the action to v4 (#42).** Each routing job's `Wait for Tailscale network` step now polls `tailscale status --json` (≤30s) asserting `BackendState == "Running"` **and** `Self.Online == true`, failing **loud** on timeout (with a diagnostic pointing at `TS_OAUTH_*` / the `tag:ci-runner` ACL) instead of the old blind 10s wait that then proceeded into a cryptic curl/ssh failure — Pattern A from `silent-fallback-hazards.md`. Bumps `tailscale/github-action` `@v3` → **v4.1.2**, pinned by commit SHA (no-floating-tags directive); v4 enables native binary caching (`use-cache: true`, default) + `tailscale up` retry. Drops the readiness wait from a fixed 10s to ~1-2s (≈8-9s/route off the dominant Tailscale phase). Inputs verified compatible at the pinned SHA; no routing-semantics change.

## [1.3.0] — 2026-04-17

### Added

- `route-by-ci-completion` job in `agent-router.yml` (#6). Notifies the authoring agent's tmux session when CI finishes on an agent-authored PR, eliminating the wait-for-human-ping polling pattern. Filters out human/external authors, draft PRs, stale CI after force-push, and non-actionable conclusions (`neutral`/`cancelled`/`skipped`).
- On success: routes a prompt like `PR #N: CI SUCCESS. URL. Next: merge if you're the author.`
- On failure: names the first failing check (from `check_runs` enumeration) for faster triage.
- Shell-quoting hardened: strips single quotes from generated prompts (user-controlled PR titles) to prevent remote-parse breakage.

### Non-breaking caller change

Consumers subscribing to the reusable workflow need to add `check_suite: { types: [completed] }` to their caller workflow's `on:` list to receive CI-completion routing. Without this, existing v1.2 behavior (label + mention routing) continues unchanged — the new job simply never fires.

### Permissions — ⚠ consumer action required

The reusable workflow now requests `checks: read` to enumerate `check_runs` in a completed suite. GitHub's `workflow_call` rule is that a reusable workflow's `GITHUB_TOKEN` cannot exceed the caller's permissions — so **every consumer that subscribes to `check_suite` must also grant `checks: read` in its caller workflow's `permissions:` block**, or the failing-check lookup will 403. Existing consumers upgrading to `@v1` (floating tag) should update their `routing.yml` to match:

```yaml
permissions:
  contents: read
  issues: write
  pull-requests: read
  checks: read    # add for CI-completion routing (v1.3+)
```

Known consumers to update (as of this release): `groundnuty/macf`, `groundnuty/academic-resume`. Without `checks: read`, existing label/mention routing continues to work; only the CI-completion routing job is affected.

## [1.0.0] — 2026-04-15

### Added

- Initial release. Extracts the routing Action from `groundnuty/macf` into a reusable workflow.
- `agent-router.yml` reusable workflow with three jobs:
  - `route-by-label` — SSH + tmux delivery when issue is labeled with an agent name
  - `route-by-mention` — SSH + tmux delivery when agent is `@mentioned`
  - `cleanup-labels` — strips status labels on issue close
- Behavior matches the current per-repo Action exactly — same SSH+tmux delivery, same config file format, same secrets.
- Callable via `uses: groundnuty/macf-actions/.github/workflows/agent-router.yml@v1` with `secrets: inherit`.
- Reads `.github/agent-config.json` from the caller's checkout.

### Tags

- `v1.0.0` — immutable
- `v1.0` — floats to latest `v1.0.x`
- `v1` — floats to latest `v1.x.x`
