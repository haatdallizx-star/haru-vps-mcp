# HealthKit iOS Bridge Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a self-contained iPhone HealthBridge app that reads heart rate, HRV, steps, and sleep from HealthKit, durably queues incremental changes, and uploads them to the isolated VPS HealthKit ingest API without requiring a local Mac for development.

**Architecture:** The app is a SwiftUI shell around focused HealthKit, encoding, SQLite outbox, Keychain configuration, and background-upload components. Each HealthKit type has an independent archived query anchor; samples and deletions are committed to SQLite before the anchor advances. Foreground/manual sync is implemented first, then observer/background delivery and background URLSession are layered on top.

**Tech Stack:** Swift 5.10+, SwiftUI, HealthKit, Security/Keychain, SQLite3, Foundation URLSession, XCTest, XcodeGen, GitHub Actions macOS runner.

**Spec:** `docs/superpowers/specs/2026-08-31-healthkit-bridge-design.md`

## Global Constraints

- Phase 1 supports exactly heart rate, HRV, step count, and sleep stages.
- Existing shortcut-based health pipeline remains untouched.
- First synchronization reads at most the previous 24 hours when no anchor exists.
- Each HealthKit type owns an independent query anchor.
- Never advance an anchor until all returned additions and deletions are durably committed locally.
- Local delivery is at-least-once; server UUID idempotency makes replay safe.
- Bearer token is never embedded in source, project files, CI, logs, or ordinary UserDefaults.
- Token is stored in Keychain with `kSecAttrAccessibleAfterFirstUnlock`.
- Only HTTP 2xx marks an inflight batch delivered.
- Batch size is capped at 800 records.
- Timestamps transmitted to the VPS are timezone-aware ISO-8601 UTC strings.
- No strict minute-level delivery SLA is claimed; retain sample, queued, and server-received timestamps for measurement.
- Build artifacts must preserve HealthKit and HealthKit background-delivery entitlements.
- The iOS app must not require a developer-owned local Mac to compile.

---

## File Structure

Create a standalone iOS project under `ios/HealthBridge/` so it does not alter the Python gateway or VPS ingest runtime.

```text
ios/HealthBridge/
  project.yml                         XcodeGen project definition
  HealthBridge.entitlements           HealthKit/background entitlements
  HealthBridge/
    App/HealthBridgeApp.swift          launch wiring and observer bootstrap
    App/AppModel.swift                 UI-facing state/actions
    Config/SecureConfig.swift          endpoint + Keychain token
    Health/HealthMetric.swift          four supported HealthKit type definitions
    Health/HealthKitClient.swift       protocol seam around HKHealthStore
    Health/HealthKitManager.swift      auth, observer, anchored fetch orchestration
    Health/SampleEncoder.swift         HKSample -> wire records
    Persistence/SQLiteDatabase.swift   sqlite connection/schema/transactions
    Persistence/AnchorCodec.swift      secure archive/unarchive HKQueryAnchor
    Persistence/Outbox.swift           samples/deletions/anchors + pending/inflight
    Network/IngestEnvelope.swift       schema-v1 request/response Codable types
    Network/Uploader.swift             foreground/background URLSession upload
    UI/ContentView.swift               setup/status/manual sync UI
  HealthBridgeTests/
    HealthMetricTests.swift
    SampleEncoderTests.swift
    OutboxTests.swift
    SecureConfigTests.swift
    UploaderTests.swift
    HealthKitManagerTests.swift
  scripts/verify-project.sh            generated-project/build entitlement checks
```

---

### Task 1: XcodeGen skeleton, entitlements, and four-metric definitions

**Files:**
- Create: `ios/HealthBridge/project.yml`
- Create: `ios/HealthBridge/HealthBridge.entitlements`
- Create: `ios/HealthBridge/HealthBridge/App/HealthBridgeApp.swift`
- Create: `ios/HealthBridge/HealthBridge/UI/ContentView.swift`
- Create: `ios/HealthBridge/HealthBridge/Health/HealthMetric.swift`
- Create: `ios/HealthBridge/HealthBridgeTests/HealthMetricTests.swift`

