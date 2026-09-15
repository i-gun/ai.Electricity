#!/usr/bin/env python3
"""Human-invocable helper that lands a local branch onto a protected branch
via a Pull Request, gated on required CI checks and reviewer approval.

Mirrors the vcs-agent merge policy in agents/version-control-agent.yaml, for
developers who want the same guardrails when working outside the Actions-driven
flow. Never merges without explicit interactive confirmation, never force-pushes.

Requires: git, GitHub CLI (`gh`) installed and authenticated (`gh auth status`).

Usage:
    python .github/scripts/vcs_pull_request.py --base main [--title "..."] [--body "..."]
"""
from __future__ import annotations

import argparse
import json
import shutil
import subprocess
import sys

PROTECTED_BRANCHES = ["main", "master"]


def run(cmd: list[str], check: bool = True) -> subprocess.CompletedProcess:
    return subprocess.run(cmd, capture_output=True, text=True, check=check)


def current_branch() -> str:
    return run(["git", "rev-parse", "--abbrev-ref", "HEAD"]).stdout.strip()


def is_protected(branch: str) -> bool:
    return branch in PROTECTED_BRANCHES or branch.startswith("release/")


def preconditions() -> str | None:
    if not shutil.which("gh"):
        return "gh_cli_unavailable: install the GitHub CLI (https://cli.github.com/)"
    if run(["gh", "auth", "status"], check=False).returncode != 0:
        return "gh_not_authenticated: run `gh auth login` (or export GH_TOKEN) first"
    return None


def poll_checks_and_review(pr_number: str) -> tuple[bool, str]:
    checks = run(["gh", "pr", "checks", pr_number], check=False)
    print(checks.stdout or checks.stderr)
    if checks.returncode != 0:
        return False, "required checks are pending or failing; re-run after they pass"

    view = run(["gh", "pr", "view", pr_number, "--json", "reviewDecision"], check=False)
    decision = json.loads(view.stdout or "{}").get("reviewDecision")
    if decision != "APPROVED":
        return False, f"review not approved yet (reviewDecision={decision})"
    return True, ""


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--base", default="main", help="Target protected branch (default: main).")
    parser.add_argument("--title", help="PR title. Defaults to the last commit subject.")
    parser.add_argument("--body", default="", help="PR body.")
    args = parser.parse_args()

    precondition_failure = preconditions()
    if precondition_failure:
        print(f"BLOCKED: {precondition_failure}", file=sys.stderr)
        return 2

    branch = current_branch()
    if is_protected(branch):
        print(f"BLOCKED: current branch '{branch}' is protected; create a feature branch first.", file=sys.stderr)
        return 2

    push = run(["git", "push", "-u", "origin", branch], check=False)
    if push.returncode != 0:
        print(push.stderr, file=sys.stderr)
        return 1
    print(push.stderr or push.stdout)

    existing = run(["gh", "pr", "view", "--json", "number,state,url"], check=False)
    if existing.returncode == 0:
        pr = json.loads(existing.stdout)
        pr_number, pr_url = str(pr["number"]), pr["url"]
        print(f"Reusing existing PR #{pr_number} ({pr['state']}): {pr_url}")
    else:
        title = args.title or run(["git", "log", "-1", "--pretty=%s"]).stdout.strip()
        create = run(
            ["gh", "pr", "create", "--base", args.base, "--head", branch, "--title", title, "--body", args.body],
            check=False,
        )
        if create.returncode != 0:
            print(create.stderr, file=sys.stderr)
            return 1
        pr_url = create.stdout.strip().splitlines()[-1]
        pr_number = pr_url.rstrip("/").rsplit("/", 1)[-1]
        print(f"Opened PR #{pr_number}: {pr_url}")

    ready, reason = poll_checks_and_review(pr_number)
    if not ready:
        print(f"NOT READY TO MERGE: {reason}")
        print("Re-run this script once checks pass and review is approved.")
        return 0

    confirm = input(f"All checks passed and review approved for PR #{pr_number}. Merge now? [y/N] ").strip().lower()
    if confirm != "y":
        print("Merge skipped by user. Nothing further to do.")
        return 0

    merge = run(["gh", "pr", "merge", pr_number, "--squash", "--delete-branch"], check=False)
    print(merge.stdout or merge.stderr)
    if merge.returncode != 0:
        return 1

    run(["git", "switch", args.base], check=False)
    run(["git", "pull", "origin", args.base], check=False)
    print(f"Merged and switched back to '{args.base}'.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
