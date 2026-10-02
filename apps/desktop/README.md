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

For account-sync testing, pass the public desktop OAuth client ID at build
time. Do not use a client secret or commit a client ID tied to a developer
account:

```powershell
flutter build windows --release `
  --dart-define=GOOGLE_OAUTH_DESKTOP_CLIENT_ID=your-public-desktop-client-id
```

Without a configured client ID, the app still builds for offline/manual UI
review, but Google sign-in and Drive sync are unavailable. Configure the
matching desktop OAuth client in the Google Cloud project before testing sync.

## Google OAuth Setup

Create an OAuth client with application type **Desktop app**, and use its client
ID for `GOOGLE_OAUTH_DESKTOP_CLIENT_ID`. Enable the Google Drive API and include
the account in the OAuth consent screen's test-user list while the app is in
Testing mode. This flow opens the system browser and uses a root loopback
redirect at `http://127.0.0.1:<ephemeral-port>`; it does not use a web-client
redirect path or an embedded browser. A `redirect_uri_mismatch` message usually
means the client is not a Desktop app client or the client ID belongs to a
different Cloud project.

macOS and Linux use the same `GOOGLE_OAUTH_DESKTOP_CLIENT_ID` define and their
respective `flutter build macos --release` and `flutter build linux --release`
commands from this directory. Linux runtime requires Secret Service/libsecret
for secure credential storage.