**Interfaces:**
- Produces: `enum HealthMetric: String, CaseIterable, Codable` with `heartRate`, `hrv`, `steps`, `sleep`.
- Produces: `HealthMetric.objectType: HKObjectType` and `HealthMetric.sampleType: HKSampleType`.
- Produces: app target `HealthBridge` and test target `HealthBridgeTests`.

- [ ] **Step 1: Write metric tests first**

```swift
import XCTest
@testable import HealthBridge

final class HealthMetricTests: XCTestCase {
    func testPhaseOneContainsExactlyFourMetrics() {
        XCTAssertEqual(Set(HealthMetric.allCases.map(\.rawValue)),
                       Set(["heart_rate", "hrv", "steps", "sleep"]))
    }

    func testEveryMetricResolvesAHealthKitSampleType() {
        for metric in HealthMetric.allCases {
            XCTAssertNotNil(metric.sampleType)
        }
    }
}
```

- [ ] **Step 2: Generate project and verify RED**

Run on macOS CI/dev environment:

```bash
cd ios/HealthBridge
xcodegen generate
xcodebuild test -project HealthBridge.xcodeproj -scheme HealthBridge -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:HealthBridgeTests/HealthMetricTests
```

Expected: FAIL because `HealthMetric` does not exist.

- [ ] **Step 3: Implement the minimal metric mapping**

Map identifiers exactly:

```swift
case heartRate = "heart_rate" // HKQuantityTypeIdentifier.heartRate
case hrv = "hrv"             // HKQuantityTypeIdentifier.heartRateVariabilitySDNN
case steps = "steps"         // HKQuantityTypeIdentifier.stepCount
case sleep = "sleep"         // HKCategoryTypeIdentifier.sleepAnalysis
```

The project entitlements must include `com.apple.developer.healthkit = true` and `com.apple.developer.healthkit.background-delivery = true`. Add HealthKit usage text to generated Info.plist settings. The app requests read-only HealthKit access; do not add share/write types.

- [ ] **Step 4: Run tests and generated-project sanity check**

```bash
xcodegen generate
xcodebuild test -project HealthBridge.xcodeproj -scheme HealthBridge -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:HealthBridgeTests/HealthMetricTests
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add ios/HealthBridge
git commit -m "feat: scaffold HealthBridge iOS app"
```

---

### Task 2: Wire-format sample encoder with canonical units and sleep stages

**Files:**
- Create: `ios/HealthBridge/HealthBridge/Health/SampleEncoder.swift`
- Create: `ios/HealthBridge/HealthBridge/Network/IngestEnvelope.swift`
- Create: `ios/HealthBridge/HealthBridgeTests/SampleEncoderTests.swift`

**Interfaces:**
- Produces: `struct WireSample: Codable, Equatable`.
- Produces: `struct WireDeletion: Codable, Equatable { let uuid: String; let metric: String; let queuedAt: Date }`.
- Produces: `SampleEncoder.encode(sample: HKSample, metric: HealthMetric, queuedAt: Date) throws -> WireSample`.
- Produces: `SampleEncoder.encodeDeletion(_ object: HKDeletedObject, metric: HealthMetric, queuedAt: Date) -> WireDeletion`.

- [ ] **Step 1: Write failing encoder tests**

Cover heart-rate conversion to `bpm`, HRV to `ms`, steps to `count`, UTC dates, UUID preservation, source metadata, and sleep values for in-bed/asleep/awake/core/deep/REM. Include an unknown sleep integer and assert its raw integer survives even when normalized label is `unknown`.

Representative assertion:

```swift
let encoded = try encoder.encode(sample: sample, metric: .heartRate, queuedAt: queued)
XCTAssertEqual(encoded.type, "heart_rate")
XCTAssertEqual(encoded.unit, "bpm")
XCTAssertEqual(encoded.uuid, sample.uuid.uuidString)
```

