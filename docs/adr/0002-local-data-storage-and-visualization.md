# ADR 0002: Local Data Storage, Domain Model, and Visualization for the ai.Electricity MVP

- **Status**: Accepted (human-approved 2026-09-14; new runtime dependencies authorized)
- **Date**: 2026-09-14
- **Author**: Advisory Agent
- **Supersedes / depends on**: [ADR 0001](0001-cross-platform-stack-and-testing-strategy.md) (Flutter stack)

## Context

The MVP must let a user record electricity meter readings locally (no backend), labelled by tariff
zone (`total`, `day`, `night`, and user-defined multi-zone variants), configure tariff prices, and
review consumption and expenses in a table and in charts with a default window of the last
3 months. The same storage and charting stack must run on Windows/macOS/Linux desktop and
Android/iOS mobile, and the business logic must stay in `core/` at 100% test coverage.

## Decision 1 — Storage: SQLite via `drift` (+ `sqlite3_flutter_libs`, `path_provider`)

| Option | Desktop + mobile | Verdict |
|---|---|---|
| **`drift` over SQLite** | Yes — `sqlite3_flutter_libs` ships the native lib for all 5 targets; `drift_flutter` resolves the DB path. | **Chosen.** Relational model fits readings/zones/rates naturally; type-safe generated queries; first-class migrations; reactive `Stream` queries for live table/chart updates; `NativeDatabase.memory()` makes repository tests fast and deterministic in CI. |
| `sqflite` | Mobile only by default; desktop needs `sqflite_common_ffi` with a different init path. | Rejected — two initialization paths, raw SQL strings, no migration/query type safety. |
| `Hive` / `Isar` | Good cross-platform reach, very fast. | Rejected — document stores make period aggregation, joins to historical tariff rates, and date-range queries manual; Isar's maintenance status is a supply-chain risk for a long-lived app. |
| `ObjectBox` | Fast, cross-platform. | Rejected — heavier native/licensing footprint than SQLite for a small local dataset. |
| Plain JSON file / `shared_preferences` | Trivial. | Rejected — no indexed range queries, whole-file rewrites, corruption risk, does not scale past a few hundred records. |

**Layering rule (non-negotiable, enforced by Code Review Agent):** `core/` defines only abstract
repositories (`MeterReadingRepository`, `TariffRepository`) plus pure domain logic. The Drift
implementation lives in a new `data/` Flutter package that depends on `core/`. App shells inject
the implementation. This keeps `core/` free of platform imports so the 100% coverage gate stays
meaningful.

## Decision 2 — Domain model

Readings are stored as **cumulative meter values** (what the user reads off the meter), never as
deltas. Consumption is *derived* by the domain layer as the difference between consecutive
readings of the same zone. This makes late/edited/back-dated entries self-correcting.

```
tariff_zone   (id, code, name, kind[total|day|night|custom], colorArgb, sortOrder, isArchived)
tariff_rate   (id, zoneId, pricePerKwh, currencyCode, validFrom, validTo?)   -- history, no destructive edits
meter_reading (id, zoneId, readingDate, valueKwh, note?, createdAt, updatedAt)
              UNIQUE(zoneId, readingDate)
```

Rules the domain layer owns (and the Testing Agent must cover exhaustively):
- A reading may not be lower than the previous reading of the same zone unless flagged as a meter
  reset/replacement.
- In a multi-zone setup, `day + night` consumption is reconciled against `total` when a `total`
  zone is also tracked; a mismatch beyond a tolerance surfaces as a warning, not an error.
- Expenses use the rate whose `[validFrom, validTo)` window contains the consumption period; a
  period spanning a price change is split proportionally by day.
- All money math uses integer minor units (no `double` for currency).

## Decision 3 — Charts: `fl_chart`

Chosen for MVP: pure Dart, no platform channels, works identically on all 5 targets, supports bar,
line, and pie with theming and accessible touch/mouse interaction.

Recommended chart types:

| View | Chart | Why |
|---|---|---|
| Consumption per period (default view) | **Stacked vertical bar chart**, one bar per bucket (day/week/month depending on range) | Consumption is a discrete quantity accumulated over a bucket, not a continuously sampled signal. Bars communicate "how much in this period" honestly, and stacking `night` on `day` shows both the split and the total in one glance. A line here implies interpolation between readings that never happened. |
| Meter value trend (secondary) | **Line chart** | The meter value *is* a monotonic continuous series, so a line is correct here. |
| Expenses by zone | **Pie (donut) chart** + a legend with absolute amounts | Part-to-whole over a fixed period; cap at ~6 slices. |

Default date range is **the last 3 months**, with a user-facing range selector (1M / 3M / 6M / 1Y /
custom). Range state lives in `core/` so desktop and mobile share it.

## Decision 4 — Platform adaptation (one codebase, two shells)

- Shared screens live in `ui/`; the shells only choose layout: desktop uses a two-pane
  master/detail with a data grid and inline editing; mobile uses a list + bottom-sheet form.
- Table view: shared virtualized list/`DataTable` in `ui/` — do not fork the widget per platform.
- Storage path resolution (`path_provider`) and window sizing are the only per-shell concerns.

## Consequences

- New dependencies: `drift`, `drift_flutter`, `sqlite3_flutter_libs`, `path_provider`, `fl_chart`,
  dev-dependency `drift_dev` + `build_runner`. Approved by a human maintainer per AGENTS.md §3.
- A new `data/` package joins the layout in `docs/conventions.md`; CI must run codegen
  (`build_runner`) before analyze/test.
- Drift schema migrations must be versioned from day one (`schemaVersion: 1`) with migration tests.
- Follow-up ADRs expected for: CSV/JSON export & backup, cloud sync, and OCR meter-photo entry —
  explicitly **out of MVP scope**.

## Implementation handoff

Backlog ticket: [`docs/backlog/mvp-001-meter-tracking.md`](../backlog/mvp-001-meter-tracking.md)
(label `agent:codegen`, actionable now that this ADR is accepted).
