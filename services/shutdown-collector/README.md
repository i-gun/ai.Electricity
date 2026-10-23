# Local DTEK Shutdown Collector

Experimental, undocumented DTEK Kyiv-region and Kyiv-city integration. The Flutter Windows
app uses `http://127.0.0.1:47831/shutdowns` by default. The collector is a
separate local service, not bundled into or automatically started by Flutter.
No DTEK credentials are required. DTEK availability and anti-bot challenges
can prevent a lookup; failures never imply that power is available.

## Windows Manual Review

Install Node.js 22+ and Microsoft Edge, then run from this directory:

```powershell
npm ci --ignore-scripts
npm test
npm start
```

Leave the collector running. In the desktop app open Locations, edit a
location, select Region, enter City, Street and Building, then save. Open Status
next to Stats and Sync; it follows the active location selected in the app bar.
The location's schedule icon remains available as a shortcut.
Each location owns its address independently; duplicate addresses are allowed.
Empty, partial and archived location addresses never issue a schedule request.
The active address loads once for the navigation bulb; opening Status shares
that result, and changing the active address starts a new lookup. Refresh is
explicit, with no periodic collector polling. Selecting Kyiv city fills the city field
with `м. Київ`. Empty street/building fields still prevent any lookup.

The Status button uses the app theme's filled bulb when no outage is scheduled
for the current Kyiv time, and an outlined bulb during a scheduled or reported
outage. This is not a live power sensor. Its tooltip distinguishes the source;
missing, failed, future-dated, older-than-five-minute, or missing-date data uses
a neutral bulb with a question marker. The indicator checks its clock every
30 seconds without making network requests, including across half-hour
boundaries and Kyiv daylight-saving changes. Use Status refresh for fresh data.

## Region Routing

| Region | Code | Provider |
| --- | --- | --- |
| Kyiv region | `krem` | `https://www.dtek-krem.com.ua` |
| Kyiv city | `kem` | `https://www.dtek-kem.com.ua` |

Kyiv city is separate from the surrounding Kyiv region. Its address city must
be Kyiv (`м. Київ`, `М. Київ`, `Київ` or `Kyiv`); no region is inferred from a
street name. Existing schema-v13 locations migrate to Kyiv region, preserving
the previous provider. Region is stored and encrypted-synced per location;
legacy sync records without it preserve the existing selection. Cache entries
are isolated by region as well as city, street and building. Unsupported
region codes are rejected, never interpolated into an upstream URL.

The first request opens a dedicated Edge profile. If DTEK displays a challenge,
complete it in that browser and retry. No protection-bypass service is used.
The profile is stored outside the repository under
`%LOCALAPPDATA%/ai.Electricity/shutdown-browser`; it is not your normal browser
profile. Do not share it or commit cookies, screenshots, or tokens.

Triage address: city `с. Кам'яна Гребля`, street `Новоселецька`, building `66`.
The live site resolved this to `с. Кам’яна Гребля`, `вул. Новоселецька`, group
`GPV4.1` on 2026-10-23. This is a lookup observation, not a permanently assigned
group. Addresses are never inserted into a user's existing database by setup.

## Behavior And Limits

- Allowlisted upstreams: `https://www.dtek-krem.com.ua/ua/shutdowns` and
  `https://www.dtek-kem.com.ua/ua/shutdowns`, each with its own `/ua/ajax` endpoint.
  Kyiv city's flat street list needs no city form field; the regional site
  resolves city then street. City/street matches must be unique; buildings match exactly.
- The browser retains its dedicated session, but reloads source data for a new
  uncached lookup. Address lookups are serialized. Duplicate in-flight requests
  are shared; successful results are cached for three minutes, at most 100 entries.
- `POST /shutdowns` accepts JSON `{ "region": "krem", "city": "...", "street": "...", "building": "66" }`.
  An omitted region defaults to `krem` for older clients. New clients always send it
  and reject a mismatched response region.
  Address values are not put in URL query strings or logged. `GET /health`
  reports service readiness, not successful DTEK/browser access.
- Responses contain the resolved address, group keys, raw DTEK update text,
  collection timestamp, and dated wall-clock minute intervals in Europe/Kyiv.
  Full and half-hour outages are supported. Multiple groups are combined as a
  union and identified in the UI. Dates are always shown explicitly; a missing
  future day is not interpreted as a day with no outages.
- Incomplete/unknown slots, missing buildings/groups and upstream failures return
  HTTP 503. Expired data is never silently served after a failure. Published
  schedules and reported outage notices are not a real-time power sensor.
- The service binds only to IPv4 loopback, rejects browser Origin headers and
  unexpected Host headers, and exposes no CORS API. Do not expose it publicly.

Optional environment variables: `PORT`, `BROWSER_CHANNEL` (`msedge`, `chrome`,
or `chromium`), `HEADLESS=true`, `DTEK_PROFILE`. For `chromium`, explicitly install
the Playwright browser with `npx playwright install chromium` first. Defaults
use installed Edge without downloading a browser binary.

Desktop endpoint overrides use `--dart-define=SHUTDOWN_COLLECTOR_URL=<url>`.
The client permits HTTPS or loopback HTTP only. Mobile remains disabled unless
that define is supplied; its loopback is the phone, not this Windows machine.
A shared mobile collector requires a separately secured HTTPS deployment, which
is outside this local prototype. No mobile cleartext/network exceptions are added.

Build Windows from `apps/desktop` with `flutter build windows --release`.
Keep the entire resulting Release folder, including DLLs and data, not only
the executable. The collector still requires Node, Edge and its dependencies.