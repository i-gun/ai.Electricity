---
name: orchestrator
description: "Use when: determining ai.Electricity routing for issues, PRs, labels, workflow failures, check gates, or tag releases. Coordination only; mirrors agents/orchestrator.yaml."
argument-hint: "Event, label, PR, issue, or routing state"
user-invocable: true
---
# Orchestrator Skill

## Purpose

Use this skill to inspect or explain routing. The Orchestrator is not a smart agent and does not make product or code decisions.

Machine-readable source: `agents/orchestrator.yaml`.
Human-invocable agent: `.github/agents/orchestrator.agent.md`.

## Procedure

1. Identify the GitHub event: issue, PR, workflow run, check state, or tag create.
2. Read labels/checks involved in routing.
3. Apply `agents/orchestrator.yaml` routing rules exactly.
4. Report the target agent, labels/checks to set, and any missing state.
5. Do not edit application code, merge, release, or override gates.

## Routing Summary

- Feature/bug issue: `agent:codegen`.
- Advisory label: `advisory-agent`.
- Ready PR opened/synchronized: `review-agent` + `testing-agent`.
- Failed `ci-build-test`: `error-resolution-agent`.
- Review approve + testing pass: `vcs-agent` merge path.
- SemVer tag: `vcs-agent` release path.
