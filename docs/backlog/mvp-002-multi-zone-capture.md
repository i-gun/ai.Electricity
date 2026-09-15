# MVP-002 — Multi-zone capture, zone lifecycle, and per-zone donuts

- **Labels**: `agent:codegen`, `type:bug`, `status:in-review`
- **Depends on**: [ADR 0004](../adr/0004-multi-zone-capture-and-per-zone-visualisation.md) — **Accepted**
- **Branch**: `fix/<issue-number>-multi-zone-capture`
- **Source**: defects reported against the first successful Windows desktop build (2026-09-15)

## Reported defects

1. Reading date cannot be set on add, nor changed on edit.
2. Reading label cannot be set for multi-zone tariff accounting.
3. Pre-set `Day` and `Night` zones cannot be activated.
4. No way to add a zone — only a tariff value, and without a date.
5. The `expenses by zone` donut shows a single `Total` slice; a `consumption by zone` donut is
   missing. Both should sit side by side, each occupying half the width.

## Root causes

See ADR 0004 §Context. In short: `ui/lib/ui.dart` hardcoded `zoneId: 'total'` and the zone list;
`DriftTariffZoneRepository`/`DriftTariffRateRepository` were implemented but never injected, so
zones and rates never persisted; the donut was a placeholder. Two latent bugs were found during
triage — cross-zone delta pairing and UI-generated id collisions causing silent row overwrites.

## Scope

**`core/`**
- `copyWith` on `TariffZone` (name/colour/sortOrder/isArchived only), `TariffRate`, `MeterReading`.
- `TariffZoneRepository.delete`, `TariffRateRepository.delete`, `TariffRateRepository.watchAll`.
- Fix `ConsumptionCalculator.deltas` to group by zone before pairing.
- Add `ConsumptionCalculator.totalsByZone` and `ExpenseCalculator.calculateByZone`.

**`data/`**
- Implement the new repository methods.
- Treat `id <= 0` as "new row" (`Value.absent()`) so SQLite assigns ids.

**`ui/`**
- Reading form: zone dropdown (active zones), date picker capped at today, cumulative kWh, optional
  label, meter-reset checkbox, inline `ReadingValidator` messages, correct add/edit title.
- Zones tab: data-driven list, per-zone activation `Switch`, create/rename/recolour zones, expandable
  rate history with add/delete, rate dialog with `validFrom` + optional `validTo`, auto-closing of
  the superseded open window, `RateValidator.overlaps` enforced before save.
- Delete confirmations for readings, zones, and rates; `total` and zones with readings are
  delete-protected.
- Stats tab: paired `Consumption by zone` / `Expenses by zone` donuts in a `Row` of `Expanded`,
  collapsing to a `Column` below 600 px; zone colours from `colorArgb`; legends with absolute
  values; component zones supersede `total`; `ZoneReconciliation` warning banner; zone column added
  to the data table; bar and line charts coloured per zone.

**`apps/desktop/`, `apps/mobile/`**
- Inject `DriftTariffZoneRepository` and `DriftTariffRateRepository` alongside the reading repository.

## Acceptance criteria

1. A reading can be created and edited with an explicit zone, date, and label; the date is
   changeable on both paths.
2. `Day` and `Night` can be activated from the Zones tab and immediately appear in the reading
   form's zone dropdown.
3. A custom zone can be created, renamed, recoloured, and — when it has no readings and is not
   `total` — deleted.
4. A tariff rate can be added with an explicit `validFrom`; adding a newer rate closes the previous
   window instead of rewriting history; overlaps are rejected.
5. Zones, rates, and readings all survive an app restart.
6. The stats tab shows two donuts side by side, split by zone, with no `Total` slice whenever
   component zones carry data.
7. `flutter analyze` clean; `dart format` clean; all package test suites green.

## Out of scope — see MVP-003

True stacked bars, custom date range, bucket granularity, per-zone entry in one submit, undo on
delete, locale-aware currency and date formatting.
