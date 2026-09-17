---
name: "Ship Pull Request"
description: "Inspect local changes, group independent change contexts, infer PR branch names, checkout before staging, create Conventional Commits, push without force, and open draft pull requests."
agent: "Version Control Agent"
tools: [read, search, execute]
argument-hint: "Commit message, PR title/body, and optional target branch"
---

Ship the current local changes through this exact sequence for each independent change context: inspect, infer branch name, confirm, checkout a new branch, stage only that context, commit, push, then open a draft pull request.

Inputs:
- Commit message: {{commit_message}}
- PR title: {{pr_title}}
- PR body: {{pr_body}}
- Target branch: {{target_branch}}

Rules:
1. Inspect the current branch, working-tree status, staged changes, untracked files, remotes, configured upstream, and diff. Never stage, commit, or push directly on `main`, `master`, `develop`, `release/*`, or any protected branch.
2. If the current branch is protected, stop after inspection unless the next confirmed action is to checkout a new branch from the current HEAD before staging.
3. Run `git diff --check` before staging. If it fails, stop and report the offending files.
4. Detect unrelated, non-interfering change contexts by file ownership, package boundary, behavior area, and prompt/instruction scope. Examples: core code changes and agent customization updates are separate contexts unless one directly depends on the other.
5. Order independent contexts by least-cost first: smallest blast radius, fewest files, documentation or prompt-only changes before application code, tests before broad implementation, and no dependency on a later context.
6. Infer a branch name for each context from the inspected changes. Use a lowercase slug based on the package or ownership area and the behavior being changed, prefer established prefixes such as `feat/`, `fix/`, `docs/`, `test/`, `refactor/`, or `chore/`, and include an issue number when one is evident from the request or existing branch. Do not require manual branch-name input.
7. Present the inspected state, inferred context windows in execution order, inferred branch name for each context, files to be staged per context, proposed Conventional Commit message per context, push target, and PR title/body. Require explicit human confirmation before any write operation.
8. After confirmation, execute only this order for the first context, stopping on the first failure:
   - Checkout a new branch using the confirmed inferred branch name for that context.
   - Verify the branch changed and is not protected.
   - Run `git diff --check` again before staging.
   - `git add` only the confirmed files for that context.
   - Create one plain commit using the confirmed Conventional Commit message for that context.
   - Push the new branch to the confirmed remote with `git push -u`, without force-pushing.
   - Open a draft pull request with `gh pr create --draft` against the confirmed target branch.
9. After a context is shipped, return to the original base branch or confirmed target branch, verify the remaining uncommitted changes still match the next context window, and repeat Rule 8 for the next context. Stop and ask for confirmation again if the remaining diff no longer matches the confirmed plan.
10. Do not stage files outside the current context window. Do not amend, reset, force-push, force-push-with-lease, merge, delete branches, rewrite history, or bypass required checks.
11. Report each context window with its commit SHA, pushed branch, and pull-request URL, or the exact step and error that blocked the flow.