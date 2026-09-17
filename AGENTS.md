# AGENTS.md — ai.Electricity Multi-Agent Development System

This document is the source-of-truth contract for every automated agent that participates in
building, reviewing, testing, and releasing **ai.Electricity**. It exists so that agents (and the humans
supervising them) can be reasoned about independently: each agent is single-responsibility,
stateless/idempotent, and communicates only through the shared artifacts described below — never
by calling into another agent's internals.

See also:
- [`docs/adr/0001-cross-platform-stack-and-testing-strategy.md`](docs/adr/0001-cross-platform-stack-and-testing-strategy.md) — chosen stack & testing strategy.
- [`agents/`](agents/) — one machine-readable config per agent.
- [`schemas/task.schema.json`](schemas/task.schema.json) and [`schemas/agent-report.schema.json`](schemas/agent-report.schema.json) — the JSON contracts every message on the bus must satisfy.
- [`.github/workflows/`](.github/workflows/) — the event bus implementation (GitHub Issues/PRs/Actions).

## 0. Shared Infrastructure (the "bus")

No dedicated message broker exists yet, so the **event bus is GitHub itself**:

| Bus primitive | Role |
|---|---|
| Issues | Task board / backlog. Labels (`agent:*`, `type:*`, `status:*`) encode routing state. |
| Issue/PR comments | Structured agent reports (see `schemas/agent-report.schema.json`), forming the audit trail. |
| Pull Requests | Handoff artifact from Generation → Review/Testing → Version Control. |
| GitHub Actions | Orchestrator implementation — routes `issues`, `pull_request`, `push`, `workflow_run`, and `create` (tag) events to the correct agent workflow. |
| `/logs` (repo artifact, uploaded per workflow run) | Structured record of every agent decision + confidence score. |
| Branch protection rules | Enforcement point for "no agent merges without review + green tests". |

