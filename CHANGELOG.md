# Changelog

All notable changes to this project will be documented in this file. The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

(no unreleased changes)

## [3.5.0] — 2026-08-31

> **⚠️ WHOEVER CUTS v3.5.0 — a `macf` verdict branch activates with this tag.**
>
> `#75`'s `TAILNET_NEEDED` carve-out makes `TS_OAUTH_CLIENT_ID`/`TS_OAUTH_SECRET`
> non-required for a job routing to a self-hosted runner. `macf`'s fleet verdict
> (`fleet-verdict.ts`, `MIN_TAILNET_CARVEOUT_ACTIONS_VERSION = 'v3.5.0'`) keys its
> required-secret set on the *pinned* router version, so **cutting this tag is the
> moment that branch becomes reachable** — and it has never run against a real pin.
>
> A wrong `carries` marks a still-six-required fleet **CONFIRMED**, which is silent.
> **First fleet to pin v3.5.0: verify its routing verdict against actual secret
> presence before trusting it.** Ref `groundnuty/macf#1239`.


### Added

- **`<PROJECT>_CA_CERT` now resolves from the REGISTRY first, with the repo variable as
  fallback** (`#66`/`#70`). Previously each `route-by-*` job read the CA solely from a
  per-repo variable, so a repo that never received one could not route
  (`groundnuty/macf#806`), and a CA rotation left every already-provisioned repo pinned
  to the superseded cert with no signal (`groundnuty/macf#800`) — the router kept
  presenting a client cert its peer no longer trusted, which surfaces as a connection
  failure rather than as "your CA is stale". The repo-variable fallback keeps
  pre-existing fleets working unchanged.

  **The rotation benefit is CONDITIONAL on `registry-api-path` being fleet-scoped.**
  That input is configurable (DR-006: `/orgs/<org>`, a profile repo, or any repo), and
  the registry read is literally `${REG_PATH}/actions/variables/<SEG>_CA_CERT`. Where a
  fleet points each agent's `registry-api-path` at that agent's OWN repo — which is how
  both `macf-experiment` fleets are configured today — the registry read and the
  repo-variable fallback resolve **the same store**, so rotation still requires touching
  every repo. Point `registry-api-path` at a shared scope to get the single-source
  property this feature enables.
 — matches `groundnuty/macf`'s `MIN_BUNDLE_CAPABLE_ACTIONS_VERSION` gate

