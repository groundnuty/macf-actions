# macf-actions

Reusable GitHub Actions workflows for [MACF](https://github.com/groundnuty/macf) (Multi-Agent Coordination Framework). Single source of truth for routing infrastructure, distributed via versioned tags.

## What this is

A centrally-maintained, versioned reusable workflow for routing GitHub events (issues, PR comments, reviews) to MACF agents. Consumers reference it by Git ref (`@v1`) instead of copying 200+ lines of YAML into each repo.

## Usage

### v2 (current major, mTLS transport)

In your MACF-enabled repo, create `.github/workflows/agent-router.yml`:

```yaml
name: Agent Router
on:
  issues: { types: [labeled, closed] }
  issue_comment: { types: [created] }
  pull_request: { types: [opened] }
  pull_request_review: { types: [submitted] }
  check_suite: { types: [completed] }
permissions:
  contents: read
  issues: write
  pull-requests: read
  checks: read
jobs:
  route:
    uses: groundnuty/macf-actions/.github/workflows/agent-router.yml@v2
    secrets: inherit
```

### v1.x (SSH+tmux transport, maintained for backward-compat)

v1.x is still available via `@v1` / `@v1.3.0` tags for consumers that haven't migrated to mTLS yet. v1.3.0 added `check_suite` / CI-completion routing; v2.0.0 is a breaking change (different transport, different secrets). See [CHANGELOG.md](./CHANGELOG.md) for the migration.

### Required secrets (v2)

Configure these in your repo's **Settings → Secrets and variables → Actions**:

**Secrets (→ `Secrets` tab):**

| Secret | Purpose |
|---|---|
| `ROUTING_CLIENT_CERT` | Base64 PEM of the routing-action client certificate. Mint via `macf certs issue-routing-client`. |
| `ROUTING_CLIENT_KEY` | Base64 PEM of the routing-action client private key. Same output as above. **Keep strictly secret.** |
| `TS_OAUTH_CLIENT_ID` | Tailscale OAuth client ID for the runner |
| `TS_OAUTH_SECRET` | Tailscale OAuth secret for the runner |

**Variables (→ `Variables` tab, not `Secrets` — these are PUBLIC-readable PEM, not private):**

| Variable | Purpose |
|---|---|
| `PROJECT_CA_CERT` | Project CA certificate (PEM, from `macf certs init`). Used to verify each agent's server cert during the mTLS handshake. |

> **Paste the CA PEM with literal newlines preserved.** Some web forms strip or escape whitespace; the CA cert value in the GHA Variables UI must contain actual `\n` line breaks between `-----BEGIN CERTIFICATE-----` and `-----END CERTIFICATE-----`. If you paste from the output of `cat <your-project>/<project-id>/ca-cert.pem` directly, you're fine. If you paste from a system that replaces newlines with literal `\n` characters or joins into a single line, the TLS handshake will fail with a "malformed PEM" or similar error at workflow runtime.

The standard `GITHUB_TOKEN` is provided automatically by Actions.

### Required secrets (v1.x, legacy)

Consumers still on `@v1` / `@v1.3.0` use the old secret set:

| Secret | Purpose |
|---|---|
| `AGENT_SSH_KEY` | SSH private key for connecting to agent hosts (legacy SSH+tmux transport) |
| `TS_OAUTH_CLIENT_ID` | Tailscale OAuth client ID for the runner |
| `TS_OAUTH_SECRET` | Tailscale OAuth secret for the runner |

After migrating to `@v2`, remove `AGENT_SSH_KEY` from your repo secrets (unused, reduces blast radius if it leaks).

### Required config file

Your repo must have `.github/agent-config.json` describing the agents:

**v2 format (mTLS transport):**

```json
{
  "agents": {
    "code-agent": {
      "host": "100.86.5.117",
      "port": 8800,
      "app_name": "macf-code-agent"
    },
    "science-agent": {
      "host": "100.86.5.117",
      "port": 8801,
      "app_name": "macf-science-agent"
    }
  }
}
```

v2 fields:
- **`host`** (required) — Tailscale IP or hostname the GHA runner reaches the agent's channel server at
- **`port`** (required, new in v2) — port the agent's channel server listens on (from the agent's `.macf/macf-agent.state.json` or registry)
- **`app_name`** (required) — GitHub App name (matched against `@<app_name>[bot]` mentions and PR authors)

