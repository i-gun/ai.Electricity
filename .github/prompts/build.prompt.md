---
name: "Build Artifacts"
description: Use this prompt to build verification artifacts with the Code Build Agent.
agent: "Code Build Agent"
tools: [execute, read, edit, search, web, agent, todo]
---

Build verification artifacts from the latest code using the Code Build Agent.

Source:
- source_ref: main
- Resolve `main` to a full immutable commit SHA before doing any build work.
- Report the resolved SHA and use only that SHA for all subsequent work.

Requested targets:
- Windows desktop: Flutter Windows bundle
- macOS desktop: Flutter macOS app bundle
- Linux desktop: Flutter Linux bundle
- Android: debug APK
- iOS simulator: unsigned simulator app

Requested build modes:
- debug
- release
- profile

Platform confirmation gate:
1. Before checkout, dependency resolution, validation, or artifact creation, display the resolved commit SHA and the complete target matrix above.
2. Require an explicit confirmation in this exact form before proceeding:

   confirmed
   commit: <resolved-full-sha>
   windows-desktop: Flutter Windows bundle, debug
   macos-desktop: Flutter macOS app bundle, debug
   linux-desktop: Flutter Linux bundle, debug
   android: debug APK, debug
   ios-simulator: unsigned simulator app, debug

3. Do not infer confirmation from this request. If confirmation is absent, incomplete, changes any platform/mode/format, or the resolved SHA changes, stop without building and request renewed confirmation.

After valid confirmation:
- Run dependency resolution, Drift source generation, formatting validation, `flutter analyze`, and scoped tests.
- Build each target only on its compatible runner.
- Discover produced outputs; record relative paths and byte sizes.
- Produce SHA-256 checksums and a versioned JSON artifact manifest.
- Upload immutable artifact names containing platform, mode, and commit SHA, retained for 14 days.
- Emit the structured build log under `logs/code-build-agent/<run-id>.json`, the agent report, and the informational `code-build-agent/artifacts` check.

Constraints:
- Do not modify application source.
- Do not push, tag, merge, publish releases, or create signed/distribution artifacts.
- Do not request, expose, or use signing secrets.
- On validation or build defects, stop and hand off to Error Resolution Agent.
- On unsupported platforms/formats, report the concrete limitation and route architectural requests to Advisory Agent.
- Use idempotency key:
  <commit-sha>:<normalized-platforms>:debug:<normalized-formats>