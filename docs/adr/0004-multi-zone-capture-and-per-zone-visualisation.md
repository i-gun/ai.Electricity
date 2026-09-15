# ADR 0004: Multi-Zone Reading Capture, Zone Lifecycle, and Per-Zone Visualisation

- **Status**: Accepted
- **Date**: 2026-09-15
- **Author**: Advisory Agent
- **Depends on**: [ADR 0002](0002-local-data-storage-and-visualization.md) (Drift schema, seeded zones), [ADR 0003](0003-monorepo-tooling-and-ci-wiring.md) (package layout)

## Context

The first successful Windows build proved the reading CRUD path end to end, but user testing
surfaced five defects. Triage showed that the domain model (`core/`) and the Drift schema (`data/`)
already supported every missing capability — the gaps were concentrated in `ui/lib/ui.dart` and in
app-shell composition:

1. `_ReadingDialog` exposed a single kWh field. `zoneId` was the string literal `'total'`,
   `readingDate` defaulted to `DateTime.now()` and was passed through unchanged on edit, and `note`
   and `isReset` were never set.
2. `ZonesView` was a static `Card` containing three hardcoded `ListTile`s. The "Archived until
   enabled" subtitle was a string constant, not bound state, so `TariffZone.isArchived` could never
   be toggled. Its "New zone" button was wired to the rate dialog.
3. `DriftTariffZoneRepository` and `DriftTariffRateRepository` were implemented but **never
   instantiated**. Both app shells injected only `readingRepository`, and `SharedHome` held zones
   and rates as in-memory literals — so every zone or tariff a user created was discarded on
   restart while appearing to work, because `setState` refreshed the view.
4. The "Expenses by zone" donut was a placeholder with one hardcoded slice titled `Total`.
5. Two latent correctness bugs: `ConsumptionCalculator.deltas` sorted globally by date and skipped
   any consecutive pair whose `zoneId` differed, so interleaved multi-zone readings produced near-
   zero consumption; and `_ReadingDialog(nextId: readings.length + 1)` generated ids that collide
   after a delete, which `insertOnConflictUpdate` turns into silent row overwrites.

## Decision 1 — `zoneId` is the zone **code**, not the zone row id

