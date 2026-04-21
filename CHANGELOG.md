# Changelog

All notable changes to this project will be documented in this file. The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [3.0.0] — 2026-04-21

### Changed — ⚠ breaking

Agent endpoint resolution moved from caller's `agent-config.json` to the MACF registry (GitHub Variables per DR-005/DR-006/DR-007). v2.0.1 read `.host` and `.port` from `agent-config.json` per-agent entries, which contradicted DR-007 ("anyone who needs the port reads the variable, not a config file") and forced operators to pin ports manually — losing the multi-agent-on-one-VM property dynamic port assignment was designed for. v3 restores the original design: each agent self-registers its runtime host+port under `<PROJECT>_AGENT_<NAME>` at bind time; the routing workflow resolves from the registry on every event. Closes [`groundnuty/macf-actions#18`](https://github.com/groundnuty/macf-actions/issues/18).

Same release also parameterizes the CA-cert variable name by project (was hardcoded `PROJECT_CA_CERT`, now `<PROJECT>_CA_CERT` matching the `macf certs init` convention). Eliminates a second drift vector flagged in the same issue thread.

### Prerequisites

v3 assumes the consumer has already gone through the standard MACF bootstrap for its project:

- **`macf repo-init`** has run in the consumer repo → `agent-config.json` exists, labels + project field are populated.
- **`macf certs init`** has run → the `<PROJECT>_CA_CERT` variable is set at the vars-accessible scope (caller repo level, or org-with-visibility).
- **Each agent has registered at least once** on its runtime host → `<PROJECT>_AGENT_<NAME>` exists in the registry with current `host` + `port`. Agents re-register on every channel-server start, so a running MACF system already satisfies this.

If any of these are missing, v3 either fails at token-mint (missing App secrets) or produces registry-miss at routing time (agent never registered). See the failure-semantics table below for what happens per path.

### Migration for consumers upgrading `@v2` → `@v3`

1. **Create a dedicated `macf-routing` GitHub App**, if one doesn't exist yet:
   - Owner: your registry-holding org (typically the same org as your consumer repo, or `groundnuty` for personal-account projects).
   - Permissions: **only** `Organization variables: Read`. Nothing else. This App exists solely to mint short-lived registry-read tokens; minimum-scope App = minimum blast radius if creds ever leak.
   - Install on the registry org.
   - Generate a private key.

2. **Add these secrets** to each consumer repo:
   - `MACF_ROUTING_APP_ID` — App ID from step 1
   - `MACF_ROUTING_APP_KEY` — PEM private key from step 1

3. **Pass the new required input** in your caller workflow:
   ```yaml
   jobs:
     route:
       uses: groundnuty/macf-actions/.github/workflows/agent-router.yml@v3.0.0
       with:
         project: <your-project-name>  # e.g. academic-resume
       secrets: inherit
   ```
   Optional: override `registry-api-path` if your registry isn't in the caller's org (default is `/orgs/${{ github.repository_owner }}`). Use `/repos/<user>/<user>` for DR-006 profile scope.

4. **Rename your CA-cert variable** from `PROJECT_CA_CERT` to `<PROJECT_SEG>_CA_CERT` where `<PROJECT_SEG>` is your project name uppercased with hyphens→underscores (e.g. `academic-resume` → `ACADEMIC_RESUME_CA_CERT`). Matches what `macf certs init` already writes; the v2.0.1 workflow was looking at the wrong name. After confirming v3 works, delete the legacy `PROJECT_CA_CERT` variable.

5. **Slim down `agent-config.json`** — `host` and `port` are no longer read. Keep `app_name` per agent (for attribution-skip) and `label_to_status`. Can leave `tmux_session`/`tmux_bin` in place for eventual v1 callers but they have no effect under v3.

6. **Verify agent self-registration is working.** Your agents must register their runtime host+port to `<PROJECT_SEG>_AGENT_<AGENT_NAME_SEG>` at startup (standard `macf` channel-server behavior since P2). If you're adopting v3 on a project that skipped registration, agents won't resolve from registry.

### Failure semantics (updated)

- **Registry-miss on label routing:** applies `agent-offline` label + comment. Same UX as v2.0.1's `agent-config.json` miss.
- **Registry-miss on mention / CI-completion:** log-only skip. A missing registration for one event shouldn't page.
- **Token-mint failure (bad `MACF_ROUTING_APP_*` secrets):** fails the job loudly at the `actions/create-github-app-token@v3` step with a clear error.

### Non-goals (deferred)

- **Cross-org registry federation** (multiple registry scopes per caller) — parameterizable via `registry-api-path` already; no further per-agent override in v3. If a consumer needs agents registered in different scopes, file an issue.
- **macf-actions self-routing bump** (`routing.yml` in this repo) — stays on `@v1.3.0` for this release. Self-bump after v3.0.0 is tagged + the `macf-routing` App + secrets are in place.

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
