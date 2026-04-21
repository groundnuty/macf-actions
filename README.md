# macf-actions

Reusable GitHub Actions workflows for [MACF](https://github.com/groundnuty/macf) (Multi-Agent Coordination Framework). Single source of truth for routing infrastructure, distributed via versioned tags.

## What this is

A centrally-maintained, versioned reusable workflow for routing GitHub events (issues, PR comments, reviews) to MACF agents. Consumers reference it by Git ref (`@v1`) instead of copying 200+ lines of YAML into each repo.

## Usage

### v3 (current major, registry-driven mTLS)

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
    uses: groundnuty/macf-actions/.github/workflows/agent-router.yml@v3
    with:
      project: your-project-name  # e.g. academic-resume
    secrets: inherit
```

`project` drives the registry variable-name convention (`<PROJECT>_AGENT_<NAME>` for agent endpoints, `<PROJECT>_CA_CERT` for the CA) — match the `project` field your agent writes to `.macf/macf-agent.json`.

Optional input: `registry-api-path` (default `/orgs/${{ github.repository_owner }}`) — override for DR-006 profile scope (`/repos/<user>/<user>`) or cross-org registries.

### v2.x (deprecated — DR-007 violating)

`@v2` / `@v2.0.1` are superseded by v3. v2 read agent endpoints from caller's `agent-config.json`, contradicting DR-007 ("registry is the single source of truth for port/host"). Existing consumers on `@v2` still work, but migrate at next convenient window — see [CHANGELOG §3.0.0](./CHANGELOG.md) for the step-by-step upgrade.

### v1.x (SSH+tmux transport, legacy)

`@v1` / `@v1.3.0` available for pre-mTLS consumers. v2.0.0 broke SSH→mTLS; v3.0.0 refactored where port/host come from. See [CHANGELOG.md](./CHANGELOG.md) for the full migration path.

### Required secrets (v3)

Configure these in your repo's **Settings → Secrets and variables → Actions**:

**Secrets (→ `Secrets` tab):**

| Secret | Purpose |
|---|---|
| `ROUTING_CLIENT_CERT` | Base64 PEM of the routing-action client certificate. Mint via `macf certs issue-routing-client`. |
| `ROUTING_CLIENT_KEY` | Base64 PEM of the routing-action client private key. Same output as above. **Keep strictly secret.** |
| `TS_OAUTH_CLIENT_ID` | Tailscale OAuth client ID for the runner |
| `TS_OAUTH_SECRET` | Tailscale OAuth secret for the runner |
| `MACF_ROUTING_APP_ID` | GitHub App ID for a dedicated `variables:read`-only App. Used to mint short-lived registry-read tokens. See below. |
| `MACF_ROUTING_APP_KEY` | PEM private key for the `macf-routing` App. **Keep strictly secret.** |

**Variables (→ `Variables` tab, not `Secrets` — these are PUBLIC-readable PEM, not private):**

| Variable | Purpose |
|---|---|
| `<PROJECT>_CA_CERT` | Project CA certificate (PEM, written by `macf certs init`). Variable name is derived from the `project` input: uppercased, hyphens→underscores. E.g. `academic-resume` → `ACADEMIC_RESUME_CA_CERT`. |

> **Paste the CA PEM with literal newlines preserved.** Some web forms strip or escape whitespace; the CA cert value in the GHA Variables UI must contain actual `\n` line breaks between `-----BEGIN CERTIFICATE-----` and `-----END CERTIFICATE-----`. If you paste from the output of `cat <your-project>/<project-id>/ca-cert.pem` directly, you're fine. If you paste from a system that replaces newlines with literal `\n` characters or joins into a single line, the TLS handshake will fail with a "malformed PEM" or similar error at workflow runtime.

The standard `GITHUB_TOKEN` is provided automatically by Actions.

#### The `macf-routing` App

v3 mints a short-lived registry-read token via [`actions/create-github-app-token@v3`](https://github.com/actions/create-github-app-token) instead of using `GITHUB_TOKEN` (which is repo-scoped and can't read org variables). Use a **dedicated** GitHub App, not an existing MACF App:

1. Register a new GitHub App named `macf-routing` under your registry org.
2. **Permissions: only `Organization variables: Read`.** No `issues`, no `contents`, nothing else — minimum blast radius if the creds ever leak.
3. Install on the registry org (no repo selection needed — token is org-scoped).
4. Generate a private key.
5. Save the App ID as `MACF_ROUTING_APP_ID` and the PEM as `MACF_ROUTING_APP_KEY` in each consumer repo's Secrets.

Reusing a more-privileged App like `macf-code-agent` (which has `issues:write`, `pull_requests:write`) would give the workflow token far more scope than it needs. DR-019's minimum-permission doctrine applies.

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

**v3 format (registry-driven mTLS):**

```json
{
  "agents": {
    "code-agent":    { "app_name": "macf-code-agent" },
    "science-agent": { "app_name": "macf-science-agent" }
  }
}
```

v3 fields:
- **`app_name`** (required) — GitHub App name (matched against `@<app_name>[bot]` mentions and PR authors)

v2 fields `host` and `port` are **ignored** in v3 — the registry is the single source of truth (DR-007). v1.x fields (`tmux_session`, `tmux_bin`, `ssh_user`, `ssh_key_secret`, `tmux_window`, `workspace_dir`) are also ignored.

Keys are GitHub labels (e.g., `code-agent` label triggers routing to the agent with key `code-agent`).

## Versioning

Standard GitHub Actions versioning — floating major tags + immutable semver:

| Tag | Moves? | Recommended for |
|---|---|---|
| `v1` | Floats to latest `v1.x.x` | **Typical consumers** (auto-update within major) |
| `v1.0` | Floats to latest `v1.0.x` | Production (patches only) |
| `v1.0.0` | Immutable | Maximum stability / reproducibility |

Breaking changes become a new major (`v3`). Older majors remain live and can receive backported patches.

## Upgrading

When a new major is released, update your caller's ref:

```yaml
# Before
uses: groundnuty/macf-actions/.github/workflows/agent-router.yml@v2

# After
uses: groundnuty/macf-actions/.github/workflows/agent-router.yml@v3
with:
  project: your-project-name
```

Check [CHANGELOG.md](./CHANGELOG.md) for breaking changes between majors — v3 adds required input + required secrets.

## Behavior

### v3 — registry-driven mTLS (current major)

v3 resolves each agent's host+port from the MACF registry (GitHub Variables per DR-005/DR-006/DR-007) on every event, minted via a short-lived token from a dedicated `variables:read`-only GitHub App. v2 read endpoints from the caller's `agent-config.json`; v3 makes registry the single source of truth — restoring the multi-agent-on-one-VM property dynamic port assignment was designed for.

CA certificate variable is also project-derived (`<PROJECT>_CA_CERT`) so the value `macf certs init` already writes matches the name the workflow reads.

**Hard-fail on unreachable for label routing:** if the POST to an agent's `/notify` fails, the workflow adds the `agent-offline` label + issue comment (same UX as v2). Registry-miss (agent never registered) goes through the same offline path. Mention and CI-completion paths log-only skip — one missed comment shouldn't trip offline.

### Jobs

The workflow provides four jobs:

1. **`route-by-label`** — when an issue is labeled with an agent name, resolve the agent's endpoint from the registry and POST a notification to `/notify` via mTLS.
2. **`route-by-mention`** — when an agent is `@mentioned` in a comment, PR body, or review, resolve + route the mention to each mentioned agent.
3. **`route-by-ci-completion`** — when CI finishes on an agent-authored PR, notify the authoring agent so it can merge on success or push a fix on failure without polling. Filters:
    - Only fires for PRs authored by agents configured in `agent-config.json` (skips human / dependabot / external authors)
    - Skips draft PRs
    - Skips stale CI (when the PR HEAD moved past the SHA the suite ran on, e.g. after a force-push)
    - Only terminal conclusions (`success`, `failure`, `timed_out`, `action_required`); skips `neutral`, `cancelled`, `skipped`
4. **`cleanup-labels`** — when an issue closes, remove status labels (`in-progress`, `in-review`, `blocked`)

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
