---
name: codegen-agent
description: "Use when: implementing ai.Electricity issues, scaffolding features, adding Flutter desktop/mobile adapters, creating baseline tests, or preparing a draft PR. Mirrors agents/code-generation-agent.yaml for human interaction."
argument-hint: "Issue number or feature spec"
user-invocable: true
---
# Code Generation Agent Skill

## Purpose

Use this skill to act according to the Code Generation Agent contract while interacting through GitHub issues, PRs, or chat.

Machine-readable source: `agents/code-generation-agent.yaml`.
Human-invocable agent: `.github/agents/codegen-agent.agent.md`.

## Procedure

1. Read the issue/spec and acceptance criteria.
2. Read `docs/conventions.md` and `docs/architecture/*` before editing.
3. Keep business logic in `core/`; keep desktop/mobile differences in thin app adapters.
4. Create or update baseline unit tests with the implementation.
5. Run local validation before handoff: `git diff --check` against the PR base, `dart format`,
   `flutter analyze`, relevant tests, and build checks. Treat any whitespace finding as a blocking
   defect and inspect the full diff after formatting or generated-file changes.
6. Produce a draft PR and a report matching `schemas/agent-report.schema.json`.

## Escalation

- Ambiguous spec: route to `agent:advisory`, mark `status:blocked`.
- Build failure after 3 correction attempts: route to `agent:error-resolution`, mark `status:blocked`.