`MeterReading.zoneId` and `TariffRate.zoneId` are `String` while `TariffZone.id` is `int`. We fix
the ambiguity in favour of the stable, human-meaningful `ZoneCode` value (`total`, `day`, `night`,
or a slug derived from a custom zone's name). Codes are unique, immutable after creation, and
already what the seed migration writes. Renaming a zone therefore never orphans its readings.

Consequence: zone **rename** is allowed, zone **code** change is not. `TariffZone.copyWith` exposes
`name`, `colorArgb`, `sortOrder`, and `isArchived` only — `id`, `code`, and `kind` are identity.

## Decision 2 — Archive is the activation switch; delete is the exception

`isArchived` is the single activation flag, surfaced as a `Switch` per zone bound to
`!zone.isArchived`. Day and Night ship archived (per the ADR 0002 seed) and are enabled by the user,
never recreated. Deletion is blocked for the `total` zone (reconciliation baseline) and for any zone
that owns readings; the UI directs the user to archive instead. This satisfies MVP-001 acceptance
criterion 5 without a cascade-delete path that could destroy history.

Only **active** zones are offered in the reading form. Editing an existing reading falls back to the
full zone list so a reading recorded against a since-archived zone stays editable.

## Decision 3 — Tariff rates are append-only validity windows

Adding a rate to a zone closes the open-ended window it supersedes by setting that window's
`validTo` to the new window's `validFrom`, rather than mutating the price in place. The projected
rate set is run through `RateValidator.overlaps` before anything is written; a conflict aborts the
save with a message. Historical expenses before a rate change therefore keep the old price
(MVP-001 acceptance criterion 2).

`validFrom` and optional `validTo` are explicit date pickers. Previously both were implicit, so
every rate silently overlapped and `RateValidator` — written and unit-tested — was never called from
the UI. The same applies to `ReadingValidator`, now invoked by the reading form for duplicate,
future-date, and non-decreasing checks.

## Decision 4 — Ids are assigned by SQLite, never by the UI

Repository `save` treats `id <= 0` as "new row" and passes `Value.absent()` so SQLite's
`AUTOINCREMENT` assigns the id; `id > 0` keeps upsert-by-primary-key semantics for edits. Dialogs
return entities with `id: 0`. The in-memory fallback path (widget used without repositories) derives
`max(id) + 1` instead. This removes the overwrite-after-delete data-loss class entirely.

## Decision 5 — Consumption deltas are paired within a zone

`ConsumptionCalculator.deltas` now groups readings by `zoneId` first, sorts each group by date, and
pairs within the group, emitting a globally date-sorted result. The previous global sort made the
calculator degrade to near-zero output precisely when multi-zone accounting was enabled. Two new
aggregation helpers keep the charting math in the 100%-covered package rather than in widgets:
`ConsumptionCalculator.totalsByZone` and `ExpenseCalculator.calculateByZone`.

## Decision 6 — Two donuts, and component zones supersede the aggregate

The stats tab renders **Consumption by zone** and **Expenses by zone** as paired donut charts, each
in an `Expanded` inside a `Row` (half the available width), with slice colours taken from
`TariffZone.colorArgb` so a zone reads identically across both charts, and a legend carrying
absolute values.

Slice selection rule: **if any non-`total` zone has data in the range, only component zones are
charted; otherwise the `total` zone is charted alone.** Including `total` alongside day and night
would double-count, since `total ≈ day + night` by definition. The residual difference is not
discarded — it is surfaced through the previously unused `ZoneReconciliation` as a non-blocking
warning banner above the charts.

Below ~600 px the `Row` collapses to a `Column` via `LayoutBuilder`; half-width donuts are
unreadable on a phone. This is a layout breakpoint, not a `compact` flag, so a narrow desktop window
behaves the same as a phone.

| Option for the aggregate slice | Verdict |
|---|---|
| Chart every zone including `total` | Rejected — double-counts; the `total` slice would always be ~50%. |
| Component zones supersede `total`, reconciliation shown as a banner | **Chosen.** No double-counting, and the discrepancy stays visible. |
| Drop the `total` zone from the model once day/night exist | Rejected — `total` is the meter-level ground truth and the reconciliation baseline. |

## Decision 7 — Keep `setState`; defer a state-management framework

`SharedHome` now subscribes to three repository streams instead of one. We keep the existing
`StatefulWidget` + `Stream.listen` approach rather than introducing Riverpod or BLoC mid-feature:
the state is three lists and a date range, all owned by one widget, and swapping frameworks would
add risk without addressing any of the five reported defects. Repositories stay injected as nullable
constructor parameters, which keeps `ui/` testable without a database.

**Revisit trigger**: a fourth stream, cross-tab shared state, or any need for state to outlive
`SharedHome`. Tracked as
[`docs/backlog/mvp-003-stats-and-state-followups.md`](../backlog/mvp-003-stats-and-state-followups.md).

## Consequences

- Zones and tariff rates persist for the first time; the pre-fix in-memory behaviour means any
  zone/rate a tester created before this change was never stored. No migration is required —
  `schemaVersion` stays at 1 because no table changed.
- `TariffZoneRepository` and `TariffRateRepository` gain `delete(int id)`, and
  `TariffRateRepository` gains `watchAll()`. These are breaking interface additions; the only
  implementations live in `data/`.
- The bar and line charts are now coloured per zone but are still single-series per bucket; true
  stacked bars and a custom date range are deferred to MVP-003.
- Zone codes for custom zones are slugs derived from the name and validated against `ZoneCode`'s
  `^[a-z0-9_-]+$` rule and against existing codes.
