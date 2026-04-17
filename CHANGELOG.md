# Changelog

All notable changes to this project will be documented in this file. The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [2.0.1] — 2026-04-17

### Changed

- `route-by-ci-completion` payload now uses `type: 'ci_completion'` with the full structured schema (`pr_number`, `pr_title`, `pr_url`, `conclusion`, `failing_check_name`, `message`) landed in `groundnuty/macf#122`. Receivers no longer need to disambiguate via `source: 'ci_completion'` — the `type` discriminator is sufficient.

### Removed

- v2.0.0 "Known limitation" note about the `type: 'mention'` shoehorn — resolved by this release.

### Consumer action

None. Patch-version bump: server-side `NotifyPayloadSchema.parse` already accepts both the old and new shape, so consumers on `@v2` auto-pick up the cleaner payload on next dispatch. No secret / variable / agent-config changes.

## [2.0.0] — 2026-04-17

### Changed — ⚠ breaking

Transport swapped from SSH + `tmux send-keys` to mTLS HTTPS POST to each agent's `/notify` endpoint. Matches the original MACF P6 design (DR-004 mTLS architecture). See [`groundnuty/macf-actions#8`](https://github.com/groundnuty/macf-actions/issues/8) for the design discussion.

### Migration for consumers upgrading `@v1` → `@v2`

1. **Mint a routing-client cert** on a workspace that has the project CA key locally:
   ```bash
   macf certs issue-routing-client
   ```
   (Requires `macf` CLI `v0.1.1+` — the `issue-routing-client` subcommand was added in `groundnuty/macf#119` / PR #120.)

2. **Add these secrets** to each consumer repo's Settings → Secrets and variables → Actions:
   - `ROUTING_CLIENT_CERT` — base64 PEM from step 1
   - `ROUTING_CLIENT_KEY` — base64 PEM from step 1

3. **Add this repo Variable** (public-readable PEM, NOT a secret):
   - `PROJECT_CA_CERT` — contents of `<PROJECT>_CA_CERT` from your project's registry (or directly from the CA cert on disk, whichever is easier)

4. **Update `.github/agent-config.json`** — add `port` field to each agent entry. Look up each agent's port from `.macf/macf-agent.state.json` (the agent's self-registration) or from the registry variable `<PROJECT>_<AGENT>_ENDPOINT`.

5. **Update the `uses:` ref** in your caller workflow: `@v1` → `@v2`.

6. **Remove the `AGENT_SSH_KEY` secret** once you've verified v2 routing works.

### Failure semantics

- **Label routing on unreachable agent:** still applies the `agent-offline` label + issue comment (UX preserved from v1).
- **Mention / CI-completion on unreachable agent:** log-only (no label/comment). One missed comment shouldn't trip the offline flag.
- **No SSH fallback.** v2 is hard-fail by design (macf-actions#8 Option A) — the whole point of migrating is to retire the SSH path cleanly.

### Known limitation (resolved in v2.0.1)

- `NotifyPayload.type='mention'` was used for CI-completion notifications in v2.0.0 because `groundnuty/macf`'s `NotifyPayloadSchema` didn't yet have a dedicated `ci_completion` variant. Resolved in v2.0.1 after `groundnuty/macf#122` shipped the proper schema.

### Not removed (yet)

- `tailscale/github-action` Tailscale bootstrap. Still required — the GHA runner reaches agent VMs over Tailscale in both v1 and v2.

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
