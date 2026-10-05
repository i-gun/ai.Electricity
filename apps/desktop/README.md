# Desktop App

The Windows, macOS, and Linux desktop shells use the shared `ui`, `data`, and
`core` packages. Run package commands from the workspace root unless noted.

## Local Release Builds

Resolve dependencies and generate Drift sources from the repository root:

```powershell
dart pub get
Push-Location data
dart run build_runner build --delete-conflicting-outputs
Pop-Location
```

Build Windows from this directory:

```powershell
flutter build windows --release
```

The runnable bundle is `build/windows/x64/runner/Release/`. Keep the complete
directory together; `desktop.exe` depends on the adjacent Flutter DLL, plugins,
and `data/` assets. No installer or code-signing step is configured.

For account-sync testing, pass the Desktop OAuth client ID and its matching
client secret at build time:

```powershell
flutter build windows --release `
  --dart-define=GOOGLE_OAUTH_DESKTOP_CLIENT_ID=your-public-desktop-client-id `
  --dart-define=GOOGLE_OAUTH_DESKTOP_CLIENT_SECRET=your-desktop-client-secret
```

The Desktop client secret is included in the distributed executable and is
therefore public and extractable; it is a compatibility parameter, not a
security boundary. Supply it from release configuration, never commit it or
use a Web application client secret. The secret is sent only to Google's HTTPS
token endpoint and is not stored with user credentials. Rotating the secret for
the same client ID requires rebuilding and distributing the app; changing the
client ID requires users to authorize again and must be checked for continued
access to existing Drive app-data files.

Without both OAuth values, the app still builds for offline/manual UI review,
but Google sign-in and Drive sync are unavailable. Configure the matching
Desktop OAuth client in the Google Cloud project before testing sync. Release
workflows read the ID from the `GOOGLE_OAUTH_DESKTOP_CLIENT_ID` repository
variable and the matching value from the `GOOGLE_OAUTH_DESKTOP_CLIENT_SECRET`
repository secret.

## Google OAuth Setup

Create an OAuth client with application type **Desktop app**, and use its client
ID for `GOOGLE_OAUTH_DESKTOP_CLIENT_ID`. Enable the Google Drive API and include
the account in the OAuth consent screen's test-user list while the app is in
Testing mode. This flow opens the system browser and uses a root loopback
redirect at `http://127.0.0.1:<ephemeral-port>`; it does not use a web-client
redirect path or an embedded browser. A `redirect_uri_mismatch` message usually
means the client is not a Desktop app client or the client ID belongs to a
different Cloud project.

If token exchange reports `client_secret is missing`, confirm that the
configured ID and secret are the matching pair from the **Desktop app** OAuth
client. Never use a Web application client secret in the Flutter executable.

macOS and Linux use the same `GOOGLE_OAUTH_DESKTOP_CLIENT_ID` define and their
respective `flutter build macos --release` and `flutter build linux --release`
commands from this directory; provide both defines on each build. Linux
runtime requires Secret Service/libsecret for secure credential storage.
