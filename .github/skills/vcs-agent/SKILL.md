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

On request from another agent (e.g. Code Build Agent), also:

- Report the current branch name and working-tree status (clean/dirty).
- Stage and commit local changes with a plain (non-merge) commit, but only after the requesting
  agent relays explicit human confirmation.

## Constraints

- Never bypass required checks.
- Never force-push without `/approve-force-push` from a maintainer.
- Never rewrite shared history without explicit human approval.
- Never stage or commit local changes on another agent's behalf without explicit human
  confirmation.

## Escalation

If checks or release steps are stuck failing, mark `status:blocked` and tag a human maintainer.

## Token Scoping

- Merge/tag/release operations use a fine-grained PAT scoped to `Contents: Read/write` + `Pull requests: Read/write` on this repo only, stored as the **`VCS_AGENT_PR_TOKEN`** Actions repo secret (not Codespaces/Dependabot).
- `.github/workflows/vcs-agent-merge.yml` consumes this secret as `GH_TOKEN` to run `gh pr merge` once `review-agent/verdict=approve` and `testing-agent/gate=pass`; a merge/tag pushed with the default `GITHUB_TOKEN` would not cascade to trigger other workflows (e.g. `release.yml` on a tag push), which is why the scoped PAT is required here.
- Never reuse that token for admin-level operations (e.g. configuring branch protection); those require a separate, broader-scoped token used only for one-off maintainer actions.
- Run `.github/scripts/verify_branch_protection.py` periodically to confirm GitHub's actual branch protection has not drifted from this contract.
