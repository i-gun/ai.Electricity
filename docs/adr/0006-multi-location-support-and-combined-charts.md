# ADR 0006: Multi-Location Support and Combined Consumption/Expense Charts

- **Status**: Accepted (human-approved 2026-09-24; new domain entity, schema migration, and
  breaking repository interface change authorized)
- **Date**: 2026-09-24
- **Author**: Advisory Agent
- **Depends on**: [ADR 0002](0002-local-data-storage-and-visualization.md) (storage/domain model),
  [ADR 0004](0004-multi-zone-capture-and-per-zone-visualisation.md) (zone lifecycle, per-zone charts)

## Context

The current model supports exactly one physical meter/property: `TariffZone` (`total`/`day`/
`night`/custom) partitions readings *within* one location, and `MeterReading.zoneId` /
`TariffRate.zoneId` reference that zone by its stable `ZoneCode`. There is no entity above `zone`
representing a second home, rental unit, or business premises with its own meter(s), zones, and
tariff rates — a user who wants to track two properties today has to either run two separate
installs (no combined view) or misuse zones as locations (breaks the `total ≈ day + night`
reconciliation from ADR 0004 Decision 6, and collapses two independent meters' cumulative readings
into one zone-code namespace).

This ADR proposes adding a `Location` entity above `TariffZone` and a location-aware "combined"
chart mode, reusing the aggregation pattern ADR 0004 already established for zones.

## Decision 1 — `Location` is a new parent entity; `TariffZone` gains `locationId`

```
location      (id, name, colorArgb, sortOrder, isArchived)
tariff_zone   (id, locationId, code, name, kind, colorArgb, sortOrder, isArchived)
tariff_rate   (id, zoneId, ...)          -- unchanged, still traces to a zone
meter_reading (id, zoneId, ...)          -- unchanged, still traces to a zone
```

`code` (`ZoneCode`) stays unique **per location**, not globally — two locations may each have a
`total`/`day`/`night` zone. Readings and rates keep referencing `zoneId`/`zone.code` exactly as
today; location is resolved by one join (`zone.locationId`), not duplicated onto every row.

| Option | Verdict |
|---|---|
| Add `locationId` directly to `meter_reading`/`tariff_rate` (denormalized, like `zoneId` today) | Rejected — duplicates the exact ambiguity ADR 0004 Decision 1 fixed for zones; a reading's location is already fully determined by its zone, so a second FK can drift out of sync with `zone.locationId`. |
| `Location` owns zones via `locationId` FK on `TariffZone` (one join away) | **Chosen.** Single source of truth; readings/rates need no schema change beyond the join. |
| Separate SQLite database file per location | Rejected — no cross-location query for the combined chart without opening N connections and merging in Dart; complicates backup/export (deferred ADR) and `path_provider` resolution per ADR 0002. |
| Tag locations as a special `ZoneKind` | Rejected — conflates two different lifecycles (a location has zones; a zone does not have zones) and breaks the existing `day + night ≈ total` reconciliation, which is scoped per location. |

## Decision 2 — Migration: `schemaVersion` 1 → 2, backfilled to a default location

`onUpgrade` creates `locations`, inserts a single `"Home"` location (`isArchived: false`), and adds
`locationId` to `tariff_zones` defaulting to that row's id — every existing zone, rate, and reading
keeps working unchanged. `locationId` is `NOT NULL` after backfill; a zone always belongs to exactly
one location. A migration test (Testing Agent) asserts pre-migration fixture data survives with the
default location attached.

## Decision 3 — Reconciliation and rate validation stay scoped per location

`ZoneReconciliation` (ADR 0004 Decision 6) and `RateValidator.overlaps` currently operate over "all
zones" — they must be re-scoped to "all zones of a given location". A `total` zone's reconciliation
against `day`/`night` is meaningless across two different meters, so cross-location double-counting
must not reappear once locations exist. No change to the underlying math, only to what set of zones
is passed in.

## Decision 4 — Combined view: a location-grouping mode alongside the existing zone-grouping mode

Extend the two aggregation helpers added in ADR 0004 Decision 5 with location-level siblings in
`core/`, kept at 100% coverage like every other calculator:

- `ConsumptionCalculator.totalsByLocation`
- `ExpenseCalculator.calculateByLocation`

