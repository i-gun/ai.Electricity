## Summary

<!-- What does this PR do? Link the issue it resolves. -->

## Checklist (enforced by agent gates, not just self-reported)

- [ ] `flutter analyze` / `dart format` clean
- [ ] Business logic lives in `core/`, not in `apps/*`
- [ ] Tests added/updated for new behavior
- [ ] No secrets/credentials added or logged

## Agent gates

This PR merges only when both required checks are green:
- `review-agent/verdict` = approve
- `testing-agent/gate` = pass

See [AGENTS.md](../AGENTS.md) for the full contract.
