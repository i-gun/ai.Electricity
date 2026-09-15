#!/usr/bin/env python3
"""Read-only verification that GitHub branch protection matches the merge
policy declared in agents/version-control-agent.yaml (required PR, required
status checks, required reviews, no force-push, admins enforced).

Never modifies protection settings; only reports drift so a repo admin can
remediate. Requires the GitHub CLI (`gh`) to be installed and authenticated.

Usage:
    python .github/scripts/verify_branch_protection.py [--branch main] [--json]
"""
from __future__ import annotations

import argparse
import json
import shutil
import subprocess
import sys

DEFAULT_BRANCHES = ["main"]


def gh_available() -> bool:
    return shutil.which("gh") is not None


def resolve_repo_slug() -> str | None:
    proc = subprocess.run(
        ["gh", "repo", "view", "--json", "nameWithOwner", "-q", ".nameWithOwner"],
        capture_output=True,
        text=True,
    )
    if proc.returncode != 0:
        return None
    return proc.stdout.strip() or None


def check_branch_protection(repo_slug: str, branch: str) -> dict:
    """Query GitHub's unified "effective rules for a branch" endpoint, which
    reports guardrails from both classic branch protection and Rulesets (the
    UI now creates Rulesets by default, so checking only the classic
    `/branches/{branch}/protection` endpoint would miss them)."""
    proc = subprocess.run(
        ["gh", "api", f"repos/{repo_slug}/rules/branches/{branch}"],
        capture_output=True,
        text=True,
    )
    if proc.returncode != 0:
        return {
            "branch": branch,
            "protected": False,
            "error": proc.stderr.strip()[:400] or "could not resolve effective rules for this branch",
        }
    try:
        rules = json.loads(proc.stdout)
    except json.JSONDecodeError:
        return {"branch": branch, "protected": False, "error": "unparseable gh api response"}

    by_type = {rule.get("type"): rule.get("parameters", {}) for rule in rules if isinstance(rule, dict)}

    pull_request = by_type.get("pull_request")
    required_reviewers = (pull_request or {}).get("required_approving_review_count", 0)
    required_checks = (by_type.get("required_status_checks") or {}).get("required_status_checks", [])
    blocks_force_push = "non_fast_forward" in by_type
    blocks_deletion = "deletion" in by_type

    gaps = []
    if pull_request is None:
        gaps.append("no rule requires a pull request before merging")
    elif required_reviewers < 1:
        gaps.append("required_approving_review_count is 0")
    if not required_checks:
        gaps.append("no required status checks configured (expect review-agent/verdict, testing-agent/gate)")
    if not blocks_force_push:
        gaps.append("force pushes are not blocked (missing non_fast_forward rule)")
    if not blocks_deletion:
        gaps.append("branch deletion is not restricted (missing deletion rule)")
    if not rules:
        gaps.append("no branch protection rule or ruleset applies to this branch")

    return {
        "branch": branch,
        "protected": not gaps,
        "required_pull_request_reviews": pull_request is not None,
        "required_approving_review_count": required_reviewers,
        "required_status_checks": [c.get("context") for c in required_checks],
        "force_pushes_blocked": blocks_force_push,
        "deletion_restricted": blocks_deletion,
        "gaps": gaps,
        "note": "Bypass-list actors (e.g. admin exemptions) are a ruleset property not reported by this endpoint; verify manually under Settings > Rules.",
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--branch", action="append", help="Branch to check (repeatable). Default: main.")
    parser.add_argument("--json", action="store_true", help="Emit machine-readable JSON output only.")
    args = parser.parse_args()

    if not gh_available():
        print("ERROR: GitHub CLI (`gh`) is not installed or not on PATH. Install it: https://cli.github.com/", file=sys.stderr)
        return 2

    branches = args.branch or DEFAULT_BRANCHES
    repo_slug = resolve_repo_slug()
    if not repo_slug:
        print("ERROR: Could not resolve repository (run `gh auth login` first, or run inside a gh-authenticated git repo).", file=sys.stderr)
        return 2

    results = [check_branch_protection(repo_slug, b) for b in branches]
    all_protected = all(r["protected"] for r in results)

    if args.json:
        print(json.dumps({"repository": repo_slug, "branches": results, "all_protected": all_protected}, indent=2))
    else:
        print(f"Branch protection verification for {repo_slug}\n")
        for r in results:
            status = "OK" if r["protected"] else "GAP"
            print(f"[{status}] {r['branch']}")
            for gap in r.get("gaps", []):
                print(f"    - {gap}")
            if r.get("error"):
                print(f"    - {r['error']}")
        print()
        print(
            "Result: all checked branches enforce required guardrails."
            if all_protected
            else "Result: one or more branches are missing required guardrails. Remediate in GitHub repo settings before relying on this as the merge gate."
        )

    return 0 if all_protected else 1


if __name__ == "__main__":
    sys.exit(main())