- [ ] **Step 2: Run encoder tests and verify RED**

```bash
xcodebuild test -project HealthBridge.xcodeproj -scheme HealthBridge -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:HealthBridgeTests/SampleEncoderTests
```

Expected: FAIL because `SampleEncoder`/wire types do not exist.

- [ ] **Step 3: Implement strict encoding**

Use `HKUnit.count().unitDivided(by: .minute())` for heart rate, `.secondUnit(with: .milli)` for HRV, and `.count()` for steps. Sleep is interval/category data and must never emit scalar `value` or `unit`. Encode source name/bundle and only the metadata allowlist already accepted by the VPS (`HKWasUserEntered`, `HKMetadataKeyHeartRateMotionContext`).

For sleep, wire stage labels must be lowercase stable values accepted by the server (`in_bed`, `asleep`, `awake`, `core`, `deep`, `rem`, or `unknown`) and retain the raw category integer in the phone-side record/diagnostic representation.

- [ ] **Step 4: Run encoder tests**

Run the command from Step 2. Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add ios/HealthBridge/HealthBridge/Health/SampleEncoder.swift ios/HealthBridge/HealthBridge/Network/IngestEnvelope.swift ios/HealthBridge/HealthBridgeTests/SampleEncoderTests.swift
git commit -m "feat: encode HealthKit samples for ingest"
```

---

### Task 3: Transactional SQLite outbox and anchor durability

**Files:**
- Create: `ios/HealthBridge/HealthBridge/Persistence/SQLiteDatabase.swift`
- Create: `ios/HealthBridge/HealthBridge/Persistence/AnchorCodec.swift`
- Create: `ios/HealthBridge/HealthBridge/Persistence/Outbox.swift`
- Create: `ios/HealthBridge/HealthBridgeTests/OutboxTests.swift`

**Interfaces:**
- Produces: `Outbox.commit(metric:additions:deletions:newAnchor:queuedAt:) throws`.
- Produces: `Outbox.claimBatch(limit: Int) throws -> ClaimedBatch?`.
- Produces: `Outbox.markDelivered(batchID: UUID) throws`.
- Produces: `Outbox.returnInflightToPending(batchID: UUID) throws`.
- Produces: `Outbox.recoverInflight() throws`.
- Produces: `Outbox.anchor(for metric: HealthMetric) throws -> HKQueryAnchor?`.
- Produces: `Outbox.pendingCount() throws -> Int`.

- [ ] **Step 1: Write failing transaction/recovery tests**

Tests must prove: additions and deletions are inserted in the same transaction as the new anchor; a simulated insert failure leaves the old anchor intact; independent metrics have independent anchors; claim atomically moves up to 800 records pending -> inflight; app restart returns stranded inflight records to pending; delivered deletion removes only its outbox record; duplicate UUID/type entries do not multiply; corrupt anchor decode throws a diagnostic error rather than returning a blank anchor.

- [ ] **Step 2: Run Outbox tests and verify RED**

```bash
xcodebuild test -project HealthBridge.xcodeproj -scheme HealthBridge -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:HealthBridgeTests/OutboxTests
```

Expected: FAIL because persistence types do not exist.

- [ ] **Step 3: Implement native SQLite3 schema**

Use three focused tables:

```sql
CREATE TABLE anchors(metric TEXT PRIMARY KEY, archive BLOB NOT NULL, updated_at TEXT NOT NULL);
CREATE TABLE outbox_records(id TEXT PRIMARY KEY, metric TEXT NOT NULL, kind TEXT NOT NULL, payload BLOB NOT NULL, state TEXT NOT NULL CHECK(state IN ('pending','inflight')), batch_id TEXT, queued_at TEXT NOT NULL);
CREATE TABLE diagnostics(key TEXT PRIMARY KEY, value TEXT, updated_at TEXT NOT NULL);
```

Archive `HKQueryAnchor` with `NSKeyedArchiver(requiringSecureCoding: true)` and unarchive with the secure API. `commit(...)` begins an immediate SQLite transaction, writes every addition/deletion, then writes the anchor last, then commits. Any failure rolls back all three effects.

- [ ] **Step 4: Run Outbox tests**

Run Step 2 command. Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add ios/HealthBridge/HealthBridge/Persistence ios/HealthBridge/HealthBridgeTests/OutboxTests.swift
git commit -m "feat: add durable HealthBridge outbox"
```

