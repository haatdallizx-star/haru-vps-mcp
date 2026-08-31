# HealthKit iOS collector (Phase 2A)

The phone-side half of the HealthKit bridge: a SwiftUI iOS app that reads iOS
HealthKit **quantity** samples, durably queues them on a two-stage disk-backed
outbox, and uploads them to the VPS ingest service via
`POST /healthkit/v1/ingest`. It is built on a macOS GitHub Actions runner into an
**ad-hoc signed .ipa** whose HealthKit entitlements are verified to be present.

The VPS server-side ingest service is a separate component living on the
`healthkit-vps-ingest` branch (PR #1). This collector is an isolated, additive
component under `ios/` and does **not** modify or redeploy that service.

## Architecture

```
Apple Watch -> iPhone HealthKit -> HealthBridge app -> HTTPS POST /healthkit/v1/ingest -> VPS store
```

Responsibilities are kept isolated (mirroring the approved bridge design):

| Component | Responsibility |
|---|---|
| `HealthKitManager` | HealthKit authorization, `HKObserverQuery` registration (at launch, for background relaunch), `enableBackgroundDelivery`, `HKAnchoredObjectQuery` incremental reads |
| `SampleEncoder` | Map raw values to server-contract `HealthSample`s (canonical units, UTC ISO-8601, metadata allow-list) |
| `AnchorStore` | One persisted anchor per metric; first-run 24 h read window |
| `Outbox` | Durable two-stage `pending`/`inflight` queue; batch cap 800 |
| `Uploader` | Background `URLSession` upload; only 2xx removes a batch from inflight |
| `SecureConfig` | Endpoint (UserDefaults) + bearer token (Keychain, `kSecAttrAccessibleAfterFirstUnlock`) |
| `SyncEngine` | Orchestrates: queue samples → advance anchor → drain queue |
| App UI | Authorization, background-delivery, queue depth, last-upload status, manual sync |

### Durability before progress

A HealthKit anchor is advanced **only after** newly read samples are durably
written to the outbox. Ordering (enforced in `SyncEngine.didRead`):

1. Encode + `outbox.enqueue(...)` (persist to disk)
2. `anchorStore.update(...)` (advance anchor)
3. `drainQueue()` (upload)

### Retry model

```
new samples -> pending -> (atomic move) -> inflight -> HTTP upload
                                              -> 2xx: delete inflight
                                              -> failure: requeue to pending
```

- Moving `pending -> inflight` is an atomic rename, so a process death mid-move
  never loses records.
- A batch is removed from inflight **only** after a 2xx response.
- Failed / 5xx / offline uploads stay queued for a later retry; 401/403 keeps data
  queued but stops aggressive retry.

### First-run 24 h window

On first use of a metric (no stored anchor), only the previous 24 hours are read,
so a fresh install never imports an entire Health history. Historical backfill is
explicitly deferred.

## Metrics

Phase 2A ships **quantity** samples only, in an extensible registry
(`HealthKitMetrics`):

| type | HealthKit identifier | canonical unit |
|---|---|---|
| `heart_rate` | `HKQuantityTypeIdentifierHeartRate` | `bpm` |
| `hrv` | `HKQuantityTypeIdentifierHeartRateVariabilitySDNN` | `ms` |
| `steps` | `HKQuantityTypeIdentifierStepCount` | `count` |

Category metrics (sleep / menstrual / etc.) are intentionally **not** added yet.
Adding a metric is one entry in `HealthKitMetrics` plus the corresponding read in
`HealthKitManager`, plus (server-side) a matching type.

## Security

- No production bearer token or endpoint is hardcoded or committed.
- The endpoint is entered in Settings and stored in `UserDefaults` (not secret).
- The token is entered in Settings and stored in **Keychain** with
  `kSecAttrAccessibleAfterFirstUnlock` so background work can read it after the
  first unlock following a reboot. It is never written to UserDefaults or logs.
- The metadata allow-list forwards only known-safe keys
  (`HKWasUserEntered`, `HKMetadataKeyHeartRateMotionContext`).

## GitHub Actions build

`.github/workflows/ios-build.yml` (`runs-on: macos-14`):

1. `actions/checkout@v7`
2. install XcodeGen (`brew install xcodegen`)
3. `xcodegen generate` (in `ios/`)
4. run unit tests on an iPhone simulator
5. build **Release** for `iphoneos` (temporary unsigned), then **ad-hoc sign** it
   with the app's entitlements (`codesign --sign - --entitlements ...`)
6. **entitlement gate**: `ios/scripts/verify-entitlements.sh` — fails the job
   unless **both** `com.apple.developer.healthkit` and
   `com.apple.developer.healthkit.background-delivery` are in the signed app's
   entitlements
7. package `Payload/HealthBridge.app` -> `HealthBridge.ipa`
8. `actions/upload-artifact@v4` uploads the `.ipa` + the verified entitlements
   plist

**Where to download the IPA:** the workflow run page → **Artifacts** →
**HealthBridge-ipa** → `HealthBridge.ipa`. (No Apple Developer account is needed
to produce it.)

## Required entitlements

`ios/HealthBridge/HealthBridge.entitlements`:

- `com.apple.developer.healthkit`
- `com.apple.developer.healthkit.background-delivery`

These are the two keys the build gate requires and the source of the observation +
background-delivery capabilities.

## Why ad-hoc signing is intentional

The CI signs the built app **ad-hoc** (`-` identity) rather than leaving it
unsigned. A fully unsigned build (`CODE_SIGNING_ALLOWED=NO` as the final state)
has **no embedded entitlements** in the code signature, so it would fail the
inspection gate and would not carry the HealthKit metadata that matters here.

Ad-hoc signing embeds the entitlement keys into the final signature with **no
Apple Developer account and no provisioning profile**, which is exactly what lets
this build be reproducible on a shared macOS runner while keeping the entitlement
metadata inspectable.

Implication: ad-hoc signing does **not** fully provision the app for a real
device (it has no team/provisioning behind it). Installing and re-signing on a
physical iPhone is a separate, later subsystem (see "Not done yet").

## Not done yet (explicitly out of Phase 2A scope)

- **Patched `xtool` build** (Phase 2B): a pinned upstream xtool commit patched to
  add the HealthKit background-delivery entitlement for Windows/WSL install.
- **Physical-device installation / weekly re-sign** over the WSL/usbmuxd bridge.
- **Apple-ID signing** and a real provisioning profile.
- **Category metrics** (sleep, etc.) and the read-only `healthkit_query` MCP tool.
- Real-device 24–48 h acceptance validation.

## Tests

Swift unit tests in `ios/HealthBridgeTests/` run on the simulator and do not need
a physical device:

- `SampleEncoderTests` — canonical units + fields, metadata allow-list
- `OutboxTests` — pending → inflight → success/failure transitions, persistence,
  recovery of in-flight batches on relaunch, 800-batch cap
- `AnchorStoreTests` — first-run 24 h window, per-metric independence, anchor
  persistence, durability-before-progress ordering
- `UploadTests` — response classification (2xx/401/403/4xx/5xx), only-2xx-deletes
  routing, request builder (Bearer auth + JSON)
- `SecureConfigTests` — token is stored only in Keychain, never in UserDefaults;
  HTTPS-only endpoint validation

## Local validation on a non-Mac machine

There is no Xcode/Swift toolchain on a Linux box, so the `.ipa` and the Swift unit
tests can only be produced/run on the macOS CI runner. What can be validated
locally (and is part of this change's CI):

- YAML well-formedness of `project.yml` and `ios-build.yml`
- plist/entitlements well-formedness of `Info.plist` / `HealthBridge.entitlements`
  and that both HealthKit keys are present
- `bash -n` on `scripts/verify-entitlements.sh`
