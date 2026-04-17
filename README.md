# macf-actions

Reusable GitHub Actions workflows for [MACF](https://github.com/groundnuty/macf) (Multi-Agent Coordination Framework). Single source of truth for routing infrastructure, distributed via versioned tags.

## What this is

A centrally-maintained, versioned reusable workflow for routing GitHub events (issues, PR comments, reviews) to MACF agents. Consumers reference it by Git ref (`@v1`) instead of copying 200+ lines of YAML into each repo.

## Usage

In your MACF-enabled repo, create `.github/workflows/agent-router.yml`:

```yaml
name: Agent Router
on:
  issues: { types: [labeled, closed] }
  issue_comment: { types: [created] }
  pull_request: { types: [opened] }
  pull_request_review: { types: [submitted] }
  check_suite: { types: [completed] }   # CI-completion routing (v1.3+)
permissions:
  contents: read
  issues: write
  pull-requests: read
  checks: read                          # required by CI-completion routing
jobs:
  route:
    uses: groundnuty/macf-actions/.github/workflows/agent-router.yml@v1
    secrets: inherit
```

**Upgrading to v1.3 (or via the floating `@v1` tag once it moves past v1.3.0):** if your caller workflow already defines a `permissions:` block, add `checks: read`. Without it the CI-completion routing job will 403 when it tries to enumerate `check_runs` to name the first failing check. GitHub's `workflow_call` rule is that the reusable workflow's token can't exceed the caller's scope, so this permission must be granted at the caller level.

That's it. GitHub downloads the workflow definition at run time and passes your secrets and events to it.

### Required secrets

Configure these in your repo's **Settings → Secrets and variables → Actions**:

| Secret | Purpose |
|---|---|
| `AGENT_SSH_KEY` | SSH private key for connecting to agent hosts |
| `TS_OAUTH_CLIENT_ID` | Tailscale OAuth client ID for the runner |
| `TS_OAUTH_SECRET` | Tailscale OAuth secret for the runner |

The standard `GITHUB_TOKEN` is provided automatically by Actions.

### Required config file

Your repo must have `.github/agent-config.json` describing the agents:

```json
{
  "agents": {
    "code-agent": {
      "host": "100.86.5.117",
      "app_name": "macf-code-agent",
      "tmux_session": "code-agent",
      "ssh_user": "ubuntu",
      "tmux_bin": "tmux"
    },
    "science-agent": {
      "host": "100.86.5.117",
      "app_name": "macf-science-agent",
      "tmux_session": "science-agent",
      "ssh_user": "ubuntu"
    }
  }
}
```

Keys are GitHub labels (e.g., `code-agent` label triggers routing to the agent with key `code-agent`). Use `app_name` to match against `@<app_name>[bot]` mentions.

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

## See also

- [MACF framework](https://github.com/groundnuty/macf) — agent implementation, CLI, plugin
- [GitHub docs: reusable workflows](https://docs.github.com/en/actions/how-tos/reuse-automations/reuse-workflows)

## License

MIT
