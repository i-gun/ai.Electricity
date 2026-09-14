# Architecture Snapshot

Living summary the Advisory Agent maintains and the Code Generation Agent reads before scaffolding.

## Layers

- **`core/`** — domain models, business logic, state management. Pure Dart, no platform imports. 100% test coverage required.
- **`data/`** — Drift/SQLite implementations of the repository interfaces declared in `core/` (ADR 0002).
- **`ui/`** — shared, platform-agnostic Flutter widgets consumed by both app shells.
- **`apps/desktop/`** and **`apps/mobile/`** — thin shells: platform channels, window/permission handling, composition of `ui/` + `core/`.

## Current decisions

- Stack: Flutter — see [`docs/adr/0001-cross-platform-stack-and-testing-strategy.md`](adr/0001-cross-platform-stack-and-testing-strategy.md).
- Local storage (Drift over SQLite), domain model, and charting for the MVP — **accepted**, see [`docs/adr/0002-local-data-storage-and-visualization.md`](adr/0002-local-data-storage-and-visualization.md).

## Open items

- Backlog ticket [`docs/backlog/mvp-001-meter-tracking.md`](../backlog/mvp-001-meter-tracking.md) is ready for the Code Generation Agent.
- Follow-up ADRs still owed: export/backup, cloud sync, OCR meter-photo entry.
