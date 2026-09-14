# MVP-001 — Local electricity consumption tracking (codegen prompt)

- **Labels**: `agent:codegen`, `type:feature`, `status:ready`
- **Depends on**: [ADR 0002](../adr/0002-local-data-storage-and-visualization.md) — **Accepted**
- **Branch**: `feat/<issue-number>-mvp-meter-tracking`

> Paste the block below as the issue body / agent prompt.

---

## Prompt for the Code Generation Agent

Implement the ai.Electricity MVP: an offline-first Flutter app for tracking electricity meter readings,
tariff zones, and expenses, targeting Windows/macOS/Linux desktop and Android/iOS mobile from one
codebase.

Authoritative context you must read first: [`AGENTS.md`](../../AGENTS.md),
[`docs/conventions.md`](../conventions.md),
[`docs/adr/0001-cross-platform-stack-and-testing-strategy.md`](../adr/0001-cross-platform-stack-and-testing-strategy.md),
[`docs/adr/0002-local-data-storage-and-visualization.md`](../adr/0002-local-data-storage-and-visualization.md),
[`docs/platform-matrix.md`](../platform-matrix.md).

### Scope — deliver in this order, one PR per numbered slice

**1. Domain core (`core/`, pure Dart, 100% coverage required)**
- Value objects: `Kwh` (non-negative, fixed precision), `Money` (integer minor units + ISO currency
  code), `ZoneCode`, `DateRange`.
- Entities: `TariffZone { id, code, name, kind: total|day|night|custom, colorArgb, sortOrder,
  isArchived }`, `TariffRate { id, zoneId, pricePerKwh: Money, currencyCode, validFrom, validTo? }`,
  `MeterReading { id, zoneId, readingDate, valueKwh: Kwh, note?, createdAt, updatedAt }`.
- Abstract repositories `MeterReadingRepository`, `TariffZoneRepository`, `TariffRateRepository`
  with CRUD + range queries returning `Stream`s. No Flutter/platform imports anywhere in `core/`.
- Services:
  - `ConsumptionCalculator` — derives per-zone consumption deltas from consecutive cumulative
    readings; buckets them by day/week/month for a `DateRange`; handles gaps, out-of-order and
    back-dated entries, and meter-reset readings.
  - `ExpenseCalculator` — maps bucketed consumption to `Money` using the `TariffRate` valid for
    each sub-period; splits a bucket proportionally by day when a rate change falls inside it.
  - `ZoneReconciliation` — when a `total` zone coexists with `day`/`night`, reports the delta
    between `day + night` and `total` as a non-blocking warning with a configurable tolerance.
- Validation rules as explicit, individually testable result types (no exceptions for expected
  user-input errors): duplicate `(zoneId, readingDate)`, value lower than previous reading without
  a reset flag, future-dated reading, overlapping tariff rate windows for one zone.

**2. Persistence (`data/`, new package depending on `core/`)**
- Drift database, `schemaVersion: 1`, tables per ADR 0002 (`tariff_zone`, `tariff_rate`,
  `meter_reading` with `UNIQUE(zoneId, readingDate)` and an index on `readingDate`).
- Drift-backed implementations of the `core/` repository interfaces; expose reactive queries.
- Path resolution via `drift_flutter`/`path_provider`; the DB opener is the only platform-aware
  code in this package.
- Seed migration inserting default zones: `total`, `day`, `night` (day/night archived until the
  user enables multi-zone).
- Repository tests run against `NativeDatabase.memory()`; include a migration test harness.

**3. Shared UI (`ui/`, platform-agnostic widgets)**
- **Readings screen** — table of `date | value kWh | zone`, sortable by date, grouped per day when
  multiple zones are recorded; add / edit / delete with confirm-on-delete and undo; a single
  entry form that records all active zones for one date in one submit.
- **Zones & tariffs screen** — create/rename/archive zones, pick a colour, and edit the rate
  history (`pricePerKwh`, `validFrom`, optional `validTo`). Editing a rate never mutates history:
  it closes the current window and opens a new one.
- **Stats screen** — date-range selector defaulting to **the last 3 months** (presets 1M/3M/6M/1Y/
  custom), with:
  - a **stacked vertical bar chart** of consumption per bucket, stacked by zone (bucket granularity
    auto-selects day/week/month from the range length),
  - a **line chart** of raw cumulative meter values per zone,
  - a **pie/donut chart** of expenses per zone for the selected range, with absolute amounts in the
    legend,
  - summary tiles: total kWh, total cost, average daily kWh, day/night share.
- Charts use `fl_chart`. Every chart must have a non-graphical equivalent (the table) and
  `Semantics` labels; respect the platform text scale and dark mode; empty and single-reading
  states must render meaningful placeholders, not exceptions.

**4. App shells (`apps/desktop/`, `apps/mobile/`)**
- Desktop: two-pane master/detail, keyboard shortcuts for add/save/delete, window min-size.
- Mobile: list + FAB, bottom-sheet forms, safe-area handling.
- Shells contain only composition, dependency injection of the `data/` implementations, and
  platform adapters — zero business logic.

### Non-functional requirements
- Offline-only; no network calls, no analytics, no telemetry in the MVP.
- No secrets, tokens, or credentials anywhere in the codebase.
- All user input is validated in `core/` before it reaches the database; all Drift access uses
  generated/parameterised queries (no string-concatenated SQL).
- `dart format` and `flutter analyze` clean; `build_runner` codegen committed or generated in CI
  before analyze/test.
- Coverage gate: ≥ 90% overall, 100% for `core/business-logic/**`.

### Out of scope (do not implement; file follow-up tickets instead)
Cloud sync, accounts, CSV/JSON export & backup, OCR/photo meter reading, notifications/reminders,
multi-currency conversion, forecasting.

### Acceptance criteria
1. A user can add, edit, and delete a reading for any active zone, and the table + charts update
   without an app restart.
2. A user can create a custom zone, set a tariff rate with a `validFrom` date, later change the
   rate, and historical expenses before the change remain calculated at the old rate.
3. The stats screen opens on the last 3 months by default and re-renders for any selected range.
4. Data survives an app restart on every platform in the matrix.
5. Deleting a zone with readings is blocked (archive instead) and the UI explains why.
6. CI is green on all five targets; the coverage gate passes.

### Escalate instead of guessing
Ambiguous bucket-granularity thresholds, currency/locale formatting rules, or meter-reset UX →
comment `status:blocked` and label `agent:advisory`.
