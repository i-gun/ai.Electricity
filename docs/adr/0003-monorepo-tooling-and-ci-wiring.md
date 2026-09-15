# ADR 0003: Monorepo Tooling, Package Layout, and CI Wiring

- **Status**: Accepted (human-approved 2026-09-14)
- **Date**: 2026-09-14
- **Author**: Advisory Agent
- **Depends on**: [ADR 0001](0001-cross-platform-stack-and-testing-strategy.md) (Flutter stack), [ADR 0002](0002-local-data-storage-and-visualization.md) (Drift + `data/` package)

## Context

[`docs/conventions.md`](../conventions.md) mandates a multi-package layout (`core/`, `ui/`, `data/`,
`apps/desktop/`, `apps/mobile/`), but [`.github/workflows/ci-build-test.yml`](../../.github/workflows/ci-build-test.yml)
runs a single root-level `flutter analyze` / `flutter test --coverage` / `flutter build`. A root
invocation does not traverse sibling packages, so analysis and tests for `core/`, `ui/`, and `data/`
would silently never run, and the `testing-agent/gate` would report green against nothing. ADR 0002
additionally requires a `build_runner` codegen pass before analysis, which CI does not perform.

Toolchain baseline for this decision: Flutter stable **3.47.4** (Dart ≥ 3.6), installed at
`C:\src\flutter` for local development.

## Decision 1 — Dart pub workspaces, not Melos

| Option | Verdict |
|---|---|
| **Dart pub workspaces** (`resolution: workspace` in each package, `workspace:` list in the root `pubspec.yaml`) | **Chosen.** Built into the SDK from Dart 3.6 — zero extra dependency, zero bootstrap step in CI. One shared `pubspec.lock` and one `.dart_tool/package_config.json` means every package resolves identical dependency versions, which removes a whole class of "works in `core/`, breaks in `apps/mobile/`" failures. `dart pub get` at the root resolves all five packages at once. |
| Melos | Rejected for the MVP. Adds a dependency and a `melos bootstrap` step to every CI job to solve problems (task orchestration, versioning across many packages) that five packages with a single released artifact do not have. Revisit only if per-package publishing is ever needed. |
| Separate repos | Rejected — defeats ADR 0001's shared-core premise and multiplies the CI matrix. |

## Decision 2 — Package layout and responsibilities

```
pubspec.yaml            root workspace manifest (workspace: list, no app code)
analysis_options.yaml   single shared lint ruleset, included by every package
core/                   pure Dart package    — domain + business logic, 100% coverage
data/                   Flutter package      — Drift/SQLite repository implementations
ui/                     Flutter package      — shared platform-agnostic widgets
apps/desktop/           Flutter app          — Windows/macOS/Linux shell
apps/mobile/            Flutter app          — Android/iOS shell
```

Dependency direction is strictly one-way and enforced by Code Review Agent:
`apps/* → ui/, data/, core/` · `ui/ → core/` · `data/ → core/` · `core/ → nothing in this repo`.
`core/` must not depend on `flutter`; it is a plain `dart` package so its tests run under
`dart test` without a device or widget binding.

## Decision 3 — The coverage path is `core/` (gate-path correction)

`agents/testing-agent.yaml` and AGENTS.md §6 currently name `core/business-logic/**` for the 100%
rule, but no such directory exists in the layout. **The 100% rule applies to `core/lib/**`** — the
entire `core` package, since by construction it contains nothing but domain and business logic.
Configs referencing `core/business-logic/**` must be updated to `core/lib/**` as part of MVP-000.

## Decision 4 — CI must change before any package code lands

`ci-build-test.yml` is rewritten to, in order:

1. `dart pub get` at the workspace root (resolves all packages).
2. `dart run build_runner build --delete-conflicting-outputs` in `data/` (Drift codegen) — must run
   **before** analysis, otherwise generated `*.g.dart` files are missing and `flutter analyze` fails.
3. `dart format --output=none --set-exit-if-changed .` at the root.
4. `flutter analyze` at the root (a workspace-aware invocation covers all member packages).
5. Tests per package, each writing its own coverage file:
   `dart test --coverage` for `core/`, `flutter test --coverage` for `data/`, `ui/`, `apps/*`.
6. Merge the per-package lcov files and **enforce the thresholds for real** — the current
   `coverage-gate` job is an `echo` placeholder that passes unconditionally and must be replaced
   with an lcov merge plus a failing threshold check (≥ 90% overall, 100% for `core/lib/**`).
7. Platform builds as today.

Generated `*.g.dart` files are **not** committed; CI regenerates them. `.gitignore` must cover
`*.g.dart`, `.dart_tool/`, `build/`, and `coverage/`.

## Consequences

- MVP-001 cannot start until the workspace skeleton and the CI rewrite land; that work is split out
  as **MVP-000** ([`docs/backlog/mvp-000-workspace-bootstrap.md`](../backlog/mvp-000-workspace-bootstrap.md)).
- Contributors and agents run `dart pub get` once at the root, never per package.
- A future web target or a sixth package joins by adding one line to the root `workspace:` list.
- If package count grows past ~10 or per-package publishing becomes a requirement, revisit Melos in
  a new ADR.
