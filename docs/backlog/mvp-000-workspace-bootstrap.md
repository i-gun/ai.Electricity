# MVP-000 — Workspace bootstrap & CI wiring (codegen prompt)

- **Labels**: `agent:codegen`, `type:chore`, `status:ready`
- **Depends on**: [ADR 0003](../adr/0003-monorepo-tooling-and-ci-wiring.md) — **Accepted**
- **Blocks**: [MVP-001](mvp-001-meter-tracking.md)
- **Branch**: `feat/<issue-number>-workspace-bootstrap`

---

## Prompt for the Code Generation Agent

Bootstrap the ai.Electricity Flutter workspace so that MVP-001 can be implemented against a
building, testing, analyzable skeleton. **Create structure and wiring only — no domain logic, no
screens, no Drift tables.** Those belong to MVP-001.

Read first: [`AGENTS.md`](../../AGENTS.md), [`docs/conventions.md`](../conventions.md),
[ADR 0001](../adr/0001-cross-platform-stack-and-testing-strategy.md),
[ADR 0002](../adr/0002-local-data-storage-and-visualization.md),
[ADR 0003](../adr/0003-monorepo-tooling-and-ci-wiring.md).

Toolchain: Flutter stable 3.47.4 at `C:\src\flutter` (Dart ≥ 3.6, pub workspaces available).

### Deliverables

**1. Root workspace**
- Root `pubspec.yaml` declaring `workspace: [core, data, ui, apps/desktop, apps/mobile]`, an
  `environment.sdk` constraint matching the installed Dart, and no application dependencies.
- Root `analysis_options.yaml` with a single shared ruleset (`flutter_lints` plus
  `strict-casts`/`strict-raw-types`), `include`d by every package's own `analysis_options.yaml`.
- `.gitignore` covering `.dart_tool/`, `build/`, `coverage/`, `*.g.dart`, `*.freezed.dart`,
  platform build outputs, and IDE noise.
- `dart pub get` at the root must resolve all five packages successfully.

**2. `core/` — pure Dart package** (`dart` package, must NOT depend on `flutter`)
- `core/pubspec.yaml` with `resolution: workspace`, dev-dependency `test`.
- `core/lib/core.dart` barrel export.
- A single trivial placeholder (e.g. a `packageName` constant) plus a passing test, purely so the
  package is non-empty and CI is exercised end to end.

**3. `data/` — Flutter package**
- `resolution: workspace`; dependencies `core` (path), `drift`, `drift_flutter`,
  `sqlite3_flutter_libs`, `path_provider`; dev-dependencies `drift_dev`, `build_runner`,
  `flutter_test`.
- A minimal Drift database class with `schemaVersion: 1` and **no tables yet**, plus the
  `build.yaml`/codegen wiring, so that `dart run build_runner build --delete-conflicting-outputs`
  succeeds and proves the toolchain works.
- One test opening `NativeDatabase.memory()` and closing it, to prove the in-memory test harness
  from ADR 0002 functions.

**4. `ui/` — Flutter package**
- `resolution: workspace`; depends on `core` and `fl_chart`.
- App theme (light/dark) and nothing else. One widget test.

**5. `apps/desktop/` and `apps/mobile/` — Flutter apps**
- Generate with `flutter create` using the appropriate `--platforms` per shell
  (desktop: `windows,macos,linux`; mobile: `android,ios`), then convert each to
  `resolution: workspace` and strip the counter-app boilerplate.
- Each shows a placeholder home screen using the `ui/` theme. No business logic.
- Organization/bundle id: `dev.aielectricity` (`dev.aielectricity.desktop` / `.mobile`).

**6. CI rewrite — [`.github/workflows/ci-build-test.yml`](../../.github/workflows/ci-build-test.yml)**
Implement the pipeline order from ADR 0003 §Decision 4:
`dart pub get` (root) → `build_runner` in `data/` → `dart format --set-exit-if-changed` →
`flutter analyze` (root) → per-package tests with coverage → merge lcov → **real** threshold
enforcement → platform builds.
- Replace the `coverage-gate` `echo` placeholder with an actual lcov merge and a check that
  **fails the job** when overall coverage < 90% or `core/lib/**` < 100%.
- Upload per-package coverage artifacts with distinct names.

**7. Config path correction**
- In `agents/testing-agent.yaml` and [`AGENTS.md`](../../AGENTS.md), replace
  `core/business-logic/**` with `core/lib/**` per ADR 0003 §Decision 3. Update
  [`docs/conventions.md`](../conventions.md) layout to include `data/` and the root workspace files.

### Definition of done
1. `dart pub get` at the root resolves all five packages.
2. `dart run build_runner build --delete-conflicting-outputs` succeeds in `data/`.
3. `dart format --output=none --set-exit-if-changed .` and `flutter analyze` are clean.
4. All package tests pass; the coverage gate runs real numbers and would fail if thresholds dropped.
5. `flutter build windows` succeeds locally; the CI matrix is green on all five targets.
6. No domain models, no screens, no Drift tables — reviewers should see scaffolding only.

### Constraints
- Never push to `main`; branch per [`docs/conventions.md`](../conventions.md) and open a **draft** PR.
- Commit no generated `*.g.dart`.
- No network calls, no telemetry, no secrets anywhere.

### Escalate instead of guessing
Dependency version conflicts under a single workspace lockfile, or an lcov tooling choice that
would add a heavyweight dependency → comment `status:blocked`, label `agent:advisory`.