v1.x fields (`tmux_session`, `tmux_bin`, `ssh_user`, `ssh_key_secret`, `tmux_window`, `workspace_dir`) are ignored by v2.

Keys are GitHub labels (e.g., `code-agent` label triggers routing to the agent with key `code-agent`).

## Versioning

Standard GitHub Actions versioning — floating major tags + immutable semver:

| Tag | Moves? | Recommended for |
|---|---|---|
| `v1` | Floats to latest `v1.x.x` | **Typical consumers** (auto-update within major) |
| `v1.0` | Floats to latest `v1.0.x` | Production (patches only) |
| `v1.0.0` | Immutable | Maximum stability / reproducibility |

Breaking changes become a new major (`v2`). Older majors remain live and can receive backported patches.

## Upgrading

When a new major is released, update your caller's `@v1` reference:

```yaml
# Before
uses: groundnuty/macf-actions/.github/workflows/agent-router.yml@v1

# After (when v2 ships)
uses: groundnuty/macf-actions/.github/workflows/agent-router.yml@v2
```

Check [CHANGELOG.md](./CHANGELOG.md) for breaking changes between majors.

## Behavior

## v2 — mTLS transport (current major)

v2 delivers notifications via mTLS HTTPS POST to each agent's `/notify` endpoint. v1.x used SSH + `tmux send-keys` into the agent's VM. The migration is breaking (new secrets, new agent-config.json field), but simplifies downstream operations: no per-agent SSH key distribution, no tmux-session assumptions, aligns with MACF's designed endgame (DR-004 mTLS architecture).

**Hard-fail on unreachable:** if the POST to an agent's `/notify` fails (timeout, cert mismatch, connection refused), the job fails. The existing `agent-offline` label + issue comment UX is preserved for label-routed events. Mention and CI-completion events don't mark agents offline (too noisy — one missed comment shouldn't trip the offline flag).

### Jobs

The workflow provides four jobs:

1. **`route-by-label`** — when an issue is labeled with an agent name, route it to that agent via SSH + tmux send-keys
2. **`route-by-mention`** — when an agent is `@mentioned` in a comment, PR body, or review, route the mention to the agent
3. **`route-by-ci-completion`** (v1.3+) — when CI finishes on an agent-authored PR, notify the authoring agent in its tmux session so it can merge on success or push a fix on failure without polling. Filters:
    - Only fires for PRs authored by agents configured in `agent-config.json` (skips human / dependabot / external authors)
    - Skips draft PRs
    - Skips stale CI (when the PR HEAD moved past the SHA the suite ran on, e.g. after a force-push)
    - Only terminal conclusions (`success`, `failure`, `timed_out`, `action_required`); skips `neutral`, `cancelled`, `skipped`
4. **`cleanup-labels`** — when an issue closes, remove status labels (`in-progress`, `in-review`, `blocked`)

If an agent is unreachable, the workflow adds the `agent-offline` label so the agent can pick up missed work on startup.

## v2 (planned)

The v1 workflow uses SSH + tmux for message delivery. v2 will swap this for mTLS HTTP POST to each agent's channel endpoint (see [macf P3](https://github.com/groundnuty/macf/blob/main/design/phases/P3-cert-management.md) for the cert infrastructure). Consumers opt in by bumping `@v1` → `@v2`.

## Contributing

CI enforces two checks on PRs:

1. **[actionlint](https://github.com/rhysd/actionlint)** — validates `.github/workflows/*.yml` for syntax, unused permissions, shell-injection-by-quotation, and typos in `${{ ... }}` contexts. Runs on every push and PR that touches workflows.
2. **[commitlint](https://github.com/conventional-changelog/commitlint)** — enforces the 13-type enum shared with [`groundnuty/macf`](https://github.com/groundnuty/macf/blob/main/commitlint.config.mjs): `feat / fix / security / reliability / refactor / perf / docs / test / chore / ci / revert / build / style`. Parity across the two repos means release-note derivation + `git log --grep='^security|^reliability'` work consistently.

PR subjects follow [Conventional Commits](https://www.conventionalcommits.org/) format with one of those types. Subject capped at 100 chars (`@commitlint/config-conventional` default).

## See also

- [MACF framework](https://github.com/groundnuty/macf) — agent implementation, CLI, plugin
- [GitHub docs: reusable workflows](https://docs.github.com/en/actions/how-tos/reuse-automations/reuse-workflows)

## License

MIT
