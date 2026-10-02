# Mobile App

The Android and iOS shells use the shared `ui`, `data`, and `core` packages.
Resolve workspace dependencies and generate Drift sources from the repository
root before building.

## Android

Build an unsigned Release APK from this directory:

```powershell
flutter build apk --release `
  --dart-define=GOOGLE_OAUTH_CLIENT_ID=your-public-android-client-id `
  --dart-define=GOOGLE_OAUTH_WEB_CLIENT_ID=your-public-web-client-id
```

The APK is written to `build/app/outputs/flutter-apk/app-release.apk`. No
debug-key signing fallback is configured for Release. Signing/distribution
keys must be provisioned through a separately approved release process. Google
Sign-In also requires the Android package name and signing certificate SHA
fingerprint registered in Google Cloud.

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
