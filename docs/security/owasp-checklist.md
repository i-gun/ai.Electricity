# OWASP Top 10 Review Checklist (Code Review Agent)

Checked on every PR diff that touches auth, storage, network, or user input:

1. **Broken Access Control** — verify authorization checks on every new endpoint/screen action.
2. **Cryptographic Failures** — no secrets/keys in source; use platform secure storage, not plaintext prefs.
3. **Injection** — parameterized queries/commands only; no string-built SQL/shell.
4. **Insecure Design** — flag missing rate limiting, missing input validation at trust boundaries.
5. **Security Misconfiguration** — no debug flags/verbose logging of sensitive data in release builds.
6. **Vulnerable/Outdated Components** — flag new dependencies with known CVEs or no maintenance activity.
7. **Identification & Authentication Failures** — session/token handling reviewed, no custom crypto.
8. **Software & Data Integrity Failures** — verify CI/CD steps don't fetch unpinned/unverified artifacts.
9. **Security Logging & Monitoring Failures** — security-relevant events are logged without leaking secrets.
10. **Server-Side Request Forgery (SSRF)** — validate/allow-list any user-influenced outbound URLs.

Any item that cannot be verified with confidence → `request-changes` + `status:needs-human-review`.
