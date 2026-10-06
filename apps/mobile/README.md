# Mobile App

The Android and iOS shells use the shared `ui`, `data`, and `core` packages.
Resolve workspace dependencies and generate Drift sources from the repository
root before building.

## Android

Build a Release APK from this directory:

```powershell
flutter build apk --release `
  --dart-define=GOOGLE_OAUTH_CLIENT_ID=your-public-android-client-id `
  --dart-define=GOOGLE_OAUTH_WEB_CLIENT_ID=your-public-web-client-id
```

The APK is written to `build/app/outputs/flutter-apk/app-release.apk`. Gradle
signs it when all four environment variables are provided:
`ANDROID_KEYSTORE_PATH` (absolute keystore path), `ANDROID_KEYSTORE_PASSWORD`,
`ANDROID_KEY_ALIAS`, and `ANDROID_KEY_PASSWORD`. A partial configuration fails.
Without these variables, local diagnostic builds remain unsigned and cannot be
installed or published. There is no debug-key fallback for Release.

### Create and provision a release signing key

Create the key yourself in a local terminal. Never paste private keys or
passwords into chat, commit them, or include passwords in command arguments.
On Windows with Android Studio installed:

```powershell
$keytool = 'C:\Program Files\Android\Android Studio\jbr\bin\keytool.exe'
$keystore = Join-Path $env:USERPROFILE '.android\ai-electricity-release.jks'
New-Item -ItemType Directory -Force (Split-Path $keystore) | Out-Null
& $keytool -genkeypair -v -storetype JKS -keystore $keystore `
  -alias ai-electricity -keyalg RSA -keysize 3072 -validity 10000
```

Answer the password and certificate identity prompts directly in the terminal.
Record both the keystore and key passwords in a password manager. If you accept
the same password for both, provision that password for both GitHub secrets.
Keep an encrypted backup of the keystore and passwords: losing or replacing the
key prevents updates to existing installations. Run this command only once;
reuse the same key for every subsequent release.

From the repository root, use GitHub CLI to upload the keystore without printing
its contents, and enter passwords only at the CLI prompts:

```powershell
[Convert]::ToBase64String([IO.File]::ReadAllBytes($keystore)) |
  gh secret set ANDROID_KEYSTORE_BASE64
gh secret set ANDROID_KEYSTORE_PASSWORD
gh secret set ANDROID_KEY_ALIAS --body ai-electricity
gh secret set ANDROID_KEY_PASSWORD
& $keytool -list -v -keystore $keystore -alias ai-electricity
```

Take the **SHA256 certificate fingerprint** from the last command, remove its
colons, and set the public repository variable (not a secret):

```powershell
gh variable set ANDROID_SIGNING_CERT_SHA256 --body '<64-hex-character-fingerprint-without-colons>'
```

Alternatively, provision these four repository secrets and the repository
variable under **Settings > Secrets and variables > Actions**. The keystore
secret must contain the base64-encoded file, not a file path. Repository secrets
are used directly; environment-scoped secrets require a corresponding workflow
environment configuration.

### Publication gate and upgrades

The release workflow requires all signing secrets and the certificate pin before
building Android. It decodes the keystore into a private temporary runner file,
signs through Gradle, and runs `apksigner verify` plus a certificate fingerprint
comparison before packaging or uploading the APK. The temporary key is deleted
even when the job fails. A missing key, invalid signature, or different signing
certificate fails the Android job and prevents the entire GitHub Release from
being published or updated by that workflow.

Publish a new SemVer tag on a commit containing the signing changes, such as
`v0.2.1`, after the normal review/test gates. Re-running the old `v0.2.0` tag does
not update its checked-out Gradle configuration. Existing published assets are
not repaired automatically.

The v0.1.0 APK used a CI-generated debug certificate. A new release key cannot
update that installation in place. Unless its original private signing key is
available, back up/export local data before uninstalling the old app and
installing the first correctly signed release. Future updates must retain the
same application ID and signing key and use increasing Android `versionCode`
values (the `+build-number` in this app's `pubspec.yaml`); GitHub tags alone do
not change the Android package version.

Google Sign-In also requires `dev.aielectricity.mobile` and the release
certificate SHA fingerprint registered in Google Cloud. APK signing does not
by itself configure OAuth or guarantee compatibility with every Android device.

## iOS

iOS OAuth needs the iOS client ID and its reversed client ID URL scheme. Supply
the values in `ios/Flutter/Local.xcconfig`, based on
`ios/Flutter/Local.xcconfig.example`; that local config is git-ignored. Flutter
also receives the client IDs as Dart defines:

```bash
cp apps/mobile/ios/Flutter/Local.xcconfig.example \
  apps/mobile/ios/Flutter/Local.xcconfig
# Set both public client values in Local.xcconfig before building:
# GOOGLE_OAUTH_CLIENT_ID = your-public-ios-client-id
# GOOGLE_OAUTH_REVERSED_CLIENT_ID = your-reversed-ios-client-id
export GOOGLE_OAUTH_CLIENT_ID='<ios-client-id>'
export GOOGLE_OAUTH_REVERSED_CLIENT_ID='<reversed-ios-client-id>'
cd apps/mobile
flutter build ios --release --simulator \
  --dart-define=GOOGLE_OAUTH_CLIENT_ID="$GOOGLE_OAUTH_CLIENT_ID" \
  --dart-define=GOOGLE_OAUTH_WEB_CLIENT_ID='your-public-web-client-id'
```

Device builds require Xcode signing configuration. No signing certificate,
provisioning profile, or client secret belongs in this repository.

Empty OAuth IDs allow an offline build but do not enable account connection or
Drive synchronization. Native mobile Google Sign-In uses SDK-managed access
tokens and may require foreground reauthorization; do not assume unattended
background sync.
