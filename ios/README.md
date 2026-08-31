# HealthBridge — iOS HealthKit collector

The phone-side half of the HealthKit bridge. It observes iOS HealthKit, reads
quantity samples incrementally, durably queues them, and uploads them to your own
HTTPS ingest endpoint (`POST /healthkit/v1/ingest`). It is generated with
**XcodeGen** and built on a macOS GitHub Actions runner — you do not need a
locally owned Mac or an Apple Developer account to produce the `.ipa`.

See [`docs/healthkit-ios-collector.md`](../docs/healthkit-ios-collector.md) for the
full architecture, build, and artifact instructions.

## Layout

```
ios/
  project.yml                 XcodeGen spec (generates HealthBridge.xcodeproj)
  HealthBridge.xcconfig       HEALTHBRIDGE_BUNDLE_ID — single configurable knob
  HealthBridge/               app sources
    HealthKit/                HealthKitManager + extensible metric registry
    Model/                    HealthSample / device identity (server contract)
    Encoder/                  SampleEncoder (canonical units + metadata allow-list)
    Store/                    AnchorStore (per-metric anchors) + Outbox (2-stage queue)
    Upload/                   Uploader / SecureConfig / KeychainStore
    Orchestrator/             SyncEngine (ties everything together)
    UI/                       Status + Settings (SwiftUI)
  HealthBridgeTests/          unit tests (no physical device required)
  scripts/verify-entitlements.sh   CI entitlement gate
```

## Regenerate the Xcode project

On a Mac (or the CI runner), from `ios/`:

```sh
xcodegen generate
```

The generated `HealthBridge.xcodeproj` is git-ignored — only `project.yml` is
tracked.

## Bundle identifier

It is a single knob in `ios/HealthBridge.xcconfig`:

```ini
HEALTHBRIDGE_BUNDLE_ID = com.haru.healthbridge
```

Override per build:

```sh
xcodebuild ... PRODUCT_BUNDLE_IDENTIFIER=com.yourteam.healthbridge
```

## Build locally (requires Xcode + HealthKit-capable setup)

```sh
xcodegen generate
xcodebuild -project HealthBridge.xcodeproj -scheme HealthBridge \
  -destination 'platform=iOS Simulator,name=iPhone 15' test
```

## Build the .ipa (CI does this; requires no dev account)

The `.github/workflows/ios-build.yml` on macOS:
1. installs XcodeGen and generates the project
2. runs the unit tests on an iPhone simulator
3. builds **Release** for `iphoneos`
4. **ad-hoc signs** the app with the HealthKit entitlements
5. fails unless the **entitlement gate** sees both HealthKit entitlements
6. packages `Payload/HealthBridge.app -> HealthBridge.ipa`
7. uploads the `.ipa` + the verified entitlements plist as a workflow artifact

Download the `.ipa` from the workflow run → **Artifacts → HealthBridge-ipa**.
