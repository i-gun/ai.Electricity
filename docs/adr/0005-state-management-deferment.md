# ADR 0005: Defer State-Management Framework

## Status

Accepted

## Decision

Keep `setState` and the three repository subscriptions in `SharedHome`. MVP-003 adds
aggregation and presentation state, but does not introduce a fourth stream, cross-tab shared
state, or state that must outlive `SharedHome`. The revisit triggers from ADR 0004 Decision 7
therefore remain unmet.

Re-evaluate a state-management framework when one of those triggers appears. Until then,
introducing one would add dependency and migration cost without solving a current problem.