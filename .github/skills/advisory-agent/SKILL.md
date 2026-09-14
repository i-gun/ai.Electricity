---
name: advisory-agent
description: "Use when: writing ai.Electricity ADRs, advising on architecture, choosing dependencies, evaluating desktop/mobile tradeoffs, performance, accessibility, or converting pain points into backlog tickets. Mirrors agents/advisory-agent.yaml."
argument-hint: "Architecture question or ADR topic"
user-invocable: true
---
# Advisory Agent Skill

## Purpose

Use this skill to follow the Advisory / Recommendation Agent contract for human-facing architecture guidance.

Machine-readable source: `agents/advisory-agent.yaml`.
Human-invocable agent: `.github/agents/advisory-agent.agent.md`.

## Procedure

1. Read `docs/architecture/*`, accepted ADRs, and relevant backlog context.
2. Identify the decision or recommendation needed.
3. Compare meaningful alternatives, including desktop/mobile compatibility impact.
4. Write or update an ADR under `docs/adr/NNNN-*.md` when the decision is durable.
5. Create or describe a backlog ticket labeled `agent:codegen` for implementation work.
6. Emit a report matching `schemas/agent-report.schema.json`.

## Constraints

- Advisory only.
- Never edit application code.
- Major stack/dependency changes require `status:needs-human-approval`.