---

### Task 4: Secure endpoint/token configuration

**Files:**
- Create: `ios/HealthBridge/HealthBridge/Config/SecureConfig.swift`
- Create: `ios/HealthBridge/HealthBridgeTests/SecureConfigTests.swift`

**Interfaces:**
- Produces: `SecureConfig.save(endpoint: URL, token: String) throws`.
- Produces: `SecureConfig.endpoint() -> URL?`.
- Produces: `SecureConfig.token() throws -> String?`.
- Produces: `SecureConfig.clear() throws`.

- [ ] **Step 1: Write failing secure-config tests**

Assert only `https` endpoints are accepted, credential-bearing URLs are rejected, blank/short tokens are rejected, endpoint may live in ordinary app preferences, token is stored through an injected Keychain adapter, and the Keychain add/update request contains `kSecAttrAccessibleAfterFirstUnlock`.

- [ ] **Step 2: Run tests and verify RED**

```bash
xcodebuild test -project HealthBridge.xcodeproj -scheme HealthBridge -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:HealthBridgeTests/SecureConfigTests
```

- [ ] **Step 3: Implement Keychain-backed token storage**

Use a service name scoped to the bundle identifier and a single account key such as `healthkit-ingest-token`. Never conform the token container to `Codable`; never print it in errors. Reject endpoints with user/password, fragments, or non-HTTPS schemes.

- [ ] **Step 4: Run secure-config tests**

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add ios/HealthBridge/HealthBridge/Config ios/HealthBridge/HealthBridgeTests/SecureConfigTests.swift
git commit -m "feat: secure HealthBridge server configuration"
```

---

### Task 5: Foreground uploader and exact delivery semantics

**Files:**
- Create: `ios/HealthBridge/HealthBridge/Network/Uploader.swift`
- Modify: `ios/HealthBridge/HealthBridge/Network/IngestEnvelope.swift`
- Create: `ios/HealthBridge/HealthBridgeTests/UploaderTests.swift`

**Interfaces:**
- Produces: `Uploader.uploadNext() async -> UploadOutcome`.
- Consumes: `Outbox.claimBatch(limit:)`, `SecureConfig`, schema-v1 ingest envelope.
- Produces diagnostics for success, auth failure, validation failure, retryable network/server failure.

- [ ] **Step 1: Write failing URLProtocol-backed tests**

Prove Authorization header format, JSON `schema_version = 1`, stable installation `device_id`, UTC `sent_at`, max 800 records, 200/204 marks delivered, 401/403 retains queue and returns `.authenticationRequired`, 400/422 retains queue and returns `.validationRejected`, timeout/offline/5xx returns records to pending, and response/log strings never contain the bearer token.

- [ ] **Step 2: Run tests and verify RED**

```bash
xcodebuild test -project HealthBridge.xcodeproj -scheme HealthBridge -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:HealthBridgeTests/UploaderTests
```

- [ ] **Step 3: Implement foreground URLSession uploader**

Build `POST <configured-origin>/healthkit/v1/ingest`; do not permit the user to configure an arbitrary path that can silently diverge from the server contract. Installation ID is a random UUID created once and persisted locally; it is not IDFV/IDFA/hardware identity.

Important compatibility gate: until the VPS endpoint accepts deletion records, claim/send ordinary samples only and leave deletion tombstones pending. Do not discard them. This keeps anchor correctness without pretending deletions were delivered.

- [ ] **Step 4: Run uploader tests**

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add ios/HealthBridge/HealthBridge/Network ios/HealthBridge/HealthBridgeTests/UploaderTests.swift
git commit -m "feat: upload queued HealthKit samples"
```

