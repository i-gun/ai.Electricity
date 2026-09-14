# ADR 0001: Cross-Platform Stack and Testing Strategy for ai.Electricity

- **Status**: Accepted
- **Date**: 2026-09-13
- **Author**: Advisory Agent (initial seed ADR for this task's deliverables)

## Context

ai.Electricity must ship to desktop (Windows/macOS/Linux) and mobile (iOS/Android) from a single shared
codebase, with a layered architecture (shared core/domain/business-logic + thin platform UI
adapters) and a test suite covering all code paths, enforced in CI on every PR.

Candidates evaluated:

| Option | Pros | Cons |
|---|---|---|
| **Flutter** | Single language (Dart) for core + UI; first-class desktop (Windows/macOS/Linux) and mobile (iOS/Android) targets from one codebase; mature widget-testing (`flutter_test`), integration-testing (`integration_test`), and coverage tooling (`flutter test --coverage` → lcov) that runs the same on every platform; strong CI support (headless desktop builds, Android emulator, iOS simulator on macOS runners). | UI layer is Flutter-specific (not native widgets); larger app size than native. |
| .NET MAUI | Single language (C#); good desktop/mobile reach; native-ish controls. | Weaker Linux desktop story; test/coverage tooling less unified across all 5 targets; smaller ecosystem for this kind of layered core-sharing today. |
| React Native + Electron/Tauri | Reuses web skills; large ecosystem. | Two distinct runtimes (RN for mobile, Electron/Tauri for desktop) means the "shared core" is only shared at the JS/TS logic level, not the app shell; doubles the platform-adapter surface and CI matrix complexity; two different test runners/coverage pipelines to unify. |

## Decision

Adopt **Flutter** (Dart) as the single technology stack:

- `core/` — pure-Dart package: domain models, business logic, state management, no platform UI
  imports. This is the layer the Testing Agent enforces at **100% coverage**.
- `apps/mobile/` and `apps/desktop/` — thin Flutter app shells consuming `core/`, holding only
  platform-specific adapters (e.g., platform channels, window management, mobile-only
  permissions) and UI composition.
- Shared UI widgets that are platform-agnostic live in `ui/` (a Flutter package), imported by both
  app shells, to avoid duplicating screens.

## Testing Strategy

- **Unit tests** (`core/`, `ui/`): `flutter test`, run on every PR, coverage collected via
  `--coverage` → lcov, aggregated by the Testing Agent.
- **Integration tests** (`apps/*/integration_test/`): `integration_test` package, run headless on
  desktop runners (Windows/macOS/Linux GitHub Actions images) and on Android emulator / iOS
  simulator for mobile.
- **E2E smoke tests**: one smoke flow per platform (launch app, load a meter reading, render a
  chart) run on every PR as part of the CI matrix; deeper e2e suites run on a nightly schedule.
- **Coverage gate** (enforced by Testing Agent, see [`agents/testing-agent.yaml`](../../agents/testing-agent.yaml)):
  - Overall: ≥ 90% lines/branches.
  - `core/business-logic/**`: 100% lines/branches (critical domain logic).
- **CI matrix**: every PR builds + tests on `windows-latest`, `macos-latest`, `ubuntu-latest`
  (desktop) and Android + iOS targets on `macos-latest` runners (mobile), as wired in
  [`.github/workflows/ci-build-test.yml`](../../.github/workflows/ci-build-test.yml).

## Consequences

- All Code Generation Agent output must place business logic in `core/` and platform-specific
  code only in `apps/mobile/` or `apps/desktop/` — enforced by Code Review Agent style checks.
- The Testing Agent's coverage gate is meaningful because `core/` cannot contain
  platform-conditional code that's hard to exercise in CI.
- Any future proposal to change stack (e.g., add a web target, or migrate a subsystem) must go
  through a new ADR from the Advisory Agent, per [`AGENTS.md`](../../AGENTS.md#3-advisory--recommendation-agent).
