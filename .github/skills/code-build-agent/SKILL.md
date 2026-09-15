---
name: code-build-agent
description: "Use when: building retained artifacts, enforcing platform confirmation, packaging Windows/macOS/Linux/Android/iOS targets, creating checksum manifests, or handing build failures to troubleshooting."
---
# Code Build Agent Skill

## Sources

Machine-readable contract: `agents/code-build-agent.yaml`.
Interactive agent: `.github/agents/code-build-agent.agent.md`.
Workflow: `.github/workflows/code-build-artifacts.yml`.

## Scope and Matrix

This skill creates build artifacts from one immutable commit after explicit confirmation. CI
verification builds and distributable release artifacts are different: this workflow retains
verification outputs but does not publish releases or create signed distribution packages.

| Target | Runner | Current format | Host requirement |
|---|---|---|---|
| Windows desktop | `windows-latest` | Flutter Windows bundle | Windows desktop tooling |
| macOS desktop | `macos-latest` | Flutter macOS app bundle | macOS/Xcode |
| Linux desktop | `ubuntu-latest` | Flutter Linux bundle | Linux desktop tooling |
| Android | `ubuntu-latest` | debug APK | Android SDK; no signing secret |
| iOS simulator | `macos-latest` | unsigned simulator app | macOS/Xcode simulator |

Signed Android App Bundles, signed iOS IPAs, notarized macOS applications, installers, and
publishing are unsupported. They require an approved future ticket/ADR and demonstrably configured
credentials; this agent never requests or emits signing material.

## Gates and Provenance

0. When human-invoked, consult the Version Control Agent for the current branch and working tree
   status before anything else. Never run `git status`/`git add`/`git commit` directly.
   - Clean tree on `main`: proceed to gate 1.
   - Clean tree, not on `main`: explicitly ask the human to confirm building on the current branch
     before proceeding.
   - Dirty tree (any branch): explicitly ask the human whether to stage/commit local changes. If
     yes, delegate the stage/commit task to the Version Control Agent, then re-run this gate once
     that flow completes. If no, stay blocked and report the dirty tree.
1. Resolve the ref to a full commit SHA and record it. Renew confirmation if it changes.
2. Require `confirmed` for every selected platform, mode, and format before build commands.
3. Run workspace dependency resolution, Drift generation, formatting validation, `flutter analyze`,
   and scoped tests before artifact creation.
4. Build only on a compatible runner and report blocked targets explicitly.
5. Discover actual outputs, record relative paths and byte sizes, hash every output with SHA-256,
   and generate a versioned JSON manifest.
6. Upload immutable names containing platform, mode, and commit SHA, retaining build artifacts for
   14 days.
7. Emit a small structured report under `logs/code-build-agent/<run-id>.json`. Do not persist verbose
   `*.build-log.json` diagnostics in commits. Re-runs use the
   same idempotency key and must not create misleading duplicate logical manifests.

## Failure Handoff

Ambiguous confirmation or unsupported targets are blocked without a build. A clear existing
validation/build defect goes to Error Resolution Agent; a new platform or distribution architecture
goes to Advisory Agent. Review Agent, Testing Agent, and Version Control Agent ownership is unchanged.