---

### Task 6: HealthKit authorization, 24-hour first read, and manual incremental sync

**Files:**
- Create: `ios/HealthBridge/HealthBridge/Health/HealthKitClient.swift`
- Create: `ios/HealthBridge/HealthBridge/Health/HealthKitManager.swift`
- Create: `ios/HealthBridge/HealthBridge/App/AppModel.swift`
- Modify: `ios/HealthBridge/HealthBridge/UI/ContentView.swift`
- Create: `ios/HealthBridge/HealthBridgeTests/HealthKitManagerTests.swift`

**Interfaces:**
- Produces: `HealthKitManager.requestAuthorization() async throws`.
- Produces: `HealthKitManager.sync(metric: HealthMetric) async throws -> SyncResult`.
- Produces: `HealthKitManager.syncAll() async -> [HealthMetric: Result<SyncResult, Error>]`.
- Consumes: archived anchor from Outbox and commits additions/deletions/new anchor transactionally.

- [ ] **Step 1: Write failing orchestration tests using a fake HealthKit client**

Prove no-anchor query applies `startDate = now - 24h`; existing-anchor query does not reset to history; each metric uses its own anchor; additions/deletions are encoded before commit; outbox commit failure prevents anchor advancement; one metric failure does not suppress the other three; manual sync triggers uploader after durable commit.

- [ ] **Step 2: Run tests and verify RED**

```bash
xcodebuild test -project HealthBridge.xcodeproj -scheme HealthBridge -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:HealthBridgeTests/HealthKitManagerTests
```

- [ ] **Step 3: Implement HealthKit client seam and manager**

`HKHealthStore.requestAuthorization(toShare: [], read: Set(HealthMetric.allCases.map(\.objectType)))`. Use `HKAnchoredObjectQuery` with the stored anchor. On first read only, add a strict 24-hour predicate. Preserve `HKDeletedObject.uuid` tombstones. Call Outbox `commit` exactly once per query result before reporting success.

HealthKit read authorization privacy is intentionally opaque; UI should distinguish request completion from actual data availability and must not claim a type is readable merely because the request sheet completed.

- [ ] **Step 4: Add minimal setup/status UI**

UI fields/actions: HTTPS server origin, bearer token, Save/Test Connection, Request Health Access, Sync Now. Status: pending queue count, last successful upload, last error category, and one row per metric showing last observed/sync event. Do not render raw health samples or token.

- [ ] **Step 5: Run all iOS unit tests**

```bash
xcodebuild test -project HealthBridge.xcodeproj -scheme HealthBridge -destination 'platform=iOS Simulator,name=iPhone 16'
```

Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add ios/HealthBridge
git commit -m "feat: add manual HealthKit incremental sync"
```

---

### Task 7: Observer queries, background delivery, and background upload

**Files:**
- Modify: `ios/HealthBridge/HealthBridge/Health/HealthKitManager.swift`
- Modify: `ios/HealthBridge/HealthBridge/Network/Uploader.swift`
- Modify: `ios/HealthBridge/HealthBridge/App/HealthBridgeApp.swift`
- Modify: `ios/HealthBridge/HealthBridge/App/AppModel.swift`
- Create/Modify: `ios/HealthBridge/HealthBridgeTests/HealthKitManagerTests.swift`
- Create/Modify: `ios/HealthBridge/HealthBridgeTests/UploaderTests.swift`

**Interfaces:**
- Produces: `HealthKitManager.startObservers()` called during app launch.
- Produces: `HealthKitManager.enableBackgroundDelivery()`.
- Produces: background `URLSession` with stable identifier.
- Produces: observer completion handler invoked only after anchored fetch has been scheduled/completed safely.

- [ ] **Step 1: Add failing observer/background tests**

Using the HealthKit seam, assert four observers register on launch, observer callback invokes the corresponding anchored sync, completion handler is always called exactly once, background-delivery enablement is requested per type, and a relaunch first calls `recoverInflight()` before claiming new uploads.

- [ ] **Step 2: Run tests and verify RED**

Run full HealthBridge tests. Expected: FAIL on missing observer/background behavior.

- [ ] **Step 3: Implement observer registration and background delivery**

Register observer queries as early as application launch wiring permits. Request `.immediate` where HealthKit supports it, but treat the value as a request rather than an SLA; do not encode assumptions that steps arrive more frequently than iOS permits.

- [ ] **Step 4: Switch transfer path to background URLSession**

Use `URLSessionConfiguration.background(withIdentifier:)`, `sessionSendsLaunchEvents = true`, and non-discretionary transfer for the small ingest requests. Persist enough batch/request identity in SQLite to reconcile completion callbacks after relaunch. 2xx deletes inflight; all other transport/server outcomes follow Task 5 semantics.

- [ ] **Step 5: Run full iOS tests**

Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add ios/HealthBridge
git commit -m "feat: enable background HealthKit delivery"
```

