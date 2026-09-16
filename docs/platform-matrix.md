# Platform Test Matrix

CI must build and run at least a smoke-level e2e per platform on every PR.

| Platform | Runner | Build target | Test types run on every PR |
|---|---|---|---|
| Windows desktop | `windows-latest` | `flutter build windows` | unit, integration, e2e smoke |
| macOS desktop | `macos-latest` | `flutter build macos` | unit, integration, e2e smoke |
| Linux desktop | `ubuntu-latest` | `flutter build linux` | unit, integration, e2e smoke |
| Android | `ubuntu-latest` + emulator (API 33) | `flutter build apk --debug` (CI smoke) / `flutter build apk --release` (published artifact) | unit, integration, e2e smoke |
| iOS | `macos-latest` + simulator | `flutter build ios --simulator` | unit, integration, e2e smoke |

Nightly schedule additionally runs deeper e2e suites per platform (not required for PR merge).
