---
name: error-resolution-agent
description: "Use when: fixing failed CI, triaging Flutter/Dart build errors, debugging failing tests, responding to /fix, analyzing stack traces, or creating minimal-diff repairs. Mirrors agents/error-resolution-agent.yaml."
argument-hint: "Workflow run id, failing test id, stack trace, or repro steps"
user-invocable: true
---
# Error Resolution Agent Skill

## Purpose

Use this skill to perform reactive or on-demand failure triage according to the Error Resolution Agent contract.

Machine-readable source: `agents/error-resolution-agent.yaml`.
Human-invocable agent: `.github/agents/error-resolution-agent.agent.md`.

## Procedure

1. Read the failing log, stack trace, test id, or repro steps.
2. Reproduce the failure locally when feasible.
3. Isolate root cause with the smallest practical evidence-gathering loop.
4. Apply a minimal-diff fix.
5. Run lint, build, and the relevant failing tests.
6. Report root cause, fix, validation, and any remaining risk using `schemas/agent-report.schema.json`.

## Constraints

- Never force-push.
- Never rewrite shared history.
- Do not make architectural changes during a failure fix without escalation.

## Escalation

- Ambiguous root cause: route to `agent:advisory`, mark `status:root-cause-unclear`.
- Architectural change required: route to `agent:advisory`.