Stats tab gains a **scope switch**: `Per zone` (today's behaviour, implicitly "current location") vs
`Combined (all locations)`. In combined mode:

- The consumption/expense donuts (ADR 0004 Decision 6) chart one slice per **active, non-archived**
  location instead of per zone, using `location.colorArgb`.
- A new **stacked bar chart**, one bar per period bucket (day/week/month, matching ADR 0002
  Decision 3's existing bucket logic) with one stack segment per location, lets a user compare
  trends across properties over time in a single chart — this is the "combined chart" capability
  requested; it is additive to, not a replacement for, the existing per-zone stacked bar.
- The data table gains an optional `Location` column, hidden when only one location exists (keeps
  the single-location experience visually unchanged, satisfying the "no regression for existing
  users" bar every prior ADR in this project has held to).

| Option for the combined chart type | Verdict |
|---|---|
| Overlaid line chart, one line per location | Rejected — consumption is bucketed/discrete per ADR 0002 Decision 3's own reasoning; a line implies interpolation between readings that didn't happen, now across two independent meters. |
| Single donut mixing zones and locations | Rejected — different granularities in one chart is confusing; keep zone-grouping and location-grouping as separate, explicit modes. |
| Stacked bar per period, one segment per location (mirrors existing per-zone stacked bar) | **Chosen.** Reuses an already-validated, already-tested visual language; consistent bucket math. |

## Decision 5 — Single currency per combined view; mixed currencies are a hard error, not a conversion

`Money` (ADR 0002 Decision 2) already carries `currencyCode` and refuses to add mismatched
currencies. Rather than introduce FX conversion (out of scope, needs a rate source and staleness
policy — a future ADR if requested), `ExpenseCalculator.calculateByLocation` throws/reports a
validation error if the locations being combined use different `currencyCode`s, and the UI disables
the combined-expense donut (consumption-by-location, being `Kwh` not `Money`, is unaffected) with an
explanatory message instead of silently summing incompatible currencies.

## Consequences

- Breaking interface addition: new `LocationRepository` in `core/` (CRUD + `watchAll`), implemented
  as `DriftLocationRepository` in `data/`, injected by both app shells alongside the existing three
  repositories — same pattern as ADR 0004 Decision 7 already established for zones/rates.
- New "Locations" management screen in `ui/`, list-style like the Zones tab (ADR 0004 Decision 2):
  create/rename/recolour/archive; delete blocked while the location owns any zone (mirrors the
  zone-delete protection already in place for zones that own readings).
- `TariffZone` construction gains a required `locationId`; every call site (seed data, dialogs,
  tests) must be updated — a mechanical but wide-reaching change.
- `docs/platform-matrix.md` and coverage targets are unaffected; this is additive schema/UI, not a
  new platform.
- Deferred, not addressed here: FX conversion for genuinely multi-currency combined views, and
  cross-location export/backup (tracked as an open item alongside the existing export/backup and
  cloud-sync follow-ups noted in ADR 0002's Consequences).

## Implementation handoff

Backlog ticket: [`docs/backlog/mvp-004-multi-location-support.md`](../backlog/mvp-004-multi-location-support.md)
(label `agent:codegen`, actionable now that this ADR is accepted).

## Addendum (2026-09-24) — Decision 1 revised: zones are many-to-many with locations

Initial implementation gave `TariffZone` a single `locationId`, so a zone (and its tariff rates)
belonged to exactly one location. User feedback identified a real MVP gap this created: a user
with `Home` and `Apartment` who both bill `Day`/`Night` on the same tariff would have to duplicate
those zones and rates per location — exactly the duplication this ADR set out to avoid.

**Revised model**: `TariffZone` no longer carries a location at all; a new `location_zone` join
table (`locationId`, `zoneId`) lets a zone — and by extension every tariff rate recorded against
it — be linked to any number of locations. `MeterReading` gains its own `locationId`, because a
shared zone code alone no longer identifies which location's meter a reading belongs to.

```
location       (id, name, colorArgb, sortOrder, isArchived)
tariff_zone    (id, code, name, kind, colorArgb, sortOrder, isArchived)   -- no location field
location_zone  (locationId, zoneId)                                      -- many-to-many
tariff_rate    (id, zoneId, ...)                    -- unchanged; shared automatically via the zone
meter_reading  (id, locationId, zoneId, ...)         -- locationId added; UNIQUE(locationId, zoneId, readingDate)
```

| Option | Verdict |
|---|---|
| Keep `TariffZone.locationId` (one location per zone) | Rejected — forces duplicating a zone and its whole rate history to reuse an identical tariff at a second location, which is the exact pain point reported. |
| `location_zone` join table; zone stays location-agnostic; rates unchanged | **Chosen.** A zone/tariff is defined once and linked to N locations; unlinking (not just deleting) a zone from a location is now possible. |
| Composite zone identity (`locationId + zoneId` as the code) | Rejected — reintroduces duplication of the tariff rate rows to keep two locations' "Day" in sync, which is what a shared zone is meant to eliminate. |

Consequences of the revision: `ConsumptionCalculator.deltas` now pairs readings per
`(locationId, zoneId)`, not per `zoneId` alone, so two locations sharing a zone never cross-pair
each other's cumulative readings. The Stats tab's `Per zone` mode is now scoped to a single
"current location" (a new app-bar switcher, shown only once a second location exists) for the same
reason; `Combined` mode is unaffected. `TariffZoneRepository.save` persists the zone row and its
`location_zone` links transactionally; `delete` cascades the links. This addendum supersedes
Decision 1's schema and the "required `locationId`" consequence above; Decisions 2–5 and the
combined-chart design are otherwise unchanged.
