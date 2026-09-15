# ai.Electricity Repo Conventions

## Layout

```
pubspec.yaml       Dart pub workspace manifest for all five packages
analysis_options.yaml shared analyzer and lint rules for every package
core/              pure-Dart domain & business logic (no platform UI imports) — 100% coverage required
data/              Drift/SQLite persistence implementations; generated code is build-time only
ui/                platform-agnostic shared Flutter widgets
apps/mobile/       Flutter mobile app shell (iOS/Android adapters only)
apps/desktop/      Flutter desktop app shell (Windows/macOS/Linux adapters only)
docs/              architecture notes, ADRs, conventions, agent-facing reference docs
agents/            machine-readable agent configs
schemas/           JSON schemas for inter-agent messages
.github/workflows/ CI + agent-routing workflows
logs/              small structured per-agent-run audit reports (uploaded as CI artifacts; verbose *.build-log.json files are ignored)
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
- `quality` (analysis and package coverage generation)
- `coverage-gate`
- `ci-build-test` platform build jobs

## Artifact builds

`code-build-artifacts.yml` is workflow-dispatch only. It builds from a resolved immutable commit
after explicit confirmation of every selected platform, mode, and format, then uploads a retained
manifest, checksums, logs, and real discovered outputs. It is not a release or publishing workflow;
signed Android bundles, signed iOS IPAs, notarized macOS apps, and installers are unsupported until
an approved ADR and configuration exist.
