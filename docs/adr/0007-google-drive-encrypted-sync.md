# ADR 0007: Local-First, Encrypted Google Drive Sync

- **Status**: Accepted (human approval granted 2026-09-29; implementation and release gates remain open)
- **Date**: 2026-09-29
- **Depends on**: ADR 0002 (local storage), ADR 0004 (zones and rates), ADR 0006 (shared zones and locations)

## Context

Readings, tariff rates, locations, zones and their links currently live only in a
local Drift/SQLite database. Local integer IDs can collide across independent
installations. A user wants changes on Windows, Linux, macOS, Android and iOS
to converge through their Google account, including offline and overlapping
edits. Cloud storage must not hold plaintext readings or credentials. The app
must remain usable without an account or network.

## Proposed decision

Google Drive's per-app `appDataFolder` is an optional transport, not a database
or merge engine. All five apps must use OAuth clients from a compatible Google
Cloud project; verify cross-client access to the same app data before release.
Request only `drive.appdata` and any minimum identity scope necessary to bind a
local vault to an account. The remote payload consists of versioned, opaque,
immutable, independently encrypted change objects. Do not sync or overwrite
the SQLite file, and do not use a single mutable snapshot as the source of
truth. Publishing a new object must be safe with concurrent writers. Poll and
page remote files on launch, foreground and explicit Sync now; checkpoint only
after durable local application. Retain changes until a separately designed
compaction protocol is proved safe for long-offline devices.

Every location, zone, rate, reading and relationship needs a globally stable
identity separate from its local SQLite integer key. A versioned migration
backfills identities for existing rows, including seeded rows, and preserves
foreign-key relationships. Local changes and outbox entries are committed in
one transaction. Received changes are applied idempotently by change ID
without echoing them into the outbox; deletion uses tombstones. Record the
causal parent/base revision of edits and resolutions, not just wall-clock
timestamps. A first connection between two independently populated devices
must match their separately seeded locations/zones explicitly or through a
reviewed deterministic rule, not by local integer ID or display name alone.

The shared pure-Dart merge layer distinguishes identical deliveries from
concurrent changes. Independent readings on different location/zone/date keys
combine; a change to the same reading, or two differing readings for the same
location/zone/calendar date, stays unresolved with both candidates. Treat
rate-period overlaps, concurrent deletes/edits and zone-link changes as
conflicts; never silently take the higher meter value, choose the latest
timestamp, trim tariff windows or rely on SQLite upsert to decide. Revalidate
domain rules after each accepted resolution and recompute derived usage and
cost. Identity aliasing for genuinely identical readings from two independent
installs needs an explicit, durable mapping so later edits do not fork.

The initial pure-Dart reading merge contract lives in `core/lib/src/sync.dart`.
The data layer now includes schema v12 stable entity IDs, local outbox capture
for location, zone/link, rate and reading changes, incoming replay protection,
per-entity causal heads and parent-change IDs, persisted remote ancestry, and a
durable superseded-branch ledger. It also includes an
Argon2id/AES-GCM recovery vault, a testable
encrypted appDataFolder HTTP transport, an OS secure-storage adapter, a
desktop installed-app OAuth flow using PKCE/loopback, and an Android/iOS
Google Sign-In adapter using SDK-managed access tokens. Native client IDs are
read from Dart build defines, not checked in. Both app shells wire account
connect/disconnect, vault create/join, recovery-secret unlock, Sync now and
eligible conflict-resolution choices to a shared Sync settings view. Existing
rows are bootstrapped as deterministic content-addressed baseline events;
exact built-in seeds receive canonical IDs during fresh creation or migration.
A conflict inbox and incoming applier
validate/decrypt remote changes, apply safe new entities without outbox echo,
deduplicate replays, and preserve identity, dependency, slot and rate-window
collisions without overwriting local data. Conflicting readings retain both
candidate values, and remote edits apply only when their causal parent matches
the local entity head. Same-identity conflicts with complete snapshots can be
resolved by choosing a candidate; the encrypted resolution event names both
full branch histories, is accepted only when a peer's head is among those
branches, and records superseded ancestors so late files cannot reopen the
conflict. Explicit
identity merges are supported for same-slot readings, single-pair overlapping
rates, and duplicate locations/zones; aliases are durable, and location/zone
relationships are reconciled. Deletions that would break dependent records and
ambiguous multi-rate overlaps remain unresolved. Bootstrap handles exact
built-in seeds and journals existing rows; duplicate names/codes are offered
for review, never silently matched. Unlocked vault keys
can be cached per account in OS secure storage; the recovery secret is not
persisted. The Android debug APK and Windows desktop builds compile with the
secure-storage plugin. iOS still needs its project-specific reversed
client ID URL scheme and has not been built here. Live cross-platform Drive
sync and conflict-resolution verification remain. These components must not
be presented as a finished sync feature.

## Security and recovery gates

