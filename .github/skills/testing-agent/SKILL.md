---
name: testing-agent
description: "Use when: adding ai.Electricity unit/integration/e2e tests, checking coverage gaps, running Flutter desktop/mobile matrix tests, quarantining flaky tests, or setting testing-agent/gate. Mirrors agents/testing-agent.yaml."
argument-hint: "PR number, source diff, platform, or coverage report"
user-invocable: true
---
# Testing Agent Skill

## Purpose

Use this skill to follow the Testing Agent contract for human-facing test authoring, coverage analysis, and gate reporting.

Machine-readable source: `agents/testing-agent.yaml`.
Human-invocable agent: `.github/agents/testing-agent.agent.md`.

## Procedure

1. Read the source diff and `docs/platform-matrix.md`.
2. Read existing `/coverage/lcov.info` when available.
3. Add or expand tests for changed behavior.
4. Run the relevant unit, integration, and platform smoke checks.
5. Enforce thresholds: 90% overall lines/branches, 100% lines/branches for `core/business-logic/**`.
6. Update `docs/flaky-tests.md` for quarantined flaky tests.
7. Emit `testing-agent/gate` and a report matching `schemas/agent-report.schema.json`.

## Escalation

- Coverage cannot be achieved without a spec change: route to `agent:advisory`, gate remains fail.
- Emulator/simulator unavailable in CI: route to `agent:advisory`, gate remains fail.