---

### Task 8: BGAppRefresh fallback and diagnostics

**Files:**
- Modify: `ios/HealthBridge/project.yml`
- Modify: `ios/HealthBridge/HealthBridge/App/HealthBridgeApp.swift`
- Modify: `ios/HealthBridge/HealthBridge/App/AppModel.swift`
- Modify: `ios/HealthBridge/HealthBridge/UI/ContentView.swift`
- Create: `ios/HealthBridge/HealthBridgeTests/BackgroundRefreshTests.swift`

**Interfaces:**
- Produces background task identifier `com.haru.healthbridge.refresh`.
- Produces refresh handler that calls `syncAll`, attempts queued upload, records diagnostic result, and schedules the next fallback refresh.

- [ ] **Step 1: Write failing scheduler/handler tests behind a small scheduler protocol**

Assert launch registration, refresh rescheduling, expiration cancellation, and diagnostic update. The fallback must not be presented as a precise timer.

- [ ] **Step 2: Run tests and verify RED**

Run full HealthBridge tests. Expected: FAIL.

- [ ] **Step 3: Implement BGTaskScheduler fallback**

Add `BGTaskSchedulerPermittedIdentifiers` through XcodeGen Info properties and enable background processing modes required by HealthKit/background fetch. Schedule conservatively; HealthKit observers remain the primary trigger.