- Google authorization uses an installed/native app flow with PKCE S256,
  validated state, system browser or approved native SDK and supported platform
  redirects. Desktop loopback is restricted to `127.0.0.1` for the OAuth
  callback only; it is not a remote plaintext connection. Android and iOS use
  the Google Sign-In SDK and do not receive a client secret. The Desktop OAuth
  client may require its matching `client_secret` during direct code exchange
  and refresh. This value is bundled as public, extractable client
  configuration, not treated as confidential and not relied on as a security
  boundary. Never ship a Web application client secret, service-account key,
  Google password or user credential in the app.
- Persist tokens and any optional unlocked vault key only in an OS-backed
  encrypted secret store. Review Keychain entitlements, Android Keystore and
  backup exclusions, Windows protected storage and Linux Secret Service
  availability at build and runtime. Missing or locked keyring means sync is
  unavailable, never a plaintext fallback. Never log tokens, keys, passwords,
  authorization codes, decrypted payloads, or sensitive URL parameters.
- Generate a random per-vault data key. Wrap it with a recovery secret using
  an audited memory-hard KDF and a random salt with versioned parameters.
  Encrypt every remote change and sensitive metadata with vetted AEAD and a
  unique random nonce and authenticated vault/schema/change context. The
  recovery secret is never persisted verbatim; a new device must unlock the
  vault. Losing the recovery secret and all unlocked devices loses access.
  Drive's own encryption is not a substitute for this client-side encryption.
- Only use authenticated HTTPS with certificate validation for Google APIs,
  OAuth token exchange and revocation. No insecure transport, disabled TLS
  verification, embedded browser credentials, or bearer tokens in URLs.
  Reject malformed, oversized, unsupported or unauthenticated remote objects
  without modifying local data. Do not log unredacted provider error bodies.
- Keep local readings in the existing SQLite database in this phase. Local
  database encryption is a separate decision; the cloud payload and all
  persisted credentials must nevertheless be encrypted as specified above.

## Alternatives and tradeoffs

| Option | Benefit | Cost / reason not chosen first |
|---|---|---|
| Google Drive app data + encrypted immutable changes | User-owned storage across all five platforms; no hosted sync backend | OAuth and platform keyrings; file listing/quotas; application owns merge, encryption and recovery |
| CloudKit private database | Native Apple-account experience | No equivalent native Windows/Linux/Android path for this app |
| Hosted relational service | Centralized conflict checks and cross-platform identity | Ongoing backend operation, billing and privacy obligations |
| One mutable encrypted Drive snapshot | Simple upload/download prototype | Concurrent writes can overwrite each other; not an acceptable sync protocol |

## Release criteria and open approval items

The approved first crypto dependency is `cryptography` (Argon2id and AES-256-GCM);
OS secret storage and OAuth implementations still need verification on all five
targets before shipping. Check vendor behavior rather
than assuming Drive offers compare-and-swap, transactional multi-file updates
or automatic conflict resolution. Securely caching the unlocked key per
account is implemented; finish recovery/export UX and define metadata
retention/deletion policy. Validate
Google consent-screen requirements and a live two-device cross-client smoke.

Tests must include independently populated installs, concurrent conflicting
readings/rates, replay, offline edits, remote corruption, wrong account/key,
token revocation, partial upload, quota and rate-limit failures, keyring
unavailability and migration from existing versions. No real Google tokens in
CI. Maintain 100% `core/lib/**` and at least 90% overall coverage, with a
working secure-store and sync smoke for Windows, Linux, macOS, Android and iOS.

## Build-time Google OAuth configuration

OAuth client IDs are public identifiers, not secrets, but must be supplied by
the release environment rather than committed as user/project-specific values:

- Desktop Windows/Linux/macOS: `GOOGLE_OAUTH_DESKTOP_CLIENT_ID` via Dart
  `--dart-define`, and the matching `GOOGLE_OAUTH_DESKTOP_CLIENT_SECRET` via
  Dart `--dart-define`. The client secret is public/extractable in the
  distributed app; source repositories and logs must not contain its value.
- Android: `GOOGLE_OAUTH_CLIENT_ID` and `GOOGLE_OAUTH_WEB_CLIENT_ID` via Dart
  `--dart-define`, plus the Android package name and signing certificate SHA
  registered in Google Cloud.
- iOS: the same Dart defines, plus the iOS OAuth client ID and its reversed
  client ID registered as a URL scheme in the Runner target. Google Sign-In
  also has App Store account-login requirements to review before release.

Desktop publishes changes with a refresh token stored in OS-backed secure
storage. Secret-only rotation retains the OAuth client ID; verify refresh of
existing tokens with the replacement secret before retiring the old value.
Changing the client ID requires reauthorization and a cross-client Drive
appDataFolder access smoke; do not assume existing remote files remain visible.
The native Android/iOS Google Sign-In SDK currently exposes access tokens only
to this Flutter plugin; it obtains renewed tokens through the SDK when possible
and requires foreground reauthorization otherwise. Do not assume native
background sync will remain authorized indefinitely. Treat refresh-token
parity, iOS URL scheme setup, App Store login requirements and actual OAuth
consent-screen verification as release blockers, not secrets to add to source.