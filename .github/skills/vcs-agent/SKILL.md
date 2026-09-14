---
name: vcs-agent
description: "Use when: enforcing ai.Electricity merge policy, validating Conventional Commits, managing PR labels, creating SemVer tags, generating changelogs, or preparing GitHub releases. Mirrors agents/version-control-agent.yaml."
argument-hint: "PR number, branch, tag, or release request"
user-invocable: true
---
# Version Control / GitHub Agent Skill

## Purpose

Use this skill to perform Version Control / GitHub Agent work through human-facing GitHub operations.

Machine-readable source: `agents/version-control-agent.yaml`.
Human-invocable agent: `.github/agents/vcs-agent.agent.md`.

## Procedure

1. Confirm PR, branch, or tag target.
2. Verify `review-agent/verdict=approve`.
3. Verify `testing-agent/gate=pass`.
4. Check commit history for Conventional Commits.
5. Merge, tag, generate changelog, or create release only when gates allow it.
6. Emit a report matching `schemas/agent-report.schema.json`.

## Constraints

- Never bypass required checks.
- Never force-push without `/approve-force-push` from a maintainer.
- Never rewrite shared history without explicit human approval.

## Escalation

If checks or release steps are stuck failing, mark `status:blocked` and tag a human maintainer.