Every agent, on every run, must:
1. Read only the inputs defined in its contract (no reaching into another agent's config or state).
2. Emit a small report matching `schemas/agent-report.schema.json` as a PR/issue comment AND as a log artifact under `/logs/<agent>/<run-id>.json`. Verbose build logs are disposable and must not be committed.
3. Be safe to re-run on the same input (idempotent) — re-running must not duplicate side effects (e.g., must update its own prior comment/label rather than posting duplicates).
4. Never perform an action outside its declared **Outputs** — in particular, never merge, force-push, or rewrite history without the human-in-the-loop gate.

## 1. Code Generation Agent

| | |
|---|---|
| **Name** | `codegen-agent` |
| **Trigger** | Issue labeled `agent:codegen` (from Orchestrator routing on `issues.opened`/`issues.labeled`), or an Advisory Agent ticket labeled `type:tech-debt`/`type:adr-followup`. |
| **Inputs** | Issue body (feature spec), `docs/architecture/*`, existing shared `core/` package, platform adapter conventions in `docs/conventions.md`. |
| **Outputs** | New branch `feat/<issue-number>-<slug>`, source files + unit tests (baseline, expanded later by Testing Agent), draft PR (`draft: true`) linked to the issue, a generation report comment. |
| **Skills/Tools** | Source scaffolding, spec-to-code generation, platform adapter generation (desktop shell vs. mobile shell against the shared `core/` business-logic layer), local lint/build runner. |
| **Constraints** | Must never push to `main`/`release/*`. Must run local whitespace, lint, test, and build checks before opening the PR; `git diff --check` is required because remote review rejects trailing whitespace in generated and documentation files. If a check fails, it self-corrects up to N attempts, then escalates. Must not mark the PR ready-for-review until its own checks pass. |
| **Escalation** | If spec is ambiguous or local build/lint cannot be made green after retries → comment on the issue with `status:blocked`, label `agent:advisory` (spec clarification) or `agent:error-resolution` (build failure), and stop. |

## 2. Code Review Agent

| | |
|---|---|
| **Name** | `review-agent` |
| **Trigger** | `pull_request.opened` / `pull_request.synchronize` when PR is `ready_for_review` (routed by Orchestrator). |
| **Inputs** | PR diff, `docs/conventions.md` (style guide), prior review comments on the PR (for idempotent re-review), OWASP Top 10 checklist. |
| **Outputs** | Structured review comment (blocking issues vs. suggestions per `schemas/agent-report.schema.json`), a review verdict (`approve` / `request-changes`) surfaced as a required GitHub check `review-agent/verdict`. |
| **Skills/Tools** | Static analysis, style/lint enforcement, security review (OWASP Top 10), diff-level reasoning, suggested-edit comments. |
| **Constraints** | **Read-only** against source — may only affect the repo via review comments or GitHub "suggested changes"; never commits directly. |
| **Escalation** | If diff is too large/out of scope to review deterministically, or touches security-sensitive code (auth, secrets handling) beyond its confidence threshold → verdict `request-changes` with `status:needs-human-review` label, tagging a human reviewer. |

## 3. Advisory / Recommendation Agent

| | |
|---|---|
| **Name** | `advisory-agent` |
| **Trigger** | Manual/scheduled (roadmap review), or invoked when another agent reports a `pain-point` (e.g., Error Resolution Agent sees a recurring failure class, Testing Agent sees a persistent coverage gap). |
| **Inputs** | Current architecture snapshot (`docs/architecture/*`), roadmap/backlog issues, pain-point reports from other agents. |
| **Outputs** | ADR files under `docs/adr/NNNN-*.md`, backlog issues labeled `agent:codegen` (handoff as tickets), never code. |
| **Skills/Tools** | Architecture/dependency tradeoff analysis, cross-platform (desktop vs. mobile) compatibility review, performance/accessibility guidance. |
| **Constraints** | **Advisory only** — never edits application code directly; all action items become tickets for the Code Generation Agent. |
| **Escalation** | If a recommendation requires a major dependency/framework change → open ADR as `status:proposed` and label `status:needs-human-approval`; do not auto-file as an actionable ticket until a human accepts the ADR. |

## 4. Error Resolution Agent

| | |
|---|---|
| **Name** | `error-resolution-agent` |
| **Trigger** | **Reactive**: `workflow_run` failure event from `ci-build-test.yml` on any branch/PR. **On-demand**: developer comment `/fix` on an issue/PR, or explicit invocation with repro steps. |
| **Inputs** | Failing stack trace/log (CI artifact), failing test id(s), or an explicit repro description. |
| **Outputs** | A minimal-diff fix pushed to the *same* PR branch (or a new `fix/<...>` branch for standalone bugs) with an explanation comment, **or** an escalation issue labeled `status:root-cause-unclear` if it cannot isolate a cause. |
| **Skills/Tools** | CI log triage, root-cause analysis, minimal-diff patching, local repro runner. |
| **Constraints** | Never force-pushes; never rewrites shared history; fixes must pass the same lint/build/test gate as Code Generation Agent output before being handed back to Review/Testing agents. |
| **Escalation** | Root cause ambiguous after bounded investigation, or fix would require an architectural change → file escalation issue for `agent:advisory` and/or a human, with full triage notes attached. |

## 5. Version Control / GitHub Agent

| | |
|---|---|
| **Name** | `vcs-agent` |
| **Trigger** | Generation/Error-Resolution agent marks a PR ready; Review Agent verdict = `approve`; Testing Agent gate = `pass`; tag push (`create` event matching `v*.*.*`). |
| **Inputs** | Completed branch/PR, Review Agent verdict, Testing Agent gate result, Conventional Commits history. |
| **Outputs** | Enforced branch naming, Conventional-Commit-formatted merge commits, labeled/merged PRs, changelog entries (`CHANGELOG.md`), SemVer tags, GitHub Releases. |
| **Skills/Tools** | Branch management, PR creation/labeling, merge-policy enforcement (required checks), changelog generation, SemVer tagging. |
| **Constraints** | Merges only when **both** `review-agent/verdict = approve` **and** `testing-agent/gate = pass` are green required checks. Never force-pushes or rewrites shared history without an explicit human approval comment (`/approve-force-push` from a maintainer). |
| **Escalation** | Required checks stuck failing beyond retry budget, or a release step (tagging/publish) fails → open a `status:blocked` issue tagging a human maintainer; never bypasses the gate itself. |

## 6. Testing Agent

| | |
|---|---|
| **Name** | `testing-agent` |
| **Trigger** | `pull_request.opened`/`synchronize` (routed by Orchestrator alongside Review Agent). |
| **Inputs** | Source diff, existing coverage report (`/coverage/lcov.info`), target platform matrix (`docs/platform-matrix.md`). |
| **Outputs** | New/expanded unit/integration/e2e-smoke tests, updated coverage report, a required GitHub check `testing-agent/gate` (`pass`/`fail`), flaky-test quarantine list (`docs/flaky-tests.md`). |
| **Skills/Tools** | Unit/integration/e2e authoring, coverage-gap detection, cross-platform test execution (desktop targets + mobile emulators/simulators in CI), fixture/test-data generation. |
| **Constraints** | Gate fails merge if line/branch coverage < **90%** overall, or < **100%** for files under `core/lib/**` (critical domain logic). Flaky tests are quarantined (marked `@skip` + tracked), not silently deleted. |
| **Escalation** | Cannot raise coverage without a spec/architecture change, or a platform emulator target is unavailable in CI → escalate to `agent:advisory` (spec/tooling gap) with the gate left at `fail`. |

## 7. Orchestrator

The Orchestrator is **not an intelligent agent** — it is pure event routing/state-keeping, implemented
as GitHub Actions workflows plus label-based task-board state, so the real agents never poll each
other directly.

| Event | Routed to |
|---|---|
| `issues.opened` / `issues.labeled: type:feature,type:bug` | Code Generation Agent (`agent:codegen`) |
| `pull_request.opened` / `.synchronize` (ready for review) | Code Review Agent + Testing Agent (parallel, decoupled) |
| `workflow_run` failure of CI build/test | Error Resolution Agent (`agent:error-resolution`) |
| `pull_request` all required checks green | Version Control Agent (merge) |
| `create` (tag `v*.*.*`) | Version Control Agent (release) |
| pain-point report comment (`agent:advisory` label) from any agent | Advisory Agent |
| `workflow_dispatch:code-build-artifacts` | Code Build Agent (manual, confirmation-gated artifact verification) |

State lives entirely in GitHub labels/issue status (`status:*`) and PR check-runs — the Orchestrator
itself is stateless and only re-derives routing from the current event + current labels.

## Cross-Cutting Guardrails

- No agent bypasses code review or the testing gate.
- No agent pushes directly to `main`/`release/*`.
- Secrets/credentials are never generated, logged, or requested by any agent.
- All destructive git operations (force-push, history rewrite, branch deletion of shared branches, major dependency bumps) require an explicit human approval comment before the Version Control Agent will act.
- Every agent run produces a small structured audit entry under `/logs/<agent>/<run-id>.json` in addition to its human-facing comment. Verbose `*.build-log.json` files are local/CI diagnostics only and are excluded from commits.

## 8. Code Build Agent

The Code Build Agent is manually invoked through `code-build-artifacts.yml` only. It resolves a
branch/ref to an immutable commit, requires explicit confirmation of every platform, mode, and
format, runs the quality and capability gates, and retains checksummed artifacts and logs. When
human-invoked, it first consults the Version Control Agent for the current branch and working-tree
status: on a clean `main` tree it proceeds; on a clean non-`main` tree it explicitly asks whether to
build on the current branch; on a dirty tree it explicitly asks whether to stage/commit local
changes and, if confirmed, delegates that to the Version Control Agent before re-checking. It never
inspects or mutates git state directly, never changes application source, publishes releases, tags
or pushes commits, merges pull requests, or creates signed/distribution artifacts without a future
approved design. Version Control Agent, Review Agent, and Testing Agent ownership is unchanged.
