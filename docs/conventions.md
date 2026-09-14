# ai.Electricity Repo Conventions

## Layout

```
core/              pure-Dart domain & business logic (no platform UI imports) — 100% coverage required
ui/                platform-agnostic shared Flutter widgets
apps/mobile/       Flutter mobile app shell (iOS/Android adapters only)
apps/desktop/      Flutter desktop app shell (Windows/macOS/Linux adapters only)
docs/              architecture notes, ADRs, conventions, agent-facing reference docs
agents/            machine-readable agent configs
schemas/           JSON schemas for inter-agent messages
.github/workflows/ CI + agent-routing workflows
logs/              per-agent-run audit trail (uploaded as CI artifacts)
```

## Commit messages

[Conventional Commits](https://www.conventionalcommits.org/): `feat:`, `fix:`, `chore:`, `docs:`,
`test:`, `refactor:`. Breaking changes use `!` or a `BREAKING CHANGE:` footer.

## Branch naming

- `feat/<issue-number>-<slug>` — Code Generation Agent output.
- `fix/<slug>` — Error Resolution Agent standalone fixes.
- `release/<version>` — cut by Version Control Agent only.

## Code style

- Dart/Flutter: `dart format` + `flutter analyze` must be clean before a PR leaves draft state.
- No business logic in `apps/*` — only platform adapters and UI composition.
- Public APIs in `core/` require doc comments; internal helpers do not need restated comments.

## Required PR checks

- `review-agent/verdict`
- `testing-agent/gate`
- `ci-build-test` (platform matrix build)
