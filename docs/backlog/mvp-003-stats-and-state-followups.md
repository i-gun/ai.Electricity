# MVP-003 — Stats depth, entry ergonomics, and state-management revisit

- **Labels**: `agent:codegen`, `type:tech-debt`, `status:ready`
- **Depends on**: [MVP-002](mvp-002-multi-zone-capture.md), [ADR 0004](../adr/0004-multi-zone-capture-and-per-zone-visualisation.md)
- **Branch**: `feat/<issue-number>-stats-followups`

Deferred deliberately from MVP-002 so the five reported defects could land as a minimal diff.

## 1. True stacked bars and bucketed periods

`Consumption by period` currently renders one `BarChartRodData` per delta, coloured by that delta's
zone. MVP-001 asks for **stacked** bars: bucket deltas by day/week/month (granularity auto-selected
from the range length) and stack one rod segment per zone within each bucket. The bucketing belongs
in `core/` (`ConsumptionCalculator`), not in the widget, so it stays inside the 100% coverage rule.

## 2. Custom date range

The range dropdown offers 1M/3M/6M/1Y only. MVP-001 also requires a custom range. Add a
`showDateRangePicker` option and drop `_rangeKey`'s day-count heuristic, which cannot round-trip an
arbitrary range.

## 3. Missing summary tiles

MVP-001 specifies **average daily kWh** and **day/night share**. Only total kWh, total cost, and
range length are rendered today. The day/night share is already computable from
`ConsumptionCalculator.totalsByZone`.

## 4. One submit for all active zones

MVP-001 asks for "a single entry form that records all active zones for one date in one submit".
The current dialog records one zone per submit, which means three dialogs for a day/night/total
setup. Extend the form to a per-zone value row set while keeping per-zone validation, and group the
readings list by date when several zones are recorded.

## 5. Undo on delete

Delete is guarded by a confirmation dialog; MVP-001 also asks for undo. A `SnackBar` action that
re-saves the removed entity is sufficient given ids are stable.

## 6. Locale-aware formatting

`_money` hardcodes `CURRENCY 0.00` and `_formatDate` hardcodes ISO `yyyy-MM-dd`. Adopt `intl` with
the ambient locale for both, and confirm the chosen format against the platform text-scale and
right-to-left checks in [`docs/platform-matrix.md`](../platform-matrix.md).

## 7. State-management revisit

ADR 0004 §Decision 7 keeps `setState` with three repository stream subscriptions in `SharedHome`.
Re-evaluate when a fourth stream appears, when state must be shared across tabs, or when state must
outlive `SharedHome`. Deliverable is an ADR, not code, if the answer is "adopt a framework".

## 8. Coverage

Confirm the AGENTS.md gate (≥ 90% overall, 100% for `core/lib/**`) against the expanded surface, and
correct any agent config still referencing `core/business-logic/**` (see ADR 0003 §Decision 3).