- [ ] **Step 4: Run full iOS tests**

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add ios/HealthBridge
git commit -m "feat: add HealthBridge refresh fallback"
```

---

### Task 9: macOS CI build and entitlement verification

**Files:**
- Create: `.github/workflows/healthbridge-ios.yml`
- Create: `ios/HealthBridge/scripts/verify-project.sh`
- Modify: `README.md`

**Interfaces:**
- Produces GitHub Actions artifact `HealthBridge-unsigned.ipa` (ad-hoc signed app packaged as IPA).
- Produces deterministic entitlement check before artifact upload.

- [ ] **Step 1: Write verification script before workflow**

The script must fail unless generated project builds and the built `.app` entitlement dump contains both:

```text
com.apple.developer.healthkit
com.apple.developer.healthkit.background-delivery
```

It must also fail if source/project files contain a value matching the configured token variable name with a non-placeholder secret.

- [ ] **Step 2: Add macOS workflow**

Pin XcodeGen installation/version, run unit tests, build for generic iOS device with ad-hoc signing, run entitlement verification, package `Payload/HealthBridge.app` into an IPA zip, and upload the artifact. Do not use repository secrets for the ingest bearer token.

- [ ] **Step 3: Run workflow and inspect artifact**

Expected: tests green; entitlement script exit 0; IPA artifact present.

- [ ] **Step 4: Commit**

```bash
git add .github/workflows/healthbridge-ios.yml ios/HealthBridge/scripts README.md
git commit -m "ci: build and verify HealthBridge IPA"
```

---

### Task 10: Contract compatibility and real-device acceptance handoff

**Files:**
- Create: `docs/HEALTHBRIDGE-ACCEPTANCE.md`
- Modify: `ios/HealthBridge/HealthBridge/Network/IngestEnvelope.swift`
- Modify tests as required by the final VPS contract.

**Interfaces:**
- Produces a frozen schema-v1 client contract before patched-xtool/Windows installation work begins.
- Produces a real-device checklist with observable pass/fail evidence.

- [ ] **Step 1: Verify client payload against VPS tests/probe**

Compare encoded fixture JSON to `healthkit_ingest.models.parse_batch` expectations: `schema_version`, `device_id`, `sent_at`, sample UUID/type/value/unit/stage/start/end/queued/source/metadata. Add a checked-in non-sensitive JSON fixture consumed by both Swift fixture tests and a Python parser test if needed.

- [ ] **Step 2: Resolve deletion/step-aggregate compatibility before declaring iOS bridge complete**

Deletion tombstones must never be silently discarded. If the VPS hardening endpoint is not yet merged, document them as intentionally retained pending records and block phase-1 completion until the server accepts them. Likewise, raw step samples may upload now, but authoritative user-facing totals remain blocked until HealthKit-consistent aggregate snapshots/query semantics are implemented server-side.

- [ ] **Step 3: Write real-device acceptance document**

Record exact checks: authorization/setup, manual four-type sync, locked-phone heart-rate/HRV/sleep delivery, expected OS-controlled step cadence, offline queue growth, automatic drain after network restoration, app termination/relaunch recovery, duplicate replay, deletion propagation once server support lands, measured sample->queue->VPS latency, and old shortcut-path continuity for 24–48 hours.

- [ ] **Step 4: Run final pre-device verification**

```bash
cd ios/HealthBridge
xcodegen generate
xcodebuild test -project HealthBridge.xcodeproj -scheme HealthBridge -destination 'platform=iOS Simulator,name=iPhone 16'
./scripts/verify-project.sh
```

Expected: PASS. Do not claim real-device/background acceptance from simulator tests.

- [ ] **Step 5: Commit**

```bash
git add ios/HealthBridge docs/HEALTHBRIDGE-ACCEPTANCE.md tests
git commit -m "docs: define HealthBridge device acceptance gate"
```

---

## Plan Self-Review

- **Spec coverage:** Four types, 24-hour first read, independent anchors, durable-before-anchor ordering, manual sync, pending/inflight recovery, Keychain token, foreground and background upload, launch-time observers, background delivery, diagnostic UI, CI build, entitlement verification, and real-device acceptance all map to explicit tasks.
- **Hardening coverage:** HealthKit deletions are captured transactionally and retained until the VPS accepts them; no deletion is silently lost. Native SQLite3 replaces split JSON/UserDefaults durability. BGAppRefresh is a fallback, not a timer guarantee.
- **Step-count caveat:** This app uploads raw step records but does not claim that summing them is authoritative. HealthKit-consistent aggregate snapshots/query semantics remain a server/query contract dependency and are explicitly gated before phase-1 completion.
- **Old-path isolation:** All production app code lives under `ios/HealthBridge/`; no task modifies the existing shortcut health path or `haru_mcp/` gateway.
- **Placeholder scan:** No TBD/TODO/fill-in-later implementation steps are permitted; deferred work is explicitly represented as a completion gate rather than silently omitted.
- **Type consistency:** `HealthMetric`, `WireSample`, `WireDeletion`, `Outbox`, `SecureConfig`, `Uploader`, and `HealthKitManager` interfaces are named once and consumed consistently by later tasks.

## Execution Order After This Plan

1. Execute Tasks 1–6 to obtain a foreground-capable, durable bridge.
2. Execute Tasks 7–9 for background delivery and CI-built IPA.
3. Harden the VPS contract for deletions and authoritative step aggregates before marking Task 10 complete.
4. Then write/execute the separate pinned-xtool + Windows/WSL one-click installation plan.
5. After real-device acceptance, implement the separate read-only `healthkit_query` MCP plan.
