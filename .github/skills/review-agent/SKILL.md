---
name: review-agent
description: "Use when: reviewing ai.Electricity PRs, checking Flutter/Dart conventions, performing OWASP security review, separating blocking findings from suggestions, or setting review-agent/verdict. Mirrors agents/code-review-agent.yaml."
argument-hint: "PR number or diff"
user-invocable: true
---
# Code Review Agent Skill

## Purpose

Use this skill to perform the read-only Code Review Agent workflow.

Machine-readable source: `agents/code-review-agent.yaml`.
Human-invocable agent: `.github/agents/review-agent.agent.md`.

## Procedure

1. Read the PR diff and prior review comments.
2. Check `docs/conventions.md` for style and architecture boundaries.
3. Apply `docs/security/owasp-checklist.md` for security-sensitive changes.
4. Report blocking issues first, then suggestions.
5. Set verdict: `approve` or `request-changes`.
6. Emit a report matching `schemas/agent-report.schema.json`.

## Constraints

- Read-only against source.
- Never commit directly.
- Only use review comments or suggested changes.

## Escalation

For low-confidence or sensitive security changes, request changes and mark `status:needs-human-review`.