- **Every `route-by-*` job now accepts `MACF_ROUTING_BUNDLE`** — a single `base64(JSON)` secret bundling the six routing secrets below, keyed by their own names ([groundnuty/macf#1112](https://github.com/groundnuty/macf/issues/1112) / [#1118](https://github.com/groundnuty/macf/pull/1118) / [groundnuty/macf-actions#1169](https://github.com/groundnuty/macf-actions/issues/1169)). A caller supplying the bundle needs no other routing secret, and its generated `secrets:` block never has to change again when this workflow's secret set changes — closing the class of bug where a caller generated before a secret-set change fails with `Secret X is required, but not provided` on a stale caller.
- **New first step per job, "Resolve routing secrets (prefer MACF_ROUTING_BUNDLE)"**: decodes + validates the bundle, or falls back to the legacy six individually-passed secrets (`ROUTING_CLIENT_CERT`, `ROUTING_CLIENT_KEY`, `TS_OAUTH_CLIENT_ID`, `TS_OAUTH_SECRET`, `MACF_ROUTING_APP_ID`, `MACF_ROUTING_APP_KEY`) when the bundle is absent. Additive, never a replacement — a **malformed** (present-but-unreadable) bundle fails the job loudly, naming what's wrong, and never silently falls through to the six even when those happen to be present too. A caller supplying **neither** form fails loudly, naming exactly which secret(s) are missing — never a partial run on GitHub Actions' empty-string-for-missing-secret substitution (`silent-fallback-hazards.md` Pattern D). **Exception:** `TS_OAUTH_CLIENT_ID`/`TS_OAUTH_SECRET` are NOT required in the fallback path when this run won't attempt a Tailscale connect — i.e. on the self-hosted `macf-vm` runner (already tailnet-joined, `#64`), which is the common case since `transport.tailscale_oauth_required` defaults to `false` on the `groundnuty/macf` side. Requiring them unconditionally would have broken every such already-routing fleet's upgrade.
- All six legacy secrets relax from `required: true` to `required: false` at the `workflow_call` level, so a bundle-only caller's `secrets:` block doesn't need to enumerate them. The `required: false` declaration only catches "caller's `secrets:` block omits the name" — the actual "bundle OR complete six (minus the Tailscale carve-out)" invariant is enforced in the new resolve step, the one place that already needs to inspect both sources.
- Every resolved secret value is masked (`::add-mask::`, applied **per line** — a single call on a multi-line value like `MACF_ROUTING_APP_KEY`'s raw PEM does not reliably redact it from logs, [actions/runner#475](https://github.com/actions/runner/issues/475)) before being written to `$GITHUB_ENV` behind a random per-call delimiter.
- **`route-by-label` reordered: the Label gate (skip non-agent labels + self-routing) now runs FIRST**, before secret resolution and Tailscale connect, which are gated on its `skip` output. Preserves the pre-existing no-op behavior for irrelevant-label events exactly (previously these never reached secret-dependent steps because Mint was already gated on the same output). **Visible side effect on a github-hosted (non-self-hosted) fallback runner:** an irrelevant-label event no longer joins the tailnet at all — previously it did, spending the join plus a 10s wait for a route that was never going to fire. Beneficial, but noted here since it's an observable behavior change. The other three `route-by-*` jobs have no in-job early exit, so their secret-resolution step stays first, unconditional, unchanged.
- New `test/routing-bundle-unpack.sh` canonical-vector test (wired into `ci.yml`'s `unit-tests` job) — 10 cases covering both success paths (bundle-only, legacy-six-only), 6 failure shapes (neither supplied, malformed base64, non-object JSON, partial bundle, malformed-bundle-does-not-fall-back-to-a-complete-six, partial legacy six), and 2 cases for the TS_OAUTH_* carve-out (not needed → succeeds; needed → fails naming only the two Tailscale secrets).
- `README.md` "Required secrets (v3)" section documents the bundle as the preferred form, the legacy six as the fallback, and the TS_OAUTH_* carve-out for self-hosted-only fleets.
- **New optional `runner-runs-on` input on the reusable workflow** ([groundnuty/macf-actions#81](https://github.com/groundnuty/macf-actions/issues/81)) mirrors a fleet manifest's `routing.runner.runs_on` verbatim. When a caller passes exactly `self-hosted`, `pick-runner` now FAILS the job — naming the actor, the `MACF_TRUSTED_ACTORS` variable, and the repo — instead of silently relocating to a metered `ubuntu-latest` runner for a non-fork event whose actor isn't trusted. Previously a declared-self-hosted fleet had no way to reach `pick-runner` at all (the reusable workflow accepted only `project` + `registry-api-path`), so a drifted/missing trusted-actor entry billed silently with no operator-visible signal. **The fork downgrade is unchanged** — an untrusted fork PR still relocates to hosted without failing, regardless of this input, because self-hosted access for an unreviewed fork is exactly what that downgrade exists to prevent. Omitted, empty, or any other value (e.g. `hosted`) leaves `pick-runner` exactly as it behaved before #81 — no caller migration required. **Behavior-visible detail:** the fork carve-out is keyed on `IS_FORK == "true"` specifically (only true on a `pull_request`/`pull_request_review` event from a fork); on `issues`/`issue_comment`/`check_suite` events — the majority of what this router handles — `github.event.pull_request` doesn't exist and `IS_FORK` resolves empty, so an untrusted actor there with `self-hosted` declared now fails the job too, where it previously ran green on hosted. New `test/pick-runner-decision.sh` canonical-vector test (wired into `ci.yml`'s `unit-tests` job) covers the decisive pair (self-hosted + untrusted → fails naming cause; self-hosted + trusted → unchanged), the fork-downgrade preservation for both `IS_FORK="true"` and the empty-string non-PR-event case, the hosted/undeclared no-op cases, the fail-closed case when `MACF_TRUSTED_ACTORS` itself is unreadable, and a mutation check proving the decisive case actually depends on the new enforcement. **Known gap, unverified/out of scope by design:** a trusted actor whose declared self-hosted runner isn't actually registered still gets self-hosted labels and queues indefinitely rather than failing — `pick-runner` only ever observes `MACF_TRUSTED_ACTORS` membership, never live runner-registration state.

### Unchanged (consumer migration not required)

Consumers who only `uses: .../agent-router.yml@v3` or `@v3.<minor>` and pass the six secrets individually (or `secrets: inherit` within the same org/enterprise) continue to work unchanged — the bundle is purely additive. No caller action is required to keep routing working; adopting the bundle is opt-in via `macf repo-init` regenerating the caller workflow once both `macf` and `macf-actions` are on bundle-capable versions.

### Verification caveat

This repo's own self-routing caller (`.github/workflows/routing.yml`) is pinned to `@v1.3.0` — a different major line entirely (SSH+tmux transport) — so it does **not** exercise this change at all, pre- or post-merge. Verification for this entry is static + a shell-level vector test only (`actionlint`, `blind-spot-lint.sh`, `test/routing-bundle-unpack.sh`); there is no live end-to-end GitHub Actions run backing it. `#1169`'s own closure condition ("a live fleet routes with a caller that passes only the bundle") remains unmet until that's run for real.

### Reliability

- **`pick-runner` (the first job) now asserts one complete routing-secrets form before any other job does any work** ([groundnuty/macf-actions#82](https://github.com/groundnuty/macf-actions/issues/82)). Relaxing all seven routing secrets to `required: false` (above, `#1169`) removed the composition-time failure a misconfigured caller used to get, but the only run-time check that replaced it lived inside each `route-by-*` job's own "Resolve routing secrets" step — so a caller supplying **neither** form only found out once an event happened to trigger one of those four jobs, and `config` had already run first. The new "Assert one complete routing-secrets form before any work" step is the LAST step of `pick-runner` (after runner selection, so it can read the same self-hosted/github-hosted decision the Tailscale carve-out needs) and fails the job loudly — before `config` or any `route-by-*` job runs — naming both valid forms (A: the six individual secrets: `MACF_ROUTING_APP_ID`, `MACF_ROUTING_APP_KEY`, `ROUTING_CLIENT_CERT`, `ROUTING_CLIENT_KEY`, `TS_OAUTH_CLIENT_ID`, `TS_OAUTH_SECRET`; B: `MACF_ROUTING_BUNDLE`) and exactly which of form A's six is missing (`groundnuty/macf#1336`'s live case — a partially-complete form A). A `pick-runner` failure fails/skips every downstream job via the *existing* `needs:` chain (`config: needs: pick-runner`; every `route-by-*`: `needs: [config, pick-runner, ...]`) — no new `needs:` edges were added anywhere. Each `route-by-*` job's own resolution step (`#1169`, above) is unchanged and still runs — it is what actually populates the resolved values for that job's use (App-token mint, mTLS POST); given the same inputs, it should never newly fail once the `pick-runner` assertion has already passed, so it now serves primarily as the value-resolution mechanism plus defense-in-depth. The `if:` gating this new step mirrors the *union* of the four `route-by-*` jobs' own top-level event/action gates (deliberately coarser than their finer internal filters — e.g. it requires a complete form on the first `issues: labeled` event even for a non-agent label, rather than waiting for the first agent-labeled one) — kept in lockstep by hand, same convention as the test-lockstep note below.
- **The "neither form supplied" error (in all five places — the new `pick-runner` assertion and all four pre-existing `route-by-*` "Resolve routing secrets" steps) now names the likely cause for a cross-org/enterprise caller**: GitHub's `secrets: inherit` only propagates within the *same* organization/enterprise, so a caller in a different org can have all six secrets set on its own repo and still receive nothing here ([groundnuty/macf#1338](https://github.com/groundnuty/macf/issues/1338), the reproduction case for this fix). The malformed-bundle and missing-bundle-key messages are unchanged (those indicate a bundle-packing bug, not a cross-org gap, so the hint doesn't apply there).
- New `test/pick-runner-secrets-preflight.sh` canonical-vector test (wired into `ci.yml`'s `unit-tests` job, same convention as `test/routing-bundle-unpack.sh`) — covers the decisive pair from `#82` (neither form → fails naming both forms; either form alone → proceeds unchanged), a partially-complete form A naming the empties, both forms present → no ambiguity error, the TS_OAUTH self-hosted carve-out, and malformed-bundle-does-not-fall-back. Manually verified against an always-pass mutation of the check (the decisive "neither form complete" case fails, as `assert-the-wrong-path.md` requires of a decisive test) — not itself part of the committed suite, since a hand-mutated copy isn't a repeatable CI artifact.

### Verification caveat (#82)

Same caveat as `#1169` above — this repo's own self-routing caller stays on `@v1.3.0`, unrelated to this change. Verification here is `python3 -c 'import yaml; yaml.safe_load(...)'` (parses clean), `actionlint` (zero *new* findings — diffed against the pre-change baseline, same 4 pre-existing shellcheck/expression notes at shifted line numbers), and the new `test/pick-runner-secrets-preflight.sh` (11/11 passing) plus the pre-existing 6 vector-test files (all still passing unchanged). No live GitHub Actions run backs this entry.

## [3.2.0] — 2026-04-25

### Added — visible payload-shape change (hence minor bump)

- **`route-by-label` payload now includes `repo` field** ([#30](https://github.com/groundnuty/macf-actions/issues/30)). Multi-homed agents (e.g. `macf-code-agent[bot]` serving `macf` + `macf-testbed` + `macf-marketplace` + `macf-actions`) need the origin-repo for any subsequent `gh issue view` they run; bare `gh issue view N` defaults to the cwd's repo otherwise, so a routing event from `macf-testbed` could resolve to a stale `macf#N` on the receiver side. The `repo` field carries `${{ github.repository }}` from the routing context so receivers can render `--repo` into the prompt without guessing. Receivers built against the prior payload shape ignore the extra field; consumers who want the new behavior need a receiver-side update (in macf, see notify-formatter.ts).
- **`NotifyPayloadSchema` extension** assumed on the receiver: optional `repo` field on the `issue_routed` variant. macf's schema + formatter landed in parallel ([groundnuty/macf#237](https://github.com/groundnuty/macf/pull/237)).

### Reliability

- **New CI job `blind-spot-lint`** (`test/blind-spot-lint.sh`). Static-analysis guard against 3 specific YAML patterns that have shipped broken external-caller behavior in v3.0.x: `permission-variables:` on `create-github-app-token@v3` (#20), local `uses: ./.github/actions/...` in a reusable workflow (#22), `github.workflow_sha` in a reusable workflow (#25). Each pattern references the issue that introduced it so future contributors see not just "forbidden" but *why*. Runs in `.github/workflows/ci.yml` on every push + PR. Partial close on [#24](https://github.com/groundnuty/macf-actions/issues/24); dynamic external-caller smoke remains outstanding.
- **`README.md` Contributing section** documents the lint's existence, the 3 patterns, and the self-test-blind-spot pattern that motivates it.

## [3.1.0] — 2026-04-21

### Changed

- **`resolve-agent-endpoint` composite action inlined into `route-by-label`.** Extracting to a composite was meant to dedupe across 3 jobs, but only `route-by-label` ever used it — `route-by-mention` and `route-by-ci-completion` already inline because they're loop-driven. Net duplication reduction = zero, but the composite pulled in a cross-repo dependency whose resolution hit two framework pitfalls:
  - Step-level `uses:` doesn't evaluate `${{ github.* }}` (see [#22](https://github.com/groundnuty/macf-actions/issues/22)), forcing an intermediary `actions/checkout` step.
  - `github.workflow_ref` is caller-scoped in reusable workflows (see [#25](https://github.com/groundnuty/macf-actions/issues/25)), so there's no reliable context-based way to pin the checkout at the reusable's own commit. v3.0.3 worked by coincidence when caller and reusable tracked the same branch; a silent-drift vector for tag-pinned consumers.
- **Fix:** inlined the 15-line registry-lookup shell into `route-by-label` directly, parity with the two already-inline jobs. Eliminates:
  - `.github/actions/resolve-agent-endpoint/` directory (removed).
  - Cross-repo `actions/checkout` step (removed from route-by-label).
  - `Resolve reusable workflow ref` step + its `github.workflow_ref` parse (removed).
  - `actions/create-github-app-token@v3` call (no permission change — still same token minting, just in the inline path).
- **Test drift-catcher retained:** `test/resolve-agent-endpoint-transform.sh` continues to run against the pure-shell transform (it tests the transform itself, not the wrapper); still paired with macf's `test/registry/variable-name.test.ts` per the canonical-vector-shared contract.

### Removed — ⚠ visible surface change (hence minor bump, not patch)

- `.github/actions/resolve-agent-endpoint/action.yml` directory is gone. Anyone who was directly referencing it via `uses: groundnuty/macf-actions/.github/actions/resolve-agent-endpoint@...` from their own workflow will fail. Extremely unlikely to affect any real consumer — the composite was documented as reusable-internal, never advertised as a standalone surface — but documented as breaking regardless per strict semver.

### Unchanged (consumer migration not required for normal callers)

Consumers who only `uses: .../agent-router.yml@v3` or `@v3.<minor>` continue to work unchanged. Floating `@v3` moves on release; next event picks up v3.1.0. No new inputs, no new secrets, no config schema change.

### Related

- #18 (original v3.0.0 composite extraction)
- #22 (first cross-repo-checkout bug)
- #25 (second — workflow_ref scoping)
- #24 (CI: external-caller smoke test — still outstanding, higher priority than ever after this)

## [3.0.3] — 2026-04-21

### Fixed

- **Composite-action checkout now pins to the reusable workflow's OWN ref** via `github.workflow_ref` parsing, not `github.workflow_sha`. In a reusable-workflow context, `github.workflow_sha` is the **caller's** commit SHA, not the reusable's — a documented GitHub Actions quirk ([community#31054](https://github.com/orgs/community/discussions/31054), [toolkit#1264](https://github.com/actions/toolkit/issues/1264)). v3.0.2's checkout passed the caller's SHA to `repository: groundnuty/macf-actions, ref: ...`, which 100% of the time is a SHA that doesn't exist in macf-actions's git history. `fatal: not our ref <sha>` at checkout, job failed. Closes [`groundnuty/macf-actions#25`](https://github.com/groundnuty/macf-actions/issues/25).

### Fix shape

New `Resolve reusable workflow ref` step parses `github.workflow_ref` (format: `owner/repo/.github/workflows/file.yml@refs/{tags,heads}/<ref>` or `...@<sha>`) via pure shell:

```bash
ref="${GH_WORKFLOW_REF##*@}"
ref="${ref#refs/tags/}"
ref="${ref#refs/heads/}"
```

Handles all three consumer pin forms (tag, branch, raw SHA). The subsequent `actions/checkout` uses the parsed ref, so the composite-action copy comes from the exact macf-actions commit/tag the caller invoked.

### Root-cause pattern — 4th self-test blind spot

This is the 4th v3-series bug (after #18, #20, #22) that passed macf-actions self-tests and broke live external callers. Self-routing runs with caller-workflow-SHA == reusable-workflow-SHA, hiding every cross-repo pinning bug. **#24 (external-caller smoke test per tag) is now the highest-priority infra item** — no more v3 patches should ship without it.

### Unchanged (consumer migration not required)

No consumer action required. Floating `@v3` moves on release; callers auto-pick up `v3.0.3` on next event.

## [3.0.2] — 2026-04-21

### Fixed

- **Composite action `resolve-agent-endpoint` now loads from `groundnuty/macf-actions` regardless of caller.** v3.0.0–v3.0.1 called `uses: ./.github/actions/resolve-agent-endpoint` after a local sparse-checkout — which worked in macf-actions self-tests (checkout fetches macf-actions itself) but broke for every external caller (checkout fetches the caller's repo, where the composite doesn't exist). Route-by-label then errored with `Can't find 'action.yml' ... under .github/actions/resolve-agent-endpoint` and fell through to the `agent-offline` path. The END symptom was misleading — consumers saw "agent is not registered" comments for agents that were actually registered fine. Closes [`groundnuty/macf-actions#22`](https://github.com/groundnuty/macf-actions/issues/22).
- **Fix:** the `actions/checkout` preceding the composite now explicitly pulls `groundnuty/macf-actions` at `${{ github.workflow_sha }}` (the reusable-workflow's own commit SHA — immutably pinned). The local `uses: ./...` then resolves against that checked-out copy. Step-level `uses:` refs can't evaluate `${{ github.* }}` contexts directly, so the cross-repo-at-workflow-SHA pattern requires the explicit checkout intermediary.

### Removed

- **Dead sparse-checkout step in `route-by-ci-completion`.** Defensive leftover from v3.0.0 authoring — that job uses inline registry lookup (not the composite action), so the composite-action checkout was never needed. Dropping it in v3.0.2 saves ~30s per CI-completion event.

### Self-test blind spot — recurring theme

This is the 3rd v3 bug caught by a live external caller (after #18 port-config and #20 permission-variables). macf-actions's self-routing tests run in a context where the caller IS macf-actions, which hides any bug that's specific to cross-repo consumers. Follow-up: add an automated external-caller smoke test per tag before promoting floating majors. Filing as a separate issue after v3.0.2 ships.

### Unchanged (consumer migration not required)

No consumer action required. Floating `@v3` moves on release; callers auto-pick up `v3.0.2` on next event.

## [3.0.1] — 2026-04-21

### Fixed

- **Dropped `permission-variables: read` input from all 3 `actions/create-github-app-token@v3` steps.** That input isn't in `create-github-app-token@v3`'s schema (per-permission inputs map to GitHub Apps' [permission names](https://docs.github.com/en/rest/apps/apps#list-installations-for-the-authenticated-app), e.g. `permission-actions`, `permission-contents` — there's no `permission-variables` because actions-variables isn't separately exposable through that subset mechanism). v3.0.0 passed it anyway; GitHub's API received it as a subset-request and returned `422: "The permissions requested are not granted to this installation"`, blocking every routing event. Closes [`groundnuty/macf-actions#20`](https://github.com/groundnuty/macf-actions/issues/20).
- The `macf-routing` App is minimum-scope by design (Organization Variables + Actions Variables read-only) — minting a token with the App's full default permission set is already the narrowest grant available, so no subset-request is needed or helpful here.

### Unchanged (consumer migration not required)

No consumer action required. Existing callers on `@v3` / `@v3.0.0` auto-pick up `v3.0.1` because the floating `v3` tag moves on release. No new secrets, no agent-config.json changes, no `with:` input changes. Just merge + tag.

### Known deprecation warning (not yet fixed)

`create-github-app-token@v3` warns that `app-id` is deprecated in favor of `client-id`. Fix is deferred to v4 (breaking: requires consumers to set `MACF_ROUTING_CLIENT_ID` secret instead of reusing `MACF_ROUTING_APP_ID`). Ignoring the warning in v3.0.1 keeps floating-tag consumers on v3 working.

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
