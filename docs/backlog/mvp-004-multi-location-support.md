# MVP-004 — Multi-location support and combined charts

- **Labels**: `agent:codegen`, `type:feature`
- **Depends on**: [ADR 0006](../adr/0006-multi-location-support-and-combined-charts.md) — **Accepted**
- **Branch**: `feat/mvp-004-multi-location-support`

## Goal

Let a user track more than one physical property/meter (each with its own zones and tariff rates)
and view combined consumption/expense charts across locations, without regressing the current
single-location experience.

## Scope

**`core/`**
- New `Location` entity (`id`, `name`, `colorArgb`, `sortOrder`, `isArchived`) and abstract
  `LocationRepository` (CRUD + `watchAll`).
- `TariffZone` gains a required `locationId`; update `copyWith` call sites and constructors.
- Re-scope `ZoneReconciliation` and `RateValidator.overlaps` to operate per-location (all zones of
  one location), not globally.
- Add `ConsumptionCalculator.totalsByLocation` and `ExpenseCalculator.calculateByLocation`
  (currency-mismatch across locations is a validation error, not silently summed).
- Keep 100% coverage on every new/changed unit in `core/lib/src/domain.dart`.

**`data/`**
- New `Locations` Drift table; `locationId` column on `TariffZones`.
- `schemaVersion` 1 → 2 migration: create `locations`, insert a default `"Home"` location, backfill
  `tariff_zones.locationId` to it. Add a migration test using fixture data.
- `DriftLocationRepository` implementing `LocationRepository`.

**`ui/`**
- New "Locations" management screen (list-style, mirrors the Zones tab): create/rename/recolour/
  archive; delete blocked while the location owns any zone.
- Stats tab: scope switch `Per zone` vs `Combined (all locations)`.
  - Combined mode: consumption/expense donuts chart one slice per active location.
  - New stacked bar chart, one bar per period bucket, one stack segment per location.
  - Data table gains an optional `Location` column, hidden when only one location exists.
  - Combined expense donut disabled with an explanatory message when locations use different
    `currencyCode`s.

**`apps/desktop/`, `apps/mobile/`**
- Inject `DriftLocationRepository` alongside the existing repositories.

## Acceptance criteria

1. A second location can be created, renamed, recoloured, and archived; deletion is blocked while
   it owns a zone.
2. Existing single-location installs migrate with zero data loss; all pre-existing zones/rates/
   readings remain attached to the default `"Home"` location.
3. Per-zone reconciliation and rate-overlap checks are unaffected within a single location and do
   not leak across locations once a second one exists.
4. The Stats tab's `Combined` mode renders a consumption-by-location donut, an expenses-by-location
   donut (or the disabled/explained state on currency mismatch), and a stacked-bar trend chart with
   one segment per location.
5. With only one location, the UI is visually unchanged from today (no `Location` column, no
   visible scope switch value change).

## Out of scope (deferred)

- FX conversion for mixed-currency combined views.
- Cross-location export/backup.
